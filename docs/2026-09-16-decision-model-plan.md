# 决策模型更正 实施计划（目标设备 + 回落）

**状态：已完成，随后经过一次设计变更**——Task 1–4 已实现、验证并上线（2026-09-16），结果记在 `AGENTS.md` 第 6 节。**当晚使用者的复核推翻了其中两处**：跨轮安全阀改成「立即回落 + 轮内复探 15 秒」、去掉 `StartInterval`、回落不再通知。所以**本文档 Task 2 里内联的代码与配方是变更前的版本**；变更后的权威描述见 `docs/2026-09-16-decision-model-design.md` 的 §5/§7/§8/§11.2/§12。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「离开已知网络」自动回落到默认位置（并通知），同时让「还在那张网上、但环境与设置不符」只通知、不回落。

**Architecture:** 在现有探测器里把「一台设备」拆成两个角色——特征设备回答「我在哪张网上」，目标设备回答「这张网还是我设置里期待的那张吗」。特征设备连续两轮未确认就走回落；目标设备未确认就进 `broken` 只通知。状态文件从两态换成 `state=`/`miss=` 两个键。触发层（plist、`WatchPaths`、`StartInterval`、幂等收敛）一行不改。

**Tech Stack:** bash 3.2、`arp -n` + `/dev/udp` 二层探测、`scselect`、launchd。无第三方依赖，无测试框架。

**Spec:** `docs/2026-09-16-decision-model-design.md`

**本计划的来源**：设计文档 + 2026-09-16 的一轮 code review。review 里经复核成立的项目已折进对应任务——重名子串误杀（P1）与 IP 段值越界（P3）进了 Task 1，状态写入非原子（P4）进了 Task 2，脚本自述/`--help` 硬编码行号、README 与代码相反的那句、文档状态标注、以及线上日志的证据表进了 Task 3。review 里归因不成立的两项（任务 3 会改 header、Home 上两次误报）没有采纳，理由见当次对话。

## Global Constraints

- **纯 bash 3.2**：不得用 `${var,,}`、`mapfile`、关联数组。大小写归一化用 `tr`。
- **零依赖**：只用 macOS 自带命令。
- **语言**：面向用户的字符串、注释、README 用**英文**；`AGENTS.md` 与 `docs/` 用**中文**。
- **隐私**：仓库内文件、注释、**提交信息**里不得出现真机 IP/MAC/个人路径。示例值用 RFC 7042 的 `00:00:5e:00:53:xx` 与 RFC 5737 的 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`。
- **通知文案**不得包含 SSID、以及两台设备的地址与 MAC。
- **约定 4（IP + MAC 双匹配）**对两台设备都适用。
- **约定 6（幂等）**：回落同样必须收敛，不能来回抖。
- **约定 12**：状态文件的语义是「用户是否已被告知异常」，只有**真的送达**了才写 `broken`。
- 本仓库无测试框架；每个任务的验证都必须实际执行并贴出输出。

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `wifi-loc-detect.sh` | 唯一的判定代码：配置解析 + 判定分支 + 状态文件 | 1, 2 |
| `locations.env.example` | 新字段的示例与说明 | 3 |
| `README.md` | 判定表（`## Scope of the automation`）、回落说明、新字段 | 3 |
| `AGENTS.md` | 约定 5 重写、约定 4 扩展、第 6 节配方与已验证项 | 3 |
| `docs/2026-09-16-launchagent-design.md` | 加一行指向前置文档，避免两份状态表冲突 | 3 |
| `~/.wifi-loc-control/locations.env` | 线上配置补目标设备两行 | 4 |

---

### Task 1: 配置层——目标设备字段（含默认与校验）

**Files:**
- Modify: `wifi-loc-detect.sh` 的 `load_config()`（当前在 144–186 行）
- Test: `/tmp/wlc-target-config.sh`（不提交）

**Interfaces:**
- Consumes: 现有 `log()`、`CONFIG`。
- Produces: 两个新并行数组 `LOC_TARGET_IPS`、`LOC_TARGET_MACS`，下标与 `LOC_NAMES`/`LOC_IPS`/`LOC_MACS` 一一对应；每个位置多出一条日志 `config: rule '<名>': feature <ip>, target <tip>`（地址只进本地日志）。

- [ ] **Step 1: 写验证脚本（此时必然失败）**

创建 `/tmp/wlc-target-config.sh`：

