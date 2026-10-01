# VPS Audit Plus

[中文](README.md) | **English**

A lightweight VPS security-check script, forked from [Nuver-Labs/vps-audit](https://github.com/Nuver-Labs/vps-audit), with Alpine support, weekly scheduling and Chinese Telegram warning messages. It produces a local baseline report; it is not a real-time intrusion-detection service or a guarantee of host security.

## Intended support and checks

- Alpine Linux 3.19+, Debian 12/13, Ubuntu 22.04/24.04; OpenRC/systemd.
- SSH configuration, failed logins, public listeners, firewall rules, package updates, resource use, SUID files, Fail2ban/CrowdSec and sudo logging.
- `sshd -T` for effective SSH settings, including drop-in effects.
- systemd failed-login count over the last 24 hours; non-journal sources report their actual log window.
- Active nftables input-hook/policy or iptables INPUT checks; public listeners are distinguished from loopback-bound services.
- Chinese warning/failure messages, automatically split when long. Full reports remain on the host and are not uploaded as Telegram files.

Some checks need root and relevant tools. Package-update findings are not confirmation that every update is security-specific. High SSH ports alone are not a security boundary. Root key-only access, password policies and Match-specific SSH contexts require interpretation of the report, not blind remediation.

## Review and install

Use a real interactive terminal and root/sudo. **The installer changes packages, files and Cron**, unlike the audit itself.

```sh
git clone https://github.com/lauipaui/vps-audit.git
cd vps-audit
less install.sh
sudo bash install.sh
```

The installer downloads `vps-audit.sh` from this fork's `main` even when run from a local checkout; this does not pin every downloaded file. The original remote entry is also available after review:

```sh
curl -fsSL https://raw.githubusercontent.com/lauipaui/vps-audit/main/install.sh | sudo bash
```

Enter the Telegram Bot Token and numeric Chat ID locally. Prepare the bot with BotFather, message it once, and grant message permission if using a group. The installer validates the configuration and runs an initial audit; Telegram receives a warning only if warning/failure items exist, not the full report.

Do not paste real tokens into Komari/web-command execution fields, shell history, host lists or GitHub. A first-time install with missing credentials needs `/dev/tty`; use the batch deployer from an interactive management machine rather than a non-interactive web executor.

## Installed paths and schedule

| Path | Purpose |
| --- | --- |
| `/usr/local/lib/vps-audit/vps-audit.sh` | Audit script |
| `/usr/local/sbin/vps-audit-run` | Audit/notification/retention wrapper |
| `/etc/vps-audit/telegram.env` | Root-only configuration, mode 0600 |
| `/var/lib/vps-audit/reports/` | Local full reports, default retention 30 days |
| `/var/log/vps-audit.log` | Runner log |
| `/etc/cron.d/vps-audit` | Debian/Ubuntu schedule |
| `/etc/crontabs/root` | Alpine schedule entry |

Default expression: `30 4 * * 0`, Sunday 04:30 in the **server's local timezone**. Change the installed Cron entry to change the schedule. The runner is not always resident; SUID scanning (`find / -xdev`) is the principal I/O work and stays on the root filesystem.

The Telegram configuration is sourced as shell code: accept only a trusted root-only file. Do not equate "not in Git" with "cannot appear in process/network diagnostics"; sanitize any shared output.

## Run and inspect

```sh
# Runs an audit and sends only warnings/failures
sudo /usr/local/sbin/vps-audit-run
sudo tail -n 100 /var/log/vps-audit.log
sudo ls -lh /var/lib/vps-audit/reports/
# Audit directly without the notification wrapper
sudo VPS_AUDIT_REPORT_DIR=/root /usr/local/lib/vps-audit/vps-audit.sh
```

Direct audit execution still scans the host and writes a report. It does not automatically repair SSH, firewalls or packages. Reports can contain account names, IPs, listening ports and paths; redact before sharing.

## Update or reuse configuration

Rerun the reviewed installer to fetch the current audit script; existing nonempty credentials are reused. Explicit reuse mode requires an existing readable configuration:

```sh
sudo bash install.sh --reuse-config
```

It is an installation/update operation, **not** a read-only test. There is no complete transactional rollback/version-pinning mechanism. Save the installed audit script, runner, Cron entry and protected configuration/report data before updating.

## Multiple VPS hosts

The management machine needs working SSH key access to each host. Review [`deploy-all.sh`](deploy-all.sh), then use:

```sh
./deploy-all.sh --hosts servers.txt
```

Example host file (documentation addresses only):

```text
root@192.0.2.10
root@[2001:db8::10]
root@example.com -p 2222
```

The deployer asks once for Telegram credentials and passes them through SSH standard input instead of SSH command arguments. It validates and audits hosts sequentially and summarizes successes/failures. It uses `BatchMode=yes` and `StrictHostKeyChecking=accept-new`; independently verify first-contact host identity. It does not provision SSH keys, and a real host inventory should remain private.

## Checks and troubleshooting

```sh
bash -n install.sh
bash -n deploy-all.sh
bash -n vps-audit.sh
```

These syntax checks do not deploy, scan SUID files or send messages. No unified automated acceptance suite is included. This documentation update did not deploy hosts or revalidate live notifications.

- `/dev/tty: No such device or address`: use an interactive terminal, preconfigured trusted credentials, or the deployer on a management machine.
- Cron `systemd-sysv-install` synchronization messages on Debian/Ubuntu are normally service-enable information, not errors by themselves.
- No Telegram report: a clean audit generates no warning message. Separately check local report generation, credentials, permissions, DNS/network and Telegram responses using protected output.
- Interpret false positives and missing-tool limitations in context; do not apply unrelated SSH/firewall changes blindly.

## Uninstall and rollback

```sh
sudo bash install.sh --uninstall
```

Uninstall removes the scheduled entry and runner. It intentionally leaves credentials and historical reports, and does **not** mean the audit script, all logs or installed system dependencies have been erased. Decide separately what to retain or remove.

On regression, pause this project's Cron, restore the saved known-good audit/runner and matching schedule, then validate with protected configuration. Never publish credential backups.

## License and attribution

Retains the upstream [MIT License](LICENSE) and Nuver-Labs attribution. Review component licenses separately. The script is a baseline aid, not penetration testing, compliance certification or continuous monitoring.
