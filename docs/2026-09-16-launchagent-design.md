# LaunchAgent 设计（路线图第 2 阶段：事件驱动）

日期：2026-09-16
状态：设计已确认，待实现
前置：第 1 阶段探测器已实现并实测通过（判定、进入/离家/往返/关 Wi-Fi，见 `AGENTS.md` 第 6 节）

## 1. 目标

把已经实测过的**判定**逻辑接上**触发**，让这个工具不需要人手动运行：

1. 加入已知网络时自动切到该网络的位置（进入方向，唯一自动的一条）。
2. 离开该网络时**只通知一次**，不自动切。

这里的「离开」包括：换到别的网络（手机热点）、彻底关掉 Wi-Fi。

### 非目标

- 不做菜单栏（第 3 阶段）。
- 不改判定逻辑：IP + MAC 双匹配、二层探测、退出方向不自动切（设计约定 4、5）。
- 不引入任何第三方依赖（设计约定 10）。
- 不做日志轮转（见第 7 节）。

## 2. 组件

| 文件 | 类型 | 职责 |
|---|---|---|
| `wifi-loc-detect.sh` | 改动 | 增加「通知去重」：状态文件 + 只在离家状态**刚出现**时通知 |
| `com.yayadesu.auto-network-location.plist` | 新增 | LaunchAgent 定义，装到 `~/Library/LaunchAgents/` |
| `~/.wifi-loc-control/state` | 运行时生成 | 记录用户当前是否已被告知离家（600） |
| `~/.wifi-loc-control/agent.log` | 运行时生成 | LaunchAgent 的 stdout/stderr（**launchd 建成 644**，见第 4 节实测） |

探测器仍然是唯一的代码文件，agent 不引入任何包装脚本——触发层保持「哑」的，所有判断都留在探测器里。

## 3. 状态语义

`state` 文件的含义是「**用户当前是否已被告知离家**」，不是「上次判定结果」。这个区别是本节的全部要点。

探测器的三种结局，按是否该打扰用户归档：

- `ok`：命中了某位置（无论是否已经在其中），或没命中但**当前位置就是默认位置**。不需要告诉用户任何事。
- `away`：没命中，且当前位置不是默认位置。该告诉用户。

状态转移：

| state 文件 | 判定 | `--notify` | 通知 | 新 state |
|---|---|---|---|---|
| 不存在 / `ok` | `ok` | 任意 | 不发 | 写 `ok` |
| `away` | `ok` | 任意 | 不发 | 写 `ok`（重置） |
| 不存在 / `ok` | `away` | 是 | **发** | 写 `away` |
| `away` | `away` | 是 | 不发（日志记一行说明） | 不变 |
| 任意 | `away` | 否 | 不发 | **不变** |

最后两行是关键，各自挡掉一个 bug：

- **`away` + `--notify` 不重复通知**：这就是「只通知一次」的实现。
- **`--notify` 缺席时不写状态**：否则你手动跑一次（不带 `--notify`）就会把状态改成 `away` 却没真的通知过，之后 agent 再跑就会认为「已经通知过了」而永远不提醒你。

由此 `--notify` 的语义从「无法识别网络就通知」变成「**无法识别网络、且这个状态还没报告过，就通知**」。参数个数不变，仍是 4 个。

其他约定：

- 路径 `~/.wifi-loc-control/state`，内容就是一行 `ok` 或 `away`。
- **内容不是 `away` 时（缺失、空、未知值）一律按「没通知过」处理**——失败方向要偏向「多打扰一次」，而不是静默吞掉。
- **只有通知真的送达才写 `away`**：`notify()` 失败时返回非零，状态不写，下一次触发会重试。理由同上——投递失败时重试的代价几乎是零（本来就不成功，不会真的弹窗打扰），而一旦 `osascript` 恢复正常，用户就能收到。
- 可用环境变量 `WLC_STATE` 覆盖，供测试使用（与 `WLC_CONFIG`、`WLC_DEFAULT` 一致）。
- **先通知、后写状态**：写失败只会导致下次重复通知；反过来会永久漏报，更糟。
- 写状态失败只记一行日志，**不影响**判定与切换的退出码。
- 状态文件位于 `~/.wifi-loc-control/`，**不在被监视的目录里**，所以它自身不会触发 launchd。

## 4. plist 规格

Label：`com.yayadesu.auto-network-location`

下文 `<repo>` 指 `__REPO__`。plist 里必须是这个字面绝对路径——launchd 不展开 `~`，也不做任何路径推导，所以仓库一移动就得重装（第 8 节）。

