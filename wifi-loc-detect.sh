#!/usr/bin/env bash
#
# wifi-loc-detect.sh —— 判断当前网络属于哪个位置：靠一台特征设备在不在。
#
# 设计（2026-09-16 定稿；同一份说明的英文版见 README.en.md 与 docs/）：
#   * 每张已知网络由一台特征设备识别：它的地址与 MAC。这台设备必须在 Mac 处于该
#     网络期间一直在场，不必是 Mac 当前的网关（上游路由器是个好选择）。
#   * 探测走二层，不用 ICMP、不用 raw socket：向该地址发包促使内核做 ARP 解析，
#     再读邻居表（`arp -n`）。因此设备不是当前网关也照样能测，而且在 ping 与
#     traceroute 都不可用的受限环境里也能用。
#   * 第二台可选设备回答的是另一个问题：目标设备，通常就是本位置自己的设置所依赖
#     的那一台（它的网关或 DNS）。缺省等于特征设备，所以不需要单独核对一张网络时
#     就不需要单独配置。
#   * 两个方向都自动化，但只有「离开」是无条件的：
#       - 特征设备在场 -> 进入该位置；
#       - 它不在了，或该地址已经换了设备 -> 第一遍扫描结束就回落到默认位置，让机器
#         在它实际所在的网络上先能用。剩下的探测预算仍在这一轮里跑完：设备要是又在
#         那儿应答了，说明只是读了一次坏数据，就静默切回去；要是没有，这一轮会再等
#         一段时间做最后一次复探，然后正式判定离开；
#       - 位置对上了，但它的目标设备不在了 -> 只通知、不动设置：那是这张网本身变了，
#         擅自动作会把静态设置悄悄换成 DHCP。
#   * 切换位置是「热」的：scselect 立刻生效，不改变 Wi-Fi 网络。
#   * 位置读不出来时绝不猜：scselect 失败、或输出不是本脚本认识的样子，这一轮就
#     非零退出，一次 scselect 都不调。每次 scselect 都会改写 SystemConfiguration、
#     因而再触发一轮，把读失败猜成「不在默认位置」就会变成每分钟切一次。
#
# 配置：~/.wifi-loc-control/locations.env（可用 WLC_CONFIG 覆盖）。该文件被 source，
# 按编号成组：
#
#     LOCATION_1_NAME="Home"
#     LOCATION_1_IP="192.0.2.1"
#     LOCATION_1_MAC="00:00:5e:00:53:01"
#     # 可选；缺省等于上面的特征设备
#     LOCATION_1_TARGET_IP="192.0.2.100"
#     LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"
#
# 位置名是「值」而不是「变量名」，所以允许空格与非 ASCII。该文件是被 source 的代码：
# 请自己持有它、权限 600，不要从不可信来源拷一份进来。
#
# 语言：配置里的 SCRIPT_LANG（"zh_CN" 默认 / "en"），环境变量 WLC_LANG 可覆盖。
# 它只改变 --help 文本与通知正文；日志与状态文件固定英文（测试断言按英文匹配）。
#
# 用法（细节见 --help）：
#   ./wifi-loc-detect.sh                    # 干跑：只打印结论
#   ./wifi-loc-detect.sh --apply            # 真的执行 scselect
#   ./wifi-loc-detect.sh --apply --notify   # 网络与设置不符时投递通知
#   ./wifi-loc-detect.sh --print-mac <ip>   # 辅助：打印某个地址的 MAC，用来填配置
#
set -uo pipefail

CONFIG="${WLC_CONFIG:-$HOME/.wifi-loc-control/locations.env}"
DEFAULT_LOCATION="${WLC_DEFAULT:-Automatic}"
ATTEMPTS=4          # 一次探测预算里的尝试次数
RETRY_DELAY=1       # 两次尝试之间的等待秒数（切换位置后接口要时间稳定）
PROBE_PORT=33445    # 只用来促使内核做 ARP 解析的 UDP 端口
STATE="${WLC_STATE:-$HOME/.wifi-loc-control/state}"
CONFIRM_DELAY="${WLC_CONFIRM_DELAY:-15}"   # 回落之后的第二次查看，单位秒
APPLY=0
NOTIFY=0
SCRIPT_LANG_DEFAULT="zh_CN"
SCRIPT_LANG_RESOLVED="$SCRIPT_LANG_DEFAULT"
SCRIPT_LANG_WARN=""

