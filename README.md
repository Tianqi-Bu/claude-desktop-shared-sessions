# claude-desktop-shared-sessions

**Claude Desktop 共享会话列表（Windows）** · Share one Claude Desktop session list across accounts and third-party gateways

换 Claude 账号、或者用 CC Switch 之类的工具切到第三方中转后，Claude 桌面端 Code 标签里的会话列表就空了。这个项目让本机所有登录方式共用**同一份**会话列表：打开 Claude，之前的对话都在，点开就能接着干。

[English below](#english)

## 原理

对话内容本来就是共用的，存在 `%USERPROFILE%\.claude\projects\*.jsonl`，跟登录哪个号无关。

桌面端只是把"会话列表"按登录方式分开存：

```
<数据目录>\claude-code-sessions\<账号ID>\<组织ID>\local_*.json
```

- 官方账号的数据目录：`%APPDATA%\Claude`（商店版在 `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude`）
- 第三方 / 网关模式：`%LOCALAPPDATA%\Claude-3p`

换号或切第三方，桌面端就去读另一个空目录。本项目选一个目录作为主列表，把其他目录都换成指向它的 NTFS 目录联接（junction）。这样所有登录读写的都是同一组文件，不需要定时同步，也不会出现两份副本越改越不一样。

- 不需要管理员权限，不装后台程序或计划任务，不修改 Claude 本体，不联网
- 只用 Windows 自带的 Windows PowerShell 5.1（PowerShell 7 未测试），源码可以直接读
- 不复制、不改写对话内容

## 用法

下载：`git clone https://github.com/Tianqi-Bu/claude-desktop-shared-sessions.git`，或在 GitHub 页面点 Code → Download ZIP 后解压（解压后可对文件夹运行 `Get-ChildItem -Recurse | Unblock-File`）。

### 最简单：双击

1. 新账号（或新的第三方配置）登录一次，打开一次 Code 标签。这一步是让桌面端先把这个登录的目录建出来。
2. 右键 `Connect-NewLogin.ps1` →「使用 PowerShell 运行」，按中文提示操作：
   - 先退出 Claude
   - 预览要做的改动
   - 回车确认后执行
   - 执行完自动体检

   想放到桌面上：新建一个快捷方式，目标填
   ```
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本项目路径>\Connect-NewLogin.ps1"
   ```
3. 重新打开 Claude。

### 命令行

```powershell
# 从托盘右键退出 Claude（Claude 在运行时，脚本会拒绝执行 -Apply）
powershell -ExecutionPolicy Bypass -File .\Link-ClaudeAccounts.ps1          # 空跑：只显示计划，不改动任何东西
powershell -ExecutionPolicy Bypass -File .\Link-ClaudeAccounts.ps1 -Apply   # 执行
powershell -ExecutionPolicy Bypass -File .\Check-ClaudeSwitch.ps1           # 体检：只读，Claude 开着也能跑
```

`-ExecutionPolicy Bypass` 只对这一次运行生效，不会改系统设置。如果你的电脑由组策略强制了执行策略，这个参数无效，请先对下载的脚本运行 `Unblock-File`，或者联系管理员。

## 主列表

- 第一次执行时，主列表选**官方数据目录里会话最多的那个目录**；只有官方目录不存在时，才会用第三方目录。
- 选定后，脚本会在主列表里放一个标记文件 `.claude-session-link-master`。以后撤销再链接，主列表也不会换。
- 如需手动指定，用 `-Master <目录>`。
- 脚本每次都会打印主列表在哪。

## 合并规则

执行 `-Apply` 时，被换成联接的目录里的会话卡片会先合并进主列表。两边都有同一张卡片时，按下面的顺序决定保留哪份：

1. **桌面端能读的优先。** 带 UTF-8 BOM 的、空文件、解析不了的 JSON（例如写到一半被截断），桌面端都会跳过。这种卡片不会被复制，也不会覆盖别的卡片。
2. **完好的优先。** 桌面端找不到对话文件时，会清掉卡片里的 `cliSessionId` 并标记 `transcriptUnavailable`（[anthropics/claude-code#63082](https://github.com/anthropics/claude-code/issues/63082)），这种卡片不会覆盖完好的卡片。
3. **`lastActivityAt` 更新的优先。**
4. **文件修改时间更新的优先。** 比如在另一个登录里改了标题或归档了会话。

其他情况：

- 主列表里没有的卡片：直接复制过去
- 主列表里已经删除的会话（有 `deleted_<id>` 墓碑）：不会被带回来
- 只在被替换目录里删除、主列表里还在的会话：会重新显示，脚本会提示数量
- 被替换目录里卡片以外的东西（定时任务、backlog 等）：如果和主列表里的同名文件内容相同，不提示；内容不同的，会列出来但不合并，定时任务会单独警告
- 被替换的目录整个移到 `%USERPROFILE%\claude-session-link-backup\<时间>\`，不删除
- 主列表里被覆盖的卡片，原始版本保存在备份的 `master-before\` 里。同一次运行中多次覆盖同一张卡片时，只保留最初那份
- 脚本只按字节复制文件，从不改写卡片内容

## 安全措施

- **Claude 桌面端在运行时拒绝执行 `-Apply`。** 判断依据是各数据目录里的 `lockfile` 是否被占用。
- **遇到链接目录时不动手。** 会话根目录（`claude-code-sessions`）本身是链接时直接拒绝；账号目录是链接时跳过；如果更上层的目录是链接，移动之前会先写一个探针文件，确认这个目录和主列表不是同一个物理目录。
- **备份目录必须和会话目录在同一个盘上**，保证移动是原子操作。
- **建好联接后会读回来核对**，确认它指向主列表。
- **失败时尽量恢复原样。** 建联接失败时，目录会被移回原处；如果连移回都失败，会告诉你目录现在在哪。已经合并进主列表的卡片会留在主列表里。
- **主列表标记只在至少成功链接了一个登录后才写入**，失败的运行不会把主列表固定下来。
- **读不了的文件不会让整个运行中止。** 比如被别的程序锁住的文件，会被当作"内容不同"列出来，保留在备份里。

## 必须满足的前提

- **所有登录用同一个 `~/.claude`。** 不要给不同账号设置不同的 `CLAUDE_CONFIG_DIR`，否则某个登录找不到对话文件，会把共用的卡片标成"找不到对话"，所有登录都受影响。体检脚本会检查这一点。
- **不要同时运行官方和第三方两个桌面端实例。**
- **切换前等 Claude 回完当前这一轮。** 桌面端换号时会结束正在运行的会话。

## 共享了什么，没共享什么

| 共享（都在本机） | 不共享 |
|---|---|
| 会话列表、对话内容 | claude.ai 云端连接器（Google Drive、Claude Docs 等），以及发布的 Artifact |
| `~/.claude` 下的 skill、插件、hooks、CLAUDE.md | 账号同步下来的 skill（`skills-plugin` 目录归桌面端管理，会按登录方式重写）。需要的话复制一份到 `~/.claude/skills` |
| 用户级 MCP（`~/.claude.json`） | 侧边栏自建分组（存在桌面端 Local Storage，按账号和服务器同步） |
| 主列表里的定时任务（在当前登录的账号下运行） | 每个账号的"跳过权限确认"开关、Remote Control |

## 换后端接着跑，要知道的事

- **之前的思考过程会被丢掉。** 换账号或换中转后，接口会丢掉旧的思考块，Claude 重读对话后继续，内容不会丢。Claude Code 会自动处理签名错误，前提是中转把上游错误原样返回。
- **第一条消息更耗额度。** prompt 缓存按账号区分，换号后第一轮要重新计算。
- **中转返回的不一定是 Claude 模型。** 有的中转、或 CC Switch 的模型映射，会把 `claude-*` 映射成别家模型，这种情况谈不上无损。
- **用过联网搜索的会话，切到非 Anthropic 后端前先 `/compact`。**
- **建议在 `settings.json` 里设置 `"cleanupPeriodDays": 3650`。** 默认 30 天后会删除较早的对话。

## CC Switch 用户

CC Switch 3.20.4 切换渠道时会**整个重写** `~/.claude/settings.json`。没勾"写入通用配置"的渠道，切过去后插件、hooks、权限、状态栏都会丢（[cc-switch#6871](https://github.com/farion1231/cc-switch/issues/6871)）。

修法：在 CC Switch 的通用配置片段里放好你的设置，并在**每个** Claude 渠道上勾选"写入通用配置"。装了 Python 时，体检脚本会检查这一项，并核对通用配置里的键都还在 `settings.json` 里。

**`settings.json` 里只要有一个值不合法，Claude Code 就会忽略整个文件**，所有插件、hooks、权限一起失效，而且不会弹任何提示。例如某些版本只接受字符串形式的 `"attribution": {"commit": "", "pr": ""}`，写成 `false` 就会触发。所以体检脚本会调用 `claude doctor`，它报告 "Invalid settings" 时判为 FAIL。

CC Switch 给桌面端第三方模式用的是一个固定的配置 ID，所以在 CC Switch 里换中转不会产生新目录。第一次用 CC Switch，或者改用别的第三方配置方式时，可能会多出一个目录，体检会提示，再接入一次就行。

## 撤销与恢复

**撤销链接**：退出 Claude 后运行 `Unlink-ClaudeAccounts.ps1 -Apply`。

- 每个联接会变回独立目录，里面放一份主列表的完整副本，包括卡片、墓碑和定时任务。脚本会先复制到临时目录，复制成功后才替换联接。替换失败时，会把联接重新建回去。
- 主列表本身不变，合并时做的改动也不会撤回。

**主列表丢失了**（比如商店版被重置或卸载，所有联接都指向一个已经不存在的目录）：

- 备份文件夹里只有各个登录在链接之前的原目录，**没有主列表本身**。
- 如果你自己备份过主列表，把它放回原位置即可。
- 否则运行 `Unlink-ClaudeAccounts.ps1 -Apply -AllowEmpty`，把断掉的联接换成空目录，从头开始。需要的话，再从 `claude-session-link-backup` 里取回某个登录原来的目录。

**把某个目录恢复成链接之前的原样**：先执行上面的撤销，再用 `claude-session-link-backup\<时间>\<账号>__<组织>\` 里的内容替换那个目录。一定要先撤销：如果直接往联接里复制，文件会写进主列表。

## 风险说明

- 桌面端的存储格式不是公开接口，以后的版本可能改变。
- 主列表通常在官方数据目录里。**卸载商店版、在"设置 → 应用"里重置 Claude、或者在 App 里重置应用数据**，都会清空主列表，所有登录一起受影响。做这些操作前，先运行 `Unlink-ClaudeAccounts.ps1 -Apply`，或者备份主列表目录。
- 本项目与 Anthropic 无关。

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

测试在 `%TEMP%` 下搭建一套假的目录结构，跑完会清理。测试不会修改本机的真实数据；不过体检相关的用例会只读地读取本机的 `settings.json` 和 CC Switch 数据库。`claude doctor` 那一项用假的 `claude` 程序测试，不会运行真的 CLI。

覆盖的情况有：

- 空跑不改动任何东西
- 合并规则，以及备份里保留的是最初的原件
- 重复运行没有副作用
- 新出现的登录能被接入
- 撤销后再链接，主列表不变，也不误报定时任务
- 有多个官方账号时，主列表保持不变
- Claude 运行时拒绝执行
- 文件被占用时安全失败
- 坏卡片、带 BOM 的卡片、截断的卡片不会扩散
- `lastActivityAt` 相同时按文件修改时间判断
- 数据目录本身是链接时拒绝执行
- 路径含空格、方括号、中文时正常
- 备份目录在别的盘上时拒绝执行
- 主列表丢失时的体检结果和撤销行为，以及 `-AllowEmpty`
- `claude doctor` 报告设置无效时，体检判为 FAIL
- 撤销中途失败时联接保持原样
- 链接全部失败时不写主列表标记
- 读不了的文件不会中止运行

开发环境：Windows 11、Windows PowerShell 5.1、Claude 桌面端商店版 2.19675.0、CC Switch 3.20.4。

## 文件

| 文件 | 作用 |
|---|---|
| `Link-ClaudeAccounts.ps1` | 合并并链接，默认空跑 |
| `Connect-NewLogin.ps1` | 双击用的中文引导，内部调用 Link 和 Check |
| `Check-ClaudeSwitch.ps1` | 只读体检：共享列表和链接、坏卡片、`CLAUDE_CONFIG_DIR`、对话保留期、CC Switch 通用配置，以及用 `claude doctor` 确认 `settings.json` 有效 |
| `Unlink-ClaudeAccounts.ps1` | 撤销链接 |
| `common.ps1` | 公共函数 |
| `tests\Run-Tests.ps1` | 自动化测试 |

## 相关项目

- [alksdesu/ClaudePlusPlus](https://github.com/alksdesu/ClaudePlusPlus)：同样用 junction 统一会话池，是带托盘守护的 Tauri 应用
- [RasmusKD/claude-desktop-session-sync](https://github.com/RasmusKD/claude-desktop-session-sync)：每 5 分钟用计划任务复制同步一次，同时同步分组和定时任务。"完好的卡片优先"这条规则借鉴自它
- [ramonmazinga/claude-code-multi-account-bridge](https://github.com/ramonmazinga/claude-code-multi-account-bridge)、[craigstoller/claude-code-sessions](https://github.com/craigstoller/claude-code-sessions)、[brunoflma/claude-session-linker](https://github.com/brunoflma/claude-session-linker)、[vitaliyhayda/claude-transplant](https://github.com/vitaliyhayda/claude-transplant)：复制或迁移类的方案
- 官方 issue：[#74662](https://github.com/anthropics/claude-code/issues/74662)、[#97295](https://github.com/anthropics/claude-code/issues/97295)、[#48511](https://github.com/anthropics/claude-code/issues/48511)

和这些方案相比，本项目不做持续的复制或同步，也不常驻后台：只在链接时合并一次，之后各个目录都指向同一处。

---

## English

Switching Claude accounts, or pointing Claude Desktop at a third-party gateway (e.g. with CC Switch), empties the Code tab's session list. The conversations themselves live in `~/.claude/projects` and are shared; only the list is stored per login, at `<userData>\claude-code-sessions\<account>\<org>\`. These scripts keep one real folder and replace every other account/org folder, in both the official and the `Claude-3p` profile, with an NTFS junction pointing at it, so every login reads and writes the same list. No admin rights, no background task, no app patching. Runs on Windows PowerShell 5.1; PowerShell 7 is untested.

**Scripts**

- `Link-ClaudeAccounts.ps1` merges records into the master, then links each other folder.
  - Dry run by default; `-Apply` to act. Refuses while Claude Desktop is running (lockfile check).
  - The master is the official profile's biggest folder. It is then marked with `.claude-session-link-master`, so it stays the master after unlink and relink.
  - When both sides hold a record, the winner is decided in this order: readable beats unreadable (BOM, empty, invalid or truncated JSON); healthy beats transcript-unlinked; newer `lastActivityAt`; newer file time.
  - Master tombstones are respected. The master's original copies and the replaced folders are kept in a same-drive backup.
  - Linked roots are refused; a probe file guards against moving the master; the new link is read back and verified; a failed link rolls the folder back.
- `Connect-NewLogin.ps1` is a guided, double-click wrapper (Chinese prompts).
- `Check-ClaudeSwitch.ps1` is a read-only health check: one shared list, valid links, missing master, unreadable or unlinked records, `CLAUDE_CONFIG_DIR`, transcript retention, CC Switch common-config coverage, and `settings.json` validity via `claude doctor` (one invalid value makes Claude Code ignore the whole file, silently turning off every plugin, hook and permission; use `-SkipDoctor` to skip this check).
- `Unlink-ClaudeAccounts.ps1` turns links back into real folders, each holding a full copy of the list. It stages the copy first and restores the link if the swap fails. If the master is missing it refuses; `-AllowEmpty` replaces the broken links with empty folders. The backup holds each login's folder from before linking, never the shared list itself.
- `common.ps1` holds shared helpers. `tests\Run-Tests.ps1` runs self-contained tests on fake folders under `%TEMP%`; they read the real `settings.json` and CC Switch database read-only, and never modify them.

**Requirements:** every login uses the same `~/.claude` (no per-account `CLAUDE_CONFIG_DIR`); don't run the official and third-party desktop instances at once; switch between turns, not during one.

**Not shared:** claude.ai connectors, account-synced skills, sidebar custom groups, per-account permission opt-ins.

Uninstalling or resetting the Store app wipes the shared list for every login, so unlink or back up first. Independent project, not affiliated with Anthropic. MIT license.
