# VPS Audit Plus

轻量 VPS 安全巡检脚本，Fork 自 [Nuver-Labs/vps-audit](https://github.com/Nuver-Labs/vps-audit)，增加 Alpine Linux、每周定时运行及 Telegram 中文告警。

## 支持

- Alpine Linux 3.19+
- Debian 12/13
- Ubuntu 22.04/24.04
- OpenRC 与 systemd
- UFW、firewalld、iptables、nftables
- Fail2ban/CrowdSec、SSH、开放端口、更新、资源占用、SUID 文件检查
- 使用 `sshd -T` 检查最终生效配置，兼容 `sshd_config.d` 覆盖项
- SSH 失败登录默认统计最近 24 小时，不把数月累计日志误报为实时攻击
- 识别真正生效的 nftables/iptables 入站规则及公网监听端口
- Telegram 仅发送中文的警告和失败项，内容过长时自动分段
- 不向 Telegram 上传报告文件，完整报告只保存在 VPS 本机
- 默认每周日 04:30 运行，报告本地保留 30 天

脚本不是常驻服务，只在计划时间运行。Telegram Bot Token 仅保存在 VPS 的 `/etc/vps-audit/telegram.env`，权限为 `600`，不会提交到 GitHub。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash
```

安装时输入 Telegram Bot Token 和 Chat ID，安装器会验证配置并立即执行一次巡检。只有发现警告或失败项时，Telegram 才会收到中文文本消息。

该命令需要真实交互终端。不要在 Lite Monitor、Komari 网页命令框或其他没有 `/dev/tty` 的远程执行页面中运行，否则无法安全输入 Telegram 凭据。多台 VPS 或无交互环境请使用下一节的 `deploy-all.sh`。

## 从仓库一键更新

已安装过的 VPS 可直接重新运行安装器。它会从仓库下载最新版并自动复用现有 Telegram 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash
```

多台 VPS 请在管理机更新 `deploy-all.sh` 后重新批量部署：

```bash
curl -fsSL -o deploy-all.sh https://raw.githubusercontent.com/lauipaui/vps-audit/main/deploy-all.sh && chmod +x deploy-all.sh && ./deploy-all.sh --hosts servers.txt
```

## 使用

```bash
# 立即巡检；仅将警告和失败项发送到 Telegram
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

Telegram Token 和 Chat ID 只输入一次，通过 SSH 标准输入写入各 VPS 的 root-only 配置文件，不放进 SSH 命令参数。部署器会逐台验证配置并执行首次巡检，最后列出成功和失败主机。

> 不建议把 Bot Token 直接写进 Lite Monitor/Komari 命令、Shell 历史、`servers.txt` 或 GitHub 仓库。

## 修改运行时间

默认 Cron 表达式为 `30 4 * * 0`，即服务器本地时间每周日 04:30。

- Alpine：编辑 `/etc/crontabs/root`
- Debian/Ubuntu：编辑 `/etc/cron.d/vps-audit`

## Telegram 配置

1. 在 Telegram 中通过 `@BotFather` 创建 Bot 并获取 Token。
2. 给 Bot 发送一条消息。
3. 获取个人或群组 Chat ID。
4. 群组使用时，先将 Bot 加入群组并允许其发送消息。

重新配置可以再次运行安装命令。配置文件不会被巡检报告读取或上传。

## 报告说明

- `SSH Root 登录`：`PermitRootLogin no`，或 root 仅允许密钥登录（`prohibit-password`）；允许 root 登录但全局密码认证关闭时仍会标记为警告。
- `SSH 密码认证`：读取 `sshd -T` 的最终结果，而不是简单搜索配置文件。
- 非默认 SSH 高端口不会被误判为“不安全”；端口号本身不是安全边界。
- `失败登录`：systemd 主机统计最近 24 小时；Alpine 无 journal 时会明确标记实际日志窗口。
- `防火墙状态`：检查 nftables input hook/policy，或 iptables INPUT 的策略与规则数量。
- `端口安全`：只计算绑定到 `0.0.0.0`、`::` 或通配地址的监听端口。
- `系统更新`：表示存在普通软件包更新，不冒充“已确认的安全更新”。
- `Sudo 日志`：支持独立 logfile、systemd-journald 和 syslog。

本地报告包含全部通过、警告和失败项目；Telegram 只接收中文警告和失败文本，不接收文件。报告是基线提示，不会自动修改 SSH、防火墙或软件包。

## 故障排除

### `/dev/tty: No such device or address`

说明安装命令运行在 Lite Monitor/Komari 网页执行器、Cron 或其他非交互环境中。请在管理机使用：

```bash
./deploy-all.sh --hosts servers.txt
```

新版安装器会在无 TTY 且没有预配置凭据时明确退出，不再直接读取不存在的 `/dev/tty`。

### Cron 出现 systemd-sysv-install 提示

```text
Synchronizing state of cron.service with SysV service script
Executing: /lib/systemd/systemd-sysv-install enable cron
```

这是 Debian/Ubuntu 启用 Cron 时的正常 systemd 提示，不是报错。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash -s -- --uninstall
```

卸载会移除 Cron 与运行器，但保留 Telegram 配置和历史报告，避免误删数据。

## 性能

它只在定时运行时短暂占用资源。主要 I/O 来自根文件系统的 SUID 扫描；已限制为 `find / -xdev`，不会递归扫描额外挂载盘、网络盘或其他文件系统。日常不常驻、不占用内存。

## 许可

沿用上游 MIT License，并保留原项目署名。
