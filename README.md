# auto-network-location

> English version: [README.en.md](README.en.md)

连上一个已知网络时，自动切换 macOS 的[网络位置](https://support.apple.com/en-us/105129)，
让那个网络需要的设置（静态 IPv4、网关、DNS、IPv6 状态）自动生效，不用手动改。

这是 macOS 版的「iPhone 和 Windows 按 Wi-Fi 网络配置各自的设置」。macOS 原生做不到：
IPv4/DNS 只有「按网络服务」的概念，从来没有「按 SSID」，所以在家里配的静态 IP
会跟着这台 Mac 到处跑，直到你手动改回去。

## 为什么不用现成工具

现成工具靠读 Wi-Fi SSID 判断网络。当前 macOS 上这条路不可靠：对非 root 用户，
`ipconfig getsummary` 与 `system_profiler` 把 SSID 和 BSSID 一起报成 `<redacted>`；
`networksetup -getairportnetwork` 会误报「未关联」；`airport` 命令已被移除。
剩下的办法要么需要 root，要么退化成从「首选网络列表」里猜。

本项目**完全不读 SSID**。

## 它怎么判断

一张网络由它上面**一台特征设备**标识：无论它是不是这台 Mac 的当前网关，
只要在场并应答即可。家庭网络通常就是上游路由器。

1. 向那台设备的地址发一个包（一个关闭的 UDP 套接字就够），促使内核做 ARP 解析。
2. 从内核邻居表（`arp -n`）读回它的 MAC。
3. MAC 与配置一致 → 这台 Mac 就在那张网络上。

这个探针的性质：

- 不需要 root、不用 raw socket、不用 ICMP —— `ping` 不可用的环境里照样能用；
- 不受 SSID 脱敏影响；
- 无论这台 Mac 是否正处于「以该设备为网关」的那个位置，都能工作；
- IP 对上但 MAC **不同**时，报为身份不符，而不是当成命中。

## 自动化覆盖到哪一步

两个方向都自动化，但只有「离开」是无条件的。

| 当前位置 | 探测结果 | 动作 |
|---|---|---|
| `Automatic` | 命中某张已知网络 | 切到那个位置 |
| 已在那个位置 | 命中，目标设备在场 | 什么都不做（幂等） |
| 已在那个位置 | 命中，目标设备缺席 | **通知**，不切换 |
| 任意位置 | 没有任何已知网络 | **切回默认位置** |

一张网络由**两台设备**描述：**特征设备**回答「这是哪张网」；可选的**目标设备**回答
「这还是我设置里期待的那张网吗」。目标设备缺省取特征设备，所以不需要额外核对的那种
网络，也不必额外配置。

特征设备一停止应答，就按「已经离开」处理：把这台 Mac 交回默认位置（`Automatic`，
除非 `WLC_DEFAULT` 另有指定），让它在实际所在的那张网络上就能用。默认位置是 DHCP，
几乎到哪儿都能用，所以**早动作很便宜**，脚本不会先把整个探测预算走完——第一遍扫描
大约一秒就结束，剩下的尝试随即变成「切回去」的第一次机会；15 秒后还有最后一次查看。
其中任何一次找到设备，这一轮就静默切回那个位置。

网络还在、但已经对不上——你的设置所依赖的那台设备不见了，或者那个地址现在属于
别的东西——是另一种情况。这种情况**报出来，而不是抹平**，因为切走等于把你的静态
设置悄悄换成 DHCP，而那正是本项目要消除的故障。

如果只是想留在某个位置的同时临时改用上游路由器，请直接改那个位置的设置。
**切换位置**与**临时改网关**是两件独立的事。

## 环境要求

- macOS（在 macOS 27.0、build 26A428 上开发并验证）
- bash 3.2（系统自带）——脚本刻意回避 bash 4+ 的语法
- 无第三方依赖

## 安装

### 1. 建位置

每张网络建一个位置，按那张网络的需要配好设置：

- `Automatic` —— 漫游用的默认位置：DHCP、自动 DNS。
- 例如 `Home` —— 那张网络的静态设置。

`networksetup -createlocation <名>` 建出来的是**空位置**（没有服务）；而
`-createlocation <名> populate` 建的是全新默认服务，并且**不**复制当前位置的
TCP/IP 与 DNS。这两个行为都挺反直觉；实测细节见 `AGENTS.md`。每个位置可用的做法是：
先切过去，加一个绑定到硬件端口的服务，再设值。

### 2. 写配置

```sh
mkdir -p ~/.wifi-loc-control
```

`~/.wifi-loc-control/locations.env` —— **每张网络一个编号组**：

```sh
# the macOS location to switch to, the device address, and the device MAC
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"

# Optional: the device this location's own settings depend on (its gateway or
# DNS). Omit it and the characteristic device above is used. If you give one,
# give it in full: a malformed target skips the whole group rather than being
# silently ignored.
# LOCATION_1_TARGET_IP="192.0.2.100"
# LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"

# LOCATION_2_NAME="Office"
# LOCATION_2_IP="198.51.100.1"
# LOCATION_2_MAC="aa:bb:cc:dd:ee:ff"
```

加一张网络就复制一组、把编号加一。位置名是**变量值**而不是变量名，所以可以含空格
与非 ASCII 字符（`LOCATION_1_NAME="My Home"` 没问题）。

这个文件是被 **`source`** 的，也就是代码而不是数据：保持你的属主、权限 600，
也不要从不可信来源拷一份进来。文件里遗留的每个 `LOCATION_*` 变量，都会在脚本做
别的事之前被清掉。

地址是**严格**读取的：纯十进制、不许前导零、首八位组必须是单播地址。`arp` 会把前导零
当八进制——`010` 就是八，所以 `198.51.100.010` 会去探测 `198.51.100.8`；而 `0.0.0.0`
会解析成这台 Mac 当前的网关。这样写的那一组会被跳过、并在日志里留一行，而不是去
探测一个你根本没写的地址。

MAC 要在那张网络里、连着它的时候自己查：

```sh
./wifi-loc-detect.sh --print-mac 192.0.2.1
```

每个位置都要在它自己的网络上采集自己那一组。特征设备必须在 `Automatic` 与那个位置
两种状态下都在场——家庭网络用上游路由器就满足。如果某个位置的设置指向另一台盒子
（它的网关或 DNS），把那台盒子写成 `LOCATION_n_TARGET_IP` / `_TARGET_MAC`；否则两个
角色会塌缩成一个，第二次核对永远不会触发。

没有任何一组命中时，脚本会回落到默认位置，也就是 `Automatic`（用环境变量
`WLC_DEFAULT` 覆盖）——一旦第一遍扫描全部落空就回落，大约一秒；剩余预算继续跑，
15 秒后再看一次。所以单次误读会在同一轮内被撤销，并且不报任何东西。

### 3. 试一下

```sh
./wifi-loc-detect.sh            # 干跑：打印判定，什么都不改
./wifi-loc-detect.sh --apply    # 判定安全时才真的切换
```

## 用法

```
./wifi-loc-detect.sh                    干跑，打印判定了什么、以及为什么
./wifi-loc-detect.sh --apply            真的切换位置
./wifi-loc-detect.sh --apply --notify   这张网络与设置不再匹配时也通知
                                        （离开是静默的，除非设备被换了）
./wifi-loc-detect.sh --print-mac <ip>   打印某个 IP 的 MAC（配置助手）
```

退出码：`0` 正常，`1` 切换或 MAC 查询失败，`2` 参数错，`3` 配置缺失。
**当前位置读不出来**时（`scselect` 失败、或它的输出形状变了），运行也会以 `1` 退出、
并且什么都不切：在那儿猜着动手等于盲切，而每一次切换都会触发下一轮。

不带 `--notify` 的运行不投递任何东西，也不会把通知记成「已送达」——下一次带
`--notify` 的运行仍然会把它发出去。

## 自动运行

装一个 LaunchAgent，网络一变化就自动应用判定，不必自己敲：

```sh
touch ~/.wifi-loc-control/agent.log && chmod 600 ~/.wifi-loc-control/agent.log
sed "s|__REPO__|$PWD|; s|__HOME__|$HOME|" com.yayadesu.auto-network-location.plist \
  > ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl print gui/$(id -u)/com.yayadesu.auto-network-location
```

这段要在本仓库根目录执行：plist 里带着两个占位符（`__REPO__` 是仓库路径、`__HOME__`
是你的家目录），因为 launchd 既不展开 `~` 也不展开环境变量，所以它读这个文件时，
那些路径必须已经是字面值。

第一行预先把日志建出来、权限设成 600。`StandardOutPath` 那个文件是 launchd 自己建的，
plist 里的 `Umask` 对它不起作用，所以「预置一个已存在的文件」是让日志保持私密的
唯一办法。

要卸下它：

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

这个 job 监视 `/Library/Preferences/SystemConfiguration`，装载时也跑一次。已知网络出现
时切进去；第一遍扫描发现特征设备不在，就回落到默认位置（剩余预算与 15 秒后的那次
查看是「回得去」的机会）；当前网络与配置不再匹配时通知——**每个状态一次**，不是每次
触发一次。

两个前提、两点注意：

- `~/.wifi-loc-control/` 必须已经存在；job 的日志写在里面的 `agent.log`。
- plist 里是本仓库的绝对路径。仓库搬家就得重装；改了 plist 就得 `bootout` 再
  `bootstrap`，因为 launchd 不会重读它。
- `WatchPaths` 可能漏事件（`man launchd.plist` 说它「highly discouraged」），而这个 job
  刻意没有周期性兜底：它是「某个事件触发、只跑一轮」的脚本，不是轮询器。所以漏掉一次
  事件会让位置一直不对，直到下一次网络变化——下面那条手动命令因此很重要。
- 日志会无限增长，随时可以删；记录「已经报过什么」的状态文件是另一个文件。

### 它判断错了怎么办

macOS 已经不再提供任何位置 UI，手动切换就是一条命令：

```sh
networksetup -listlocations     # 有哪些位置、当前是哪个
scselect                        # 同样的事，更简短
scselect Home                   # 切到某个位置
```

因为这个 job 只在网络变化时跑，猜错的位置会一直留着，除非你手动执行上面那条命令。

## 已知限制

- **自动运行已经验证。** 装载 LaunchAgent 后，进入已知网络时会无人干预地切换位置，
  离开后会回到默认位置——实测从网络变化起**约两秒**，而且是静默的。睡眠唤醒也量过：
  合盖打开后约三十秒会跑一轮，因为重新连接会引发 `WatchPaths` 事件。
- **「离开」在第一遍扫描就决定**（约一秒时），并在同一轮内确认：剩余探测预算与 15 秒后
  的那次查看，是「回来」的机会。所以单次误读的代价是**两次快速的接口重配**，而不是
  一个错的位置；那种情况下不报任何东西。
- **离开时不报任何东西**，这是有意的：机器已经在默认位置上可用，而每次离家都会发生。
  只有**被换掉的设备**、或**目标设备不在的位置**，才值得一条通知。
- 两台设备都必须同时匹配地址**与** MAC。特征设备断电、或它的地址被别的东西占了，
  都会让那张网络无法识别。
- 每张网络只支持一台特征设备与一台目标设备；要处理冲突得换设备，或等将来的多条件规则。
- IPv6 状态是按位置存的，必须逐个位置设置，不会被推断出来。

## 路线图

1. **探测器** —— 就是这个脚本。做判断，`--apply` 才切换。*（已完成）*
2. **事件驱动常驻** —— LaunchAgent 用 `WatchPaths` 盯
   `/Library/Preferences/SystemConfiguration/`，并靠幂等收敛：切换位置会重写那个目录，
   从而再次触发 agent。*（已完成）*
3. **菜单栏** —— 显示当前位置、并允许从菜单切换，因为 macOS 不再提供任何位置 UI。

## 许可

MIT
