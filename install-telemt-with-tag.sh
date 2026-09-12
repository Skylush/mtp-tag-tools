#!/usr/bin/env bash

# Telemt MTProxy 完整安装 + 频道 TAG 绑定脚本
# 安装引擎与管理功能来自 jyucoeng/singbox-tools/mtp-new.sh

set -u

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

UPSTREAM_URL='https://raw.githubusercontent.com/jyucoeng/singbox-tools/refs/heads/main/mtp-new.sh'
UPSTREAM_SCRIPT='/opt/mtproxy/mtp-new.sh'
CONFIG_FILE=''
LAST_BACKUP=''

die() {
    echo -e "${RED}错误：$*${PLAIN}" >&2
    exit 1
}

pause_menu() {
    echo
    read -r -p "按 Enter 键继续..." _
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
}

install_downloader() {
    command -v curl >/dev/null 2>&1 && return 0
    echo -e "${BLUE}正在安装 curl...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates
    else
        die "未找到 curl，也无法识别包管理器。"
    fi
}

find_config() {
    CONFIG_FILE=''
    if [ -f /etc/telemt.toml ]; then
        CONFIG_FILE=/etc/telemt.toml
    elif [ -f /etc/telemt/telemt.toml ]; then
        CONFIG_FILE=/etc/telemt/telemt.toml
    fi
    [ -n "$CONFIG_FILE" ]
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_tag() {
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

valid_secret() {
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

valid_user() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

download_installer() {
    install_downloader
    mkdir -p /opt/mtproxy
    echo -e "${BLUE}正在下载 mtp-new.sh...${PLAIN}"
    curl -fL --retry 3 --connect-timeout 15 "$UPSTREAM_URL" -o "${UPSTREAM_SCRIPT}.download" || die "下载 mtp-new.sh 失败。"
    [ -s "${UPSTREAM_SCRIPT}.download" ] || die "下载到的脚本为空。"
    head -n 1 "${UPSTREAM_SCRIPT}.download" | grep -q '^#!/bin/bash' || die "下载内容不是有效的 Bash 脚本。"
    mv "${UPSTREAM_SCRIPT}.download" "$UPSTREAM_SCRIPT"
    chmod 700 "$UPSTREAM_SCRIPT"
}

select_ip_mode() {
    local choice
    echo "  1. 仅 IPv4（默认）" >&2
    echo "  2. 仅 IPv6" >&2
    echo "  3. IPv4 + IPv6 双栈" >&2
    read -r -p "选择监听模式 [1-3]: " choice
    case "$choice" in
        2) printf '%s' v6 ;;
        3) printf '%s' dual ;;
        *) printf '%s' v4 ;;
    esac
}