```bash
#!/bin/bash
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
T=$(mktemp -d); pass=0; fail=0
has()    { if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1";
           else fail=$((fail+1)); echo "FAIL  $1 (no /$3/)"; sed 's/^/      | /' "$2"; fi; }
hasnt()  { if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 (unexpected /$3/)";
           else pass=$((pass+1)); echo "PASS  $1"; fi; }
run()    { WLC_STATE="$T/state" WLC_CONFIG="$1" ./wifi-loc-detect.sh > "$2" 2>&1; }

cat > "$T/def.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
run "$T/def.env" "$T/o1"
has "省略目标字段时默认等于特征设备" "$T/o1" "config: rule 'Home': feature 192.0.2.1, target 192.0.2.1"

cat > "$T/exp.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="192.0.2.100"
LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"
EOF
run "$T/exp.env" "$T/o2"
has "显式目标设备被采用" "$T/o2" "target 192.0.2.100"
has "特征设备仍被采用"   "$T/o2" "feature 192.0.2.1"

cat > "$T/half.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="192.0.2.100"
EOF
run "$T/half.env" "$T/o3"
has "只给 TARGET_IP 时仍加载" "$T/o3" "target 192.0.2.100"

cat > "$T/bad.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_1_TARGET_IP="999.1.1"
EOF
run "$T/bad.env" "$T/o4"
has   "非法 TARGET_IP 报错并跳过整组" "$T/o4" "invalid TARGET_IP"
hasnt "非法组没有进入规则表"          "$T/o4" "config: rule"

# 5. 重名判断必须逐元素比较（P1：旧代码用子串匹配，会把 "Home" 误判成
#    与 "Home Office" 重名）
cat > "$T/names.env" <<'EOF'
LOCATION_1_NAME="Home Office"
LOCATION_1_IP="192.0.2.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
LOCATION_2_NAME="Home"
LOCATION_2_IP="192.0.2.2"
LOCATION_2_MAC="00:00:5e:00:53:02"
EOF
run "$T/names.env" "$T/o5"
hasnt "子串名字不算重名（P1）" "$T/o5" "duplicate"
has   "两条规则都加载"         "$T/o5" "loaded 2 location rule(s)"

# 6. 段值越界必须被跳过（P3：旧代码只查形状，999.1.1.1 会被接受并被探测）
cat > "$T/range.env" <<'EOF'
LOCATION_1_NAME="Home"
LOCATION_1_IP="999.1.1.1"
LOCATION_1_MAC="00:00:5e:00:53:01"
EOF
run "$T/range.env" "$T/o6"
has   "越界 IP 被跳过（P3）" "$T/o6" "invalid IP"
hasnt "越界组未加载"         "$T/o6" "config: rule"

rm -rf "$T"
echo "=== $pass passed, $fail failed ==="
```

- [ ] **Step 2: 运行，确认失败**

Run: `bash /tmp/wlc-target-config.sh`
Expected: FAIL——此时不认 `_TARGET_*`，`o1` 里没有 `config: rule` 行。

- [ ] **Step 3: 改 `load_config`**

把 `wifi-loc-detect.sh` 里的 `load_config()` 整体替换为：

```bash
# 0-255 in each octet. A shape-only check accepts 999.1.1.1 and then spends the
# whole probe budget on an address that cannot exist.
valid_ipv4() {
  local ip="$1" oct
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for oct in $ip; do
    (( 10#$oct <= 255 )) || return 1   # 10# forces base 10, so "08" is eight
  done
  return 0
}

load_config() {
  [[ -f "$CONFIG" ]] || return 1

  # The config is sourced: it is code, not data. Variables are unset right
  # after reading so they cannot leak into anything this script runs later.
  # shellcheck disable=SC1090
  source "$CONFIG" || return 2

  LOC_NAMES=()
  LOC_IPS=()
  LOC_MACS=()
  LOC_TARGET_IPS=()
  LOC_TARGET_MACS=()
  local n name ip mac tip tmac
  for (( n = 1; n <= 64; n++ )); do
    name="LOCATION_${n}_NAME"; ip="LOCATION_${n}_IP"; mac="LOCATION_${n}_MAC"
    tip="LOCATION_${n}_TARGET_IP"; tmac="LOCATION_${n}_TARGET_MAC"
    name="${!name:-}"; ip="${!ip:-}"; mac="${!mac:-}"
    tip="${!tip:-}"; tmac="${!tmac:-}"
    unset "LOCATION_${n}_NAME" "LOCATION_${n}_IP" "LOCATION_${n}_MAC" \
          "LOCATION_${n}_TARGET_IP" "LOCATION_${n}_TARGET_MAC"

    [[ -z "$name$ip$mac$tip$tmac" ]] && continue
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

    # The target device answers a different question than the feature device:
    # "is this still the network my settings were written for?" It defaults to
    # the feature device, so a network that needs no separate check needs no
    # separate configuration. See docs/2026-09-16-decision-model-design.md.
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

    # Compare name by name. Testing the joined list for a substring would
    # wrongly drop "Home" when "Home Office" came first, and both are valid
    # names (a location name may contain spaces).
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
```

显式给出但**非法**的 `_TARGET_*` 会让整组被跳过（与非法 `_IP`/`_MAC` 一致）；**缺失**才走默认。这样不会出现「你以为目标检查开着、其实被静默退回特征设备」。

- [ ] **Step 4: 运行，确认通过**

Run: `bash -n wifi-loc-detect.sh && bash /tmp/wlc-target-config.sh`
Expected: `bash -n` 静默；**10 passed, 0 failed**（含 P1 子串重名与 P3 段值越界两个回归）。

- [ ] **Step 5: 回归——旧判定不受影响**

Run: `bash /tmp/wlc-state-test.sh`
Expected: 11 passed, 0 failed（这份配方断言的是旧语义，Task 2 之后才会改；此刻必须仍然全过）。

- [ ] **Step 6: 提交**

```bash
git add wifi-loc-detect.sh
git commit -m "feat: add an optional target device per location

A network can need two different questions answered: which network am I
on, and is this still the network my settings were written for. The
target device answers the second and defaults to the feature device, so
networks that need no separate check need no separate configuration.

An explicitly configured but malformed target skips the whole group
rather than silently falling back to the feature device."
```

