#!/usr/bin/env python3
"""PreToolUse 守卫：拦截绕过 elevate 的直接提权命令。

允许的路径是：
    elevate --intent "..." -- <命令>

其余出现 sudo / pkexec / doas / su / runuser / setpriv 的 Bash 调用一律拒绝，
防止在嵌套 shell、绝对路径、env 包装等写法下绕过权限规则。

这是一个补充性的安全网，不是沙箱。
"""

import json
import os
import re
import sys

ESCALATORS = {"sudo", "pkexec", "doas", "su", "runuser", "setpriv"}

MESSAGE = (
    "检测到直接提权命令 `{token}`。需要 root 时不要自己调用 sudo/pkexec，"
    "请改用：elevate --intent \"<中文意图>\" -- <命令>。"
    "它会弹出带「允许/拒绝」按钮的桌面通知，允许后再由 pkexec 请求密码。"
)


def deny(token):
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": MESSAGE.format(token=token),
        }
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0

    if data.get("tool_name") != "Bash":
        return 0

    command = (data.get("tool_input") or {}).get("command", "")
    stripped = command.lstrip()

    # 授权助手本身要放行（包括绝对路径调用）
    if re.match(r"^(?:[^\s]*/)?elevate(?:\s|$)", stripped):
        return 0

    # 粗略切词，能覆盖 sudo、/usr/bin/sudo、\sudo、bash -c "sudo ..."
    for token in re.split(r'[\s;&|()<>`"\']+', command):
        token = token.lstrip("\\").strip()
        if not token:
            continue
        base = os.path.basename(token)
        if base in ESCALATORS:
            return deny(base)

    return 0


if __name__ == "__main__":
    sys.exit(main())
