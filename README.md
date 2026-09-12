# Telemt MTProxy TAG Tools

用于安装 Telemt MTProxy，并通过 `@MTProxyBot` 绑定公开赞助频道。

## 功能

- 交互式安装 Telemt MTProxy
- 自动配置 FakeTLS
- 设置全局 Ad Tag
- 按用户设置独立 Ad Tag
- 为用户配置独立端口
- 快速查看客户端连接链接
- 可选的断网检测与 Telemt 服务自愈
- 修改前自动备份配置
- Telemt 启动失败时自动回滚

## 系统要求

- Debian / Ubuntu / CentOS / RHEL / Alpine Linux
- root 权限
- 具有公网 IP 的 VPS
- VPS 可以访问 GitHub 和 Telegram 服务器
- 准备一个公开 Telegram 频道

> MTProxy 赞助位只支持公开频道，不支持群组或私密频道。

## 一键安装

登录新 VPS：

```bash
ssh root@VPS_IP
```

下载并运行完整安装脚本：

```bash
curl -fL https://raw.githubusercontent.com/Skylush/mtp-tag-tools/main/install-telemt-with-tag.sh -o install-telemt-with-tag.sh
chmod +x install-telemt-with-tag.sh
./install-telemt-with-tag.sh
```

选择：

```text
1. 完整安装/覆盖重装 Telemt，然后绑定频道
```

推荐配置：

```text
监听端口: 443，或一个已开放的自定义端口
FakeTLS 域名: www.apple.com
监听模式: 仅 IPv4
初始用户名: admin
Secret: 直接回车，使用自动生成值
流量/到期/限速: 按需设置，不需要可直接回车
```

## 在 @MTProxyBot 注册代理

安装脚本会显示一个 32 位原始 Secret。记住该 Secret，不要将它公开在截图、日志或 GitHub 中。

在 Telegram 中打开 `@MTProxyBot`：

1. 发送 `/newproxy`。
2. 发送 `VPS_IP:监听端口`。
3. 发送脚本生成的 32 位原始 Secret。
4. 复制 Bot 返回的 32 位 TAG。
5. 返回 SSH 窗口，将 TAG 粘贴给安装脚本。

TAG 写入成功后，还需要在 Bot 中设置赞助频道：

1. 发送 `/myproxies`。
2. 根据 TAG 的最后 8 位选择相应代理。
3. 点击 `Set promotion`。
4. 发送公开频道链接，例如 `https://t.me/example`。
5. 等待 Telegram 服务端同步，通常需要约 1 小时。

已订阅该频道的账号不会看到赞助位。请使用未订阅该频道的账号测试。

## 可选：断网检测与服务自愈

完整安装结束时，脚本会询问：

```text
是否启用【断网检测 + Telemt 服务自愈】附属功能？[Y/n]
```

直接回车即可启用。也可在主菜单选择：

```text
8. 断网检测 + Telemt 服务自愈监控
```

自愈模块默认每 2 分钟检查一次：

- VPS 完全断网时只记录状态，不反复重启 Telemt。
- 网络恢复后重启一次 Telemt，重建 Telegram Middle Proxy 连接池。
- Telemt 停止或任一配置端口未监听时，连续检查失败 3 次后才重启。
- 同时检查主端口和 `[access.user_ports]` 中的所有用户独立端口。
- 通过文件锁防止多个监控任务重复执行。

查看监控定时器：

```bash
systemctl status telemt-watchdog.timer --no-pager
```

查看自愈日志：

```bash
tail -n 100 /var/log/telemt-watchdog.log
```

手动执行一次健康检查：

```bash
/usr/local/sbin/telemt-watchdog
```

默认设置保存在 `/etc/telemt-watchdog.conf`：

```bash
FAIL_THRESHOLD=3
RESTART_ON_NETWORK_RECOVERY=1
CHECK_TIMEOUT=6
```

如果不希望在网络恢复时主动重启 Telemt，可将 `RESTART_ON_NETWORK_RECOVERY` 改为 `0`。也可通过主菜单选项 8 完整关闭或重新安装监控。

## 查看代理链接

```bash
mtp users
```

如果 `mtp` 快捷命令不存在：

```bash
bash /opt/mtproxy/mtp-new.sh users
```

必须使用此命令输出的 FakeTLS 链接。`@MTProxyBot` 注册成功时返回的裸 Secret 链接在 FakeTLS 模式下可能无法连接。

## Secret 格式说明

FakeTLS Secret 可能以两种等价形式出现。

十六进制形式：

```text
ee + 32 位原始 Secret + FakeTLS 域名的十六进制编码
```

Base64URL 形式：

```text
将上述完整字节串编码成 Base64URL
```

两者只是编码方式不同。建议直接复制 `mtp users` 输出的链接。Base64URL Secret 中的 `_` 是实际字符，不要写成 `\_`。

## 现有 Telemt 的 TAG 管理

已经安装 Telemt 时，可以单独使用 TAG 管理脚本：

```bash
curl -fL https://raw.githubusercontent.com/Skylush/mtp-tag-tools/main/mtp-tag-manager.sh -o mtp-tag-manager.sh
chmod +x mtp-tag-manager.sh
./mtp-tag-manager.sh
```

TAG 管理器支持：

- 设置/更换全局 TAG
- 为指定用户设置 TAG
- 删除全局或用户 TAG
- 查看当前 TAG 绑定
- 自动启用 `use_middle_proxy = true`
- 修改失败时回滚配置

## 常用命令

```bash
# 查看用户和连接链接
mtp users

# 查看主连接信息
mtp list

# 查看服务状态
systemctl status telemt --no-pager

# 查看最近日志
journalctl -u telemt -n 100 --no-pager

# 重启服务
systemctl restart telemt

# 查看 TAG 与 Middle Proxy 开关
grep -E '^(ad_tag|use_middle_proxy)' /etc/telemt.toml
```

## 故障排查

### 代理可用，但不显示赞助频道

依次检查：

1. `/etc/telemt.toml` 中的 `ad_tag` 是否与 Bot 返回的 TAG 完全一致。
2. `use_middle_proxy` 是否为 `true`。
3. `/myproxies` 中是否已完成 `Set promotion`。
4. 推广对象是否为公开频道。
5. 测试账号是否尚未订阅该频道。
6. 是否已等待约 1 小时的 Telegram 缓存同步。

检查 Middle Proxy 握手：

```bash
journalctl -u telemt -n 200 --no-pager | grep -Ei 'middle|RPC handshake|error|warn'
```

日志中出现 `RPC handshake OK` 表示 Telemt 已成功连接 Telegram Middle Proxy。

### Bot 返回的链接不能使用

这在 FakeTLS 配置中属于预期情况。请改用 `mtp users` 输出的完整链接。

## 安全提示

- 不要将真实 Secret、SSH 私钥或 Bot Token 提交到 GitHub。
- 如果 Secret 曾出现在公开截图或聊天记录中，请更换 Secret 并重新在 `@MTProxyBot` 注册。
- 建议仅开放 SSH 和 MTProxy 必需端口。
- 修改配置前建议保留 `/etc/telemt.toml` 备份。

## 上游项目

- [jyucoeng/singbox-tools](https://github.com/jyucoeng/singbox-tools)
- [telemt/telemt](https://github.com/telemt/telemt)
- [Telegram MTProxy 文档](https://core.telegram.org/proxy)

## 免责声明

请在当地法律允许范围内使用本工具。使用者应自行承担服务器、网络、账号及数据安全责任。
