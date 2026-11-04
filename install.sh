#!/usr/bin/env bash
# claude-code-elevate 安装脚本：安装助手脚本、PreToolUse 守卫，并合并 Claude Code 配置。
# 不需要 root；所有安装都落在当前用户的家目录里。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
HOOK_DIR="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"
CLAUDEMD="${HOME}/.claude/CLAUDE.md"
ICON_DIR="${HOME}/.local/share/elevate"
DRY_RUN=0

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法：./install.sh [--dry-run]

  --dry-run   只检查依赖并打印计划，不写入任何文件
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$arg（--help 查看用法）" ;;
    esac
done

# ---------------------------------------------------------------- 依赖检查
command -v python3 >/dev/null || die "缺少 python3"

if ! python3 - <<'PY'
import gi
from gi.repository import Gio, GLib
PY
then
    die "缺少 python3-gi（Debian/Ubuntu：apt install python3-gi），或通知服务不可用"
fi

if ! command -v pkexec >/dev/null; then
    warn "找不到 pkexec（policykit-1），安装后只能弹通知、无法真正以 root 执行"
fi

if [ "$DRY_RUN" = 1 ]; then
    info "依赖检查通过（dry-run，不做任何改动）"
    echo "  将安装：$BIN_DIR/elevate"
    echo "  将安装：$HOOK_DIR/root-guard.py"
    echo "  将合并：$SETTINGS"
    echo "  将追加：$CLAUDEMD（claude-code-elevate 标记块）"
    exit 0
fi

# ---------------------------------------------------------------- 安装文件
install -d "$BIN_DIR" "$HOOK_DIR" "$ICON_DIR"
install -m 0755 "$REPO_DIR/bin/elevate" "$BIN_DIR/elevate"
install -m 0755 "$REPO_DIR/hooks/root-guard.py" "$HOOK_DIR/root-guard.py"
info "已安装 elevate 与 root-guard.py"

case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) warn "${BIN_DIR} 不在 PATH 里，可能需要在 shell 配置里加上它" ;;
esac

# ---------------------------------------------------------------- 图标（可选）
# 默认从本机 Claude Code 扩展里复制官方图标，避免在仓库中再分发；
# 找不到就用系统图标，也可以用 ELEVATE_ICON 指定。
if [ -n "${ELEVATE_LOGO:-}" ] && [ -f "${ELEVATE_LOGO}" ]; then
    install -m 0644 "$ELEVATE_LOGO" "$ICON_DIR/claude-logo.png"
    info "已使用 ELEVATE_LOGO 指定的图标"
elif [ ! -f "$ICON_DIR/claude-logo.png" ]; then
    found=""
    for dir in "$HOME"/.vscode/extensions/anthropic.claude-code-*/resources \
               "$HOME"/.vscode-server/extensions/anthropic.claude-code-*/resources; do
        if [ -f "$dir/claude-logo.png" ]; then
            found="$dir/claude-logo.png"
            break
        fi
    done
    if [ -n "$found" ]; then
        cp "$found" "$ICON_DIR/claude-logo.png"
        info "已复制 Claude 图标：$found"
    else
        warn "没找到 Claude 图标，将使用系统图标（可用 ELEVATE_ICON 指定）"
    fi
fi

# ---------------------------------------------------------------- 合并配置
python3 - "$SETTINGS" "$HOOK_DIR/root-guard.py" "$CLAUDEMD" <<'PY'
import json
import os
import shutil
import sys
import time

settings_path, hook_path, claude_md = sys.argv[1:4]

ALLOW = "Bash(elevate *)"
DENY = [
    "Bash(sudo *)",
    "Bash(pkexec *)",
    "Bash(doas *)",
    "Bash(su *)",
    "Bash(runuser *)",
    "Bash(setpriv *)",
]

data = {}
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        raw = f.read().strip()
    if raw:
        data = json.loads(raw)
if not isinstance(data, dict):
    raise SystemExit(f"{settings_path} 顶层不是 JSON 对象，已中止")

perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
if ALLOW not in allow:
    allow.append(ALLOW)

deny = perms.setdefault("deny", [])
for rule in DENY:
    if rule not in deny:
        deny.append(rule)

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
bash_entry = next((e for e in pre if e.get("matcher") == "Bash"), None)
if bash_entry is None:
    bash_entry = {"matcher": "Bash", "hooks": []}
    pre.append(bash_entry)
entries = bash_entry.setdefault("hooks", [])
if not any("root-guard.py" in (h.get("command") or "") for h in entries):
    entries.append({
        "type": "command",
        "command": f"python3 {hook_path}",
        "timeout": 10,
        "statusMessage": "检查提权命令",
    })

new_text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
old_text = ""
if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        old_text = f.read()

if new_text == old_text:
    print("[install] settings.json 无需改动")
else:
    if old_text:
        backup = f"{settings_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(settings_path, backup)
        print(f"[install] 已备份 settings.json -> {backup}")
    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print("[install] settings.json 已合并 allow / deny / PreToolUse 钩子")

BLOCK = """<!-- claude-code-elevate:begin -->
## 需要 root 权限时

不要直接调用 `sudo` / `pkexec` / `doas` / `su` / `runuser` / `setpriv`
（`settings.json` 的 deny 规则和 `root-guard.py` 钩子会拦截）。

统一使用：

    elevate --intent "<一句话说明为什么需要 root>" -- <命令...>

- 弹出桌面通知，带「允许」「拒绝」按钮；
- 允许 → pkexec 弹系统密码框，通过后以 root 执行；
- 拒绝、关闭通知、超时（默认 120 秒）一律不执行（fail-closed）；
- 退出码：0 成功，10 用户拒绝，11 超时或通知被关闭，12 无法发通知 / 找不到 pkexec；
- 审计日志：`~/.local/share/elevate/requests.log`。

注意：守卫按词元匹配，命令里不要出现 `sudo` 等词（`grep sudo` 也会被拦）；
无图形会话（SSH）时通知发不出去，需要人工执行。
<!-- claude-code-elevate:end -->
"""

old_md = ""
if os.path.exists(claude_md):
    with open(claude_md, encoding="utf-8") as f:
        old_md = f.read()

if "claude-code-elevate:begin" in old_md:
    print("[install] CLAUDE.md 已有 claude-code-elevate 段落，保持不变")
else:
    os.makedirs(os.path.dirname(claude_md), exist_ok=True)
    sep = "" if not old_md else ("\n" if old_md.endswith("\n") else "\n\n")
    with open(claude_md, "a", encoding="utf-8") as f:
        f.write(sep + BLOCK)
    print("[install] CLAUDE.md 已追加全局约定")
PY

# ---------------------------------------------------------------- 完成
info "安装完成"
cat <<EOF

下一步：
  1. 重启 Claude Code（或重开会话），让 settings.json 的钩子生效；
  2. 测试通知（不会执行命令）：
       elevate --dry-run --intent "测试通知" -- true
  3. 真实提权示例：
       elevate --intent "安装 python3-gi 依赖" -- apt-get install -y python3-gi
  4. 卸载：
       $REPO_DIR/uninstall.sh

EOF
