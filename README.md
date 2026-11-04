# claude-code-elevate

让 AI 编程助手（Claude Code 等）在需要 root 时，**先弹一条带「允许 / 拒绝」按钮的桌面通知**，你点了允许、再通过 `pkexec` 输入密码，命令才会以 root 执行。

- 通知里同时显示 **意图**（为什么需要 root）和 **完整命令**；
- 拒绝、关闭通知、超时 → 命令不执行（fail-closed）；
- 配合 Claude Code 的 `PreToolUse` 钩子，拦住绕过 `elevate` 的直接 `sudo`；
- 纯用户态安装，安装脚本本身不需要 root；
- 支持自定义应用名与图标，默认适配 Claude Code。

```
┌──────────────────────────────────────────────────┐
│  Claude Code · 安装 python3-gi 依赖               │
│  $ apt-get install -y python3-gi                 │
│                              [ 允许 ]  [ 拒绝 ]  │
└──────────────────────────────────────────────────┘
```

## 为什么需要它

把终端交给 AI 之后，最危险的一步是提权：命令以 root 跑，出错就没有回头路。常见的做法是给 `sudo` 配 NOPASSWD，或者干脆让助手自己调 `sudo`——两者都等于把 root 权限永久敞开。

claude-code-elevate 把提权变成一个**需要人确认的显式动作**：

1. 助手不能直接 `sudo`，只能调用 `elevate`；
2. 每次调用都弹通知，显示它想干什么、要跑什么命令；
3. 你点「允许」之后，还有系统自己的 polkit 密码框作为第二道确认；
4. 任何一步没有通过，命令都不会执行。

## 工作原理

```
AI 助手 ──调用──> elevate ──通知──> 你点「允许」
                                      │
                                      ▼
                              pkexec 弹密码框
                                      │
                                      ▼
                              以 root 执行命令
```

`elevate` 用 Python Gio 直接向 `org.freedesktop.Notifications` 发送带动作按钮的 `Notify` 请求，并监听 `ActionInvoked` / `NotificationClosed` 信号。之所以不用 `notify-send`，是因为 Ubuntu 22.04 自带的 0.7.9 版本没有 `--action` / `--wait`。

配套的 `hooks/root-guard.py` 是 Claude Code 的 `PreToolUse` 钩子：只要 Bash 命令里出现 `sudo`、`pkexec`、`doas`、`su`、`runuser`、`setpriv`（按词元匹配，包含绝对路径和嵌套 shell 的写法），就返回 `permissionDecision: "deny"`，并提示改用 `elevate`。

## 依赖

- Linux 桌面会话（在 GNOME 42 上实测；其他实现了 `org.freedesktop.Notifications` 的桌面理论上也可用）；
- Python 3 + PyGObject（`python3-gi`）；
- polkit 的 `pkexec`；
- 可选：Claude Code（用于钩子部分）。

Debian / Ubuntu：

```bash
sudo apt install python3-gi policykit-1
```

## 安装

```bash
git clone https://github.com/YanRuiZhan/claude-code-elevate.git
cd claude-code-elevate
./install.sh
```

安装脚本只写当前用户的家目录：

| 路径 | 内容 |
| --- | --- |
| `~/.local/bin/elevate` | 提权助手 |
| `~/.claude/hooks/root-guard.py` | `PreToolUse` 守卫 |
| `~/.claude/settings.json` | 追加 allow / deny 规则和钩子（先备份） |
| `~/.claude/CLAUDE.md` | 追加一段全局约定（带标记，可幂等重复安装） |
| `~/.local/share/elevate/claude-logo.png` | 可选图标，从本机 VS Code 扩展复制 |

几点说明：

- **合并而不是覆盖**：脚本会读取现有 `settings.json`，只追加缺失的规则；写入前备份为 `settings.json.bak-<时间戳>`。
- **图标**：仓库不附带 Claude 的商标图片。安装时如果在本机 Claude Code 扩展里找到 `claude-logo.png` 就复制过来，否则回退到系统图标 `system-lock-screen`。也可以用 `ELEVATE_ICON` / `ELEVATE_LOGO` 指定。
- 安装完需要**重启 Claude Code**（或重开会话），钩子才会生效。

### 手动安装

不想跑脚本的话，把 `bin/elevate` 和 `hooks/root-guard.py` 分别复制到 `~/.local/bin` 和 `~/.claude/hooks`，然后在 `~/.claude/settings.json` 里合并：

```json
{
  "permissions": {
    "allow": ["Bash(elevate *)"],
    "deny": [
      "Bash(sudo *)",
      "Bash(pkexec *)",
      "Bash(doas *)",
      "Bash(su *)",
      "Bash(runuser *)",
      "Bash(setpriv *)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 /home/<你>/.claude/hooks/root-guard.py",
            "timeout": 10,
            "statusMessage": "检查提权命令"
          }
        ]
      }
    ]
  }
}
```

## 使用

```bash
elevate --intent "安装 python3-gi 依赖" -- apt-get install -y python3-gi
```

- `--intent`（必填）：一句话说明为什么需要 root，显示在通知标题里；
- `--timeout N`：等待响应的秒数，默认 120，超时视为拒绝；
- `--dry-run`：只走通知与授权流程，不执行命令（用于测试）；
- `--` 之后：要执行的命令（按参数原样传递，内部用 `shlex.join` 拼成 shell 命令交给 `pkexec /bin/bash -c`）。

用 AI 助手时，你不需要自己调它——全局约定会要求助手在需要 root 时使用这个入口。