---

### Task 2: 判定层——三态、`miss` 安全阀、目标核对与回落

**Files:**
- Modify: `wifi-loc-detect.sh`（状态读写函数、`current=` 那一行、`matched_location` 循环到文件末尾）
- Test: `/tmp/wlc-decision-test.sh`（不提交）

**Interfaces:**
- Consumes: Task 1 的 `LOC_TARGET_IPS`/`LOC_TARGET_MACS`；现有 `probe_device`、`norm_mac`、`notify`、`APPLY`、`NOTIFY`。
- Produces:
  - 状态文件两个键：`state=default|ok|broken`、`miss=<整数>`。
  - `read_state()`（打印状态值，可能为空）、`read_miss()`（打印整数，缺省 0）、`write_state <state> <miss>`。
  - 新的测试钩子 `WLC_CUR`：覆盖「当前位置」，缺省时行为与现在完全一致。

- [ ] **Step 1: 写验证脚本（此时必然失败）**

创建 `/tmp/wlc-decision-test.sh`。它把 `osascript` **和 `scselect` 都打桩**，所以既不会弹通知、也**不会真的改动本机位置**：

```bash
#!/bin/bash
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
T=$(mktemp -d); mkdir -p "$T/bin"
cat > "$T/bin/osascript" <<'EOF'
#!/bin/sh
echo called >> "$WLC_NOTIFY_LOG"
EOF
cat > "$T/bin/scselect" <<'EOF'
#!/bin/sh
printf '%s\n' "${1:-<read>}" >> "$WLC_SCSELECT_LOG"
EOF
chmod +x "$T/bin/osascript" "$T/bin/scselect"
export PATH="$T/bin:$PATH"
export WLC_NOTIFY_LOG="$T/notify.log" WLC_SCSELECT_LOG="$T/ss.log" WLC_STATE="$T/state"

FIP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
      | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' | head -1 | awk '{print $1}')
FMAC=$(arp -n "$FIP" | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
DEAD=203.0.113.7

pass=0; fail=0
eq()    { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1";
          else fail=$((fail+1)); echo "FAIL  $1 (want [$2], got [$3])"; fi; }
has()   { if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1";
          else fail=$((fail+1)); echo "FAIL  $1 (no /$3/)"; sed 's/^/      | /' "$2"; fi; }
hasnt() { if grep -q "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL  $1 (unexpected /$3/)";
          else pass=$((pass+1)); echo "PASS  $1"; fi; }
order() { local a b; a=$(grep -n "$2" "$3" | head -1 | cut -d: -f1)
          b=$(grep -n "$4" "$3" | head -1 | cut -d: -f1)
          if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass=$((pass+1)); echo "PASS  $1"
          else fail=$((fail+1)); echo "FAIL  $1 (line $a vs $b)"; fi; }
notify_count() { wc -l < "$WLC_NOTIFY_LOG" 2>/dev/null | tr -d ' '; }
ss_count()     { grep -c "^$1\$" "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' '; }
mkcfg() { printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\nLOCATION_1_TARGET_IP="%s"\nLOCATION_1_TARGET_MAC="%s"\n' \
            "$2" "$3" "$4" "$5" > "$1"; }
# run <配置> <默认位置> <当前位置> [探测器的参数…]
run()  { local cfg="$1" dflt="$2" cur="$3"; shift 3
         WLC_CONFIG="$cfg" WLC_DEFAULT="$dflt" WLC_CUR="$cur" ./wifi-loc-detect.sh --apply --notify > "$T/out" 2>&1; }
reset() { : > "$WLC_NOTIFY_LOG"; : > "$WLC_SCSELECT_LOG"; rm -f "$WLC_STATE"; }

OK_CFG="$T/ok.env"; mkcfg "$OK_CFG" "$FIP" "$FMAC" "$FIP" "$FMAC"
BR_CFG="$T/br.env"; mkcfg "$BR_CFG" "$FIP" "$FMAC" "$DEAD" "de:ad:be:ef:00:01"
MM_CFG="$T/mm.env"; mkcfg "$MM_CFG" "$FIP" "de:ad:be:ef:00:01" "$FIP" "de:ad:be:ef:00:01"
NO_CFG="$T/no.env"; mkcfg "$NO_CFG" "$DEAD" "de:ad:be:ef:00:01" "$DEAD" "de:ad:be:ef:00:01"

# N1/N2 —— 目标省略（默认等于特征）：ok、不通知、不切换、不重复探测
reset; run "$OK_CFG" Automatic Home
has   "N2 判定为匹配"               "$T/out" "settings match"
hasnt "N1 目标等于特征时不重复探测" "$T/out" "target device, expect"
eq    "N2 不通知"                   0 "$(notify_count)"
eq    "N2 不切换"                   0 "$(ss_count Home)"
eq    "N2 状态 ok"                  ok "$(sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null)"

# N3 —— 命中 + 目标掉线：broken，只通知一次，不切换
reset; run "$BR_CFG" Automatic Home
has "N3 进入 broken 并通知" "$T/out" "NOTIFY:"
eq  "N3 通知一次"           1 "$(notify_count)"
eq  "N3 状态 broken"        broken "$(sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null)"
eq  "N3 不切换"             0 "$(ss_count Home)"
run "$BR_CFG" Automatic Home
has "N3 第二轮被抑制"       "$T/out" "already reported"
eq  "N3 通知仍是 1 次"      1 "$(notify_count)"

# N5 —— 目标恢复回 ok；再坏一次会再通知
run "$OK_CFG" Automatic Home
eq "N5 目标恢复回 ok"  ok "$(sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null)"
run "$BR_CFG" Automatic Home
eq "N5 再坏会再通知"   2 "$(notify_count)"

# N4 —— 在默认位置时命中：先切换、再核对目标（scselect 是桩，不动真机）
reset; run "$BR_CFG" Automatic Automatic
has   "N4 识别并切换"        "$T/out" "switched to 'Home'"
eq    "N4 真的调用了切换"    1 "$(ss_count Home)"
order "N4 先切换后核对目标"  "switched to 'Home'" "$T/out" "target device, expect"
has   "N4 目标掉线判 broken"  "$T/out" "NOTIFY:"

# N10 —— 特征不可达且已在默认位置：default，不动作不通知
reset; run "$NO_CFG" Automatic Automatic
has "N10 无动作"       "$T/out" "nothing to do"
eq  "N10 不通知"       0 "$(notify_count)"
eq  "N10 状态 default" default "$(sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null)"
eq  "N10 不切换"       0 "$(ss_count Automatic)"

# N6 —— 特征不可达一轮且不在默认位置：安全阀，不回落
reset; run "$NO_CFG" Automatic Home
has "N6 第一轮不回落" "$T/out" "miss 1 of 2"
eq  "N6 miss=1"       1 "$(sed -n 's/^miss=//p' "$WLC_STATE" 2>/dev/null)"
eq  "N6 不通知"       0 "$(notify_count)"
eq  "N6 不切换"       0 "$(ss_count Automatic)"

# N7 —— 连续第二轮：回落 + 通知一次 + miss 归零
run "$NO_CFG" Automatic Home
has "N7 回落"         "$T/out" "falling back to 'Automatic'"
eq  "N7 调用了回落"   1 "$(ss_count Automatic)"
eq  "N7 通知一次"     1 "$(notify_count)"
eq  "N7 状态 default" default "$(sed -n 's/^state=//p' "$WLC_STATE" 2>/dev/null)"
eq  "N7 miss 归零"    0 "$(sed -n 's/^miss=//p' "$WLC_STATE" 2>/dev/null)"

# N11 —— 回落之后再跑一轮：不重复通知
run "$NO_CFG" Automatic Automatic
eq "N11 不重复通知" 1 "$(notify_count)"

# N9 —— 未确认一轮后又确认：miss 归零（安全阀不攒着）
reset; run "$NO_CFG" Automatic Home; run "$OK_CFG" Automatic Home
eq "N9 确认后 miss 归零" 0 "$(sed -n 's/^miss=//p' "$WLC_STATE" 2>/dev/null)"

# N8 —— 特征地址被别的设备占用（真实在线地址 + 错 MAC）：同样回落
reset; run "$MM_CFG" Automatic Home; run "$MM_CFG" Automatic Home
eq  "N8 身份不符也回落"   1 "$(notify_count)"
has "N8 文案说明换了设备" "$T/out" "was replaced"
eq  "N8 真的调用了回落"   1 "$(ss_count Automatic)"

# N12 —— 旧格式状态文件（单行 away）：按未通知处理
reset; printf 'away\n' > "$WLC_STATE"; run "$BR_CFG" Automatic Home
eq "N12 旧格式不阻止通知" 1 "$(notify_count)"

# 测试卫生：全程不应出现「读取当前位置」的真实调用
eq "全程没有误用真实 scselect" 0 "$(grep -c '^<read>$' "$WLC_SCSELECT_LOG" 2>/dev/null | tr -d ' ')"

rm -rf "$T"
echo "=== $pass passed, $fail failed ==="
```

