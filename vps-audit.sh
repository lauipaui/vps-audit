#!/usr/bin/env bash

VPS_AUDIT_VERSION="0.4.0-zh"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# -----------------------------------------
# Configuration
# -----------------------------------------

# Static Directory/File Variables
OS_RELEASE_FILE="/etc/os-release"
REBOOT_REQUIRED_FILE="/var/run/reboot-required"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
AUTH_LOG_FILE="/var/log/auth.log"
SUDOERS_FILE="/etc/sudoers"
PASSWORD_QUALITY_CONF="/etc/security/pwquality.conf"
FAIL2BAN_CONFIG_DIR="/etc/fail2ban"

# Resource Usage Thresholds (Disk/Memory/CPU %)
RESOURCE_WARN=50  # WARN if usage is >= 50%
RESOURCE_FAIL=80  # FAIL if usage is >= 80%

# Running Services Thresholds
SERVICES_WARN=20  # WARN if >= 20 services are running
SERVICES_FAIL=40  # FAIL if >= 40 services are running

# Failed Logins Thresholds (Count)
LOGINS_WARN=10    # WARN if >= 10 failed logins
LOGINS_FAIL=50    # FAIL if >= 50 failed logins

# Open Ports Thresholds (Count)
OPEN_PORTS_WARN=10  # WARN if >= 10 open ports
OPEN_PORTS_FAIL=20  # FAIL if >= 20 open ports

# Password Policy
PASSWORD_MINLEN=12  # PASS if pwquality minlen is >= this value

# Report Output Configuration

# Directory and File Naming
DEFAULT_REPORT_DIR="${VPS_AUDIT_REPORT_DIR:-.}"   # Where reports will be saved
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILENAME="vps-audit-report-${TIMESTAMP}.txt"
REPORT_FILE="${DEFAULT_REPORT_DIR}/${REPORT_FILENAME}"

# Distribution compatibility
# shellcheck disable=SC1091
. "$OS_RELEASE_FILE"
OS_ID="${ID:-unknown}"
if [ "$OS_ID" = "alpine" ]; then
    AUTH_LOG_FILE="/var/log/messages"
fi

# Ownership
ENABLE_CHOWN=false  # Whether to chown the report (and the report dir, if created)
# Defaults to the user who invoked sudo, so reports are not left owned by root.
CHOWN_USER="${SUDO_USER:-$(id -un)}"
REPORT_CHOWN_OWNER="${CHOWN_USER}:$(id -gn "$CHOWN_USER" 2>/dev/null || id -gn)"

# Ensure report directory exists
if [ ! -d "$DEFAULT_REPORT_DIR" ]; then
    if mkdir -p "$DEFAULT_REPORT_DIR"; then
        # Apply ownership only when directory was created
        if [ "$ENABLE_CHOWN" = true ]; then
            if ! chown "$REPORT_CHOWN_OWNER" "$DEFAULT_REPORT_DIR"; then
                echo -e "${RED}[错误] 无法修改 ${DEFAULT_REPORT_DIR} 的所有者。${NC}" >&2
            fi
        fi
    else
        echo -e "${RED}[错误] 无法创建目录 ${DEFAULT_REPORT_DIR}，改用当前目录。${NC}" >&2
        DEFAULT_REPORT_DIR="."
        REPORT_FILE="./${REPORT_FILENAME}"
        ENABLE_CHOWN=false
    fi
fi

# -----------------------------------------
# End Configuration
# -----------------------------------------

print_header() {
    local header="$1"
    echo -e "\n${BLUE}${BOLD}$header${NC}"
    echo -e "\n$header" >> "$REPORT_FILE"
    echo "================================" >> "$REPORT_FILE"
}

print_info() {
    local label="$1"
    local value="$2"
    echo -e "${BOLD}$label:${NC} $value"
    echo "$label: $value" >> "$REPORT_FILE"
}

# Start the audit
echo -e "${BLUE}${BOLD}VPS 安全巡检工具 v${VPS_AUDIT_VERSION}${NC}"
echo -e "${GRAY}https://nuverlabs.com/vps-audit${NC}"
echo -e "${GRAY}巡检开始时间：$(date '+%F %T %Z')${NC}\n"

echo "VPS 安全巡检工具 v${VPS_AUDIT_VERSION}" > "$REPORT_FILE"
echo "https://nuverlabs.com/vps-audit" >> "$REPORT_FILE"
echo "巡检开始时间：$(date '+%F %T %Z')" >> "$REPORT_FILE"
echo "================================" >> "$REPORT_FILE"

# System Information Section
print_header "系统信息"