### 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 命令执行成功 |
| `10` | 你点了「拒绝」 |
| `11` | 超时未响应，或通知被关闭 |
| `12` | 无法发送通知（无图形会话）或找不到 `pkexec` |
| 其余 | 命令自身的退出码；`126` / `127` 通常表示 polkit 认证失败或被取消 |

### 审计日志

每次请求都会追加一行 JSON 到 `~/.local/share/elevate/requests.log`，包含时间、意图、命令、决定（`allow` / `deny` / `executed`）、等待时长和退出码。

### 环境变量

| 变量 | 作用 |
| --- | --- |
| `ELEVATE_APP_NAME` | 通知里显示的应用名，默认 `Claude Code` |
| `ELEVATE_ICON` | 自定义图标：stock 图标名或图片绝对路径 |
| `ELEVATE_LOGO` | 仅安装脚本使用：指定要复制为默认图标的图片 |

## 一键配置 AI 提示词

把下面这段直接发给 Claude Code（或其他能改配置的助手），让它替你安装并合并配置：

```text
请在这台 Linux 机器上安装并配置 claude-code-elevate：
https://github.com/YanRuiZhan/claude-code-elevate

要求：
1. 先通读 README，然后运行 ./install.sh 安装 elevate 与 PreToolUse 守卫。
2. 修改 ~/.claude/settings.json 时必须「合并」而不是覆盖：保留现有
   permissions.allow / permissions.deny / hooks，只追加：
     - allow: "Bash(elevate *)"
     - deny: "Bash(sudo *)" "Bash(pkexec *)" "Bash(doas *)"
       "Bash(su *)" "Bash(runuser *)" "Bash(setpriv *)"
     - hooks.PreToolUse 中 matcher 为 Bash 的条目里追加
       python3 ~/.claude/hooks/root-guard.py
   修改前先备份 settings.json（settings.json.bak-时间戳）；
   已有相同规则或钩子就跳过，不要重复添加。
3. 在 ~/.claude/CLAUDE.md 末尾追加一段全局约定：需要 root 时禁止直接
   sudo/pkexec，统一改用
     elevate --intent "<中文意图>" -- <命令>
   并说明退出码 0/10/11/12 与审计日志路径
   ~/.local/share/elevate/requests.log。
4. 检查 python3-gi 和 pkexec 是否已安装；缺依赖就告诉我，不要自己提权安装。
5. 安装后运行
     elevate --dry-run --intent "测试通知" -- true
   验证通知能弹出，把结果告诉我。
```

## 安全模型与边界

**它做了什么**

- 每次提权都需要人在通知上点「允许」，再通过 polkit 认证；
- 拒绝 / 关闭 / 超时一律不执行；
- 钩子拦截常见的绕过写法（`/usr/bin/sudo`、`\sudo`、`bash -c "sudo ..."` 等）；
- `settings.json` 的 deny 规则是第二层，即使钩子失效也仍然拦截直接提权。

**它不做什么**

- **不是沙箱**。它只约束「提权」这一步，不限制 `elevate` 里到底跑什么命令——所以通知里的命令内容值得看一眼。
- 守卫是启发式的：按词元切分，能挡住常见写法，但挡不住刻意构造的混淆。它只是补充，不是攻击面隔离。
- 守卫按词元匹配，因此命令里**不要出现** `sudo` 等词，连 `grep sudo` 也会被拒绝。

**polkit 行为**

`pkexec` 走系统 polkit 认证代理（GNOME 自带密码框）。策略 `org.freedesktop.policykit.exec` 默认是 `auth_admin`，每次真实执行都需要密码；如果你手动改成了 `auth_admin_keep`，短时间内可能免密——这是 polkit 的缓存行为，不是本工具绕过了认证。

## 已知限制

- **通知排版**：GNOME 42 的 `Message.setBody()` 会把正文里的换行全部替换成空格，正文实际只有一行；标题则会对 markup 做转义。所以稳妥的两行排法是「标题 = 意图，正文 = 命令」。`<tt>` 会原样显示，`U+2028` 虽然能断行但会渲染成缺字方块，都已避开。
- **无图形会话**：SSH / 纯终端下通知发不出去，`elevate` 以退出码 12 失败，需要人工执行命令。
- **图标**：从本机扩展复制的 logo 在扩展升级后仍可用（已复制到独立目录）；如果当初没找到，用的就是系统图标。
- **配置被改写**：某些配置管理工具会重写 `~/.claude/settings.json`，若 allow / deny / hook 丢失，重新运行 `./install.sh` 即可（脚本幂等）。
- **通知按钮数量**：部分桌面环境最多显示 3 个按钮，本工具只用了 2 个。

## 卸载

```bash
./uninstall.sh
```

会删除 `elevate`、`root-guard.py`、`settings.json` 里的 `Bash(elevate *)` 与钩子条目、以及 `CLAUDE.md` 中带标记的段落。出于安全考虑，**deny 规则会保留**，需要时手动删。审计日志保留在 `~/.local/share/elevate/`。

## 目录结构

```
claude-code-elevate/
├── bin/elevate           # 通知授权 + pkexec 执行
├── hooks/root-guard.py   # Claude Code PreToolUse 守卫
├── install.sh            # 用户态安装 / 合并配置
├── uninstall.sh          # 移除脚本与配置项
├── LICENSE               # MIT
└── README.md
```

## 许可证

代码以 MIT 许可证发布，见 [LICENSE](LICENSE)。仓库不包含 Claude / Anthropic 的商标或图标文件；安装脚本可选地从本机已安装的扩展中复制图标，仅供本机使用。