| 键 | 值 | 说明 |
|---|---|---|
| `ProgramArguments` | `/bin/bash`、`<repo>/wifi-loc-detect.sh`、`--apply`、`--notify` | 绝对路径；launchd 不展开 `~` |
| `WatchPaths` | `/Library/Preferences/SystemConfiguration` | 网络状态一变就触发（见第 5 节的自触发分析） |
| `StartInterval` | `300` | 兜底，见第 7 节的睡眠限制 |
| `RunAtLoad` | `true` | 登录即判定一次。`man launchd.plist` 说此键「should be avoided」（登录期大量任务同时启动），这里保留是因为它正对「开盖在家」这个场景；代价可忽略（一次约 1 秒） |
| `ThrottleInterval` | `60` | 照 `com.valvesoftware.steamclean.plist` 先例。副作用见第 5 节 |
| `ProcessType` | `Background` | 资源限制档位，避免影响交互体验 |
| `LimitLoadToSessionType` | `Aqua` | 确保 `osascript` 的通知落进 GUI 会话 |
| `Umask` | **字符串 `"077"`** | 见下面的陷阱 |
| `StandardOutPath` / `StandardErrorPath` | `~/.wifi-loc-control/agent.log` | 展开后的绝对路径 |

### `Umask` 的陷阱

`man launchd.plist`：值是整数时按**十进制**解释，属性列表无法写八进制；要写八进制必须用**字符串**并加前导 `0`。

所以 `Umask` 必须写字符串 `"077"`。若写成整数 `77`，实际生效的是十进制 77 = 八进制 115 —— 文件权限会变成一组你没预期的值。

**但 `Umask` 管不到 launchd 替你创建的日志文件。** 2026-09-16 实测：`Umask` 写的是字符串 `"077"`、`launchctl print` 也显示 `umask = 77`、脚本自己写的 `state` 是 `-rw-------`，而 `agent.log` 是 **`-rw-r--r--`**。结论：`Umask` 只约束 job 进程自己创建的文件，`StandardOutPath` / `StandardErrorPath` 由 launchd 创建，权限不受它影响。

因此安装时预置一次：先 `touch` 日志文件、`chmod 600`，再 `bootstrap`——launchd 打开已存在的文件时不会改其权限。实际暴露本来就是零（家目录是 `drwxr-x---+`，别的本地用户进不来），预置是为了严格符合第 8 节的隐私约定。

## 5. 自触发分析

切换位置会改写 `/Library/Preferences/SystemConfiguration/preferences.plist`，而 `WatchPaths` 正是监视这个目录，所以**切换这个动作会再次触发自己**。

结论：**不会死循环**，理由有两层。

1. **幂等兜底**（设计约定 6）。被触发的那一轮读到 `current location: 'Home'`、特征设备命中、`matched == current`，于是「already in 'Home', nothing to do」并退出——**不调用 `scselect`、不写 `SystemConfiguration`**，事件链到此为止。最多多跑一轮。
2. **`ThrottleInterval 60` 可能直接把它抑制掉**，连那一轮都不跑。

代价与副作用：`ThrottleInterval 60` 意味着 60 秒内的第二次触发会被**抑制**而非延后。若某个事件恰好落在切换后的 60 秒窗口里，那一轮会丢，只能等 `StartInterval` 的兜底。这是响应速度与运行频次的取舍，第 9 节把它列为待测量项。

## 6. 失败模式

| 情况 | 行为 |
|---|---|
| `locations.env` 缺失或全组非法 | 探测器退出 3。agent 每轮都在日志里记一行，不切换、不通知。不特殊处理，靠日志可见 |
| 状态文件不可写 | 记一行日志，判定与切换照常，退出码不变 |
| `scselect` 失败 | 探测器退出 1，日志记 `scselect ... failed` |
| 通知发送失败 | 探测器记 `notification failed`，**不**写 `away`，所以下一次触发会重试 |
| 仓库被移动 | plist 里的绝对路径失效，job 每次启动即失败。必须重装（第 8 节） |

## 7. 已知弱点（记录，不修）

- **唤醒后是否立刻触发，未知。** `man launchd.plist` 对两个键都有明确警告：
  - `WatchPaths`："Use of this key is **highly discouraged**, as filesystem event monitoring is highly race-prone, and it is entirely possible for modifications to be **missed**."
  - `StartInterval`："If the system is **asleep** during the time of the next scheduled interval firing, **that interval will be missed** due to shortcomings in kqueue(3)."

  也就是说兜底**不覆盖睡眠**：睡眠期间错过的间隔是直接跳过，不是延后补发。它能保证的只是「唤醒后最多 5 分钟内会跑一次」。而「开盖那一刻就切」取决于 `WatchPaths` 会不会在重新关联 Wi-Fi 时触发——**必须实测，不能推理**。若实测证明唤醒不触发且 5 分钟静默期不可接受，退回「常驻轮询进程」方案（`KeepAlive` + 自己 sleep，唤醒后循环自然继续）。

