#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_RAW="https://raw.githubusercontent.com/lauipaui/vps-audit/main"
INSTALL_DIR="/usr/local/lib/vps-audit"
RUNNER="/usr/local/sbin/vps-audit-run"
CONFIG_DIR="/etc/vps-audit"
CONFIG_FILE="$CONFIG_DIR/telegram.env"
REPORT_DIR="/var/lib/vps-audit/reports"
LOG_FILE="/var/log/vps-audit.log"
SCHEDULE="30 4 * * 0"
REUSE_CONFIG=false

green(){ printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die(){ printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 或 sudo 运行"
. /etc/os-release
case "${ID:-}" in alpine|debian|ubuntu) ;; *) die "仅支持 Alpine、Debian、Ubuntu" ;; esac

if [ "${1:-}" = "--reuse-config" ]; then
    REUSE_CONFIG=true
    shift
fi

if [ "${1:-}" = "--uninstall" ]; then
    if [ "${ID:-}" = "alpine" ]; then
        sed -i '\|/usr/local/sbin/vps-audit-run|d' /etc/crontabs/root 2>/dev/null || true
    else
        rm -f /etc/cron.d/vps-audit
    fi
    rm -f "$RUNNER"
    yellow "已移除定时任务和运行器；配置及历史报告仍保留在 $CONFIG_DIR 和 $REPORT_DIR"
    exit 0
fi

if [ "${ID:-}" = "alpine" ]; then
    apk add --no-cache bash curl util-linux procps iproute2 findutils coreutils grep gawk >/dev/null
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || rc-service crond restart >/dev/null
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends bash curl util-linux procps iproute2 findutils gawk cron ca-certificates >/dev/null
    systemctl enable --now cron >/dev/null
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$REPORT_DIR"
chmod 700 "$CONFIG_DIR" "$REPORT_DIR"
curl -fsSL "$REPO_RAW/vps-audit.sh" -o "$INSTALL_DIR/vps-audit.sh"
chmod 755 "$INSTALL_DIR/vps-audit.sh"
bash -n "$INSTALL_DIR/vps-audit.sh"

if $REUSE_CONFIG; then
    [[ -r "$CONFIG_FILE" ]] || die "--reuse-config 需要已存在的 $CONFIG_FILE"
fi
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
token="${TELEGRAM_BOT_TOKEN:-}"
chat_id="${TELEGRAM_CHAT_ID:-}"
if [ -z "$token" ]; then
    [[ -r /dev/tty ]] || die "当前没有交互终端且未提供 Telegram 配置；请使用 deploy-all.sh 批量部署"
    read -r -s -p "Telegram Bot Token（输入不可见）：" token </dev/tty
    echo
fi
if [ -z "$chat_id" ]; then
    [[ -r /dev/tty ]] || die "当前没有交互终端且未提供 Telegram 配置；请使用 deploy-all.sh 批量部署"
    read -r -p "Telegram Chat ID：" chat_id </dev/tty
fi
[[ -n "$token" && -n "$chat_id" ]] || die "Token 和 Chat ID 不能为空"
[[ "$token" != *$'\n'* && "$chat_id" != *$'\n'* ]] || die "Telegram 参数格式无效"

{
    printf 'TELEGRAM_BOT_TOKEN=%q\n' "$token"
    printf 'TELEGRAM_CHAT_ID=%q\n' "$chat_id"
    printf 'REPORT_RETENTION_DAYS=%q\n' "30"
} >"$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

cat >"$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
. /etc/vps-audit/telegram.env
REPORT_DIR="/var/lib/vps-audit/reports"
LOG_FILE="/var/log/vps-audit.log"
mkdir -p "$REPORT_DIR"
export VPS_AUDIT_REPORT_DIR="$REPORT_DIR"

before=$(find "$REPORT_DIR" -maxdepth 1 -type f -name 'vps-audit-report-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
/usr/local/lib/vps-audit/vps-audit.sh >>"$LOG_FILE" 2>&1 || audit_rc=$?
report=$(find "$REPORT_DIR" -maxdepth 1 -type f -name 'vps-audit-report-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
[[ -n "$report" && "$report" != "$before" ]] || { echo "$(date -Is) report not generated" >>"$LOG_FILE"; exit 1; }

warn=$(grep -c '^\[警告\]' "$report" || true)
fail=$(grep -c '^\[失败\]' "$report" || true)

send_message() {
  local message="$1" response
  response=$(curl -fsS --retry 2 --connect-timeout 5 --max-time 60 \
    -d "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$message" \
    "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage")
  printf '%s\n' "$response" >>"$LOG_FILE"
  printf '%s' "$response" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' || {
    echo "$(date -Is) Telegram API 拒绝了巡检消息" >>"$LOG_FILE"
    return 1
  }
}

# Telegram 只接收警告和失败项；完整报告仍保存在本机。
if [ "$warn" -gt 0 ] || [ "$fail" -gt 0 ]; then
  header=$(printf '⚠️ VPS 安全巡检发现问题\n主机：%s\n时间：%s\n警告：%s 项｜失败：%s 项' \
    "$(hostname)" "$(date '+%F %T %Z')" "$warn" "$fail")
  chunk="$header"
  while IFS= read -r line; do
    candidate=$(printf '%s\n\n%s' "$chunk" "$line")
    # 按 UTF-8 字节数控制长度，给 Telegram 的 4096 上限留出余量。
    if [ "$(printf '%s' "$candidate" | wc -c)" -gt 3500 ]; then
      send_message "$chunk"
      chunk="$line"
    else
      chunk="$candidate"
    fi
  done < <(grep -E '^\[(警告|失败)\]' "$report" || true)
  [ -z "$chunk" ] || send_message "$chunk"
else
  echo "$(date -Is) 巡检未发现警告或失败，不发送 Telegram 消息" >>"$LOG_FILE"
fi
find "$REPORT_DIR" -type f -name 'vps-audit-report-*.txt' -mtime "+${REPORT_RETENTION_DAYS:-30}" -delete
exit "${audit_rc:-0}"
RUNNER
chmod 700 "$RUNNER"

if [ "${ID:-}" = "alpine" ]; then
    touch /etc/crontabs/root
    sed -i '\|/usr/local/sbin/vps-audit-run|d' /etc/crontabs/root
    echo "$SCHEDULE /usr/local/sbin/vps-audit-run" >>/etc/crontabs/root
    rc-service crond restart >/dev/null
else
    cat >/etc/cron.d/vps-audit <<EOF
$SCHEDULE root /usr/local/sbin/vps-audit-run
EOF
    chmod 644 /etc/cron.d/vps-audit
fi

green "已安装：每周日 04:30 自动巡检，仅将警告和失败项以中文文本发送到 Telegram"
echo "正在验证 Telegram 配置……"
telegram_check=$(curl -fsS --retry 2 --connect-timeout 5 --max-time 30 \
  -d "chat_id=$chat_id" \
  "https://api.telegram.org/bot$token/getChat") || die "Telegram 连接失败，请检查网络、Token 和 Chat ID"
printf '%s' "$telegram_check" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' || die "Telegram 配置验证失败，请检查 Token、Chat ID 以及 Bot 的群组权限"
green "Telegram 配置验证成功"
echo "正在执行首次巡检……"
if "$RUNNER"; then
    green "首次巡检完成；仅在存在警告或失败项时发送 Telegram 消息"
else
    die "测试失败，请检查 $LOG_FILE"
fi
