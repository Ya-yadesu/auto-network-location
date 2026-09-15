# AGENTS.md

本文件是 `auto-network-location` 的代理工作约定。改动代码前先读完。

> 本项目的由来：从 `wifi-loc-control` 的 fork（`Ya-yadesu/wifi-loc-control`）分出。
> 原项目与网上多数同类工具都靠**读 Wi-Fi SSID** 判断网络，而这条路在当前 macOS 上
> 已被堵死。本项目改用**特征设备的 MAC**，因此与上游没有共用代码。

## 1. 项目概览

```text
wifi-loc-detect.sh   探测器（唯一代码文件，纯 bash 3.2 兼容）
README.md            面向用户的设计与用法说明（英文）
```

判据：把「当前处于哪个网络」变成一个**二层问题**——某台特征设备在不在这个局域网里。

## 2. 不可动摇的设计约定

改动前请确认没有违反以下任何一条：

1. **不读 SSID/BSSID。** 原因见第 3 节。不要以任何形式回退到 SSID 方案。
2. **不需要 root。** 切换位置用 `scselect`（已实测免提权）。任何需要 `sudo` 的设计都要先重新论证。
3. **探针走二层，不用 ICMP、不用 raw socket。** 手段是「向目标地址发包促使内核做 ARP 解析，再读 `arp -n`」。这样不依赖设备响应 ICMP，也不受受限环境影响。
4. **IP + MAC 双匹配。** 只匹配 IP 会在「另一个网络也有同地址设备」时误判；MAC 不匹配必须报为身份不符，而不是当作命中。
5. **自动化只做「进入」方向。** 从 `Automatic` 切到识别出的位置是自动的；从非默认位置退出**只通知、不自动切**。理由是二层层面「设备消失」可能意味着真实配置变动，不该由脚本猜。
6. **幂等。** 已在目标位置就什么都不做。切换动作本身会改写 `SystemConfiguration`，会再次触发自己，必须靠幂等收敛。
7. **纯 bash 3.2。** macOS 自带 bash 是 3.2，**没有** `${var,,}`、`mapfile`、关联数组等 bash 4+ 特性。已因此写错过一次判断方向（见第 5 节）。
8. **零依赖。** 只用 macOS 自带命令。
9. 面向用户的字符串、注释、README 用**英文**；本文件与代理工作笔记用**中文**。

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
- `arp -n` 的输出格式：`? (192.0.2.1) at 00:00:5e:00:53:01 on en0 ifscope [ethernet]`。

## 5. 环境与工具陷阱（都已实际踩过）

- **bash 3.2**：`${mac,,}` 报 `bad substitution`，且**不终止脚本**（在子 shell 中失败），会把「匹配成功」判断成「身份不符」。所有大小写归一化用 `tr`。
- **`for arg in "$@"` 内 `shift` 无效**：迭代列表在进入循环前已固定。解析带取值的选项要用带下标的 `while` + `${!i}`。
- **`scselect` 切换后有 3~5 秒窗口**，期间 DNS 可能解析失败（`curl: (6) Could not resolve host`），随后自愈。判断「网络坏了」前必须等接口稳定再复测——本项目已因此误判两次。
- **`networksetup -createlocation <名>` 建的是空位置**（无服务、无接口）；`-createlocation <名> populate` 建的是**全新默认服务**（DHCP、无 DNS），**不复制**原位置的 TCP/IP 与 DNS，还会把原位置的服务清掉。要建位置就用 `-createnetworkservice <服务名> <硬件端口>` 显式创建后再 `-setmanual` / `-setdnsservers`。
- **`networksetup` 的改动只作用于「当前位置」**；两个位置可以同时存在叫 `Wi-Fi` 的服务，靠先 `scselect` 切过去消除歧义。
- **`networksetup -setv6off` 后**，`preferences.plist` 里的 `IPv6` 会带 `__INACTIVE__: True`，而不是变成 `Off`；以 `networksetup -getinfo` 显示 `IPv6: Off` 为准。
- **受限沙箱内 `ping`/`nc`/`traceroute`/`curl` 的连通性结论不可信**（`traceroute` 直接 `Operation not permitted`，同一沙箱内 ping 结果自相矛盾）。可信的是 `networksetup`、`scselect`、`route`、`scutil`、`arp`、以及 `preferences.plist`。连通性必须在真实终端核验。

## 6. 验证方式

本仓库无测试框架、无 CI。改动后至少做到：

```sh
bash -n wifi-loc-detect.sh

# 干跑（默认），用临时配置，不碰 ~/.wifi-loc-control、不改变系统状态
MAC=$(arp -n 192.0.2.1 | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
printf '192.0.2.1  %s = Home\n' "$MAC" > /tmp/t.conf
WLC_CONFIG=/tmp/t.conf ./wifi-loc-detect.sh

# 反例：故意写错 MAC，必须走「身份不符」而不是「命中」
printf '192.0.2.1  de:ad:be:ef:00:01 = Home\n' > /tmp/t-bad.conf
WLC_CONFIG=/tmp/t-bad.conf ./wifi-loc-detect.sh
```

已覆盖的用例（2026-09-16 全部通过）：MAC 匹配且已在目标位置、MAC 身份不符、多条目先命中、命中但位置不同（干跑提示不执行）、`--print-mac`、配置缺失（退出码 3）、参数缺失（退出码 2）。

**尚未验证**：`--apply` 的真实切换、以及「离家后特征设备从邻居表消失」这一半。后者必须用真实移动验证，不能靠推理。

## 7. 路线图

1. 探测器（本脚本）：只判断，`--apply` 才切换。**已完成**
2. 事件驱动常驻：LaunchAgent + `WatchPaths` 监视 `/Library/Preferences/SystemConfiguration/`；**必须处理自触发**（切换会改写该目录）。
3. 菜单栏：显示当前位置并可点击切换（macOS 已移除位置 UI，`networksetup -listlocations` 之外没有图形入口）。

## 8. 隐私

- 配置文件里的 IP/MAC 属于本机网络信息，**不要提交进仓库、不要粘进 issue**。
- 通知文案与日志**不得包含 SSID 或特征设备 MAC**；具体值只写本地日志。