- **一次未解释的 8 秒探测失败（2026-09-16，待查）。** 10:49:38 那次由 `scselect` 触发的运行里，探测器对特征设备连续重试约 8 秒全是 `no answer`，位置因此停在 `Automatic`；39 秒后再探立刻命中。使用者已确认**当时连着的是家里的网络**（不是热点），所以这条不能用「换网」解释，也尚未复现：实测接口在切换后约 **3 秒**就拿到 DHCP 地址并解析出邻居条目，另有两次无人干预的运行分别在 1 秒和 3 秒内命中。**如果它会复发**，症状是「该切的时候没切，最多等一个 `StartInterval`」。复发时按第 9 节 V4 的重复实验取证，不要凭推理改探测逻辑。
- **`agent.log` 无界增长。** 每次运行 4–8 行；若每天数百次触发就是每年几十 MB 量级。删除是安全的（`state` 是独立文件，删掉只会让下次离家重新通知一次）。暂不做轮转。
- **`RunAtLoad` 与 `StartInterval` 都可能在一次登录里产生一次多余运行**，可接受。

## 8. 安装 / 卸载

安装（仓库路径移动后必须重做）：

```sh
cp com.yayadesu.auto-network-location.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl print gui/$(id -u)/com.yayadesu.auto-network-location
```

卸载：

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

`launchctl bootstrap` / `bootout` 是当前语法；`load` / `unload` 已被 `launchctl` 自己标为待替代。改过 plist 之后必须 `bootout` 再 `bootstrap`，launchd 不会自动重读。

## 9. 验证计划

无测试框架、无 CI，沿用第 1 阶段的「用真实配置和真实系统状态验」的做法。

| # | 项目 | 方法 | 期望 |
|---|---|---|---|
| V1 | 静态检查 | `plutil -lint`、`bash -n` | 通过 |
| V2 | 状态机 | 用临时 `WLC_STATE` + 桩 `osascript` 跑「离家 → 再离家 → 回 ok → 手动离家 → 离家」，以及桩失败的一轮 | 只有第 1、5 次通知；手动（无 `--notify`）跑不改状态；投递失败不写状态、下一次会重试 |
| V3 | 装载 | `bootstrap` 后 `launchctl print` | 出现在 gui/501 域，`RunAtLoad` 立刻产生一条日志 |
| V4 | 进入方向端到端 | 先确认设备在场，再 `scselect Automatic`，然后**只观察**最多 45 秒；重复 3 轮 | 每轮数秒内自动切回 `Home`，日志显示是 agent 触发的。**若期间有人手动改 Wi-Fi 网络或关掉 Wi-Fi，本轮作废**——2026-09-16 曾因为忽视这一点，把一次正确的判断误读成缺陷 |
| V5 | 自触发收敛 | 数 V4 期间的运行轮数 | 只多跑一轮，或被 `ThrottleInterval` 抑制；**不出现连续多轮** |
| V6 | 手动触发 | `launchctl kickstart -k gui/$(id -u)/<label>` | 产生一轮运行 |
| V7 | 离家去重 | 连手机热点，等触发，再手动 `kickstart` | 通知**只弹一次**；第二次日志里出现「已报告过」那一行 |
| V8 | 唤醒 | 真实睡眠一次，唤醒后观察 | 记录唤醒后多久跑了一轮（本设计的核心未知数） |
| V9 | 权限 | `stat` 两个运行时文件 | `state` 600；`agent.log` **默认 644**（launchd 创建，`Umask` 管不到），按第 4 节预置后应为 600 |
| V10 | 日志行为 | 多次运行后看行数 | 确认 launchd 是追加而非截断，并据实写入文档 |

V8 需要一次短暂睡眠；V7 需要再连一次热点。两者都要先告知使用者。

## 10. 未来工作

- 若 V8 证明唤醒不可靠：改「常驻轮询进程」（`KeepAlive` + 循环 sleep）。
- 若日志增长成为问题：在探测器里加一个按大小截断的动作，或改用 `newsyslog` 配置。
- 第 3 阶段：菜单栏显示当前位置并可点击切换。
- 多网络（`LOCATION_2` 等）已由配置格式支持，但状态文件目前是单一布尔值；若要区分「离开的是哪个网络」，需要把状态改为按位置记录。