- [ ] **Step 2: 运行，确认失败**

Run: `bash /tmp/wlc-decision-test.sh`
Expected: 大面积 FAIL——三态、`miss`、回落都还不存在。

- [ ] **Step 3: 换掉状态读写函数**

把 `read_state`/`write_state` 替换为：

```bash
# The state file has two keys:
#   state=default|ok|broken   what the user has been told about this state
#   miss=N                    consecutive rounds the feature device was unconfirmed
# Only the literal value "broken" counts as "already told": a missing, empty or
# unknown value reads as "not told yet", so the failure direction is one notice
# too many rather than one silently swallowed. An older single-value file reads
# as "not told yet" too, so no migration is needed.
# See docs/2026-09-16-decision-model-design.md.
read_state() {
  [[ -f "$STATE" ]] || return 0
  sed -n 's/^state=//p' "$STATE" 2>/dev/null | head -n 1
}

read_miss() {
  local n
  n="$(sed -n 's/^miss=//p' "$STATE" 2>/dev/null | head -n 1)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# write_state <state> <miss>
# Written through a temporary file in the same directory: a reader must never
# see a half-written state, because two triggers can overlap.
write_state() {
  local tmp="${STATE}.tmp.$$"
  if printf 'state=%s\nmiss=%s\n' "$1" "$2" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$STATE" 2>/dev/null || { rm -f "$tmp"; log "could not write state file: $STATE"; }
  else
    log "could not write state file: $STATE"
  fi
}
```

