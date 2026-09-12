#!/usr/bin/env bash

# Telemt MTProxy 频道 TAG 交互管理器
# 适用于 jyucoeng/singbox-tools 的 mtp-new.sh 安装结果

set -u

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

CONFIG_FILE=""
BACKUP_FILE=""

die() {
    echo -e "${RED}错误：$*${PLAIN}" >&2
    exit 1
}

pause_menu() {
    echo
    read -r -p "按 Enter 键继续..." _
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 运行：sudo bash $0"
    fi
}

find_config() {
    if [ -n "${TELEMT_CONFIG:-}" ] && [ -f "$TELEMT_CONFIG" ]; then
        CONFIG_FILE="$TELEMT_CONFIG"
    elif [ -f /etc/telemt.toml ]; then
        CONFIG_FILE=/etc/telemt.toml
    elif [ -f /etc/telemt/telemt.toml ]; then
        CONFIG_FILE=/etc/telemt/telemt.toml
    else
        die "未找到 Telemt 配置文件（/etc/telemt.toml 或 /etc/telemt/telemt.toml）。"
    fi
}

require_python() {
    command -v python3 >/dev/null 2>&1 || die "未找到 python3，请先安装 python3。"
}

valid_tag() {
    [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]
}

valid_user() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

backup_config() {
    BACKUP_FILE="${CONFIG_FILE}.tag-backup.$(date '+%Y%m%d-%H%M%S')"
    cp -p "$CONFIG_FILE" "$BACKUP_FILE" || die "无法备份配置文件。"
}

# 按 TOML section 安全设置/删除一个键，避免 sed 跨 section 误删。
toml_edit() {
    local action="$1" section="$2" key="$3" value="${4:-}"
    python3 - "$CONFIG_FILE" "$action" "$section" "$key" "$value" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
action, wanted, key, value = sys.argv[2:6]
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

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

if action == "set":
    new_line = f'{key} = "{value}"'
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([f'[{wanted}]', new_line])
    else:
        replaced = False
        for i in range(start + 1, end):
            if key_re.match(lines[i]):
                lines[i] = new_line
                replaced = True
                break
        if not replaced:
            lines.insert(start + 1, new_line)
elif action == "set_bool":
    new_line = f'{key} = {value}'
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend([f'[{wanted}]', new_line])
    else:
        replaced = False
        for i in range(start + 1, end):
            if key_re.match(lines[i]):
                lines[i] = new_line
                replaced = True
                break
        if not replaced:
            lines.insert(start + 1, new_line)
elif action == "remove":
    if start is not None:
        for i in range(start + 1, end):
            if key_re.match(lines[i]):
                del lines[i]
                break
else:
    raise SystemExit("unknown edit action")

path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY
}

list_users() {
    python3 - "$CONFIG_FILE" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
inside = False
for line in lines:
    header = re.match(r'^\s*\[([^]]+)]', line)
    if header:
        inside = header.group(1).strip() == "access.users"
        continue
    if not inside:
        continue
    match = re.match(r'^\s*(?:"([A-Za-z0-9_-]+)"|([A-Za-z0-9_-]+))\s*=\s*"[0-9a-fA-F]{32}"', line)
    if match:
        print(match.group(1) or match.group(2))
PY
}

user_exists() {
    list_users | grep -Fxq "$1"
}

show_bindings() {
    python3 - "$CONFIG_FILE" <<'PY'
import re
import sys

sections = {}
current = ""
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    header = re.match(r'^\[([^]]+)]', line)
    if header:
        current = header.group(1).strip()
        sections.setdefault(current, {})
        continue
    item = re.match(r'^(?:"([^"\n]+)"|([A-Za-z0-9_-]+))\s*=\s*"([^"\n]*)"', line)
    if item and current:
        sections.setdefault(current, {})[item.group(1) or item.group(2)] = item.group(3)

general = sections.get("general", {})
print("全局 TAG : " + (general.get("ad_tag") or "未设置"))
user_tags = sections.get("access.user_ad_tags", {})
if user_tags:
    print("按用户绑定：")
    for user, tag in sorted(user_tags.items()):
        print(f"  {user}: {tag}")
else:
    print("按用户绑定：无")
PY
    echo -e "配置文件: ${BLUE}${CONFIG_FILE}${PLAIN}"
}

