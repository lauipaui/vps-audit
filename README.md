# VPS Audit Plus

轻量 VPS 安全巡检脚本，Fork 自 [Nuver-Labs/vps-audit](https://github.com/Nuver-Labs/vps-audit)，增加 Alpine Linux、每周定时运行及 Telegram 报告上传。

## 支持

- Alpine Linux 3.19+
- Debian 12/13
- Ubuntu 22.04/24.04
- OpenRC 与 systemd
- UFW、firewalld、iptables、nftables
- Fail2ban/CrowdSec、SSH、开放端口、更新、资源占用、SUID 文件检查
- Telegram 发送完整 TXT 报告及 PASS/WARN/FAIL 摘要
- 默认每周日 04:30 运行，报告本地保留 30 天

脚本不是常驻服务，只在计划时间运行。Telegram Bot Token 仅保存在 VPS 的 `/etc/vps-audit/telegram.env`，权限为 `600`，不会提交到 GitHub。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash
```

安装时输入 Telegram Bot Token 和 Chat ID，并立即执行一次测试巡检。成功后会在 Telegram 收到完整报告。

也可以通过环境变量进行无人值守安装：

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | \
  sudo TELEGRAM_BOT_TOKEN='你的Token' TELEGRAM_CHAT_ID='你的ChatID' bash
```

注意：把 Token 直接写入命令可能进入 Shell 历史，优先使用交互式安装。

## 使用

```bash
# 立即巡检并上传 Telegram
sudo /usr/local/sbin/vps-audit-run

# 查看运行日志
sudo tail -n 100 /var/log/vps-audit.log

# 查看本地报告
sudo ls -lh /var/lib/vps-audit/reports/

# 仅手动运行审计，不发送 Telegram
sudo VPS_AUDIT_REPORT_DIR=/root /usr/local/lib/vps-audit/vps-audit.sh
```

## 一键部署到所有 VPS

前提：管理机可以使用 SSH 密钥登录各 VPS。下载批量部署器：

```bash
curl -fsSL -o deploy-all.sh \
  https://raw.githubusercontent.com/lauipaui/vps-audit/main/deploy-all.sh
chmod +x deploy-all.sh
```

直接传入所有 VPS：

```bash
./deploy-all.sh root@1.2.3.4 root@5.6.7.8 root@[2001:db8::10]
```

或者创建 `servers.txt`：

```text
root@1.2.3.4
root@5.6.7.8
root@[2001:db8::10]
root@example.com -p 2222
```

然后一次部署：

```bash
./deploy-all.sh --hosts servers.txt
```

Telegram Token 和 Chat ID 只输入一次，通过 SSH 标准输入写入各 VPS 的 root-only 配置文件，不放进 SSH 命令参数。部署器会逐台发送测试报告，最后列出成功和失败主机。

## 修改运行时间

默认 Cron 表达式为 `30 4 * * 0`，即服务器本地时间每周日 04:30。

- Alpine：编辑 `/etc/crontabs/root`
- Debian/Ubuntu：编辑 `/etc/cron.d/vps-audit`

## Telegram 配置

1. 在 Telegram 中通过 `@BotFather` 创建 Bot 并获取 Token。
2. 给 Bot 发送一条消息。
3. 获取个人或群组 Chat ID。
4. 群组使用时，先将 Bot 加入群组并允许其发送文件。

重新配置可以再次运行安装命令。配置文件不会被巡检报告读取或上传。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash -s -- --uninstall
```

卸载会移除 Cron 与运行器，但保留 Telegram 配置和历史报告，避免误删数据。

## 性能

它只在定时运行时短暂占用资源。主要 I/O 来自根文件系统的 SUID 扫描；已限制为 `find / -xdev`，不会递归扫描额外挂载盘、网络盘或其他文件系统。日常不常驻、不占用内存。

## 许可

沿用上游 MIT License，并保留原项目署名。
