# AGENTS.md

本文件是 `auto-network-location` 的代理工作约定。改动代码前先读完。

> 本项目的由来：从 `wifi-loc-control` 的 fork（`Ya-yadesu/wifi-loc-control`）分出。
> 原项目与网上多数同类工具都靠**读 Wi-Fi SSID** 判断网络，而这条路在当前 macOS 上
> 已被堵死。本项目改用**特征设备的 MAC**，因此与上游没有共用代码。

## 1. 项目概览

```text
wifi-loc-detect.sh                        探测器（判定 + 可选切换，唯一代码文件，纯 bash 3.2 兼容）
com.yayadesu.auto-network-location.plist  LaunchAgent 定义（触发层，第 2 阶段）
README.md                                 面向用户的设计与用法说明（英文）
docs/                                     设计与实施文档（中文）
```

判据：把「当前处于哪个网络」变成一个**二层问题**——某台特征设备在不在这个局域网里。

## 2. 不可动摇的设计约定

改动前请确认没有违反以下任何一条：

1. **不读 SSID/BSSID。** 原因见第 3 节。不要以任何形式回退到 SSID 方案。
2. **不需要 root。** 切换位置用 `scselect`（已实测免提权）。任何需要 `sudo` 的设计都要先重新论证。
3. **探针走二层，不用 ICMP、不用 raw socket。** 手段是「向目标地址发包促使内核做 ARP 解析，再读 `arp -n`」。这样不依赖设备响应 ICMP，也不受受限环境影响。
4. **IP + MAC 双匹配。** 只匹配 IP 会在「另一个网络也有同地址设备」时误判；MAC 不匹配必须报为身份不符，而不是当作命中。这条对**特征设备与目标设备都适用**。
5. **两个方向都自动化，但只有「离开」会回落到默认位置。** 进入已知位置是自动的；特征设备连续两轮未确认（`miss` 安全阀）时自动回落到默认位置，让机器在任何网络上都能用；而**在某个已知位置内发现目标设备不符时，只通知、不回落**——那说明这张网本身变了，擅自动作会把静态设置悄悄换成 DHCP。两者靠**特征设备**（我在哪张网上）与**目标设备**（这张网还是我设置里期待的那张吗，默认取特征设备）区分，见 `docs/2026-09-16-decision-model-design.md`。
6. **幂等。** 已在目标位置就什么都不做。切换动作本身会改写 `SystemConfiguration`，会再次触发自己，必须靠幂等收敛。
7. **纯 bash 3.2。** macOS 自带 bash 是 3.2，**没有** `${var,,}`、`mapfile`、关联数组等 bash 4+ 特性。已因此写错过一次判断方向（见第 5 节）。
8. **配置是 env 文件、按编号成组。** `~/.wifi-loc-control/locations.env`，形如 `LOCATION_n_NAME/_IP/_MAC`。位置名是**变量值**而不是变量名，所以允许空格与非 ASCII。不要改回「变量名 = 位置名」的写法——那会把位置名限制成合法标识符。
9. **配置文件是被 `source` 的代码，不是被解析的数据。** 读取后立即 `unset` 掉 `LOCATION_*`，避免泄漏给子进程。新增配置项时保持这个模式，并在文档里提醒用户该文件的权限（600）与来源可信。
10. **零依赖。** 只用 macOS 自带命令。
11. 面向用户的字符串、注释、README 用**英文**；本文件与代理工作笔记用**中文**。
12. **通知去重靠状态文件，其含义是「用户当前是否已被告知一个异常状态」。** `ok` / `default` 一律重置；只有**真的送达**了才写 `broken`。这样手动跑（不带 `--notify`）不会污染状态，投递失败也不会被记成已送达，两者都不会让 agent 漏掉本该发的通知。**唯一的例外是回落**：位置真的切了，所以先记 `default` 再通知——不能因为通知失败就把状态写成「还在别处」。状态文件还存 `miss`（特征设备连续未确认的轮数）。改动这段逻辑前先读 `docs/2026-09-16-decision-model-design.md` 第 3 节的状态转移表。

## 3. 为什么不能用 SSID（实测，macOS 27.0 / 26A428）

- `ipconfig getsummary en0` 与 `system_profiler SPAirPortDataType` 在非 root 下把 **SSID 与 BSSID 同时**报成 `<redacted>`，且两者值长度相同（都是 10 字符）——说明是**输出层统一脱敏**，不是读不到网卡状态。
- `networksetup -listpreferredwirelessnetworks` 在非 root 下**不**遮蔽，但它给的是「首选网络列表」，顺序启发式，不是当前网络。
- `networksetup -getairportnetwork en0` 会**误报**「You are not associated with an AirPort network.」，即便设备已关联。
- `airport` 命令已被移除。
- 因此**不要**试图用 root/IPC 去「修好」SSID 读取；改用特征设备。

