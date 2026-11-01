#!/usr/bin/env bash
# mohist-bot 自检：容器、内存、磁盘、以及"bot 是否真的在工作"
# 用法: ./healthcheck.sh [compose目录]
set -uo pipefail

COMPOSE_DIR="${1:-$(dirname "$0")/../deploy}"
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }

check_container() {
  local name=$1 state
  state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  if [[ "$state" == "running" ]]; then
    grn "  ok   $name ($(docker inspect "$name" --format '{{.State.StartedAt}}' | cut -c1-19))"
  else
    red "  FAIL $name -> $state"
    FAIL=1
  fi
}

echo "== 容器 =="
check_container napcat
check_container astrbot

echo "== 资源 =="
free -m | awk 'NR==2{printf "  mem  used %dM / %dM\n", $3, $2}'
swapon --show=NAME,SIZE,USED --noheadings | sed 's/^/  swap /'
df -h /mnt/ssd 2>/dev/null | awk 'NR==2{printf "  ssd  used %s / %s (%s)\n", $3, $2, $5}'
df -h / | awk 'NR==2{printf "  root used %s / %s (%s)\n", $3, $2, $5}'

echo "== bot 是否真的在工作 =="
ROWS=$(docker exec -i astrbot python - <<'PY' 2>/dev/null
import sqlite3
try:
    c = sqlite3.connect('/AstrBot/data/data_v4.db')
    print(c.execute('select count(*) from provider_stats').fetchone()[0])
except Exception:
    print(-1)
PY
)
if [[ "${ROWS:-0}" -gt 0 ]]; then
  grn "  ok   provider_stats = $ROWS 次调用"
else
  ylw "  warn provider_stats = ${ROWS:-0}（从没成功调过模型，先检查 QQ 是否登录）"
fi

echo "== 通道 =="
# 不用 nsenter / ss（需要 root，且容器内未必有 ss）。
# 直接在 astrbot 容器里读 /proc/net/tcp，找本地端口 6199(0x1837) 且状态 01(ESTAB) 的连接。
ESTAB=$(docker exec -i astrbot python - <<'PY' 2>/dev/null
n = 0
for line in open('/proc/net/tcp'):
    f = line.split()
    if len(f) < 4 or f[0] == 'sl':
        continue
    try:
        port = int(f[1].split(':')[1], 16)
    except (IndexError, ValueError):
        continue
    if port == 6199 and f[3] == '01':
        n += 1
print(n)
PY
)
if [[ "${ESTAB:-0}" -gt 0 ]]; then
  grn "  ok   napcat -> astrbot:6199 已连接 (${ESTAB} 条)"
else
  red "  FAIL 没有到 6199 的连接（NapCat 掉登录或未连）"
  FAIL=1
fi

echo
[[ "$FAIL" -eq 0 ]] && grn "ALL GOOD" || red "HAS FAILURES"
exit "$FAIL"