- [ ] **Step 4: 加 `WLC_CUR`（只为可测性）**

把 `current="$(current_location)"` 换成：

```bash
# WLC_CUR lets the decision logic be tested without changing the machine's
# real location; it is not meant to be set in normal use.
current="${WLC_CUR:-$(current_location)}"
```

- [ ] **Step 5: 重写判定流程**

把从 `matched_location=""` 到文件末尾整段替换为：

```bash
matched_location=""
matched_idx=-1
matched_desc=""
feature_state="absent"   # absent | mismatch —— 只在没有任何规则命中时才有意义

idx=0
while [[ $idx -lt ${#LOC_NAMES[@]} ]]; do
  loc="${LOC_NAMES[$idx]}"
  ip="${LOC_IPS[$idx]}"
  mac="${LOC_MACS[$idx]}"
  idx=$((idx + 1))

  log "probing $ip for '$loc' (expect $mac)"
  if mac_seen="$(probe_device "$ip" "$mac")"; then
    log "  found $mac_seen at $ip -> '$loc'"
    matched_location="$loc"
    matched_idx=$((idx - 1))
    matched_desc="$ip $mac_seen"
    break
  elif [[ -n "$mac_seen" ]]; then
    # The address and both MACs stay in this local log line only: nothing
    # identifying goes into a notification (see AGENTS.md, section 8).
    log "  device at $ip has MAC $mac_seen, expected $mac (identity mismatch)"
    feature_state="mismatch"
  else
    log "  no answer from $ip"
  fi
done

# --- On a known network. The target device answers a second question: is this
# --- still the network our settings were written for?
if [[ -n "$matched_location" ]]; then
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
  else
    log "already in '$matched_location', nothing to do"
  fi

  tip="${LOC_TARGET_IPS[$matched_idx]}"
  tmac="${LOC_TARGET_MACS[$matched_idx]}"
  if [[ "$tip" == "${LOC_IPS[$matched_idx]}" ]] \
     && [[ "$(norm_mac "$tmac")" == "$(norm_mac "${LOC_MACS[$matched_idx]}")" ]]; then
    # Default case: both roles are the same device, so the probe above already
    # answered for both. Do not probe twice.
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
    write_state ok 0
    exit 0
  fi

  # The network itself changed under us. Tell the user; do not quietly swap
  # their static settings for DHCP.
  if [[ "$NOTIFY" == 1 && "$(read_state)" == "broken" ]]; then
    log "broken already reported, not notifying again"
    exit 0
  fi
  if notify "The current network no longer matches the configured settings. Check the network settings."; then
    [[ "$NOTIFY" == 1 ]] && write_state broken 0
  fi
  exit 0
fi

# --- Not on any known network. If we are not already on the default location,
# --- fall back so the machine works on whatever network it is actually on.
miss="$(read_miss)"

if [[ "$current" == "$DEFAULT_LOCATION" ]]; then
  log "not on a known network (feature device $feature_state); already in '$DEFAULT_LOCATION', nothing to do"
  write_state default 0
  exit 0
fi

miss=$((miss + 1))
if [[ "$miss" -lt 2 ]]; then
  # Safety valve: one miss can be our own switch flushing the neighbour table,
  # or a transient blip. Require two rounds before acting.
  log "feature device $feature_state; miss $miss of 2 before falling back"
  write_state "$(read_state)" "$miss"
  exit 0
fi

log "feature device $feature_state for $miss rounds; falling back to '$DEFAULT_LOCATION'"
if [[ "$APPLY" == 1 ]]; then
  if scselect "$DEFAULT_LOCATION"; then
    log "switched to '$DEFAULT_LOCATION'"
  else
    log "scselect '$DEFAULT_LOCATION' failed"
    exit 1
  fi
else
  log "dry run: would switch to '$DEFAULT_LOCATION' (use --apply)"
  exit 0
fi

# The location really did change, so record it before telling anyone: a failed
# notice here must not leave the state claiming we are somewhere we are not.
write_state default 0
if [[ "$feature_state" == "mismatch" ]]; then
  notify "Left the known network: the device at the configured address was replaced. Switched back to the default location."
else
  notify "Left the known network. Switched back to the default location."
fi
exit 0
```

**刻意保留的两处旧行为**（免得改坏已验证的东西）：命中且已在其中时仍打印 `already in '<位置>', nothing to do`；干跑（不带 `--apply`）在切换点就退出、不做目标核对——所以 `AGENTS.md` 第 6 节现有的配方仍然成立。

- [ ] **Step 6: 语法检查并跑判定用例**

Run: `bash -n wifi-loc-detect.sh && bash /tmp/wlc-decision-test.sh`
Expected: `bash -n` 静默；末行 **`=== 37 passed, 0 failed ===`**。这份用例里有约 11 次「探测不可达地址」，每次 4 次重试 ≈7 秒，所以整份约 **90 秒**——不要以为它卡住了。

- [ ] **Step 7: 回归——旧配方会失败，这是预期的**

Run: `bash /tmp/wlc-state-test.sh`
Expected: **失败**。那份配方断言的是旧语义（「离家 = 只通知」）。**不要改代码去迁就它**，按 Step 8 升级配方，并在 Task 3 把新版写进 `AGENTS.md`。

