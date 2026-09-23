# 安装与可迁移性设计（决策文档）

> **本文是三选一的决策文档，不是最终设计。** 目的是把「换一台 Mac / 重装系统后重建」这件事
> 现在卡在哪、三条候选路各自要改什么、验收标准是什么、破坏性风险怎么处理，摊开放在一起。
> 选定之后才写 `docs/2026-09-21-install-and-portability-plan.md` 与实施步骤。
>
> 阅读前先看 `AGENTS.md` 第 2 节的不可动摇约定；本文的一切取舍都以那 12 条为前提。

## 1. 目标与非目标

**目标**：把迁移从「读 README 手工做四步」变成「一条命令 + 一次自检」，并且安装动作本身
**可重入、可回滚、可验收**。

**非目标**（本轮明确不做，见 §8）：

- 菜单栏（路线图第 3 项，与可迁移性无关）；
- 对外「陌生人不读文档就能装好」——那需要先解决「什么是这张网的标识」的引导，是另一个量级的工作；
- 新的网络判据、新的探测手段、对 SSID 的任何回退。

## 2. 不变量

原有十二条一条都不放松。此外本设计**提议**新增一条边界（它是 §7 待定问题 2，尚未拍板），
它以前没有被明确写下来：

- **运行时零提权，安装时允许一次性提权。** `scselect` 免提权（已实测），这是运行时成立的基础；
  但改网络设置本身需要管理员权限——`man networksetup` 原文：
  *"The networksetup command requires at least admin privileges to change network settings. If the
  'Require an administrator password to access system-wide preferences' option is selected in
  System Preferences > Security & Privacy, then root privileges are required to change network
  settings."*（2026-09-21 本机核对）

  因此：**建位置与设值这一步绕不开提权**。任何方案都必须把「哪一步要提权、运行时一次都不要」
  写清楚，并且不得把提权引入判定路径。

## 3. 现状：现在的安装方法（准确版）

### 3.1 四步

1. **建位置**（`README.md` §安装 1）：`Automatic` 保持 DHCP；另建一个位置（如 `Home`）配那张网的
   静态设置。`-createlocation <名>` 建的是**空位置**（没有服务）；`-createlocation <名> populate`
   建的是全新默认服务、**不复制**当前位置的 TCP/IP 与 DNS，**还会把原位置的服务清掉**。
2. **写配置**（§安装 2）：`mkdir -p ~/.wifi-loc-control`，写 `locations.env`（每张网一个编号组，
   权限 600）。MAC 要在**那张网上**用 `./wifi-loc-detect.sh --print-mac <地址>` 采集。
3. **试一下**（§安装 3）：干跑 → `--apply`。
4. **装 agent**（§自动运行）：预置 600 的 `agent.log` → `sed` 把 plist 里的 `__REPO__` / `__HOME__`
   换成字面路径 → `launchctl bootstrap` → `launchctl print` 校验。

**注意：不需要重启 Mac。** `bootstrap` 加 plist 里的 `RunAtLoad` 会立刻跑一轮
（2026-09-16 实测：那一轮 1 秒内完成切换）。「重启」是登录项时代的习惯，不是本方法的一部分。

### 3.2 迁移到新 Mac 时会卡在哪

| # | 卡点 | 证据 | 能否自动化 |
|---|---|---|---|
| 1 | 建位置 | `-createlocation` 的两种行为都反直觉、`populate` 有破坏性（`AGENTS.md` §5） | 能，但**必须提权**且必须先备份 |
| 2 | 采集 MAC | 特征设备的 MAC 只能在**它所在的那张网**上采；换台机器、同一个网络才采得到 | 半自动：脚本能采集，但人必须在场并切换网络 |
| 3 | plist 占位符 | launchd 不展开 `~` 与环境变量，必须替换成字面路径；仓库一搬家就失效（`README.md` §自动运行） | 能，完全自动 |
| 4 | 日志权限 | launchd 自建的 `agent.log` 是 644，plist 里的 `Umask` 管不到；600 只能在安装时预置（`AGENTS.md` §5） | 能，完全自动 |
| 5 | 装载校验 | 不提权时 `bootstrap` 返回 `Bootstrap failed: 5`，且极易被 `2>/dev/null` 吞掉；**必须**用 `launchctl print gui/$(id -u)/<label>` 判断（`AGENTS.md` §5） | 能，完全自动 |
| 6 | 目录必须先存在 | job 的日志写在 `~/.wifi-loc-control/agent.log`，目录不存在就写不进去（`README.md` §自动运行） | 能，完全自动 |
| 7 | 配置格式 | 每次都要人写一个 env 组；MAC 与 IP 都错一个字符就走不到预期分支 | 能生成模板 + 校验，但**值只能人来提供** |

