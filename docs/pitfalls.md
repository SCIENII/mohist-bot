# 踩坑清单

按遇到顺序排列。每条都注明**症状 → 原因 → 正确做法**。

---

## 1. 只改 `data-root`，镜像速度一点没变

**症状**：把 `/etc/docker/daemon.json` 的 `data-root` 从机械盘改到 SSD，`docker pull` 依然慢到 14MB/分钟。

**原因**：Docker 29 默认使用 containerd 镜像存储。镜像内容存在 **containerd 的根目录**，不是 `data-root`。这台机器上：

```
/var/lib/containerd  →  符号链接  →  /mnt/data/containerd    (14.8G)
```

`data-root` 只有 5.9G（volumes、容器元数据），镜像的 14.8G 全在另一边。

**正确做法**：两处都要搬。

```bash
# 1. 停服务
systemctl stop docker docker.socket containerd
# 2. 两份都复制（保留 hardlink / xattr / ACL）
rsync -aHAX --numeric-ids /mnt/data/docker/     /mnt/ssd/docker/
rsync -aHAX --numeric-ids /mnt/data/containerd/ /mnt/ssd/containerd/
# 3. 改 data-root + 重指软链接
#    daemon.json: "data-root": "/mnt/ssd/docker"
ln -sfn /mnt/ssd/containerd /var/lib/containerd
```

验证：`docker info --format '{{.DockerRootDir}}'` 和 `docker images` 数量对得上。

---

## 2. `fstab` 写 `/dev/sdb`，插了块新盘就可能挂错

**症状**：本来 `/mnt/data` 是 sdb，插上 USB SSD 后重新枚举，`sdb` 可能变成别的盘。

**原因**：`/dev/sdX` 编号按枚举顺序分配，不稳定。

**正确做法**：全部换 UUID。

```bash
blkid -s UUID -o value /dev/sdb
# fstab:
UUID=xxxx  /mnt/data  ext4  defaults,noatime  0 2
```

顺带加一条保证挂载顺序，否则 Docker 可能先于挂载启动，把数据写进空挂载点、撑爆根盘：

```ini
# /etc/systemd/system/docker.service.d/mounts.conf
[Unit]
RequiresMountsFor=/mnt/ssd /mnt/data
```

---

## 3. 容器一停，QQ 就要重新扫码

**症状**：重启或重建 NapCat 容器后，`qrcode.png` 重新出现，QQ 要重新登录。

**原因（三层，逐层排查出来的）**：

1. `docker stop` 默认只给 10 秒，超时即 SIGKILL。QQ NT 客户端来不及把会话写回磁盘。
2. 容器**重建**（`docker compose up -d` 只要配置有变化就会重建）时 hostname 变成新的容器 ID，QQ 把它当成一台新设备。
3. 最根本的一层：NapCat 的 entrypoint 是

```bash
if [ -n "${ACCOUNT}" ]; then
    gosu napcat /opt/QQ/qq --no-sandbox -q $ACCOUNT
fi
```

没设 `ACCOUNT` 时根本不会尝试快速登录，永远落到扫码界面。

**正确做法**（三条一起上）：

```yaml
environment:
  ACCOUNT: "你的机器人QQ号"   # 走 -q 快速登录
hostname: napcat                # 固定设备身份
mac_address: "02:42:ac:14:00:03"
stop_grace_period: 60s          # 给 QQ 落盘的时间
```

**实测结果**：改完之后重启整机，84 秒后容器全部起来、`qrcode.png` 不存在、OneBot 连接自动建立，**不需要扫码**。

**注意**：配置改完的那一次重建仍然需要扫一次码。因为快速登录用的令牌是在"登录状态"下写出来的，先有登录才有令牌。

---

## 4. AstrBot 首次启动打印的密码是错的

**症状**：日志里打印了

```
Username: astrbot
Password: 3nJ8xQ...（22 位随机串）
```

输入提示"密码错误"。

**原因**：AstrBot 4.29.4 首启打印的明文与写入 `cmd_config.json` 的 pbkdf2 哈希对不上。
可以用 md5 自证：打印值的 md5 ≠ 配置里的 `password` 字段。

**正确做法**：直接用容器内 CLI 重置。

```bash
printf '新密码\n新密码\n' | docker exec -i astrbot astrbot password
docker restart astrbot
```

验证不要靠肉眼，直接打 API：

