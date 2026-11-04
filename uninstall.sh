#!/usr/bin/env bash
# 卸载 claude-code-elevate：移除脚本、钩子、allow 规则和 CLAUDE.md 段落。
# 出于安全考虑，不会删除 deny 规则；需要时可按 README 手动移除。
set -euo pipefail

BIN="$HOME/.local/bin/elevate"
HOOK="$HOME/.claude/hooks/root-guard.py"
SETTINGS="$HOME/.claude/settings.json"
CLAUDEMD="$HOME/.claude/CLAUDE.md"

info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

rm -f "$BIN" "$HOOK"
info "已移除 elevate 和 root-guard.py"

python3 - "$SETTINGS" "$CLAUDEMD" <<'PY'
import json
import os
import shutil
import sys
import time

settings_path, claude_md = sys.argv[1:3]

if os.path.exists(settings_path):
    with open(settings_path, encoding="utf-8") as f:
        raw = f.read().strip()
    data = json.loads(raw) if raw else {}
    if isinstance(data, dict):
        perms = data.get("permissions")
        if isinstance(perms, dict):
            allow = perms.get("allow")
            if isinstance(allow, list):
                perms["allow"] = [x for x in allow if x != "Bash(elevate *)"]

        hooks = data.get("hooks")
        if isinstance(hooks, dict):
            pre = hooks.get("PreToolUse")
            if isinstance(pre, list):
                for entry in pre:
                    entries = entry.get("hooks")
                    if not isinstance(entries, list):
                        continue
                    entry["hooks"] = [
                        h for h in entries
                        if "root-guard.py" not in (h.get("command") or "")
                    ]
                # 清掉只剩空壳的 Bash 条目
                hooks["PreToolUse"] = [
                    e for e in pre
                    if not (e.get("matcher") == "Bash" and not e.get("hooks"))
                ]

        backup = f"{settings_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(settings_path, backup)
        with open(settings_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        print(f"[uninstall] settings.json 已更新（备份：{backup}）")
        print("[uninstall] 保留 deny 规则；如需删除请手动编辑 settings.json")

if os.path.exists(claude_md):
    with open(claude_md, encoding="utf-8") as f:
        text = f.read()
    start, end = "<!-- claude-code-elevate:begin -->", "<!-- claude-code-elevate:end -->"
    if start in text and end in text:
        a = text.index(start)
        b = text.index(end) + len(end)
        text = (text[:a] + text[b:]).strip()
        with open(claude_md, "w", encoding="utf-8") as f:
            f.write(text + ("\n" if text else ""))
        print("[uninstall] CLAUDE.md 已移除 claude-code-elevate 段落")
PY

info "卸载完成（审计日志保留在 ~/.local/share/elevate/）"