- [ ] **Step 8: 升级状态机配方**

把 `/tmp/wlc-state-test.sh` 改成新语义（并把 `scselect` 也打桩，理由同 Step 1）：

- 保留：目标在特征设备上（默认）时命中 → `ok`、不通知。
- 替换：旧「离家只通知一次 + 抑制」→ 改为「特征设备在场、目标掉线 → `broken` 通知一次 + 抑制」。
- 保留：手动跑（不带 `--notify`）不写状态、不吞掉以后的通知。
- 保留：投递失败不写状态、下一轮重试。
- 新增：确认一轮后 `miss` 归零。

Run: `bash /tmp/wlc-state-test.sh`
Expected: 全过（`0 failed`）。

- [ ] **Step 9: 提交**

```bash
git add wifi-loc-detect.sh
git commit -m "feat: fall back to the default location after leaving a network

The old rule treated every unreachable feature device as 'the network
changed, do not guess', which left the machine on static settings that do
not work anywhere else. It now separates the two situations: an
unconfirmed feature device means we left (fall back to the default so the
machine works), while an unconfirmed target device means the network
changed under us (notify, leave the settings alone).

A miss counter requires two consecutive unconfirmed rounds before falling
back, because switching a location flushes the neighbour table and can
look like a departure for one round."
```

---

### Task 3: 示例配置与文档

**Files:**
- Modify: `locations.env.example`、`README.md`、`AGENTS.md`、`docs/2026-09-16-launchagent-design.md`

**Interfaces:**
- Consumes: Task 1/2 的字段名与状态词汇。
- Produces: 与代码一致的文档；`AGENTS.md` 第 6 节带新版配方与新已验证清单。

- [ ] **Step 1: `locations.env.example` 增加目标设备字段**

在第一个组的 `LOCATION_1_MAC` 之后插入：

```sh
# Optional: the device that must be present for this location's own settings
# (its gateway or DNS) to still make sense. Omit it and the feature device is
# used, which is right whenever the identifying device is also the one your
# settings depend on. If you give one, give it in full: a malformed target
# makes the whole group be skipped rather than silently ignored.
# LOCATION_1_TARGET_IP="192.0.2.100"
# LOCATION_1_TARGET_MAC="00:00:5e:00:53:02"
```

- [ ] **Step 2: README 的判定表改成新模型**

`## Scope of the automation` 整段替换（英文）：

```markdown
| Current state | Probe result | Action |
|---|---|---|
| `Automatic` | matches a known network | switch to that location |
| in that location | matches, target device present | nothing (idempotent) |
| in that location | matches, target device missing | **notify**, do not switch |
| in any location | no known network found | **switch back to the default location** |

Entering a network and leaving one are both automatic. Leaving is detected when
the feature device cannot be found for two consecutive checks, and the Mac is
returned to the default location so that it works on whatever network it is
actually on.

A network that is still there but no longer matches — the device your settings
depend on is gone, or the address now belongs to something else — is a
different case. That one is reported rather than papered over, because
switching away would silently replace your static settings with DHCP.
```

- [ ] **Step 3: README 的 `--notify`、已知限制、`## Setup` 同步**

- `## Usage` 里 `--apply --notify` 改成：在离开已知网络时、以及在设置与当前网络不符时通知；同一状态只通知一次。
- `## Setup` 的配置示例里加上注释形式的目标设备两行，并说明默认取特征设备。
- `## Known limitations` 增补：
  - 「离开的判定需要连续两轮未确认，所以真正离开后回落会晚一个检查周期：有网络活动时约 60 秒，完全安静时最多 5 分钟。」
  - 「目标设备与特征设备都必须双匹配通过，否则该位置的设置被视为与网络不符。」
  - 「**回落通知发送失败时不会重试。** 位置已经切了，没有可靠的地方记住这笔未付的通知；`broken` 的通知则遵循「没送达就不记账、下一轮重试」。」

- [ ] **Step 4: AGENTS.md 约定 5 重写**

把第 2 节第 5 条替换为：

```markdown
5. **自动化做两个方向，但只有「离开」会自动回落到默认位置。** 进入已知位置是自动的；特征设备连续两轮未确认（`miss` 安全阀）时自动回落到默认位置，让机器在任何网络上都能用；而**在某个已知位置内发现目标设备不符时，只通知、不回落**——那说明这张网本身变了，擅自动作会把静态设置悄悄换成 DHCP。两者靠**特征设备**（我在哪张网上）与**目标设备**（这张网还是我设置里期待的那张吗）区分，见 `docs/2026-09-16-decision-model-design.md`。
```

并在同节第 4 条末尾补：目标设备同样适用 IP + MAC 双匹配。

- [ ] **Step 5: AGENTS.md 第 6 节更新**

- 收入 Task 2 Step 8 之后的新版状态机配方（`osascript` 与 `scselect` 双桩，明确写「不会弹通知、不会改动本机位置」）。
- 收入判定用例命令与期望。
- 「已验证」里把旧的「离家只通知」整段替换为「特征设备未确认 → 回落 + 通知」「目标设备未确认 → `broken` 只通知」。
- 「尚未验证」保留 `10:49:38` 待查项，并加「R3S 真的下线的场景未测（只用未应答地址模拟）」与「回落通知失败不重试」。