# Get system information
OS_INFO="${PRETTY_NAME:-${NAME:-$OS_ID}}"
KERNEL_VERSION=$(uname -r)
HOSTNAME=$HOSTNAME
UPTIME=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);printf "%d 天 %d 小时 %d 分钟",d,h,m}' /proc/uptime)
UPTIME_SINCE=$(uptime -s 2>/dev/null || echo "未知")
CPU_INFO=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')
CPU_CORES=$(nproc)
TOTAL_MEM=$(free -h | awk '/^Mem:/ {print $2}')
TOTAL_DISK=$(df -h / | awk 'NR==2 {print $2}')
PUBLIC_IP=$(curl -4fsS --connect-timeout 3 --max-time 8 https://api.ipify.org 2>/dev/null || curl -6fsS --connect-timeout 3 --max-time 8 https://api64.ipify.org 2>/dev/null || echo "无法获取")
LOAD_AVERAGE=$(uptime | awk -F'load average:' '{print $2}' | xargs)

# Print system information
print_info "主机名" "$HOSTNAME"
print_info "操作系统" "$OS_INFO"
print_info "内核版本" "$KERNEL_VERSION"
print_info "运行时间" "$UPTIME（启动于 $UPTIME_SINCE）"
print_info "CPU 型号" "$CPU_INFO"
print_info "CPU 核心数" "$CPU_CORES"
print_info "内存总量" "$TOTAL_MEM"
print_info "根分区总容量" "$TOTAL_DISK"
print_info "公网 IP" "$PUBLIC_IP"
print_info "系统负载" "$LOAD_AVERAGE"

echo "" >> "$REPORT_FILE"

# Security Audit Section
print_header "安全巡检详细结果"

# Function to check and report with three states
check_security() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    
    case $status in
        "PASS")
            echo -e "${GREEN}[通过]${NC} $test_name ${GRAY}- $message${NC}"
            echo "[通过] $test_name - $message" >> "$REPORT_FILE"
            ;;
        "WARN")
            echo -e "${YELLOW}[警告]${NC} $test_name ${GRAY}- $message${NC}"
            echo "[警告] $test_name - $message" >> "$REPORT_FILE"
            ;;
        "FAIL")
            echo -e "${RED}[失败]${NC} $test_name ${GRAY}- $message${NC}"
            echo "[失败] $test_name - $message" >> "$REPORT_FILE"
            ;;
    esac
    echo "" >> "$REPORT_FILE"
}

# Check system uptime
UPTIME=$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);printf "%d 天 %d 小时 %d 分钟",d,h,m}' /proc/uptime)
UPTIME_SINCE=$(uptime -s 2>/dev/null || echo "未知")
echo -e "\n系统运行时间：" >> "$REPORT_FILE"
echo "已运行：$UPTIME" >> "$REPORT_FILE"
echo "启动时间：$UPTIME_SINCE" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo -e "系统运行时间：$UPTIME（启动于 $UPTIME_SINCE）"

# Check if system requires restart
if [ -f "$REBOOT_REQUIRED_FILE" ]; then
    check_security "系统重启" "WARN" "系统需要重启以完成更新"
else
    check_security "系统重启" "PASS" "当前不需要重启"
fi