## 4. 探针的关键实测事实

- `ipconfig sendarp` **在 macOS 27 上不存在**（`ipconfig` 子命令只有 waitall、getifaddr、ifcount、getoption、getiflist、getsummary、getpacket、getv6packet、getra、getdhcpduid、getdhcpiaid、set、setverbose）。不要用它。
- 以下方式都能促使内核发出 ARP 并填充邻居表：`/dev/udp` 打开套接字、`nc -u`、`nc -tcp`、`curl`。**本项目用 `/dev/udp`**，因为它不需要调用任何外部命令。
- 目标不存在时，条目会以 `(incomplete)` 出现——判断时必须把它当作「不在场」，不能当成 MAC。
- 邻居表条目会老化失效；脚本因此带重试（默认 4 次 × 1 秒）。
- **换网后旧条目不会残留**（2026-09-16 实测）：Wi-Fi 从家里换到手机热点、位置仍停在 `Home` 时，脚本对特征设备读到的是 `no answer`（4 次重试约 7 秒），**没有**读到换网前的缓存。彻底关掉 Wi-Fi（`en0` status `inactive`、无 IP）时同样读到 `no answer`，行为一致。这是「离家」判定成立的前提——`probe_device` 在条目已存在时直接读缓存、不重新发包。若将来在别的 macOS 版本上观察到相反行为，必须改成无条件先发包再判定。
- **切换位置会清空邻居表**（2026-09-16 实测）：`scselect` 切完之后，特征设备的条目会消失（接口在重配），所以「刚切完设备显示不在场」是**正常现象**，不是设备离线。探测器在条目缺失时会自己发包重建（`trigger_arp`），因此不需要额外处理；但任何「一次探测就下结论」的改动都会因此误判。
- `arp -n` 的输出格式：`? (192.0.2.1) at 00:00:5e:00:53:01 on en0 ifscope [ethernet]`。示例值取自留白段：MAC 用 RFC 7042 的 `00:00:5e:00:53:00/24`，IP 用 RFC 5737 的 `192.0.2.0/24`，不要换成真机值。

## 5. 环境与工具陷阱（都已实际踩过）

- **bash 3.2**：`${mac,,}` 报 `bad substitution`，且**不终止脚本**（在子 shell 中失败），会把「匹配成功」判断成「身份不符」。所有大小写归一化用 `tr`。
- **`arp -n` 会省略前导零**：同一个 MAC，arp 可能输出 `0:0:5e:0:53:1`，而手写配置通常写 `00:00:5e:00:53:01`。只做小写归一化会让两者比较不等，把「在正确网络上」误报成「身份不符」——文档里的示例值正是补零写法，照抄就会踩到。`norm_mac` 现在同时补零；改动比较逻辑时必须保留这一点。
- **bash 3.2 + `set -u` 时空数组的 `${arr[*]}` 会报 unbound variable**（bash 4 才修），例如「数组是否已含某元素」的检查。必须先判 `${#arr[@]} -gt 0` 再展开。
- **`for arg in "$@"` 内 `shift` 无效**：迭代列表在进入循环前已固定。解析带取值的选项要用带下标的 `while` + `${!i}`。
- **`scselect` 切换后有 3~5 秒窗口**，期间 DNS 可能解析失败（`curl: (6) Could not resolve host`），随后自愈。判断「网络坏了」前必须等接口稳定再复测——本项目已因此误判两次。
- **`networksetup -createlocation <名>` 建的是空位置**（无服务、无接口）；`-createlocation <名> populate` 建的是**全新默认服务**（DHCP、无 DNS），**不复制**原位置的 TCP/IP 与 DNS，还会把原位置的服务清掉。要建位置就用 `-createnetworkservice <服务名> <硬件端口>` 显式创建后再 `-setmanual` / `-setdnsservers`。
- **`networksetup` 的改动只作用于「当前位置」**；两个位置可以同时存在叫 `Wi-Fi` 的服务，靠先 `scselect` 切过去消除歧义。
- **`networksetup -setv6off` 后**，`preferences.plist` 里的 `IPv6` 会带 `__INACTIVE__: True`，而不是变成 `Off`；以 `networksetup -getinfo` 显示 `IPv6: Off` 为准。
- **受限沙箱内 `ping`/`nc`/`traceroute`/`curl` 的连通性结论不可信**（`traceroute` 直接 `Operation not permitted`，同一沙箱内 ping 结果自相矛盾）。可信的是 `networksetup`、`scselect`、`route`、`scutil`、`arp`、以及 `preferences.plist`。连通性必须在真实终端核验。

### launchd（第 2 阶段新增，都已实际踩过）