结论：**7 个卡点里 4 个是纯机械的、可以完全自动化（#3–#6）；2 个半自动（#2 需要人在场并切到那张网，
#7 的值只能由人提供，脚本只负责生成模板与校验）；剩下 1 个（#1 建位置）需要提权且必须先备份**——
它就是「可迁移性」的全部难点。

## 4. 三条候选路

三条路**共用的部分**：都要新增一份「安装期流程」（前置检查 → 备份 → 建位置 → 写配置 → 装 plist →
校验），都要新增一个**只读自检**（`--check` / `doctor`），都要新增一份安装层配方（见 §6.6）。
差别在于**代码放哪、边界画在哪**。

### A. `install.sh` + `--check`（独立安装脚本）

- **文件**：新增 `install.sh`（唯一新增代码文件）；`wifi-loc-detect.sh` 只增加一个**只读**的
  `--check`；`AGENTS.md` §1 的文件清单要加一行。
- **接口**：`./install.sh [--dry-run] [--uninstall] [--create-location <名>]`；
  `./wifi-loc-detect.sh --check`（只读，退出码 0/1）。
- **流程**（9 步，全部幂等）：前置检查（macOS、bash 3.2、`~/.wifi-loc-control` 可写、是否已有
  agent、位置上是否存在）→ `scselect` 现状存档 → **备份** `preferences.plist` → （仅当显式要求时）
  建位置并把 IPv4/DNS 写进去 → 生成 `locations.env` 模板（**已存在则一个字都不改**）→ 预置 600 的
  日志 → 生成 plist 并 `bootout`（忽略失败）+ `bootstrap` → `launchctl print` 校验 → 跑一次
  `--check` 并打印结论。
- **破坏性风险的处理**：默认**不**建位置（要求显式 `--create-location`）；位置上已有服务就停下问人；
  任何将覆盖已存在文件的操作都先停；`--dry-run` 输出「将要做什么」而不落任何盘。
- **验收标准（逐条可执行）**：`--dry-run` 之后 `git status --short` 仍为空、`~/Library/LaunchAgents`
  下没有新增文件；`launchctl print gui/$(id -u)/<label>` 能打印出该 job 且上次退出状态为 `0`；
  `stat -f '%Sp' ~/.wifi-loc-control/agent.log` 是 `600`；`wifi-loc-detect.sh --check` 退出 0；
  `install.sh --uninstall` 之后 `launchctl print` 找不到该 label 且 plist 已删除，而
  `~/.wifi-loc-control/locations.env` **保留**（卸载不动数据）。
- **代价**：多一个代码文件（与「唯一代码文件」的现状不符，需要改 `AGENTS.md` §1）；安装期一次提权；
  备份与回滚逻辑本身需要被测试覆盖。

### B. 自安装子命令（脚本自己装自己）

- **文件**：不新增文件；`wifi-loc-detect.sh` 加 `install` / `uninstall` / `check` 三个子命令。
- **与 A 的差别**：接口从「两个程序」变成「一个程序三种生命周期」，最贴合「一个代码文件」的约定。
- **风险（都要在实施前解决）**：
  1. **默认行为绝不能变**：agent 的 `ProgramArguments` 是 `<脚本> --apply --notify`，既有 132 条断言
     也都按「无子命令 = 判定」写。子命令必须与既有选项正交，且 `--help` 要同时覆盖两者。
  2. 主脚本会在**每轮**被 launchd 执行，而安装动作一年跑一次：两种生命周期的权限要求相反
     （运行时 0 提权 / 安装 1 次提权），塞进同一个文件最容易让后来的人走错路。
  3. 体积：现在 682 行，加安装层后预计 ~900 行，自测脚本也要跟着长。
- **验收标准**：同 A，但多一条——`wifi-loc-detect.sh` 不带子命令时的输出与现在**逐字节可比**
  （用现有 132 条断言回归）。

### C. Homebrew tap

- **文件**：新增一个 tap 仓库 + `Formula/auto-network-location.rb`；本仓库仍要有 A 的安装流程。
- **决定性事实**：本项目**只靠 `WatchPaths` 触发**（`AGENTS.md` §5：刻意没有 `StartInterval`，
  因为睡眠期间错过的那次是直接跳过）。而 Homebrew 的 service DSL **不支持 `WatchPaths`**：
  2026-09-21 在本机 `/opt/homebrew/Library/Homebrew/` 全目录搜 `watch_paths` / `WatchPaths`
  **零命中**（同一次搜索里能命中的触发相关键是 `run_type`、`keep_alive`、`working_dir`）。

  于是 `brew services` 只能表达 `run_type` 轮询——**那正是被刻意删掉的东西**。要用 brew，只能
  放弃 `brew services`、让它只负责把文件放进 `bin`，plist 仍由本项目的安装脚本装载——那样 C 就退化
  成「A + 一个 formula」。