# 语言取值：环境变量 WLC_LANG 优先，其次是配置里的 SCRIPT_LANG，都没有就用默认值。
# 只认 "en" 与 "zh_CN"（大小写不敏感，大小写归一化只能用 tr：macOS 自带 bash 3.2
# 没有 ${var,,}）。取值不认识时**不**报错退出：判网与切换绝不能因为一个语言值停下
# 来，所以这里只把那个值记下来，由调用方在日志里说明一次。
#
# 为什么在这里就读配置：--help 也要跟着语言走，而 --help 发生在参数解析期，比
# load_config 早。这里在子 shell 里 source 一次只为取这一个值，主流程稍后照旧再
# source 一次；两次互相隔离，配置里的其它变量不会因此提前进入本 shell。
set_script_language() {
  local raw="" peek
  if [[ -n "${WLC_LANG:-}" ]]; then
    raw="$WLC_LANG"
  elif [[ -f "$CONFIG" ]]; then
    peek="$( { set +u; . "$CONFIG" >/dev/null 2>&1; printf '%s' "${SCRIPT_LANG:-}"; } )"
    raw="$peek"
  fi
  [[ -z "$raw" ]] && raw="$SCRIPT_LANG_DEFAULT"
  case "$(printf '%s' "$raw" | tr 'A-Z' 'a-z')" in
    en)    SCRIPT_LANG_RESOLVED="en" ;;
    zh_cn) SCRIPT_LANG_RESOLVED="zh_CN" ;;
    *)     SCRIPT_LANG_RESOLVED="$SCRIPT_LANG_DEFAULT"; SCRIPT_LANG_WARN="$raw" ;;
  esac
}

# 面向用户的文本：只有帮助文本与通知正文跟着 SCRIPT_LANG 走，日志固定英文——日志是
# 排障与断言用的，混语言只会让「那一行」变成搜不到的东西。新增一条面向用户的句子时，
# 两套表都要加（tests 的 lang 套件会核对两条通知正文都在）。
# 一律用 printf '%s' 而不是 printf '<文本>'：译文里出现 % 时不会被当成格式符。
msg() {
  local key="$1"
  shift
  if [[ "$SCRIPT_LANG_RESOLVED" == "en" ]]; then
    case "$key" in
      notify_broken)   printf '%s' 'The current network no longer matches the configured settings. Check the network settings.' ;;
      notify_mismatch) printf '%s' 'The device at the configured address is not the one expected. Switched to the default location.' ;;
    esac
  else
    case "$key" in
      notify_broken)   printf '%s' '当前网络与已配置的设置不符，请检查网络设置。' ;;
      notify_mismatch) printf '%s' '配置地址上的设备与预期不符，已切换到默认位置。' ;;
    esac
  fi
}

# 每行日志都以本地时间开头。注意 log 会起一个 date 子进程：配置里任何 export 过的
# 变量都会经由它泄漏出去，所以 load_config 必须先把自己 source 进来的变量清干净
# （见那里的 sweep，以及 AGENTS.md 第 9 条）。
log() { printf '%s %s\n' "$(date +'[%Y-%m-%d %H:%M:%S]')" "$*"; }