- **两个触发键都不可靠。** `man launchd.plist` 对 `WatchPaths` 写着「highly discouraged …… entirely possible for modifications to be missed」，对 `StartInterval` 写着睡眠期间错过的那次是**直接跳过**、不是延后补发。所以兜底不覆盖睡眠，它只能保证「唤醒后最多 5 分钟内跑一次」。**本机实测（2026-09-16，合盖 5 分钟）：真正唤醒后 32 秒就触发了**；而且合盖期间系统有多次 **DarkWake**（`pmset -g log` 里每次约 10 秒），agent 在其中跑了两轮事件驱动的检查。**所以不需要常驻轮询方案。**
- **`ThrottleInterval` 是延后补跑，不是丢弃**（2026-09-16 实测）：落在窗口内的事件被推迟约 48–50 秒后**仍然执行了**。所以它既是限速也是延迟——调大能降频，代价是「你刚回到家」那一次也可能被推迟同样久。**测这类行为时观察窗口必须长于 `ThrottleInterval`**，否则会把「被推迟」误读成「没反应」：第一版验证配方用 45 秒窗口 + 70 秒间隔，三轮里误判了两轮。
- **触发频率取决于网络活动：安静时就是 `StartInterval`，活动时被 `ThrottleInterval` 压到 1/分钟。** 实测（2026-09-16）：连续网络活动期间（反复 `scselect`、热点反复重连）运行节奏是**每 60 秒一轮**，连续 11 轮无一例外；而**安静期 10 分钟只跑了 2 轮，间隔正好 300 秒**。所以「5 分钟兜底」是准确的描述，60 秒只出现在有事件的时候。据此估算日志增长：安静时约 288 轮/天（约 80 KB/天），有网络活动的日子更高。**不要只看到一段 60 秒节奏就断言「它在空转」**——先确认那段时间有没有人在动网络。
- **`scselect` 的改动会立即触发一轮**，这是「进入方向」得以自动化的原因，也是自触发的来源（见设计文档第 5 节）。
- **受限沙箱里 `launchctl bootstrap` 必须提权**：不提权返回 `Bootstrap failed: 5: Input/output error`（**没有**沙箱标记），而且这个 `rc=5` 极易被 `2>/dev/null` 吞掉——2026-09-16 因此白等 88 秒，误以为 agent 已在跑。**装载后必须用 `launchctl print gui/$(id -u)/<label>` 校验**，不要相信「命令没报错」。
- **改 plist 后必须 `bootout` 再 `bootstrap`**，launchd 不会自动重读；仓库移动后 plist 里的绝对路径失效，必须重装。
- **`launchctl` 的 `load`/`unload` 已被它自己标为待替代**，用 `bootstrap`/`bootout`。另外 `kickstart -k` 会给正在运行的实例发 SIGTERM（`print` 里留下 `last terminating signal = Terminated: 15`），调试用不带 `-k` 的形式。
- **plist 里的 `Umask` 必须写成字符串**（如 `"077"`）：属性列表的整数按十进制解释，写成整数 `77` 会得到八进制 115。但它**管不到 launchd 替你创建的 `StandardOutPath`**——实测字符串写法下 `state` 是 `-rw-------` 而 `agent.log` 是 `-rw-r--r--`。日志要 600 只能在安装时预置（见 README）。

## 6. 验证方式

本仓库无测试框架、无 CI。改动后至少做到：

```sh
bash -n wifi-loc-detect.sh

# 干跑（默认），用临时配置，不碰 ~/.wifi-loc-control、不改变系统状态
# 从本机邻居表现取一台在线设备，不要把地址写死成真机值
IP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
     | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' | head -1 | awk '{print $1}')
MAC=$(arp -n "$IP" | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
cat > /tmp/t.env <<EOF
LOCATION_1_NAME="Home"
LOCATION_1_IP="$IP"
LOCATION_1_MAC="$MAC"
EOF
WLC_CONFIG=/tmp/t.env ./wifi-loc-detect.sh

# 反例：故意写错 MAC，必须走「身份不符」而不是「命中」
sed 's/LOCATION_1_MAC=.*/LOCATION_1_MAC="de:ad:be:ef:00:01"/' /tmp/t.env > /tmp/t-bad.env
WLC_CONFIG=/tmp/t-bad.env ./wifi-loc-detect.sh
```

已覆盖的用例（2026-09-16 全部通过）：MAC 匹配且已在目标位置、命中但位置不同（干跑提示不执行）、MAC 身份不符、多条目先命中、非法与**越界** IP / 非法 MAC / 不完整组被跳过、名字含空格时不算重名、位置名含空格与非 ASCII、同一 MAC 的补零与非补零写法等价、目标字段缺省取特征设备、目标字段非法则整组跳过、`--print-mac`（含无应答退出码 1）、`--help`（含 `--print-mac` 两行）、配置缺失（退出码 3）、参数缺失与未知参数（退出码 2）。