restart_telemt() {
    local restart_ok=0
    echo -e "${BLUE}正在重启 Telemt...${PLAIN}"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files telemt.service >/dev/null 2>&1; then
        systemctl restart telemt && systemctl is-active --quiet telemt && restart_ok=1
    elif command -v rc-service >/dev/null 2>&1 && [ -e /etc/init.d/telemt ]; then
        rc-service telemt restart && rc-service telemt status 2>/dev/null | grep -q started && restart_ok=1
    else
        echo -e "${YELLOW}未找到 telemt 系统服务，配置已保存，请手动重启。${PLAIN}"
        return 0
    fi

    if [ "$restart_ok" -eq 1 ]; then
        echo -e "${GREEN}✅ Telemt 已重启，TAG 配置已生效。${PLAIN}"
        echo -e "备份文件: ${BACKUP_FILE}"
        return 0
    fi

    echo -e "${RED}❌ Telemt 重启失败，正在回滚配置...${PLAIN}"
    cp -p "$BACKUP_FILE" "$CONFIG_FILE"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart telemt 2>/dev/null || true
        journalctl -u telemt -n 30 --no-pager 2>/dev/null || true
    else
        rc-service telemt restart 2>/dev/null || true
    fi
    die "新配置未能启动，已恢复修改前配置。"
}

prepare_change() {
    backup_config
    # 广告 TAG 依赖 Telegram middle proxy。
    toml_edit set_bool general use_middle_proxy true
}

set_global_tag() {
    local tag
    echo -e "${YELLOW}请填写 @MTProxyBot 返回的 TAG，不是客户端 Secret。${PLAIN}"
    read -r -p "32 位全局 TAG: " tag
    tag="${tag,,}"
    valid_tag "$tag" || { echo -e "${RED}TAG 必须是 32 位十六进制字符。${PLAIN}"; return 1; }
    prepare_change
    toml_edit set general ad_tag "$tag"
    restart_telemt
}

set_user_tag() {
    local users user tag
    users="$(list_users)"
    [ -n "$users" ] || { echo -e "${RED}配置中没有找到用户。${PLAIN}"; return 1; }
    echo "现有用户："
    echo "$users" | nl -w2 -s'. '
    read -r -p "请输入用户名: " user
    valid_user "$user" && user_exists "$user" || { echo -e "${RED}用户不存在或用户名不合法。${PLAIN}"; return 1; }
    read -r -p "32 位 TAG: " tag
    tag="${tag,,}"
    valid_tag "$tag" || { echo -e "${RED}TAG 必须是 32 位十六进制字符。${PLAIN}"; return 1; }
    prepare_change
    toml_edit set access.user_ad_tags "$user" "$tag"
    restart_telemt
}

remove_global_tag() {
    read -r -p "确定删除全局 TAG？[y/N]: " answer
    [[ "$answer" =~ ^[yY]$ ]] || return 0
    backup_config
    toml_edit remove general ad_tag
    restart_telemt
}

remove_user_tag() {
    local user
    show_bindings
    read -r -p "请输入要解除 TAG 的用户名: " user
    valid_user "$user" || { echo -e "${RED}用户名不合法。${PLAIN}"; return 1; }
    backup_config
    toml_edit remove access.user_ad_tags "$user"
    restart_telemt
}

show_help() {
    cat <<EOF
绑定流程：
  1. 在 Telegram 联系 @MTProxyBot，发送 /newproxy。
  2. 提交服务器公网 IP:端口。
  3. 提交 [access.users] 里的 32 位原始 Secret。
  4. 在 Bot 中选择赞助频道，复制返回的 32 位 TAG。
  5. 回到本脚本，设置全局 TAG 或按用户 TAG。

注意：
  - 客户端继续使用原 mtp-new.sh 输出的 tg://proxy 链接。
  - 不要把 TAG 拼到 tg://proxy 的 secret 里。
  - 频道展示可能有 Telegram 服务端缓存延迟。
EOF
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${GREEN}      Telemt MTProxy TAG 频道管理${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        show_bindings
        echo
        echo "  1. 设置/更换全局 TAG（全部用户）"
        echo "  2. 为指定用户设置 TAG"
        echo "  3. 删除全局 TAG"
        echo "  4. 删除指定用户 TAG"
        echo "  5. 查看当前绑定"
        echo "  6. 查看 @MTProxyBot 绑定教程"
        echo "  7. 重启并查看 Telemt 状态"
        echo "  0. 退出"
        echo
        read -r -p "请选择 [0-7]: " choice
        case "$choice" in
            1) set_global_tag; pause_menu ;;
            2) set_user_tag; pause_menu ;;
            3) remove_global_tag; pause_menu ;;
            4) remove_user_tag; pause_menu ;;
            5) show_bindings; pause_menu ;;
            6) show_help; pause_menu ;;
            7)
                backup_config
                restart_telemt
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl status telemt --no-pager -l 2>/dev/null || true
                else
                    rc-service telemt status 2>/dev/null || true
                fi
                pause_menu
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项。${PLAIN}"; sleep 1 ;;
        esac
    done
}

require_root
require_python
find_config
main_menu