# --help：按 SCRIPT_LANG 打印用法。以前这里是 awk 从文件头部注释里抽用法，好让改注释
# 不再需要同步行号；现在注释是中文、而帮助要分语言，所以改成显式两份文本。
# 两段文本必须提到同样的选项（tests 的 lang 套件两条都查）。
print_help() {
  if [[ "$SCRIPT_LANG_RESOLVED" == "en" ]]; then
    cat <<'EOF'
wifi-loc-detect.sh - decide which network location this network belongs to,
based on whether a characteristic device is present.

Usage:
  ./wifi-loc-detect.sh                    dry run: print the decision only
  ./wifi-loc-detect.sh --apply            actually run scselect
  ./wifi-loc-detect.sh --apply --notify   notify when the network no longer
                                          matches the configured settings
  ./wifi-loc-detect.sh --print-mac <ip>   helper: show the MAC for an IP, to
                                          fill in the config file

Config: ~/.wifi-loc-control/locations.env (override with WLC_CONFIG). The file is
sourced; one numbered group per network: LOCATION_n_NAME / _IP / _MAC, plus the
optional _TARGET_IP / _TARGET_MAC.

Language: SCRIPT_LANG in the config file, "zh_CN" (default) or "en"; the
environment variable WLC_LANG overrides it. It changes this help text and the
notification bodies only; log lines and the state file stay in English.

Full description: README.en.md (Chinese: README.md).
EOF
  else
    cat <<'EOF'
wifi-loc-detect.sh —— 根据某台特征设备在不在，判断当前网络属于哪个位置。

用法：
  ./wifi-loc-detect.sh                    只判断并打印结论（干跑，默认）
  ./wifi-loc-detect.sh --apply            真的执行 scselect 切换位置
  ./wifi-loc-detect.sh --apply --notify   网络与已配置的设置不符时投递一条通知
  ./wifi-loc-detect.sh --print-mac <ip>   辅助：打印某个地址的 MAC，用来填配置

配置：~/.wifi-loc-control/locations.env（可用 WLC_CONFIG 覆盖）。该文件被 source，
按编号成组：LOCATION_n_NAME / _IP / _MAC，另有可选的 _TARGET_IP / _TARGET_MAC。

语言：配置里的 SCRIPT_LANG，"zh_CN"（默认）或 "en"；环境变量 WLC_LANG 可覆盖。
它只改变这段帮助文本与通知正文；日志与状态文件固定英文。

完整说明见 README.md（英文版 README.en.md）。
EOF
  fi
}

set_script_language