- **其他代价**：Homebrew 规定安装期不得交互，所以建位置与填配置**仍然**得靠单独的 `setup` 步骤；
  `brew services` 生成的 plist 路径指向 Cellar（带版本号目录），升级时由它重写，与「仓库搬家就得
  重装」这条已知限制叠加。
- **收益**：可发现性、`brew upgrade` / `brew uninstall`。
- **结论**：只有在「要对外发布」时才值得，且要接受退化形态。

## 5. 横向对比

| | A 独立安装脚本 | B 自安装子命令 | C Homebrew tap |
|---|---|---|---|
| 新增代码文件 | 1（`install.sh`） | 0 | 1（另一个仓库的 formula）+ A |
| 对「一个代码文件」约定的影响 | 需要改 §1 清单 | 无 | 无 |
| 安装期提权 | 1 次 | 1 次 | 1 次（且 brew 不代劳） |
| 能否保住 `WatchPaths` | 能 | 能 | **不能**（除非退化） |
| 升级路径 | `bootout` → 替换 → `bootstrap` | 同左 | brew 重写 plist，细节失控 |
| 对外分发 | 不解决 | 不解决 | 解决 |
| 测试成本 | 新增 1 份配方 | 新增 1 份配方 + 回归全部既有断言 | 同 A，另需维护 tap |
| 我的判断 | **推荐** | A 的变体，可后置 | 目前看不到必要收益 |

## 6. 无论选哪条都要解决的技术点

1. **建位置的可重入算法。** 幂等判据不能只看位置名：服务名会重名（两个位置里可以同时存在叫
   `Wi-Fi` 的服务，`AGENTS.md` §5），所以判据必须是「位置名 + 服务名 + 硬件端口」三者一起校验。
   三者都对齐才算「已经建好」；只要有一处不对就停下来问人，而不是覆盖。不存在才建；建完必须回头读
   一次（`networksetup -getinfo`）确认 IPv4/DNS 与预期一致——**建完不校验等于没建**。
2. **备份与回滚。** 备份什么、放哪、能否读（`/Library/Preferences/SystemConfiguration/preferences.plist`
   的读取权限要在实施时实测）、失败时回滚到哪一步、什么条件下**必须停下来问人**（位置已存在且已有
   服务 → 不动）。
3. **`--check` / `doctor` 的检查项**（全部只读）：位置是否存在且当前是哪个；该位置下服务是否绑对了
   硬件端口；IPv4/DNS 是否与配置一致；`locations.env` 是否存在、合法、是否含重复位置名；agent 是否
   已装载且上次退出状态是 `0`；`agent.log` 是否存在且权限 600；探针此刻能否命中特征设备；当前是否
   有未送达的通知欠账（`pending=`）。
4. **配置版本与迁移。** 加 `CONFIG_VERSION`；历史上已经处理过一次状态文件旧格式（`miss=` 与裸值），
   配置格式将来也会变，迁移路径要显式写出来而不是靠「读不出来就跳过」。
5. **权限边界。** 运行时 0 次提权；安装 1 次；`--check` 必须 **0 次**（只读）——这样它才能在任何
   一台机器上被人放心地跑一遍，这是「可迁移」的最小可用形态。
6. **安装层怎么测。** 用桩 `networksetup` / `launchctl` / `scselect` 记录**调用序列**，断言：
   `--dry-run` 零副作用；已存在的 `locations.env` 不被改写；位置上已有服务时不动手；失败路径不留下
   半成品。这份配方加入 runner 的 `SUITES`，让安装路径也进入现有 132 条断言的保护范围。

## 7. 推荐与待定问题

**推荐 A**：最小、最贴合现有约定、收益/风险比最好；C 目前没有可见收益（`WatchPaths` 那条事实基本
判了它的死刑，除非将来真要对外发布）。B 可以看作 A 的形态变体，等 A 的流程被证明可重入之后再谈
要不要合并成一个文件。

**待定的三个问题**（决定之后才写 `-plan.md`）：

1. **受众**：只服务自己（同一批网络、配置由我从旧机搬）还是也要给别的技术用户用？后者要额外解决
   「什么是这张网的标识」的引导与支持面。
2. **是否接受安装期提权**：接受 → 建位置可以自动化；不接受 → 安装脚本只能做「检查 + 打补丁 +
   打印一份精确的手工清单」，卡点 1 仍然留给用户。
3. **`--check` 是否严格只读**：我只读（推荐，可以在任意机器上跑）；或允许它顺手修复（更方便，但就
   不再是「安全地看一眼」）。

## 8. YAGNI（本轮明确不做）

菜单栏；`.pkg` 与代码签名/公证；客户端隔离、纯 IPv6、有线与 iPhone USB 共享等新网络形态；多用户
共享安装；配置文件加密；把 `locations.env` 改成机器可解析的数据格式（它现在是被 `source` 的代码，
这条约定有实测理由，见 `AGENTS.md` §9）。