### 三份可复用的配方

三份都用**桩**：`osascript` 让通知只记账不弹出，`scselect` 让切换只记账、**不改动本机位置**，两者放进临时 `PATH`。它们写在 `/tmp` 下（会话结束不留存），需要时按下面的清单重建；判定层那 37 条断言的完整脚本在 `docs/2026-09-16-decision-model-plan.md` 的 Task 2 Step 1。

1. **配置层** —— 10 条断言：目标字段的默认与校验，含「名字含空格时不算重名」与「越界 IP 被跳过」两条回归。
2. **判定层** —— 37 条断言，约 90 秒：设计文档 N1–N12 全覆盖（`ok` / `broken` 去重 / 先切换后核对目标 / `miss` 安全阀 / 回落与回落通知 / 身份不符也回落 / 旧格式状态文件）。**必须像 agent 一样带 `--apply --notify`**，否则通知与状态写入根本不会被走到——第一次写这份配方时正是漏了这两个参数，被 14 条失败打回来。
3. **通知状态机** —— 15 条断言：目标在场不通知、`broken` 只通知一次、手动跑（不带 `--notify`）不写状态也不吞掉以后的通知、投递失败不记账且下一轮重试、确认后 `miss` 归零。

**已验证**：

- 判定逻辑（脚本层）：进入方向真实切换；特征设备连续两轮未确认时**回落到默认位置并通知**；目标设备不符时**只通知、不回落**；通知文案不含地址与 MAC。
- 三份配方全通过（10 + 37 + 15 条断言）。
- **触发层（LaunchAgent，全部无人干预）**：`RunAtLoad` 那轮读到 `Automatic`、**1 秒**内切到 `Home`；`scselect` 改动即触发一轮；热点上只弹一次通知、60 秒后那轮打印抑制行；回落；唤醒后 **32 秒**触发一轮；幂等收敛、无失控、无需常驻轮询。

**尚未验证 / 待查**：

线上 `agent.log` 共 5 次 `no answer`，其中 4 次有明确原因，1 次待查：

| 时间 | 当时位置 | 归因 |
|---|---|---|
| 10:49:38 | `Automatic` | **待查**——使用者确认当时在家庭网络上，未复现 |
| 10:58:21 | `Home` | 使用者手动切到手机热点（10:58:07 与 10:59:03 设备均在场）|
| 11:08:26 | `Home` | 刻意的热点测试第一轮（通知一次）|
| 11:09:27 | `Home` | 同一测试第二轮（被去重抑制）|
| 11:56:52 | `Home` | 使用者手动切到手机热点（其下一条消息即在问热点下为何不切）|

连续两轮只出现过一次，且那次是真离开，所以 **`miss >= 2` 目前没有反例**；若将来观察到「在家里连续两轮未确认」，把阀值提到 3，并把依据补在这张表下面。另外两处未知：目标设备**真的**下线（R3S 掉电）未实测，只用未应答地址模拟过；回落通知投递失败不会重试（见 README 已知限制）。

## 7. 路线图

1. 探测器（本脚本）：只判断，`--apply` 才切换。**已完成**
2. 事件驱动常驻：LaunchAgent + `WatchPaths` 监视 `/Library/Preferences/SystemConfiguration/`；自触发靠幂等收敛（实测无失控）。**已完成**
3. 菜单栏：显示当前位置并可点击切换（macOS 已移除位置 UI，`networksetup -listlocations` 之外没有图形入口）。

## 8. 隐私

- 配置文件里的 IP/MAC 属于本机网络信息，**不要提交进仓库、不要粘进 issue**。仓库内文档、代码注释与**提交信息**里的示例值只用留白值：MAC 用 RFC 7042 的 `00:00:5e:00:53:xx`，IP 用 RFC 5737 的 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`，不要用真机值。（提交信息也进历史，删工作区是删不掉的。）
- 通知文案**不得包含 SSID、特征设备 MAC 或其特征地址**——通知会进通知中心、可能随 iCloud 同步，所以文案里不放任何定位信息，只留「地址与配置不符」这个结论。地址与 MAC 的具体值**只写本地日志**（`log`，即脚本 stdout）。
- **仓库里不放个人绝对路径**（`/Users/<你>`）。launchd 需要字面路径，所以 `com.yayadesu.auto-network-location.plist` 用 `__REPO__` / `__HOME__` 占位、安装时用 `sed` 替换（见 README）；脚本、配方与文档里改用 `$(git rev-parse --show-toplevel)` 或 `$HOME`。提交身份同理：本仓库的 `user.email` 用 GitHub 的 noreply 地址。