i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --apply)  APPLY=1 ;;
    --notify) NOTIFY=1 ;;
    --print-mac)
      i=$((i + 1))
      [[ $i -gt $# ]] && { echo "--print-mac needs an IP" >&2; exit 2; }
      PRINT_MAC_IP="${!i}" ;;
    -h|--help)
      print_help
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
  i=$((i + 1))
done

# 当前位置；读不出来时非零返回：1 表示 `scselect` 本身失败，2 表示它的输出不是本脚本
# 认识的样子。两者对调用方是同一件事——未知——而未知不可以猜。这个值唯一的用途是决定
# 要不要调 `scselect`，而每次 `scselect` 都会改写 SystemConfiguration、因而再触发一轮：
# 2026-09-16 实测，连「切到当前所在的位置」也会改写。所以把读失败当成「不在默认位置」
# 会变成每分钟切换一次、再触发一次，永远循环下去。
current_location() {
  local out parsed
  out="$(scselect 2>/dev/null)" || return 1
  parsed="$(printf '%s\n' "$out" | sed -n 's/^ \* .*(\(.*\))$/\1/p')"
  [[ -n "$parsed" ]] || return 2
  printf '%s\n' "$parsed"
}

# 归一化 MAC，让等价写法比较相等。手写配置与 `arp -n` 输出之间可能有两处不同：大小写，
# 以及前导零——arp 会省略它（"0:0:5e:0:53:1" 对 "00:00:5e:00:53:01"）。macOS 自带
# bash 3.2 没有 ${var,,}，所以用 tr 小写。六个八位组一趟过完，除 tr 之外不调外部命令。
norm_mac() {
  local mac out="" oct sep=""
  mac="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  local IFS=:
  for oct in $mac; do
    [[ ${#oct} -eq 1 ]] && oct="0$oct"
    out="$out$sep$oct"
    sep=":"
  done
  printf '%s' "$out"
}

# 向 <ip> 发一个包，促使内核做 ARP 解析、填充邻居表。发到一个没人监听的 UDP 端口就够了：
# 关键是要让内核去做解析，不需要任何应答。这样就不必用 ping 之类的 raw socket 工具——它们
# 并非处处可用（在 agent 沙箱里也是被挡住的）。
# 注意：这里是有意去联系配置里的地址，走 udp/PROBE_PORT。
trigger_arp() {
  local ip="$1"
  ( : > "/dev/udp/$ip/$PROBE_PORT" ) 2>/dev/null
  return 0
}

# 从内核邻居表里读 <ip> 的 MAC；条目不存在或仍是 "(incomplete)" 时什么都不打印。
arp_lookup() {
  local ip="$1" line
  line="$(arp -n "$ip" 2>/dev/null)" || return 1
  [[ "$line" == *"(incomplete)"* ]] && return 1
  printf '%s\n' "$line" | sed -n 's/.* at \([0-9a-fA-F:]\{11,17\}\) on .*/\1/p'
}

# 对一台设备做一次尝试。有应答就打印它的 MAC：
#   退出 0 + 打印 MAC -> 在场，且 MAC 与配置相符
#   退出 1 + 打印 MAC -> 在场，但是另一台设备（身份不符）
#   退出 2 + 无输出    -> 邻居表里什么都没有
# 「什么都没有」不是免费的：先发包（内核只在有需求时才解析），等 RETRY_DELAY 之后再读
# 一次表。一条过期条目和一张已经离开的网络在第一次读时长得一模一样，这就是为什么发包
# 在读结论之前。
probe_once() {
  local ip="$1" want_mac="$2" mac
  want_mac="$(norm_mac "$want_mac")"
  mac="$(arp_lookup "$ip")"
  if [[ -z "$mac" ]]; then
    trigger_arp "$ip"
    sleep "$RETRY_DELAY"
    mac="$(arp_lookup "$ip")"
  fi
  [[ -z "$mac" ]] && return 2
  printf '%s\n' "$mac"
  [[ "$(norm_mac "$mac")" == "$want_mac" ]] && return 0
  return 1
}

# 用完整预算探测一台设备。目标设备走这条路：在预算耗尽之前什么都决定不了，因为它的
# 应答是「一切正常」与「该通知」之间的分界。特征设备不这样——它按遍扫描（probe_sweep），
# 因为那里第一次未命中就已经意味着机器正踩在一份不合适的设置上。
probe_device() {
  local ip="$1" want_mac="$2" attempt rc
  for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    probe_once "$ip" "$want_mac"
    rc=$?
    [[ $rc -eq 0 ]] && return 0
    [[ $rc -eq 1 ]] && return 1
    [[ $attempt -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
  done
  return 1
}

# 从被 source 的配置文件里把规则读进几个平行数组。
# 成功返回 0；文件不存在或不可用时返回非零。
# 四个点分八位组，每个都用纯十进制写 0-255，且首八位组是单播。比「看起来像 IPv4」
# 更严有两个实测理由：
#
#   * 前导零会被 arp 与解析器当作八进制。010 是八，所以以 .010 结尾的地址实测解析到了
#     .8 那台设备——与配置里写下的不是同一台；而 .01 又恰好是想要的 .1。08 连八进制
#     都不是，解析器直接拒绝；只看形状（用 10# 解释）会把它当成八。
#   * `arp -n 0.0.0.0` 实测返回的是**网关**的条目，于是配置里写 0.0.0.0 就等于「在哪个
#     网络都能匹配上网关 MAC」。多播与广播地址在这里同样没有意义。
valid_ipv4() {
  local ip="$1" oct first="" n=0
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for oct in $ip; do
    n=$((n + 1))
    [[ ${#oct} -gt 1 && "${oct:0:1}" == "0" ]] && return 1
    (( 10#$oct <= 255 )) || return 1
    [[ $n -eq 1 ]] && first="$oct"
  done
  (( 10#$first >= 1 && 10#$first <= 223 ))
}

load_config() {
  [[ -f "$CONFIG" ]] || return 1

  # 配置是被 source 的：它是代码，不是数据。先把各组的值复制出来，然后按**前缀**把
  # LOCATION_* 整片清掉——不是只清 1-64 组的五个已知字段。配置里可能有 LOCATION_65_*、
  # 或任何同前缀的名字，而 `log` 会起一个 date 子进程，它继承一切仍然 export 的变量：
  # 2026-09-16 实测，配置里一个 `export` 就能让 LOCATION_65_NAME 在这次 sweep 出现之前
  # 到达那个子进程。
  # shellcheck disable=SC1090
  source "$CONFIG" || return 2

  local n name ip mac tip tmac v gi
  local g_idx=() g_names=() g_ips=() g_macs=() g_tips=() g_tmacs=()
  for (( n = 1; n <= 64; n++ )); do
    local vn="LOCATION_${n}_NAME" vi="LOCATION_${n}_IP" vm="LOCATION_${n}_MAC"
    local vt="LOCATION_${n}_TARGET_IP" vc="LOCATION_${n}_TARGET_MAC"
    name="${!vn:-}"; ip="${!vi:-}"; mac="${!vm:-}"; tip="${!vt:-}"; tmac="${!vc:-}"
    [[ -z "$name$ip$mac$tip$tmac" ]] && continue
    g_idx+=("$n"); g_names+=("$name"); g_ips+=("$ip")
    g_macs+=("$mac"); g_tips+=("$tip"); g_tmacs+=("$tmac")
  done
  for v in $(compgen -v | grep '^LOCATION_'); do unset "$v"; done
  # 语言字段同样是配置里的代码，同样不能留给子进程（set_script_language 已经把值取到
  # SCRIPT_LANG_RESOLVED 里，语言不会因为这次 unset 而失效）。
  unset SCRIPT_LANG

  LOC_NAMES=()
  LOC_IPS=()
  LOC_MACS=()
  LOC_TARGET_IPS=()
  LOC_TARGET_MACS=()
  for (( gi = 0; gi < ${#g_names[@]}; gi++ )); do
    n="${g_idx[$gi]}"; name="${g_names[$gi]}"; ip="${g_ips[$gi]}"
    mac="${g_macs[$gi]}"; tip="${g_tips[$gi]}"; tmac="${g_tmacs[$gi]}"

    if [[ -z "$name" || -z "$ip" || -z "$mac" ]]; then
      log "config: LOCATION_$n is incomplete (need NAME, IP and MAC), skipping"
      continue
    fi
    if ! valid_ipv4 "$ip"; then
      log "config: LOCATION_$n has an invalid IP '$ip', skipping"
      continue
    fi
    if [[ ! "$mac" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]]; then
      log "config: LOCATION_$n has an invalid MAC '$mac', skipping"
      continue
    fi

    # 目标设备回答的是另一个问题：「这张网还是我写设置时的那张吗？」它缺省等于特征
    # 设备，所以不需要单独核对的网络不需要单独配置。详见设计文档
    # docs/2026-09-16-decision-model-design.md。
    [[ -z "$tip" ]] && tip="$ip"
    [[ -z "$tmac" ]] && tmac="$mac"
    if ! valid_ipv4 "$tip"; then
      log "config: LOCATION_$n has an invalid TARGET_IP '$tip', skipping"
      continue
    fi
    if [[ ! "$tmac" =~ ^[0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}$ ]]; then
      log "config: LOCATION_$n has an invalid TARGET_MAC '$tmac', skipping"
      continue
    fi

    # 按名字逐个比较。拿拼起来的整串做子串判断会在「Home Office」在前时错杀「Home」，
    # 而两个名字都是合法的（位置名允许带空格）。
    local i dup=0
    for (( i = 0; i < ${#LOC_NAMES[@]}; i++ )); do
      [[ "${LOC_NAMES[$i]}" == "$name" ]] && { dup=1; break; }
    done
    if [[ "$dup" == 1 ]]; then
      log "config: duplicate location name '$name', skipping the later one"
      continue
    fi

    LOC_NAMES+=("$name")
    LOC_IPS+=("$ip")
    LOC_MACS+=("$mac")
    LOC_TARGET_IPS+=("$tip")
    LOC_TARGET_MACS+=("$tmac")
    log "config: rule '$name': feature $ip, target $tip"
  done

  [[ ${#LOC_NAMES[@]} -gt 0 ]]
}

# read_state / read_pending：状态文件里记着什么。
#   state=default|ok|broken   我们在哪儿，以及关于它的什么已经被通知过
#   pending=feature-mismatch  有一条还没被告知的通知
#   pending_rule=<名字>       ……是关于哪个位置的特征设备的
# 位置名用来标识这笔欠账：配置了多张网络时，后来命中 Office 不能抹掉 Home 仍欠的。
# 详见 docs/2026-09-16-decision-model-design.md。
read_state() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^state=//p' "$STATE" 2>/dev/null | head -n 1
}

read_pending() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^pending=//p' "$STATE" 2>/dev/null | head -n 1
}

read_pending_rule() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^pending_rule=//p' "$STATE" 2>/dev/null | head -n 1
}

# write_state <state>
# 经由同目录下的临时文件写入：两次触发可能重叠，读者绝不能看到写了一半的状态。
# 仍然欠着的东西自动跟着一起写：那笔欠账是本轮加载进来的一对变量（pending_kind /
# pending_rule），清除它是一个显式决定，只在「刚告诉过用户」或「设备又回来了」的地方做。
# 其它一切——包括命中了另一个位置——都保留它。
write_state() {
  local tmp="${STATE}.tmp.$$"
  if { printf 'state=%s\n' "$1"
       if [[ -n "$pending_kind" ]]; then
         printf 'pending=%s\n' "$pending_kind"
         printf 'pending_rule=%s\n' "$pending_rule"
       fi
     } > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp"; log "could not write state file: $STATE"; }
  else
    log "could not write state file: $STATE"
  fi
}

# 把一条通知正文按 SCRIPT_LANG 取出来，打印进日志，并在带 --notify 时真的投递。
# 投递失败返回非零，好让调用方不把「用户从没收到过」的通知记成已送出，下一轮触发再试。
# 参数是文案的 key，不是整句文本；文案表见 msg。
notify() {
  local message
  message="$(msg "$1")"
  log "NOTIFY: $message"
  if [[ "$NOTIFY" == 1 ]]; then
    if ! osascript -e "display notification \"$message\" with title \"auto-network-location\"" \
         >/dev/null 2>&1; then
      log "notification failed"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------

# 辅助模式：报告某个地址的 MAC，用来填配置。设置一张新网络时用：连到那张网上，然后跑它。
if [[ -n "${PRINT_MAC_IP:-}" ]]; then
  mac="$(arp_lookup "$PRINT_MAC_IP")"
  if [[ -z "$mac" ]]; then
    trigger_arp "$PRINT_MAC_IP"
    sleep 1
    mac="$(arp_lookup "$PRINT_MAC_IP")"
  fi
  if [[ -n "$mac" ]]; then
    printf '%s  %s\n' "$PRINT_MAC_IP" "$mac"
    exit 0
  fi
  echo "no answer from $PRINT_MAC_IP" >&2
  exit 1
fi

# WLC_CUR 让判定逻辑可以在不改变本机真实位置的情况下被测试；正常使用不要设置它。
if [[ -n "${WLC_CUR:-}" ]]; then
  current="$WLC_CUR"
else
  current="$(current_location)"; rc=$?
  if [[ "$rc" != 0 ]]; then
    if [[ "$rc" == 1 ]]; then why="scselect failed"; else why="its output did not parse"; fi
    log "cannot determine the current location ($why); not switching"
    exit 1
  fi
fi
log "current location: '${current:-?}'"

if ! load_config; then
  log "cannot use config: $CONFIG"
  log "expected a sourced file with groups like LOCATION_1_NAME / _IP / _MAC"
  exit 3
fi

# 语言字段写错时在这里说明一次（日志固定英文；--help 那条路已经在上面 exit 了）。
[[ -n "$SCRIPT_LANG_WARN" ]] && \
  log "SCRIPT_LANG='$SCRIPT_LANG_WARN' is not supported; using $SCRIPT_LANG_DEFAULT"

log "loaded ${#LOC_NAMES[@]} location rule(s) from $CONFIG"

matched_location=""
matched_idx=-1
matched_desc=""
feature_state="absent"   # absent | mismatch —— 只在什么都没命中时才有意义
mismatch_location=""     # 那个地址以错误 MAC 应答的规则

# 更早的一轮还欠用户什么，本轮加载一次。从这里起 write_state 会带它一起写；
# 见 write_state 上的注释。
pending_kind="$(read_pending)"
pending_rule="$(read_pending_rule)"

# 一遍扫描：每条规则做一次尝试。命中就设好 matched_* 并返回 0。feature_state 保留这遍
# 扫描失败的原因——"absent" 还是 "mismatch"——供日志行与唯一依赖它的那条通知使用。
probe_sweep() {
  local idx=0 loc ip mac seen rc
  feature_state="absent"
  mismatch_location=""
  while [[ $idx -lt ${#LOC_NAMES[@]} ]]; do
    loc="${LOC_NAMES[$idx]}"
    ip="${LOC_IPS[$idx]}"
    mac="${LOC_MACS[$idx]}"

    log "probing $ip for '$loc' (expect $mac)"
    seen="$(probe_once "$ip" "$mac")"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      log "  found $seen at $ip -> '$loc'"
      matched_location="$loc"
      matched_idx="$idx"
      matched_desc="$ip $seen"
      return 0
    elif [[ $rc -eq 1 ]]; then
      # 地址与两个 MAC 只出现在这一行本地日志里：任何带识别信息的东西都不进通知
      # （见 AGENTS.md 第 8 条）。
      log "  device at $ip has MAC $seen, expected $mac (identity mismatch)"
      feature_state="mismatch"
      mismatch_location="$loc"
    else
      log "  no answer from $ip"
    fi
    idx=$((idx + 1))
  done
  return 1
}

# 一笔欠账是关于某个位置的特征设备的。站在那张网络上、设备又对上了，说明异常已经结束，
# 这笔账可以销掉；其它任何命中都不销。在 matched_* 定下来之后调用一次。
forget_pending_if_resolved() {
  if [[ -n "$pending_kind" && -n "$pending_rule" && "$pending_rule" == "$matched_location" ]]; then
    log "feature device for '$matched_location' is present; the owed notice is resolved"
    pending_kind=""
  fi
}

# --- 离开。当我们正站在一个已知位置里，第一遍没有答案就已经足够回落：默认位置就是
# --- DHCP，所以机器在它实际所在的网络上先是可用的，而把剩下的预算等完只会让机器多停在
# --- 一份不合适的设置上。预算本身没有缩短——剩下的几遍就在这一轮里、紧接着跑——它是
# --- 切回来的第一次机会；CONFIRM_DELAY 之后还有一遍是最后一次机会。
# --- 见设计文档第 8 节。
switch_back() {
  log "the device is back after all; switching back to '$matched_location'"
  if ! scselect "$matched_location"; then
    log "scselect '$matched_location' failed"
    exit 1
  fi
  log "switched back to '$matched_location'"
  current="$matched_location"
  # 记下「这一轮是我们自己切回来的」，供下面决定还要不要打印 already in。
  switched_back=1
}

fell_back=0
switched_back=0
sweep=1
while [[ $sweep -le $ATTEMPTS ]]; do
  if probe_sweep; then
    # 这一遍里设备在某处应答了。如果我们已经为它回落过，就直接切回去；一次瞬时读数
    # 没必要让谁知道。
    [[ $fell_back -eq 1 ]] && switch_back
    break
  fi
  if [[ $sweep -eq 1 && "$current" != "$DEFAULT_LOCATION" ]]; then
    log "not on a known network (feature device $feature_state); falling back to '$DEFAULT_LOCATION'"
    if [[ "$APPLY" != 1 ]]; then
      log "dry run: would switch to '$DEFAULT_LOCATION' (use --apply)"
      exit 0
    fi
    if ! scselect "$DEFAULT_LOCATION"; then
      log "scselect '$DEFAULT_LOCATION' failed"
      exit 1
    fi
    log "switched to '$DEFAULT_LOCATION'"
    fell_back=1
  fi
  [[ $sweep -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
  sweep=$((sweep + 1))
done

if [[ -z "$matched_location" ]]; then
  if [[ "$fell_back" != 1 ]]; then
    # 没什么可切的，但更早的一轮可能仍欠着一条通知：还没告诉用户，这个位置的地址换了
    # 主人。只要异常从这里能观察到——同一个地址仍然以另一个 MAC 应答——就重试投递。
    # 从旧状态文件带过来的欠账没记规则名，所以任何 mismatch 都当作结清它的机会。
    if [[ "$feature_state" == "mismatch" && "$pending_kind" == "feature-mismatch" ]] \
       && { [[ -z "$pending_rule" ]] || [[ "$pending_rule" == "$mismatch_location" ]]; }; then
      log "still in '$DEFAULT_LOCATION' with the device changed; retrying the notice"
      if notify notify_mismatch; then
        # 只有真的被请求投递过、且送达了，才销掉这笔账。
        [[ "$NOTIFY" == 1 ]] && pending_kind=""
      fi
    fi
    log "not on a known network (feature device $feature_state); already in '$DEFAULT_LOCATION', nothing to do"
    write_state default
    exit 0
  fi

  log "feature device $feature_state in $ATTEMPTS sweeps; looking once more in ${CONFIRM_DELAY}s"
  sleep "$CONFIRM_DELAY"
  sweep=1
  while [[ $sweep -le $ATTEMPTS ]]; do
    if probe_sweep; then
      switch_back
      break
    fi
    [[ $sweep -lt $ATTEMPTS ]] && sleep "$RETRY_DELAY"
    sweep=$((sweep + 1))
  done
fi

if [[ -z "$matched_location" ]]; then
  # 真的走了。保持安静：机器本来就可用，而每次离开都会发生这件事。只有「设备被换掉了」
  # 值得告诉用户。
  log "feature device still $feature_state after ${CONFIRM_DELAY}s; we have left"
  if [[ "$feature_state" == "mismatch" ]]; then
    # 唯一值得通知的那种离开（第 7 节）。只有「请求过 --notify **且**投递成功」才算告诉过；
    # 手动跑一轮谁也没告诉，这条通知就继续欠着，留给下一次 agent 轮次投递。
    delivered=0
    if notify notify_mismatch; then
      [[ "$NOTIFY" == 1 ]] && delivered=1
    fi
    if [[ "$delivered" == 1 ]]; then
      pending_kind=""
    else
      pending_kind="feature-mismatch"
      pending_rule="$mismatch_location"
    fi
  fi
  write_state default
  exit 0
fi

# --- 在一张已知网络上。目标设备回答第二个问题：这还是我们写设置时的那张网吗？
if [[ "$matched_location" != "$current" ]]; then
  log "identified network as '$matched_location' ($matched_desc)"
  if [[ "$APPLY" == 1 ]]; then
    if scselect "$matched_location"; then
      log "switched to '$matched_location'"
    else
      log "scselect '$matched_location' failed"
      exit 1
    fi
  else
    log "dry run: would switch to '$matched_location' (use --apply)"
    exit 0
  fi
elif [[ "$switched_back" != 1 ]]; then
  # 只在「本来就在这个位置」时打印。这一轮刚由 switch_back 切回来的那种情况留空：它已经
  # 打印过 switched back …，紧跟一句 already in … 读起来像自相矛盾——线上日志里 16 次切回
  # 每一次都跟着这样一对——而判定结果已经由那两行说清楚了；下面照样继续核对目标设备。
  log "already in '$matched_location', nothing to do"
fi

# 我们在这张网络的这个位置上，且它的特征设备对上了，所以关于那台设备的欠账可以销掉。
# 关于另一个位置的欠账照旧保留。
forget_pending_if_resolved

tip="${LOC_TARGET_IPS[$matched_idx]}"
tmac="${LOC_TARGET_MACS[$matched_idx]}"
if [[ "$tip" == "${LOC_IPS[$matched_idx]}" ]] \
   && [[ "$(norm_mac "$tmac")" == "$(norm_mac "${LOC_MACS[$matched_idx]}")" ]]; then
  # 缺省情况：两个角色是同一台设备，所以上面那次探测已经替两者回答过了。不要再探一遍。
  target_ok=1
  log "target device is the feature device; its answer stands for both"
else
  log "probing $tip for '$matched_location' (target device, expect $tmac)"
  if tmac_seen="$(probe_device "$tip" "$tmac")"; then
    log "  found $tmac_seen at $tip -> target present"
    target_ok=1
  elif [[ -n "$tmac_seen" ]]; then
    log "  device at $tip has MAC $tmac_seen, expected $tmac (target identity mismatch)"
    target_ok=0
  else
    log "  no answer from $tip"
    target_ok=0
  fi
fi

if [[ "$target_ok" == 1 ]]; then
  log "target device present; settings match this network"
  write_state ok
  exit 0
fi

# 这张网本身在我们脚下变了。告诉用户；不要悄悄把他们的静态设置换成 DHCP。
if [[ "$NOTIFY" == 1 && "$(read_state)" == "broken" ]]; then
  log "broken already reported, not notifying again"
  exit 0
fi
if notify notify_broken; then
  [[ "$NOTIFY" == 1 ]] && write_state broken
fi
exit 0