install_telemt() {
    local port domain ip_mode username secret quota expire speed_up speed_down reset_day action answer
    echo -e "${BLUE}============================================${PLAIN}"
    echo -e "${GREEN}       Telemt MTProxy 完整交互安装${PLAIN}"
    echo -e "${BLUE}============================================${PLAIN}"

    action=ins
    if find_config; then
        echo -e "${YELLOW}检测到已安装的 Telemt：${CONFIG_FILE}${PLAIN}"
        read -r -p "是否覆盖重装？现有用户和配置会被删除 [y/N]: " answer
        [[ "$answer" =~ ^[yY]$ ]] || return 0
        action=rep
    fi

    read -r -p "监听端口 [443]: " port
    port="${port:-443}"
    valid_port "$port" || { echo -e "${RED}端口必须是 1-65535。${PLAIN}"; return 1; }

    read -r -p "FakeTLS 伪装域名 [www.apple.com]: " domain
    domain="${domain:-www.apple.com}"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || { echo -e "${RED}域名格式不正确。${PLAIN}"; return 1; }

    ip_mode="$(select_ip_mode)"

    read -r -p "初始用户名 [admin]: " username
    username="${username:-admin}"
    valid_user "$username" || { echo -e "${RED}用户名只能包含字母、数字、_ 和 -。${PLAIN}"; return 1; }

    secret="$(generate_secret)"
    echo -e "自动生成用户 Secret：${GREEN}${secret}${PLAIN}"
    read -r -p "如需自定义 32 位 Secret 请输入，回车保留上述值: " answer
    [ -n "$answer" ] && secret="${answer,,}"
    valid_secret "$secret" || { echo -e "${RED}Secret 必须是 32 位十六进制字符。${PLAIN}"; return 1; }

    read -r -p "每月流量配额 GB（回车=不限）: " quota
    if [ -n "$quota" ] && ! [[ "$quota" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo -e "${RED}流量配额必须是数字。${PLAIN}"
        return 1
    fi

    expire=''
    speed_up=''
    speed_down=''
    reset_day=''
    if [ -n "$quota" ]; then
        read -r -p "每月重置日 [1]: " reset_day
        reset_day="${reset_day:-1}"
        [[ "$reset_day" =~ ^([1-9]|[12][0-9]|3[01])$ ]] || { echo -e "${RED}重置日必须是 1-31。${PLAIN}"; return 1; }
    fi
    read -r -p "到期时间（如 2027-12-31，回车=永久）: " expire
    read -r -p "上行限速 MB/s（回车=不限）: " speed_up
    if [ -n "$speed_up" ]; then
        [[ "$speed_up" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo -e "${RED}限速必须是数字。${PLAIN}"; return 1; }
        read -r -p "下行限速 MB/s [${speed_up}]: " speed_down
        speed_down="${speed_down:-$speed_up}"
        [[ "$speed_down" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo -e "${RED}限速必须是数字。${PLAIN}"; return 1; }
    fi

    echo
    echo -e "${YELLOW}即将安装：端口=${port}，域名=${domain}，用户=${username}，模式=${ip_mode}${PLAIN}"
    read -r -p "确认继续 [Y/n]: " answer
    [[ "$answer" =~ ^[nN]$ ]] && return 0

    download_installer
    local -a install_env
    install_env=(
        "INSTALL_MODE=telemt"
        "PORT=$port"
        "DOMAIN=$domain"
        "IP_MODE=$ip_mode"
        "TELEMT_USER=$username"
        "SECRET=$secret"
    )
    [ -n "$quota" ] && install_env+=("TELEMT_QUOTA=$quota")
    [ -n "$reset_day" ] && install_env+=("TELEMT_RESET_DAY=$reset_day")
    [ -n "$expire" ] && install_env+=("TELEMT_EXPIRE=$expire")
    [ -n "$speed_up" ] && install_env+=("TELEMT_SPEED_UP=$speed_up" "TELEMT_SPEED_DOWN=$speed_down")

    echo -e "${BLUE}正在安装 Telemt，请等待...${PLAIN}"
    env "${install_env[@]}" bash "$UPSTREAM_SCRIPT" "$action" || die "Telemt 安装失败，请查看上方日志。"
    find_config || die "Telemt 安装结束，但未找到配置文件。"

    echo
    echo -e "${GREEN}✅ Telemt 安装完成。${PLAIN}"
    echo -e "向 @MTProxyBot 提交的原始 Secret：${GREEN}${secret}${PLAIN}"
    echo -e "${YELLOW}请现在到 Telegram 打开 @MTProxyBot：${PLAIN}"
    echo "  1. 发送 /newproxy"
    echo "  2. 提交本机公网 IP:${port}"
    echo "  3. 提交上面的 32 位原始 Secret"
    echo "  4. 复制 Bot 返回的 32 位 TAG"
    echo "  5. 写入 TAG 后，还要执行 /myproxies → Set promotion 绑定公开频道"
    echo
    read -r -p "获取 TAG 后按 Enter 继续（输入 s 可暂时跳过）: " answer
    if [[ "$answer" =~ ^[sS]$ ]]; then
        echo -e "${YELLOW}已跳过 TAG，以后重新运行本脚本即可绑定。${PLAIN}"
        return 0
    fi
    set_global_tag
}

# 在指定 TOML section 中设置/删除键。
toml_edit() {
    local action="$1" section="$2" key="$3" value="${4:-}"
    python3 - "$CONFIG_FILE" "$action" "$section" "$key" "$value" <<'PY'
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
action, wanted, key, value = sys.argv[2:6]
lines = path.read_text(encoding="utf-8").splitlines()
section_re = re.compile(r'^\s*\[([^]]+)]\s*(?:#.*)?$')
key_re = re.compile(r'^\s*(?:"' + re.escape(key) + r'"|' + re.escape(key) + r')\s*=')
start = None
end = len(lines)
for i, line in enumerate(lines):
    match = section_re.match(line)
    if not match:
        continue
    if start is not None:
        end = i
        break
    if match.group(1).strip() == wanted:
        start = i

if action in ("set", "set_bool"):
    rendered = f'{key} = {value}' if action == "set_bool" else f'{key} = "{value}"'
    if start is None:
        if lines and lines[-1].strip(): lines.append("")
        lines.extend([f'[{wanted}]', rendered])
    else:
        for i in range(start + 1, end):
            if key_re.match(lines[i]):
                lines[i] = rendered
                break
        else:
            lines.insert(start + 1, rendered)
elif action == "remove" and start is not None:
    for i in range(start + 1, end):
        if key_re.match(lines[i]):
            del lines[i]
            break
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

backup_config() {
    LAST_BACKUP="${CONFIG_FILE}.tag-backup.$(date '+%Y%m%d-%H%M%S')"
    cp -p "$CONFIG_FILE" "$LAST_BACKUP" || die "备份配置失败。"
}

restart_telemt() {
    local ok=0
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/telemt.service ]; then
        systemctl restart telemt && systemctl is-active --quiet telemt && ok=1
    elif command -v rc-service >/dev/null 2>&1 && [ -e /etc/init.d/telemt ]; then
        rc-service telemt restart && rc-service telemt status 2>/dev/null | grep -q started && ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        echo -e "${GREEN}✅ Telemt 重启成功，TAG 已生效。${PLAIN}"
        echo "修改前备份：$LAST_BACKUP"
        return 0
    fi
    echo -e "${RED}Telemt 启动失败，正在恢复原配置...${PLAIN}"
    cp -p "$LAST_BACKUP" "$CONFIG_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart telemt 2>/dev/null || true
        journalctl -u telemt -n 40 --no-pager 2>/dev/null || true
    else
        rc-service telemt restart 2>/dev/null || true
    fi
    die "新配置无法启动，已自动回滚。"
}

set_global_tag() {
    local tag
    find_config || { echo -e "${RED}请先安装 Telemt。${PLAIN}"; return 1; }
    command -v python3 >/dev/null 2>&1 || die "未找到 python3。"
    read -r -p "粘贴 @MTProxyBot 返回的 32 位 TAG: " tag
    tag="${tag,,}"
    valid_tag "$tag" || { echo -e "${RED}TAG 必须是 32 位十六进制字符。${PLAIN}"; return 1; }
    backup_config
    toml_edit set_bool general use_middle_proxy true
    toml_edit set general ad_tag "$tag"
    restart_telemt
    echo
    echo -e "${YELLOW}还需要在 @MTProxyBot 中完成频道关联：${PLAIN}"
    echo "  1. 向 @MTProxyBot 发送 /myproxies"
    echo "  2. 选择刚注册的代理"
    echo "  3. 点击 Set promotion"
    echo "  4. 发送公开频道链接，例如 https://t.me/example"
    echo "  5. 等待 Telegram 服务端同步（通常需要约 1 小时）"
    echo -e "${YELLOW}注意：只支持公开频道，不支持群组或私密频道。已订阅该频道的账号也不会看到推广位。${PLAIN}"
}

list_users() {
    python3 - "$CONFIG_FILE" <<'PY'
import re, sys
inside = False
for line in open(sys.argv[1], encoding="utf-8"):
    h = re.match(r'^\s*\[([^]]+)]', line)
    if h:
        inside = h.group(1).strip() == "access.users"
        continue
    if inside:
        m = re.match(r'^\s*(?:"([A-Za-z0-9_-]+)"|([A-Za-z0-9_-]+))\s*=\s*"[0-9a-fA-F]{32}"', line)
        if m: print(m.group(1) or m.group(2))
PY
}

set_user_tag() {
    local users username tag
    find_config || { echo -e "${RED}请先安装 Telemt。${PLAIN}"; return 1; }
    users="$(list_users)"
    [ -n "$users" ] || { echo -e "${RED}未找到 Telemt 用户。${PLAIN}"; return 1; }
    echo "现有用户："
    echo "$users" | nl -w2 -s'. '
    read -r -p "要绑定的用户名: " username
    valid_user "$username" && echo "$users" | grep -Fxq "$username" || { echo -e "${RED}用户不存在。${PLAIN}"; return 1; }
    read -r -p "该用户的 32 位 TAG: " tag
    tag="${tag,,}"
    valid_tag "$tag" || { echo -e "${RED}TAG 格式错误。${PLAIN}"; return 1; }
    backup_config
    toml_edit set_bool general use_middle_proxy true
    toml_edit set access.user_ad_tags "$username" "$tag"
    restart_telemt
}

show_tags() {
    find_config || { echo -e "${YELLOW}Telemt 尚未安装。${PLAIN}"; return 0; }
    python3 - "$CONFIG_FILE" <<'PY'
import re, sys
section = ""
found = False
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    h = re.match(r'^\[([^]]+)]', line)
    if h:
        section = h.group(1).strip()
        continue
    m = re.match(r'^(?:"([^"\n]+)"|([A-Za-z0-9_-]+))\s*=\s*"([0-9a-fA-F]{32})"', line)
    if not m: continue
    key, value = m.group(1) or m.group(2), m.group(3)
    if section == "general" and key == "ad_tag":
        print("全局 TAG: " + value); found = True
    elif section == "access.user_ad_tags":
        print("用户 TAG: %s -> %s" % (key, value)); found = True
if not found: print("当前未设置任何 TAG。")
PY
    echo "配置文件：$CONFIG_FILE"
}

show_links() {
    find_config || { echo -e "${YELLOW}Telemt 尚未安装。${PLAIN}"; return 1; }
    echo -e "${BLUE}============================================${PLAIN}"
    echo -e "${GREEN}           Telemt 快速链接信息${PLAIN}"
    echo -e "${BLUE}============================================${PLAIN}"
    if [ -f "$UPSTREAM_SCRIPT" ]; then
        bash "$UPSTREAM_SCRIPT" users
    elif command -v mtp >/dev/null 2>&1; then
        mtp users
    else
        echo -e "${RED}未找到 mtp-new.sh，无法生成链接。${PLAIN}"
        return 1
    fi
    echo
    echo -e "以后也可直接执行：${GREEN}mtp users${PLAIN}"
}

show_diagnostics() {
    find_config || { echo -e "${YELLOW}Telemt 尚未安装。${PLAIN}"; return 1; }
    echo -e "${BLUE}--- TAG 和 Middle Proxy 配置 ---${PLAIN}"
    grep -E '^\s*(ad_tag|use_middle_proxy)\s*=' "$CONFIG_FILE" 2>/dev/null || true
    echo
    echo -e "${BLUE}--- Telemt 服务状态 ---${PLAIN}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active telemt 2>/dev/null || true
        echo
        echo -e "${BLUE}--- 最近 30 条日志 ---${PLAIN}"
        journalctl -u telemt -n 30 --no-pager 2>/dev/null || true
    else
        rc-service telemt status 2>/dev/null || true
        tail -n 30 /var/log/telemt.log 2>/dev/null || true
    fi
}

menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLUE}============================================${PLAIN}"
        echo -e "${GREEN}    Telemt MTProxy 安装 + TAG 绑定${PLAIN}"
        echo -e "${BLUE}============================================${PLAIN}"
        if find_config; then
            echo -e "状态：${GREEN}已安装${PLAIN}  配置：$CONFIG_FILE"
        else
            echo -e "状态：${YELLOW}未安装${PLAIN}"
        fi
        echo
        echo "  1. 完整安装/覆盖重装 Telemt，然后绑定频道"
        echo "  2. 绑定/更换全局频道 TAG"
        echo "  3. 为指定用户绑定 TAG"
        echo "  4. 查看当前 TAG"
        echo "  5. 快速查看所有用户连接链接"
        echo "  6. 进入原 mtp-new.sh 管理菜单"
        echo "  7. 查看 TAG / Middle Proxy / 服务日志"
        echo "  0. 退出"
        echo
        read -r -p "请选择 [0-7]: " choice
        case "$choice" in
            1) install_telemt; pause_menu ;;
            2) set_global_tag; pause_menu ;;
            3) set_user_tag; pause_menu ;;
            4) show_tags; pause_menu ;;
            5) show_links; pause_menu ;;
            6)
                [ -f "$UPSTREAM_SCRIPT" ] || { echo -e "${RED}请先安装。${PLAIN}"; pause_menu; continue; }
                bash "$UPSTREAM_SCRIPT"
                ;;
            7) show_diagnostics; pause_menu ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项。${PLAIN}"; sleep 1 ;;
        esac
    done
}

require_root
menu