# Prefer sshd's fully resolved configuration. This correctly handles distro
# defaults and Include drop-ins, which simple grep-based checks often misread.
SSH_EFFECTIVE=$(sshd -T 2>/dev/null || true)
SSH_CONFIG_OVERRIDES=$(grep "^Include" "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}')
SSH_PASSWORD=$(printf '%s\n' "$SSH_EFFECTIVE" | awk '$1=="passwordauthentication"{print $2;exit}')

# Check SSH root login (handle both main config and overrides if they exist)
if [ -n "$SSH_EFFECTIVE" ]; then
    SSH_ROOT=$(printf '%s\n' "$SSH_EFFECTIVE" | awk '$1=="permitrootlogin"{print $2;exit}')
elif [ -n "$SSH_CONFIG_OVERRIDES" ] && [ -d "$(dirname "$SSH_CONFIG_OVERRIDES")" ]; then
    SSH_ROOT=$(grep "^PermitRootLogin" $SSH_CONFIG_OVERRIDES "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
else
    SSH_ROOT=$(grep "^PermitRootLogin" "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
fi
if [ -z "$SSH_ROOT" ]; then
    SSH_ROOT="prohibit-password"
fi
if [ "$SSH_ROOT" = "no" ]; then
    check_security "SSH Root 登录" "PASS" "SSH 配置已禁止 root 登录"
elif [ "$SSH_ROOT" = "prohibit-password" ] || [ "$SSH_ROOT" = "without-password" ] || [ "$SSH_ROOT" = "forced-commands-only" ]; then
    check_security "SSH Root 登录" "PASS" "已禁止 root 密码登录，仅允许密钥方式（$SSH_ROOT）"
else
    if [ "$SSH_PASSWORD" = "no" ]; then
        check_security "SSH Root 登录" "WARN" "允许 root 使用密钥登录；若无必要，建议完全禁止 root 远程登录"
    else
        check_security "SSH Root 登录" "FAIL" "root 登录和密码认证均已开启，至少应禁止 root 使用密码登录"
    fi
fi

# Check SSH password authentication (handle both main config and overrides if they exist)
if [ -z "$SSH_PASSWORD" ] && [ -n "$SSH_CONFIG_OVERRIDES" ] && [ -d "$(dirname "$SSH_CONFIG_OVERRIDES")" ]; then
    SSH_PASSWORD=$(grep "^PasswordAuthentication" $SSH_CONFIG_OVERRIDES "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
elif [ -z "$SSH_PASSWORD" ]; then
    SSH_PASSWORD=$(grep "^PasswordAuthentication" "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
fi
if [ -z "$SSH_PASSWORD" ]; then
    SSH_PASSWORD="yes"
fi
if [ "$SSH_PASSWORD" = "no" ]; then
    check_security "SSH 密码认证" "PASS" "密码认证已关闭，仅允许密钥认证"
else
    check_security "SSH 密码认证" "FAIL" "密码认证已开启，建议改为仅允许密钥认证"
fi

# Check for default/unsecure SSH ports 
SSH_PORT=""
if [ -n "$SSH_EFFECTIVE" ]; then
    SSH_PORT=$(printf '%s\n' "$SSH_EFFECTIVE" | awk '$1=="port"{print $2;exit}')
elif [ -n "$SSH_CONFIG_OVERRIDES" ] && [ -d "$(dirname "$SSH_CONFIG_OVERRIDES")" ]; then
    SSH_PORT=$(grep "^Port" $SSH_CONFIG_OVERRIDES "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
else
    SSH_PORT=$(grep "^Port" "$SSH_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}')
fi
if [ -z "$SSH_PORT" ]; then
    SSH_PORT="22"
fi

if [ "$SSH_PORT" = "22" ]; then
    check_security "SSH 端口" "WARN" "正在使用默认端口 22；可改用非默认端口以减少自动扫描噪声"
else
    check_security "SSH 端口" "PASS" "正在使用非默认端口 $SSH_PORT；端口号本身不能替代真正的安全措施"
fi

# Check Firewall Status
check_firewall_status() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -qw "active"; then
            check_security "防火墙状态（UFW）" "PASS" "UFW 已启用并正在保护系统"
        else
            check_security "防火墙状态（UFW）" "FAIL" "UFW 未启用，系统可能暴露于网络攻击"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            check_security "防火墙状态（firewalld）" "PASS" "firewalld 已启用并正在保护系统"
        else
            check_security "防火墙状态（firewalld）" "FAIL" "firewalld 未启用，系统可能暴露于网络攻击"
        fi
    elif command -v nft >/dev/null 2>&1; then
        if nft list ruleset 2>/dev/null | grep -Eq 'hook input|policy (drop|reject)'; then
            check_security "防火墙状态（nftables）" "PASS" "nftables 入站规则已生效"
        else
            check_security "防火墙状态（nftables）" "FAIL" "未发现有效的 nftables 入站规则，系统可能处于暴露状态"
        fi
    elif command -v iptables >/dev/null 2>&1; then
        IPT_POLICY=$(iptables -S INPUT 2>/dev/null | awk 'NR==1{print $3}')
        IPT_RULES=$(iptables -S INPUT 2>/dev/null | awk 'NR>1{n++} END{print n+0}')
        if [ "$IPT_POLICY" = "DROP" ] || [ "$IPT_POLICY" = "REJECT" ] || [ "$IPT_RULES" -gt 0 ]; then
            check_security "防火墙状态（iptables）" "PASS" "iptables INPUT 策略或规则已生效（策略=$IPT_POLICY，规则数=$IPT_RULES）"
        else
            check_security "防火墙状态（iptables）" "FAIL" "iptables INPUT 接受全部流量且没有过滤规则"
        fi
    else
        check_security "防火墙状态" "FAIL" "系统未安装可识别的防火墙工具"
    fi
}

# Firewall check
check_firewall_status

# Check for unattended upgrades
if [ "$OS_ID" = "alpine" ]; then
    if [ -x /etc/periodic/daily/apk-autoupdate ] || [ -x /etc/periodic/daily/apk-upgrade ]; then
        check_security "自动更新" "PASS" "已配置 Alpine APK 周期更新任务"
    else
        check_security "自动更新" "WARN" "未检测到 Alpine APK 周期升级任务"
    fi
elif dpkg -l 2>/dev/null | grep -q "unattended-upgrades"; then
    check_security "自动安全更新" "PASS" "已配置自动安全更新"
else
    check_security "自动安全更新" "FAIL" "未配置自动安全更新，系统可能错过重要补丁"
fi

# Check Intrusion Prevention Systems (Fail2ban or CrowdSec)
IPS_INSTALLED=0
IPS_ACTIVE=0

if { [ "$OS_ID" = "alpine" ] && apk info -e fail2ban >/dev/null 2>&1; } || dpkg -l fail2ban 2>/dev/null | grep -q '^ii'; then
    IPS_INSTALLED=1
    if [ "$OS_ID" = "alpine" ]; then
        rc-service fail2ban status >/dev/null 2>&1 && IPS_ACTIVE=1
    else
        systemctl is-active fail2ban >/dev/null 2>&1 && IPS_ACTIVE=1
    fi
fi

# Check docker container running fail2ban
if command -v docker >/dev/null 2>&1; then
    if { [ "$OS_ID" = "alpine" ] && rc-service docker status >/dev/null 2>&1; } || { [ "$OS_ID" != "alpine" ] && systemctl is-active --quiet docker; }; then
        if docker ps -a | awk '{print $2}' | grep "fail2ban" >/dev/null 2>&1; then
            IPS_INSTALLED=1
            docker ps | grep -q "fail2ban" && IPS_ACTIVE=1
        fi
    else
        check_security "入侵防护" "WARN" "Docker 已安装但未运行，无法检查 Fail2ban 容器"
    fi
fi

if { [ "$OS_ID" = "alpine" ] && apk info -e crowdsec >/dev/null 2>&1; } || dpkg -l crowdsec 2>/dev/null | grep -q '^ii'; then
    IPS_INSTALLED=1
    if [ "$OS_ID" = "alpine" ]; then rc-service crowdsec status >/dev/null 2>&1 && IPS_ACTIVE=1; else systemctl is-active crowdsec >/dev/null 2>&1 && IPS_ACTIVE=1; fi
fi

# Check docker container running crowdsec
if command -v docker >/dev/null 2>&1; then
    if { [ "$OS_ID" = "alpine" ] && rc-service docker status >/dev/null 2>&1; } || { [ "$OS_ID" != "alpine" ] && systemctl is-active --quiet docker; }; then
        if docker ps -a | awk '{print $2}' | grep "crowdsec" >/dev/null 2>&1; then
            IPS_INSTALLED=1
            docker ps | grep -q "crowdsec" && IPS_ACTIVE=1
        fi
    else
        check_security "入侵防护" "WARN" "Docker 已安装但未运行，无法检查 CrowdSec 容器"
    fi
fi

case "$IPS_INSTALLED$IPS_ACTIVE" in
    "11") check_security "入侵防护" "PASS" "Fail2ban 或 CrowdSec 已安装并正在运行" ;;
    "10") check_security "入侵防护" "WARN" "Fail2ban 或 CrowdSec 已安装但未运行" ;;
    *)    check_security "入侵防护" "FAIL" "未安装入侵防护系统（Fail2ban 或 CrowdSec）" ;;
esac

# Resolve a port token to a number. Accepts a numeric port or a service name
# such as "ssh", which fail2ban uses by default.
resolve_port_token() {
    local token="$1"
    if [[ "$token" =~ ^[0-9]+$ ]]; then
        echo "$token"
    else
        getent services "$token" 2>/dev/null | head -1 | awk '{print $2}' | cut -d'/' -f1
    fi
}

# Test whether a fail2ban port list ("ssh", "2022", "ssh,2222", "0:65535")
# covers a specific port number.
port_list_contains() {
    local list="$1" target="$2" token start end resolved
    local IFS=','
    for token in $list; do
        token="${token//[[:space:]]/}"
        [ -z "$token" ] && continue
        if [[ "$token" == *:* ]]; then
            start=$(resolve_port_token "${token%%:*}")
            end=$(resolve_port_token "${token##*:}")
            if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
                if [ "$target" -ge "$start" ] && [ "$target" -le "$end" ]; then
                    return 0
                fi
            fi
        else
            resolved=$(resolve_port_token "$token")
            [ "$resolved" = "$target" ] && return 0
        fi
    done
    return 1
}

# Read an option from a jail section, honouring fail2ban's file precedence:
# jail.conf, then jail.d/*.conf, then jail.local, then jail.d/*.local (last wins).
get_jail_option() {
    local section="$1" option="$2" file value result=""
    for file in "$FAIL2BAN_CONFIG_DIR/jail.conf" \
                "$FAIL2BAN_CONFIG_DIR"/jail.d/*.conf \
                "$FAIL2BAN_CONFIG_DIR/jail.local" \
                "$FAIL2BAN_CONFIG_DIR"/jail.d/*.local; do
        [ -f "$file" ] || continue
        value=$(awk -v sect="$section" -v opt="$option" '
            $0 ~ /^[[:space:]]*\[/ {
                in_sect = ($0 ~ "^[[:space:]]*\\[" sect "\\][[:space:]]*$")
                next
            }
            in_sect && $0 ~ "^[[:space:]]*" opt "[[:space:]]*=" {
                sub(/^[^=]*=[[:space:]]*/, "")
                sub(/[[:space:]]+$/, "")
                val = $0
            }
            END { if (val != "") print val }
        ' "$file" 2>/dev/null)
        [ -n "$value" ] && result="$value"
    done
    echo "$result"
}

# Check that fail2ban's SSH jail actually covers the port sshd listens on.
# The [sshd] jail inherits "port = ssh" (22) from jail.conf. When sshd runs on a
# non-standard port, the generated firewall rule still targets 22, so every ban is
# a silent no-op - while fail2ban keeps reporting the bans as successful.
check_fail2ban_port_alignment() {
    # Only meaningful when fail2ban itself is present.
    if ! command -v fail2ban-client >/dev/null 2>&1 || [ ! -d "$FAIL2BAN_CONFIG_DIR" ]; then
        return
    fi

    # Prefer sshd's own resolved config over grepping the files by hand.
    local ssh_effective_port
    ssh_effective_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    [ -z "$ssh_effective_port" ] && ssh_effective_port="$SSH_PORT"
    if ! [[ "$ssh_effective_port" =~ ^[0-9]+$ ]]; then
        check_security "Fail2ban 端口匹配" "WARN" "无法确定 SSH 实际端口，请手动核对 Fail2ban jail 的端口"
        return
    fi

    local jail_enabled jail_port jail_banaction
    jail_enabled=$(get_jail_option "sshd" "enabled")
    jail_port=$(get_jail_option "sshd" "port")
    jail_banaction=$(get_jail_option "sshd" "banaction")
    [ -z "$jail_banaction" ] && jail_banaction=$(get_jail_option "DEFAULT" "banaction")
    [ -z "$jail_port" ] && jail_port="ssh"

    if [ "$jail_enabled" != "true" ]; then
        check_security "Fail2ban 端口匹配" "WARN" "Fail2ban 的 [sshd] jail 未启用，SSH 暴力尝试不会被自动封禁"
        return
    fi

    # An allports banaction blocks every port, so the jail port is irrelevant.
    if [[ "$jail_banaction" == *allports* ]]; then
        check_security "Fail2ban 端口匹配" "PASS" "[sshd] jail 会封禁全部端口（banaction=$jail_banaction），已覆盖 SSH 端口 $ssh_effective_port"
        return
    fi

    if port_list_contains "$jail_port" "$ssh_effective_port"; then
        check_security "Fail2ban 端口匹配" "PASS" "Fail2ban 的 [sshd] jail 已覆盖当前 SSH 端口 $ssh_effective_port"
    else
        check_security "Fail2ban 端口匹配" "FAIL" "[sshd] jail 封禁端口 '$jail_port'，但 SSH 监听 $ssh_effective_port，封禁实际无效。请在 $FAIL2BAN_CONFIG_DIR/jail.local 中设置 'port = $ssh_effective_port'，或使用 banaction = nftables[type=allports]"
    fi
}

# Fail2ban jail port alignment check
check_fail2ban_port_alignment

# Check failed login attempts. Prefer a bounded 24-hour journal window so a
# months-old auth.log does not look like an attack currently in progress.
FAILED_LOGIN_WINDOW="最近 24 小时"
if command -v journalctl >/dev/null 2>&1; then
    FAILED_LOGINS=$(journalctl --since "24 hours ago" -u ssh -u sshd 2>/dev/null | grep -c "Failed password" || true)
elif [ -f "$AUTH_LOG_FILE" ]; then
    FAILED_LOGIN_WINDOW="当前认证日志"
    FAILED_LOGINS=$(grep -c "Failed password" "$AUTH_LOG_FILE" 2>/dev/null || echo 0)

# if debian version > 10, info in journalctl
elif [ "$OS_ID" = "alpine" ] && command -v logread >/dev/null 2>&1; then
    FAILED_LOGIN_WINDOW="当前系统日志缓冲区"
    FAILED_LOGINS=$(logread 2>/dev/null | grep -c "Failed password" || echo 0)
elif [ -f "/etc/debian_version" ]; then
    DEB_VERSION=$(cut -d'.' -f1 /etc/debian_version)
    if command -v journalctl >/dev/null 2>&1 && { ! [[ "$DEB_VERSION" =~ ^[0-9]+$ ]] || [ "$DEB_VERSION" -gt 10 ]; }; then
        FAILED_LOGINS=$(journalctl -u ssh --since "24 hours ago" 2>/dev/null | grep -c "Failed password" || echo 0)
    else
        FAILED_LOGINS=0
        check_security "认证日志" "WARN" "日志文件 $AUTH_LOG_FILE 不存在或无法读取，暂按 0 次失败登录处理"
    fi
else
    FAILED_LOGINS=0
    check_security "认证日志" "WARN" "日志文件 $AUTH_LOG_FILE 不存在或无法读取，暂按 0 次失败登录处理"
fi

# Ensure FAILED_LOGINS is numeric and strip whitespace
FAILED_LOGINS=$(echo "$FAILED_LOGINS" | tr -d '[:space:]')
# Remove leading zeros (if any)
FAILED_LOGINS=$((10#$FAILED_LOGINS)) # Use arithmetic evaluation to ensure it's numeric and format correctly.

if [ "$FAILED_LOGINS" -lt $LOGINS_WARN ]; then
    check_security "失败登录" "PASS" "$FAILED_LOGIN_WINDOW 内仅检测到 $FAILED_LOGINS 次失败登录"
elif [ "$FAILED_LOGINS" -lt $LOGINS_FAIL ]; then
    check_security "失败登录" "WARN" "$FAILED_LOGIN_WINDOW 内检测到 $FAILED_LOGINS 次失败登录"
else
    check_security "失败登录" "FAIL" "$FAILED_LOGIN_WINDOW 内检测到 $FAILED_LOGINS 次失败登录，请调查来源 IP"
fi

# Check system updates
if [ "$OS_ID" = "alpine" ]; then
    UPDATES=$(apk version -l '<' 2>/dev/null | wc -l | tr -d ' ')
else
    UPDATES=$(apt-get -s upgrade 2>/dev/null | awk '/^[0-9]+ upgraded/{print $1;exit}')
fi
if [ -z "$UPDATES" ]; then
    UPDATES=0
fi
if [ "$UPDATES" -eq 0 ]; then
    check_security "系统更新" "PASS" "所有系统软件包均为最新版本"
else
    check_security "系统更新" "WARN" "有 $UPDATES 个软件包可更新，请检查并安装更新"
fi

# Check running services
if [ "$OS_ID" = "alpine" ]; then
    SERVICES=$(rc-status -a 2>/dev/null | awk '/\[ *started *\]/{n++} END{print n+0}')
else
    SERVICES=$(systemctl list-units --type=service --state=running 2>/dev/null | awk '/loaded active running/{n++} END{print n+0}')
fi
if [ "$SERVICES" -lt $SERVICES_WARN ]; then
    check_security "运行中的服务" "PASS" "仅运行 $SERVICES 个服务，攻击面较小"
elif [ "$SERVICES" -lt $SERVICES_FAIL ]; then
    check_security "运行中的服务" "WARN" "当前运行 $SERVICES 个服务，建议关闭不需要的服务以缩小攻击面"
else
    check_security "运行中的服务" "FAIL" "运行中的服务过多（$SERVICES 个），攻击面较大"
fi

# Check ports using netstat or ss
if command -v ss >/dev/null 2>&1; then
    LISTENING_PORTS=$(ss -H -lntu 2>/dev/null | awk '{a=$5; if(a ~ /^(0\.0\.0\.0|\*|\[::\]|::):/) print a}')
elif command -v netstat >/dev/null 2>&1; then
    LISTENING_PORTS=$(netstat -tuln 2>/dev/null | awk 'NR>2{a=$4; if(a ~ /^(0\.0\.0\.0|\*|:::)/) print a}')
else
    check_security "端口扫描" "FAIL" "系统中没有可用的 ss 或 netstat 命令"
    LISTENING_PORTS=""
fi

# Process LISTENING_PORTS to extract unique public ports
if [ -n "$LISTENING_PORTS" ]; then
    PUBLIC_PORTS=$(echo "$LISTENING_PORTS" | awk -F':' '{print $NF}' | sort -n | uniq | tr '\n' ',' | sed 's/,$//')
    PORT_COUNT=$(echo "$PUBLIC_PORTS" | tr ',' '\n' | wc -w)
    INTERNET_PORTS=$(echo "$PUBLIC_PORTS" | tr ',' '\n' | wc -w)

    if [ "$PORT_COUNT" -lt $OPEN_PORTS_WARN ] && [ "$INTERNET_PORTS" -lt 3 ]; then
        check_security "端口安全" "PASS" "配置良好（公网监听端口数：$INTERNET_PORTS）：$PUBLIC_PORTS"
    elif [ "$PORT_COUNT" -lt $OPEN_PORTS_FAIL ] && [ "$INTERNET_PORTS" -lt 5 ]; then
        check_security "端口安全" "WARN" "建议检查公网监听端口（共 $INTERNET_PORTS 个）：$PUBLIC_PORTS"
    else
        check_security "端口安全" "FAIL" "公网暴露端口较多（共 $INTERNET_PORTS 个）：$PUBLIC_PORTS"
    fi
else
    check_security "端口扫描" "WARN" "缺少工具导致端口扫描失败，请安装 ss 或 netstat"
fi

# Function to format the message with proper indentation for the report file
format_for_report() {
    local message="$1"
    echo "$message" >> "$REPORT_FILE"
}

# Check disk space usage
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print int($5)}')
if [ "$DISK_USAGE" -lt $RESOURCE_WARN ]; then
    check_security "磁盘使用率" "PASS" "磁盘空间充足（已用 ${DISK_USAGE}%：${DISK_USED}/${DISK_TOTAL}，可用 ${DISK_AVAIL}）"
elif [ "$DISK_USAGE" -lt $RESOURCE_FAIL ]; then
    check_security "磁盘使用率" "WARN" "磁盘使用率偏高（已用 ${DISK_USAGE}%：${DISK_USED}/${DISK_TOTAL}，可用 ${DISK_AVAIL}）"
else
    check_security "磁盘使用率" "FAIL" "磁盘空间严重不足（已用 ${DISK_USAGE}%：${DISK_USED}/${DISK_TOTAL}，可用 ${DISK_AVAIL}）"
fi

# Check memory usage
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_AVAIL=$(free -h | awk '/^Mem:/ {print $7}')
MEM_USAGE=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')
if [ "$MEM_USAGE" -lt $RESOURCE_WARN ]; then
    check_security "内存使用率" "PASS" "内存使用正常（已用 ${MEM_USAGE}%：${MEM_USED}/${MEM_TOTAL}，可用 ${MEM_AVAIL}）"
elif [ "$MEM_USAGE" -lt $RESOURCE_FAIL ]; then
    check_security "内存使用率" "WARN" "内存使用率偏高（已用 ${MEM_USAGE}%：${MEM_USED}/${MEM_TOTAL}，可用 ${MEM_AVAIL}）"
else
    check_security "内存使用率" "FAIL" "内存使用率严重过高（已用 ${MEM_USAGE}%：${MEM_USED}/${MEM_TOTAL}，可用 ${MEM_AVAIL}）"
fi

# Check CPU usage
CPU_CORES=$(nproc)
read -r -a cpu1 < /proc/stat
total1=$((cpu1[1]+cpu1[2]+cpu1[3]+cpu1[4]+cpu1[5]+cpu1[6]+cpu1[7]+cpu1[8])); idle1=$((cpu1[4]+cpu1[5]))
sleep 1
read -r -a cpu2 < /proc/stat
total2=$((cpu2[1]+cpu2[2]+cpu2[3]+cpu2[4]+cpu2[5]+cpu2[6]+cpu2[7]+cpu2[8])); idle2=$((cpu2[4]+cpu2[5]))
delta_total=$((total2-total1)); delta_idle=$((idle2-idle1))
if [ "$delta_total" -gt 0 ]; then CPU_IDLE=$((100*delta_idle/delta_total)); else CPU_IDLE=0; fi
CPU_USAGE=$((100-CPU_IDLE))
CPU_LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | awk -F',' '{ print $1 }' | tr -d ' ')
if [ "$CPU_USAGE" -lt $RESOURCE_WARN ]; then
    check_security "CPU 使用率" "PASS" "CPU 使用正常（活动 ${CPU_USAGE}%，空闲 ${CPU_IDLE}%，负载 ${CPU_LOAD}，核心数 ${CPU_CORES}）"
elif [ "$CPU_USAGE" -lt $RESOURCE_FAIL ]; then
    check_security "CPU 使用率" "WARN" "CPU 使用率偏高（活动 ${CPU_USAGE}%，空闲 ${CPU_IDLE}%，负载 ${CPU_LOAD}，核心数 ${CPU_CORES}）"
else
    check_security "CPU 使用率" "FAIL" "CPU 使用率严重过高（活动 ${CPU_USAGE}%，空闲 ${CPU_IDLE}%，负载 ${CPU_LOAD}，核心数 ${CPU_CORES}）"
fi

# Check sudo configuration
if grep -q "^Defaults.*logfile" "$SUDOERS_FILE" 2>/dev/null; then
    check_security "Sudo 日志" "PASS" "sudo 命令已记录到独立审计日志"
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-journald >/dev/null 2>&1; then
    check_security "Sudo 日志" "PASS" "sudo 活动已由 systemd-journald 记录"
elif [ -r /var/log/messages ] || [ -r /var/log/secure ]; then
    check_security "Sudo 日志" "PASS" "sudo 活动已由系统日志记录"
else
    check_security "Sudo 日志" "WARN" "无法确认 sudo 活动是否被记录，请检查 journal 或 syslog 配置"
fi

# Check password policy
if [ -f "$PASSWORD_QUALITY_CONF" ]; then
    # Extract the minlen value from pwquality.conf (last uncommented definition wins)
    MINLEN_VALUE=$(grep -E '^[[:space:]]*minlen[[:space:]]*=' "$PASSWORD_QUALITY_CONF" | tail -1 | cut -d= -f2 | tr -d '[:space:]')
    if [ -z "$MINLEN_VALUE" ]; then
        check_security "密码策略" "FAIL" "$PASSWORD_QUALITY_CONF 未设置 minlen，系统可能接受弱密码"
    elif ! [[ "$MINLEN_VALUE" =~ ^[0-9]+$ ]]; then
        check_security "密码策略" "WARN" "无法解析 $PASSWORD_QUALITY_CONF 中的 minlen 值 '$MINLEN_VALUE'"
    elif [ "$MINLEN_VALUE" -ge "$PASSWORD_MINLEN" ]; then
        check_security "密码策略" "PASS" "已实施较强的密码策略（minlen=$MINLEN_VALUE）"
    else
        check_security "密码策略" "FAIL" "密码策略较弱：minlen=$MINLEN_VALUE，低于建议值 $PASSWORD_MINLEN"
    fi
elif [ "$SSH_PASSWORD" = "no" ]; then
    check_security "密码策略" "PASS" "SSH 密码认证已关闭，远程访问不依赖密码策略"
else
    check_security "密码策略" "FAIL" "未配置密码策略，系统可能接受弱密码"
fi

# Check for suspicious SUID files
COMMON_SUID_PATHS='^/usr/bin/|^/bin/|^/sbin/|^/usr/sbin/|^/usr/lib|^/usr/libexec'
KNOWN_SUID_BINS='ping$|sudo$|mount$|umount$|su$|passwd$|chsh$|newgrp$|gpasswd$|chfn$'

SUID_FILES=$(find / -xdev -type f -perm -4000 2>/dev/null | \
    grep -v -E "$COMMON_SUID_PATHS" | \
    grep -v -E "$KNOWN_SUID_BINS" | \
    wc -l)

if [ "$SUID_FILES" -eq 0 ]; then
    check_security "SUID 文件" "PASS" "未发现位于非常规目录的可疑 SUID 文件"
else
    check_security "SUID 文件" "WARN" "在标准目录之外发现 $SUID_FILES 个 SUID 文件，请确认其是否合法"
fi

# Add system information summary to report
echo "================================" >> "$REPORT_FILE"
echo "系统信息摘要：" >> "$REPORT_FILE"
echo "主机名：$(hostname)" >> "$REPORT_FILE"
echo "内核：$(uname -r)" >> "$REPORT_FILE"
echo "操作系统：$(grep PRETTY_NAME "$OS_RELEASE_FILE" | cut -d'"' -f2)" >> "$REPORT_FILE"
echo "CPU 核心数：$(nproc)" >> "$REPORT_FILE"
echo "内存总量：$(free -h | awk '/^Mem:/ {print $2}')" >> "$REPORT_FILE"
echo "根分区总容量：$(df -h / | awk 'NR==2 {print $2}')" >> "$REPORT_FILE"
echo "================================" >> "$REPORT_FILE"

echo -e "\nVPS 巡检完成，完整报告已保存至 $REPORT_FILE"
echo -e "请查看 $REPORT_FILE 中的详细建议。"

# Add summary to report
echo "================================" >> "$REPORT_FILE"
echo "VPS 巡检报告结束" >> "$REPORT_FILE"
echo "请检查所有警告和失败项目，并根据建议进行修复。" >> "$REPORT_FILE"

# If chown enabled, set ownership of report
if [ "$ENABLE_CHOWN" = true ]; then
    if ! chown "$REPORT_CHOWN_OWNER" "$REPORT_FILE"; then
        echo -e "${RED}[错误] 无法修改 ${REPORT_FILE} 的所有者。" >&2
    fi
fi