```bash
curl -s -X POST http://127.0.0.1:6185/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"astrbot","password":"新密码"}'
# 期望 {"status":"ok", ... "token":"..."}
```

---

## 5. `admins_id` 的格式

**症状**：以为要写 `qq:123456789` 或 UMO（unified_msg_origin）。

**原因**：源码里的判据是

```python
str(event.get_sender_id()) == admin_id
```

**正确做法**：写纯 QQ 号字符串。

```json
"admins_id": ["astrbot", "123456789"]
```

改完要重启 AstrBot（配置在启动时读入）。

---

## 6. `aiocqhttp` 平台配置的字段名不是 `host` / `port`

**症状**：按直觉写 `{"host": "0.0.0.0", "port": 6199}`，适配器起不来。

**原因**：AstrBot 的 aiocqhttp 适配器固定 `use_ws_reverse=True`（它做服务端，等 NapCat 连进来），读的键是：

```python
self.host = platform_config["ws_reverse_host"]
self.port = platform_config["ws_reverse_port"]
```

**正确做法**：

```json
"platform": [{
  "id": "qq",
  "type": "aiocqhttp",
  "enable": true,
  "ws_reverse_host": "0.0.0.0",
  "ws_reverse_port": 6199,
  "ws_reverse_token": ""
}]
```

## 6.1 NapCat 侧对应写 `websocketClients`

`config/onebot11_<QQ号>.json`：

```json
"network": {
  "websocketClients": [{
    "enable": true,
    "name": "astrbot",
    "url": "ws://astrbot:6199/ws",
    "messagePostFormat": "array",
    "token": "",
    "heartInterval": 30000,
    "reconnectInterval": 30000
  }]
}
```

两个容器要在同一个 docker network 里，`astrbot` 这个主机名才解析得了。

---

## 7. 面板端口不要绑 `0.0.0.0`

NapCat 的 6099 是**你 QQ 号的控制台**：能打开它的人可以接管账号、看消息。
AstrBot 的 6185 同理。

**正确做法**：compose 里绑 `127.0.0.1`，需要时用 SSH 本地转发。

```yaml
ports:
  - "127.0.0.1:6099:6099"
```

```bash
ssh -p <ssh端口> -L 16099:127.0.0.1:6099 -L 16185:127.0.0.1:6185 <user>@<host>
```

---

## 8. 7.5G 内存 + 0 swap = OOM 直接杀进程

**正确做法**：两层。

| 层 | 设备 | 大小 | 优先级 |
|---|---|---|---|
| zram（zstd 压缩） | `/dev/zram0` | 3G | 100 |
| swap 分区 | SSD | 8G | 10 |

```bash
apt install zram-tools
# /etc/default/zramswap: ALGO=zstd PERCENT=40 PRIORITY=100
```

磁盘 swap 放 SSD 而不是机械盘：换页是随机读，机械盘上 200 IOPS 会直接把系统拖死。

---

## 9. 整机只有 USB 2.0，且共用一条 480Mbps 总线

新旧两块盘挂在**同一个 hub** 上，swap、Docker、数据盘互相抢带宽。

**推论**：
- SSD 的收益来自**随机 IO 延迟**，不是吞吐
- 不要指望在这台机器上跑本地大模型
- 大文件迁移时别同时跑其他 IO 密集任务

---

## 附：几个调试方法（比结论更有用）

**日志里有 emoji 导致输出炸掉**：把输出流过滤成可打印 ASCII。

```bash
docker logs astrbot 2>&1 | tr -cd '\11\12\15\40-\176'
```

**判断容器间到底连没连上**：进目标容器网络命名空间看 socket，比读日志可靠。

```bash
nsenter -t $(docker inspect -f '{{.State.Pid}}' astrbot) -n ss -tn | grep 6199
# ESTAB 172.20.0.2:6199 ← 172.20.0.3:55528  → 通了
```

**"服务没工作"要有可证伪的信号**：不要看文件在不在、日志有没有报错。
这次真正的判据是数据库里 `provider_stats` 的行数从 0 变成 36。

**脚本变量跨块丢失**：把多步操作写进一个脚本文件整体 `bash` 执行，别依赖交互式会话里的变量。
（这次就因为 `$DEV` 在下一块是空的，擦盘命令全部空跑——幸运的是空跑，不是擦错盘。）
