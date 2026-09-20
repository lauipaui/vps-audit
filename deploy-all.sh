#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INSTALL_URL="https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh"
SSH_CONNECT_TIMEOUT=10
HOSTS=()

green(){ printf '\033[0;32m✓ %s\033[0m\n' "$*"; }
yellow(){ printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
red(){ printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; }
die(){ red "$*"; exit 1; }

usage(){
    cat <<'EOF'
用法：
  ./deploy-all.sh root@1.2.3.4 root@[2001:db8::1]
  ./deploy-all.sh --hosts servers.txt

servers.txt 每行一个 SSH 目标，可包含自定义端口：
  root@1.2.3.4
  root@[2001:db8::1]
  root@server.example.com -p 2222

要求：已配置 SSH 密钥登录；远端为 root，或用户具有免密码 sudo 权限。
EOF
}

load_hosts_file(){
    local file=$1 line
    [[ -r "$file" ]] || die "无法读取主机列表：$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=$(printf '%s' "$line" | xargs)
        [[ -n "$line" ]] && HOSTS+=("$line")
    done <"$file"
}

while (($#)); do
    case "$1" in
        --hosts) [[ $# -ge 2 ]] || die "--hosts 缺少文件名"; load_hosts_file "$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) HOSTS+=("$1"); shift ;;
    esac
done
(("${#HOSTS[@]}" > 0)) || { usage; exit 1; }

read -r -s -p "Telegram Bot Token（仅输入一次，不显示）：" token </dev/tty
echo
read -r -p "Telegram Chat ID：" chat_id </dev/tty
[[ -n "$token" && -n "$chat_id" ]] || die "Token 和 Chat ID 不能为空"
[[ "$token" != *$'\n'* && "$chat_id" != *$'\n'* ]] || die "Telegram 参数格式无效"

config_payload=$(printf 'TELEGRAM_BOT_TOKEN=%q\nTELEGRAM_CHAT_ID=%q\nREPORT_RETENTION_DAYS=30\n' "$token" "$chat_id")
unset token chat_id

success=0
failed=0
failed_hosts=()
for target in "${HOSTS[@]}"; do
    printf '\n==> %s\n' "$target"
    read -r -a target_parts <<<"$target"
    remote_host=""
    remote_port=""
    i=0
    while ((i<${#target_parts[@]})); do
        case "${target_parts[$i]}" in
            -p)
                ((i+1<${#target_parts[@]})) || die "$target 的 -p 缺少端口"
                remote_port=${target_parts[$((i+1))]}
                i=$((i+2))
                ;;
            *)
                [[ -z "$remote_host" ]] || die "$target 包含无法识别的额外参数"
                remote_host=${target_parts[$i]}
                i=$((i+1))
                ;;
        esac
    done
    [[ -n "$remote_host" ]] || die "SSH 目标为空"
    ssh_options=(-o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o StrictHostKeyChecking=accept-new)
    [[ -z "$remote_port" ]] || ssh_options+=(-p "$remote_port")
    if printf '%s' "$config_payload" | ssh \
        "${ssh_options[@]}" \
        "$remote_host" \
        "sudo sh -c 'umask 077; mkdir -p /etc/vps-audit; cat > /etc/vps-audit/telegram.env; chmod 600 /etc/vps-audit/telegram.env' && curl -fsSL '$INSTALL_URL' | sudo bash -s -- --reuse-config"; then
        green "$target 部署成功，测试报告已发送"
        success=$((success+1))
    else
        red "$target 部署失败"
        failed=$((failed+1))
        failed_hosts+=("$target")
    fi
done

printf '\n部署结果：成功 %d，失败 %d，总计 %d\n' "$success" "$failed" "${#HOSTS[@]}"
if ((failed>0)); then
    printf '失败主机：\n'
    printf '  - %s\n' "${failed_hosts[@]}"
    exit 1
fi
