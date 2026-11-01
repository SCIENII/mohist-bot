# mohist-bot

把一台 2012 年的老笔记本改造成 7×24 常驻的私人 QQ 助理，并把改造过程完整开源。

- **硬件**：i5-3230M（2C4T）/ 7.5G 内存 / 无独显 / 无电池
- **系统**：Ubuntu 22.04.5 + Docker 29
- **入口**：QQ（NapCat + OneBot v11）
- **大脑**：DeepSeek（纯云端，本地零推理）
- **成本**：无 GPU、无 API 之外的硬件投入

## 为什么值得看这个仓库

网上关于"把旧电脑变成 AI 助手"的教程已经很多，但几乎都停在"能跑起来"。
这个仓库记录的是**跑起来之后**的部分：

- 一块 128G USB SSD 插上去，Docker 到底该放哪、怎么搬、搬的时候踩什么坑
- 为什么只改 `data-root` 是白改（Docker 29 的镜像其实在 containerd 里）
- 笔记本改服务器时，`/dev/sdX` 编号漂移会怎样毁掉你的数据
- NapCat 重启一次就掉登录，原因和正确姿势
- AstrBot 首次启动打印的密码是错的

`docs/10-踩坑清单.md` 是全文精华。

## 目录

```
├─ deploy/
│  ├─ docker-compose.yml        # napcat + astrbot，端口只绑 127.0.0.1
│  ├─ .env.example
│  └─ napcat/onebot11.example.json
├─ docs/
│  ├─ 10-踩坑清单.md
│  └─ build-log/2026-11-01.md   # 改造当夜的真实时间线
└─ scripts/
   └─ healthcheck.sh            # 在线率与资源自检
```

## 快速开始

```bash
cp deploy/.env.example deploy/.env   # 填 NAPCAT_WEBUI_TOKEN
cd deploy && docker compose up -d
```

然后走两件事：NapCat WebUI 扫码登录 QQ，AstrBot 面板接入模型。

## 硬件真相

这台机器的瓶颈不在 CPU，在**总线**：

```
Bus 002 (USB 2.0, 480Mbps ≈ 40MB/s)
  └─ Hub
      ├─ 931G 机械盘  → /mnt/data
      └─ 119G SSD     → /mnt/ssd  （swap + docker）
```

两块盘挂在同一个 480Mbps 集线器上。把 Docker 搬到 SSD 收益巨大，**不是因为带宽，而是因为随机 IO**：
镜像解压是海量小文件写，机械盘上实测 14MB/分钟，SSD 上直接可用。

## License

MIT
