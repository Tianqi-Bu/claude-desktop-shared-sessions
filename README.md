# claude-desktop-shared-sessions

**Claude 桌面端换号不丢对话（Windows）** · Keep one Claude Desktop session list across accounts and third-party gateways

[English below](#english)

Claude 额度用完换个号、或者用 CC Switch 切到第三方中转之后，Claude 桌面端 Code 标签左边的对话列表就变了：之前的对话找不到，接不上之前的工作。这个项目让本机所有登录方式看到**同一份**对话列表，换号后点开就能接着干。

> ⚠️ 2026-10-09 之前的版本用的是 NTFS 联接（junction），**会导致对话卡片悄悄存不进去**，请升级。安装脚本会自动把旧版的联接换回普通文件夹。详见下面的「为什么不能用联接」。

## 它是怎么工作的

对话分两部分存：

| 内容 | 位置 | 换号会不会变 |
|---|---|---|
| 对话正文（每句话、每次工具调用） | `%USERPROFILE%\.claude\projects\…\<对话ID>.jsonl` | 不会，所有号共用一份 |
| 左边列表里的"卡片"（标题、时间、指向哪个正文文件） | `<桌面端数据目录>\claude-code-sessions\<账号ID>\<组织ID>\local_*.json` | **会**，每种登录方式各有一个文件夹 |

数据目录：官方账号在 `%APPDATA%\Claude`（商店版实际位于 `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude`），第三方 / 网关模式在 `%LOCALAPPDATA%\Claude-3p`。

所以对话从来没丢，丢的是"目录卡片"。本项目借助 Claude Code 自带的 [hooks](https://code.claude.com/docs/en/hooks)，在下面这些时刻，自动把所有登录方式的卡片合并成同一份：

- Claude 回完一句话（`Stop`），并在 3 秒、10 秒后各补一次。补跑是因为桌面端会在 hook 结束后才写入这一轮最后的卡片更新；
- 因为额度限制等原因被迫中断（`StopFailure`），这正是最常需要换号的时候；
- 打开、关闭一个对话（`SessionStart` / `SessionEnd`）。

脚本不常驻后台，没有计划任务，也不修改 Claude 本体。只用 Windows 自带的 PowerShell 5.1，不联网，**不读写对话正文**，也**不消耗 token**：作为 hook 运行时不输出任何内容。

### 合并规则

两边都有同一张卡片时，按下面的顺序决定保留哪份，选出的那份会复制到所有登录方式：

1. **桌面端能读的**。带 BOM、空文件、截断或损坏的 JSON 不会被扩散；如果它是 15 秒内刚改过的，会被视为"正在写入"，这一轮先不碰它。
2. **没有过时的**。对话压缩或 `/clear` 之后，卡片会换到新的正文文件，并在 `priorCliSessionIds` / `preClearCliSessionId` 里记下旧的。仍然指向旧文件的副本永远不会胜出，否则你会接回旧的进度。
3. **没被桌面端标成"找不到正文"的**（`transcriptUnavailable`）。
4. **`lastActivityAt` 更新的**，相同时比较文件修改时间更新的。

其他规则：

- 在某个号里删除的对话（`deleted_<id>` 墓碑），会在所有号里删除；之后又被恢复或导入的除外。
- 读不了的卡片、列不出的文件夹，这一轮都不写。
- 写入是原子操作（先写临时文件再替换），读取时不会挡住桌面端保存。

### 备份

位置：`%USERPROFILE%\claude-session-sync-backup\`

- 每天第一次同步时，把所有卡片完整快照一份，保留 14 天。
- 每次替换或删除卡片之前，先存一份旧的（相同内容只存一份），保留 3 天。
- 整个文件夹上限 300 MB，超过就先删最旧的。
- 日志 `sync.log` 每次同步写一行，满 1 MB 自动轮换，最多约 2 MB。

## 安装

```powershell
git clone https://github.com/Tianqi-Bu/claude-desktop-shared-sessions.git
cd claude-desktop-shared-sessions
powershell -ExecutionPolicy Bypass -File .\Install-SyncHook.ps1
```

如果是下载 ZIP 解压的，先对文件夹运行一次 `Get-ChildItem -Recurse | Unblock-File`。

安装脚本会做这些事：

1. 把脚本复制到 `%USERPROFILE%\.claude-session-sync\`。
2. 把旧版留下的联接文件夹换回普通文件夹。这一步需要先从托盘退出 Claude，脚本会提示你。
3. 把 hooks 加进 `%USERPROFILE%\.claude\settings.json`。你原有的其他设置和 hooks 一个字节都不动，重复运行也不会重复添加，改之前会先备份。
4. 如果装了 [CC Switch](https://github.com/farion1231/cc-switch)，把同样的 hooks 写进它的 Claude 通用配置（需要 Python）。
5. 同步一次，跑一遍体检，在桌面放一个「Sync Claude Sessions」快捷方式。

`-ExecutionPolicy Bypass` 只对这一次运行有效，不改系统设置。

## 日常使用

**什么都不用做，正常换号即可。** 只需要记住一条：**等 Claude 回完这一句再换号。**

- 一个**从没登录过**的新号第一次登录时，列表可能是空的（它的文件夹刚建出来）。切到别的号再切回来，或者重启一次 Claude 就好。
- 改名、归档、删除这类只在界面上做的操作，要等下一句回完才会同步过去，只影响显示。
- 想确认状态，双击桌面的「Sync Claude Sessions」：它会立即同步一次并做体检，最后显示 `No failures` 就说明正常。

## 体检

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-session-sync\Check-ClaudeSwitch.ps1"
```

只读，Claude 开着也能跑。检查内容：

- 所有登录方式的列表是否一致，有没有联接文件夹；
- **桌面端日志里有没有卡片保存失败**（官方和第三方两边的日志都看）；
- 有没有对话已经没有卡片；
- 有没有设置 `CLAUDE_CONFIG_DIR`；
- 对话保留期；
- hook 是否已安装，最近一次同步的结果；
- CC Switch 的每个 Claude 渠道是否启用了通用配置；
- `claude doctor` 是否认为 `settings.json` 有效（只要有一个值不合法，Claude Code 会忽略整个文件，所有插件和 hooks 都会悄悄失效）。

## 出问题时

- **误删了一个对话**：`Restore-ClaudeSession.ps1 -Id <对话ID>` 会从备份里找回卡片，写回所有登录方式，并清掉删除标记。然后切一次号或重启 Claude 就能看到。
- **有对话已经没有卡片**（体检会报出来）：在普通终端窗口里运行 `claude --desktop --resume <对话ID>`，桌面端会打开这个对话并补建卡片。菜单里的"帮助 → 故障排查 → 导入 Claude Code CLI 会话"只能找回在终端里开的对话。
- **卸载**：`Uninstall-SyncHook.ps1`。它只删除本项目的 hooks（`settings.json` 和 CC Switch 两边）、桌面快捷方式和安装的脚本；你的其他设置、所有卡片和备份都保留。

## 为什么不能用联接（junction）

最直接的想法是：把各个登录方式的卡片文件夹做成指向同一个文件夹的联接。本项目的旧版就是这么做的，结果是：

- **读取正常**：换号后能看到列表。
- **保存被拒绝**：桌面端每次保存卡片前都会检查，`<账号>\<组织>` 这一层必须是真实文件夹，而且真实路径要和表面路径一致。否则报错 `Refusing non-directory at private dir path (symlink/file plant)`，然后放弃保存。
- **后果**：在被联接的登录方式里新建的对话、以及压缩上下文后卡片的更新，都只存在内存里，桌面端一重启就消失。已有对话的卡片会停留在旧的正文文件上，再打开就接回了旧进度。

更上层的目录可以做链接，但每个登录方式最底层那个文件夹的名字各不相同，所以没法让它们变成同一个文件夹。单个卡片文件做硬链接也会被拒绝。真正共用同一个文件夹，在目前的桌面端上做不到，所以只能靠同步。

## 前提与限制

- 所有登录方式要用同一个 `~/.claude`。不要给不同账号设置不同的 `CLAUDE_CONFIG_DIR`，否则正文就分开了。
- 不要同时开着官方模式和第三方模式两个桌面端实例。
- 不共享的内容：claude.ai 的云端连接器（Google Drive、Claude Docs 等）和已发布的 Artifact；账号同步下来的 skill（`skills-plugin` 目录归桌面端管理）；侧边栏的自建分组；每个账号各自的"跳过权限确认"开关。
- 换账号或换中转后，之前各轮的"思考过程"会被接口丢掉，Claude 会重读对话再继续，文字内容完整。第一轮因为缓存失效会多耗一些额度。如果中转把 `claude-*` 映射成了别家模型，那就不是同一个模型了。
- 桌面端的存储格式不是公开接口，以后的版本可能改变。到时体检会报出来，你的对话正文不受影响。
- 本项目与 Anthropic 无关。

## 文件

| 文件 | 作用 |
|---|---|
| `Install-SyncHook.ps1` / `Uninstall-SyncHook.ps1` | 安装 / 卸载 |
| `Sync-ClaudeSessions.ps1` | 同步本体（hooks 调用它） |
| `Check-ClaudeSwitch.ps1` | 只读体检 |
| `Restore-ClaudeSession.ps1` | 从备份恢复一个对话的卡片 |
| `Unlink-ClaudeAccounts.ps1` | 把旧版的联接文件夹换回普通文件夹（安装脚本会自动调用） |
| `Sync-Now.ps1` | 桌面快捷方式：立即同步并体检 |
| `common.ps1`、`hooks.ps1` | 公共函数 |
| `tests\Run-Tests.ps1` | 75 项自动化测试，全部在 `%TEMP%` 的假目录里运行 |

测试覆盖：

- 合并、过时卡片、`/clear` 和压缩、墓碑与恢复；
- 损坏、带 BOM、截断、正在写入、被锁住的卡片；
- 联接文件夹、补跑、备份清理、中文和特殊字符路径；
- 体检的各项判断；
- 安装和卸载：其他设置不变、重复安装逐字节一致、CC Switch 配置。

开发环境：Windows 11、Windows PowerShell 5.1、Claude 桌面端商店版 2.31226、Claude Code 2.1.290、CC Switch 3.20.4。

## 相关项目与 issue

- 复制或迁移类方案：[RasmusKD/claude-desktop-session-sync](https://github.com/RasmusKD/claude-desktop-session-sync)、[ramonmazinga/claude-code-multi-account-bridge](https://github.com/ramonmazinga/claude-code-multi-account-bridge)、[craigstoller/claude-code-sessions](https://github.com/craigstoller/claude-code-sessions)、[brunoflma/claude-session-linker](https://github.com/brunoflma/claude-session-linker)、[vitaliyhayda/claude-transplant](https://github.com/vitaliyhayda/claude-transplant)。"完好的卡片优先"借鉴自 RasmusKD。
- 用联接方案的：[alksdesu/ClaudePlusPlus](https://github.com/alksdesu/ClaudePlusPlus)，原因见上文，会遇到同样的保存问题。
- 官方 issue：[#74662](https://github.com/anthropics/claude-code/issues/74662)、[#97295](https://github.com/anthropics/claude-code/issues/97295)、[#48511](https://github.com/anthropics/claude-code/issues/48511)、[#63082](https://github.com/anthropics/claude-code/issues/63082)。

---

## English

Switching Claude accounts in Claude Desktop, or pointing it at a third-party gateway (e.g. with CC Switch), changes the Code tab's session list, and earlier conversations seem to vanish. They don't: the conversations live in `~/.claude/projects` and are shared. What changes is the per-login folder of session **cards** at `<userData>\claude-code-sessions\<account>\<org>\local_*.json`. This project keeps those cards identical for every login, so after a switch you see the same list and continue where you left off.

> ⚠️ Versions before 2026-10-09 used NTFS junctions. **Claude Desktop refuses to save cards into a junctioned folder** (`Refusing non-directory at private dir path (symlink/file plant)`). Sessions created or updated under a linked login lived only in memory and disappeared on restart, and other sessions resumed an old transcript. Please upgrade; the installer turns old junctions back into real folders.

**How it works.** Claude Code [hooks](https://code.claude.com/docs/en/hooks) run `Sync-ClaudeSessions.ps1` at these points:

- `Stop`, followed by short-lived follow-ups at about +3 s and +10 s (Desktop writes a turn's last card update after the hook returns);
- `StopFailure`, e.g. a rate limit, which is exactly when people switch;
- `SessionStart` and `SessionEnd`.

There is no resident process and no scheduled task, and the app is not patched. It runs on Windows PowerShell 5.1 only and needs no network. It never reads or writes transcripts and prints nothing in hook mode, so it costs no tokens.

**Merge rules.** For each card, the best copy goes to every login, chosen in this order:

1. Readable. BOM, empty or broken JSON never spreads. A broken copy changed in the last 15 s is treated as being written and left alone.
2. Not out of date. A copy whose `cliSessionId` appears in another copy's `priorCliSessionIds` or `preClearCliSessionId` never wins, so you never resume an old point of a conversation after a compaction or `/clear`.
3. Not marked `transcriptUnavailable`.
4. Newer `lastActivityAt`, then newer file time.

Other rules:

- Deletions (`deleted_<id>` tombstones) propagate unless the card changed afterwards.
- Unreadable cards and unlistable folders are not written that run.
- Writes are atomic, and reads share access so the app is never blocked.

**Backups** live in `%USERPROFILE%\claude-session-sync-backup`:

- daily snapshots, kept 14 days;
- deduplicated pre-change copies, kept 3 days;
- a 300 MB cap on the whole folder;
- `sync.log`, which rotates at 1 MB.

**Install:** `powershell -ExecutionPolicy Bypass -File .\Install-SyncHook.ps1`. It:

1. copies the scripts to `%USERPROFILE%\.claude-session-sync`;
2. converts old junctions to real folders (quit Claude first if any exist);
3. adds the hooks to `~/.claude/settings.json`, leaving every other setting byte-for-byte as it was, idempotently and with a backup;
4. mirrors the hooks into CC Switch's common config if CC Switch is installed (needs Python);
5. syncs once, runs the health check and adds a desktop shortcut.

**Use:** nothing to do. Switch accounts after Claude finishes a reply. A brand-new login may show an empty list the first time; switch away and back, or restart Claude, once.

**Health check:** `Check-ClaudeSwitch.ps1`, read-only. It checks:

- that every list is the same and no folder is a link;
- failed card saves in the official and Claude-3p Desktop logs;
- conversations without a card;
- `CLAUDE_CONFIG_DIR`;
- transcript retention;
- that the hook is installed, and the last sync's result;
- CC Switch common-config coverage;
- `settings.json` validity via `claude doctor`.

**Recovery:**

- `Restore-ClaudeSession.ps1 -Id <id>` brings back a deleted card from the backups.
- `claude --desktop --resume <id>`, run in a normal console window, re-creates a missing card. The Help > Troubleshooting import only finds sessions started in a terminal.
- `Uninstall-SyncHook.ps1` removes only this project's hooks, shortcut and scripts.

**Why not junctions:** Claude Desktop requires each `<account>\<org>` folder to be a real directory whose real path equals its own path, and refuses hard-linked card files. Links above that level are allowed, but every login's folder has a different name, so one physical folder for all logins is impossible without patching the app.

**Limits:**

- Every login must use the same `~/.claude` (no per-account `CLAUDE_CONFIG_DIR`).
- Don't run the official and the third-party Desktop instances at the same time.
- Not shared: claude.ai connectors and published artifacts, account-synced skills, sidebar custom groups, and per-account permission opt-ins.
- After a switch, prior thinking blocks are dropped by the API, while the text history is intact.
- The storage format is not a public API; the health check will flag changes.

Not affiliated with Anthropic. MIT license.