- [ ] **Step 6: 旧设计文档加指向**

在 `docs/2026-09-16-launchagent-design.md` 开头的引用块之后加：

```markdown
> **注意**：本文档第 1 节与第 3 节关于「离家」的规则已被
> `docs/2026-09-16-decision-model-design.md` 取代（那份把「离开网络」与「网络变了」分开）。
> 触发层的机械部分（`WatchPaths` + `StartInterval` + 幂等收敛）仍然有效。
```

- [ ] **Step 7: 重写脚本自述，并把 `--help` 的行号改成哨兵**

脚本现在按新模型跑，但 header 第 16–20 行、Usage 注释和 `--help` 正文仍在说「只通知、不切」。三者都要改，否则 `--help` 会自相矛盾（这是 code review 抓到的计划缺口）。

先改 header 里那段设计说明，写成「两个方向、只有离开回落、两台设备的角色」。再把 Usage 块改成：

```bash
#   ./wifi-loc-detect.sh                    # dry run: print the decision only
#   ./wifi-loc-detect.sh --apply            # actually run scselect
#   ./wifi-loc-detect.sh --apply --notify   # notify when this network no
#                                           # longer matches the settings
#   ./wifi-loc-detect.sh --print-mac <ip>   # helper: show the MAC for an IP,
#                                           # to fill in the config file
```

然后删掉 `HELP_LAST_LINE=41` 这一行，并把 `--help` 分支换成哨兵（对行数免疫，改 header 不会再静默截断）：

```bash
    -h|--help)
      awk 'NR > 1 && /^set -uo pipefail/ { exit }
           NR > 1 { sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
```

Run: `bash -n wifi-loc-detect.sh; ./wifi-loc-detect.sh --help | grep -c 'print-mac'; ./wifi-loc-detect.sh --help | tail -4`
Expected: 语法通过；`grep -c` 是 `1`（旧版曾被截断成 `0`）；`tail` 显示完整的 Usage 尾部。

再验证哨兵对行数免疫：在 header 里临时插入一行注释，`--help` 仍应打印完整块，然后撤销那一行。

- [ ] **Step 8: 修 README 那处与代码相反的陈述与退出码**

- §2「Write the config」里那句 `When no group matches, the script switches to the default location, which is Automatic` 换成新模型的准确表述：**没命中任何已知网络时**，若当前不在默认位置就回落到它（需连续两轮确认），否则什么都不做。这句在旧代码下是错的、在新模型下才成立，所以必须随行为一起改，不能只删。
- `Exit codes` 那行补上 `1`（`scselect` 失败，或 `--print-mac` 无应答）。

Run: `grep -n 'switches to the default location' README.md || echo "PASS: 旧表述已清除"`
Expected: `PASS`。

- [ ] **Step 9: 给「谁是当前事实」加状态标注**

仓库里同时存在「旧模型代码 + 新设计文档 + 两份计划」，后来者容易照错的一份改。加三行状态：

- `docs/2026-09-16-launchagent-design.md` 第 4 行的「状态：设计已确认，待实现」→「状态：**已实施并实测**（触发层在跑，见 `AGENTS.md` 第 6 节）」。
- `docs/2026-09-16-launchagent-plan.md` 顶部加：「**状态：已执行**（6 个任务全部完成并验证）。」
- 本文件顶部加：「**状态：已批准，执行中**。」

- [ ] **Step 10: AGENTS.md 第 6 节的「尚未验证」换成证据**

把那份清单写成实测记录（时间戳取自 `~/.wifi-loc-control/agent.log`，共 5 次 `no answer`）：

```markdown
| 时间 | 当时位置 | 归因 |
|---|---|---|
| 10:49:38 | `Automatic` | **待查**——使用者确认当时在家庭网络上，未复现 |
| 10:58:21 | `Home` | 使用者手动切到手机热点（10:58:07 与 10:59:03 设备均在场）|
| 11:08:26 | `Home` | 刻意的热点测试第一轮（通知一次）|
| 11:09:27 | `Home` | 同一测试第二轮（被去重抑制）|
| 11:56:52 | `Home` | 使用者手动切到手机热点（其下一条消息即在问热点下为何不切）|
```

并注明：**连续两轮只出现过一次，且那一次是真离开**，所以 `miss >= 2` 的阀值目前没有反例。若将来观察到「在家里连续两轮未确认」，阀值应提到 3——把这条判断依据留在文档里。

- [ ] **Step 11: 文档自检 + 提交**

Run:

```sh
git grep -nE '只通知、不自动切|只通知，不自动切|no LaunchAgent yet|HELP_LAST_LINE' -- . || echo "PASS: 旧表述与硬编码行号已清除"
git grep -c '_TARGET_IP' -- . | sed 's/^/  /'
bash -n wifi-loc-detect.sh
./wifi-loc-detect.sh --help | grep -c 'print-mac'
bash /tmp/wlc-decision-test.sh | tail -1
```

Expected: 旧表述 0 命中；字段名出现在 example/README/AGENTS/设计文档；语法通过；`--help` 里有 `print-mac`；判定用例全过。

```bash
git add locations.env.example README.md AGENTS.md wifi-loc-detect.sh docs/
git commit -m "docs: describe the two device roles and the fallback

Replaces the notify-only rule in the conventions, the README decision
table, the script's own header and its --help output with what the
detector now does: fall back when the feature device is gone, notify when
the target device is gone.

--help no longer depends on a hardcoded last line, so editing the header
can no longer silently truncate it, and the two docs that describe the
current state now say which state they describe."
```

---

### Task 4: 线上配置与真实端到端（需要使用者）

**Files:**
- Modify: `~/.wifi-loc-control/locations.env`（工作区之外，需要一次提权批准）

**Interfaces:**
- Consumes: Task 1–3 已提交的探测器与文档。
- Produces: 线上配置带上真实目标设备；三条真实验证记录写回 Task 3 的文档。

- [ ] **Step 1: 先问清楚目标设备，不要推测真机值**

向使用者确认：
1. `Home` 位置的目标设备（那份静态设置的网关/DNS）的 IP 与 MAC——IP 他提过是 `1.100`，MAC 需要现取。
2. 特征设备是否就是那台上游路由器（`1.1`）。

取 MAC：

```sh
./wifi-loc-detect.sh --print-mac <使用者给出的地址>
```

**注意输出是「地址␣␣MAC」两个字段**，不是单独的 MAC——写成配置时要取第二个字段（`| awk '{print $2}'`），否则会把地址也塞进 `_TARGET_MAC` 让整组被跳过。2026-09-16 实施时正是这么踩了一次，而且当时那条命令在写入被沙箱拒绝后仍然打印了「写入完成」（`cat` 失败但后面的 `echo` 照跑）——**写入后必须在同一条命令里校验**。

- [ ] **Step 2: 写入线上配置（需要提权）**

在 `~/.wifi-loc-control/locations.env` 的第一个组里加两行。然后：

Run: `stat -f '%Sp %N' ~/.wifi-loc-control/locations.env; ./wifi-loc-detect.sh | tail -3`
Expected: 权限仍是 `-rw-------`；输出里有 `config: rule 'Home': feature <特征地址>, target <目标地址>`。

- [ ] **Step 3: 真实端到端 A——目标设备核对**

用**临时**配置模拟目标掉线，不碰线上配置：

```sh
T=$(mktemp -d)
sed 's/^LOCATION_1_TARGET_IP=.*/LOCATION_1_TARGET_IP="203.0.113.7"/' \
    ~/.wifi-loc-control/locations.env > "$T/broken.env"
WLC_STATE="$T/state" WLC_CONFIG="$T/broken.env" ./wifi-loc-detect.sh
WLC_STATE="$T/state" WLC_CONFIG="$T/broken.env" ./wifi-loc-detect.sh --apply --notify
```

Expected: 第一轮干跑打印目标 `no answer` 与 `broken` 判定；第二轮真的弹一条通知，`state` 写 `broken`，而**位置不变**。

- [ ] **Step 4: 真实端到端 B——回落（需要使用者连手机热点）**

告诉使用者：**位置保持 `Home`，连到手机热点，然后不要动任何东西**；预计最多 2 分钟后**自动切回 `Automatic` 并收到一条通知**——这正是本次要修的场景。

Run（在热点上观察）：

```sh
for i in $(seq 1 40); do
  sleep 10
  loc=$(scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p')
  echo "$(date '+%H:%M:%S') loc=$loc"
  [ "$loc" = Automatic ] && { echo "→ 已自动回落"; break; }
done
tail -14 ~/.wifi-loc-control/agent.log
cat ~/.wifi-loc-control/state
```

Expected: 两轮 `miss` 之后位置变为 `Automatic`；日志有 `falling back to 'Automatic'` 与一条 `NOTIFY:`；`state` 是 `default`。

- [ ] **Step 5: 真实端到端 C——回家自动切回**

请使用者连回家里的 Wi-Fi。Expected: 数秒内位置回到 `Home`，`state` 变 `ok`，`agent.log` 显示是 agent 触发的。

- [ ] **Step 6: 把实测结果写回文档并提交**

在 `AGENTS.md` 第 6 节记下 Step 3–5 的时间与结论（含真实的回落耗时），并把「R3S 真的下线的场景未测」按实际测到的内容改写。

```bash
git add AGENTS.md
git commit -m "docs: record the measured fallback and target-device behaviour"
```

- [ ] **Step 7: 收尾核对**

Run:

```sh
git status --short --branch
bash -n wifi-loc-detect.sh
bash /tmp/wlc-decision-test.sh | tail -1
# 通用审计（不含任何真值）：仓库里不应有个人路径，也不应有留白段以外的 MAC
git grep -nE '/Users/[A-Za-z]' -- . || echo "PASS: 无个人绝对路径"
git grep -nE '([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}' -- . \
  | grep -vE '00:00:5e:00:53|de:ad:be:ef|aa:bb:cc:dd:ee:ff' \
  || echo "PASS: MAC 只有留白段与占位值"
```

Expected: 工作区干净；语法通过；判定用例全过；两条审计都打印 `PASS`。

---

## 收尾

- **回滚**：`git revert` 对应提交即可；状态文件是纯文本，删掉只会让下一次异常状态重新通知一次。
- **提交前必查**：`git diff` 与提交信息里不得出现真机 IP/MAC/个人路径。
