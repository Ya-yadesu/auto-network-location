# LaunchAgent（事件驱动触发层）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给已经实测通过的探测器接上 launchd 触发层，使加入已知网络时自动切换位置、离开时只通知一次。

**Architecture:** 触发器保持「哑」的——一个 plist 用 `WatchPaths` + `StartInterval` 定期调用现有的 `wifi-loc-detect.sh --apply --notify`。所有判断留在探测器里，为此在探测器内加入一个状态文件，把「无法识别网络」的通知从「每次触发都发」改成「每次离家只发一次」。

**Tech Stack:** bash 3.2（macOS 自带）、launchd plist、`launchctl bootstrap`/`bootout`。无第三方依赖，无测试框架（验证靠临时配置 + 真实系统状态，沿用 `AGENTS.md` 第 6 节的做法）。

**Spec:** `docs/2026-09-16-launchagent-design.md`

## Global Constraints

- **纯 bash 3.2**：不得使用 `${var,,}`、`mapfile`、关联数组等 bash 4+ 特性。大小写归一化用 `tr`。
- **零依赖**：只用 macOS 自带命令。
- **语言**：面向用户的字符串、代码注释、README 用**英文**；`AGENTS.md` 与 `docs/` 用**中文**。
- **隐私（AGENTS.md 第 8 节）**：仓库内任何文件、代码注释、**提交信息**里都不得出现真机 IP/MAC。留白值只用 MAC 的 RFC 7042 段 `00:00:5e:00:53:xx` 与 IP 的 RFC 5737 段 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`。
- **通知文案**不得包含 SSID、特征设备 MAC 或其特征地址。
- **plist 路径必须是字面绝对路径**：launchd 不展开 `~`。
- **配置文件是被 `source` 的代码**，权限 600，只放自己写的。
- 本仓库无测试框架、无 CI；每个任务的验证都必须实际执行并贴出输出。

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `wifi-loc-detect.sh`（改） | 唯一的判定代码；新增状态文件读写与通知去重 | 1 |
| `com.yayadesu.auto-network-location.plist`（新） | 触发层定义：何时调用探测器 | 2 |
| `README.md`（改） | 面向使用者：自动运行、安装/卸载、已知限制 | 2, 6 |
| `AGENTS.md`（改） | 面向代理：launchd 陷阱、状态语义约定、验证配方 | 2, 6 |
| `~/.wifi-loc-control/state`（运行时） | 用户是否已被告知离家（600） | 1 |
| `~/.wifi-loc-control/agent.log`（运行时） | LaunchAgent 的 stdout/stderr（600） | 3 |

---

### Task 1: 探测器——状态文件与通知去重

**Files:**
- Modify: `wifi-loc-detect.sh:45-53`（新增 `STATE`）、`wifi-loc-detect.sh:187`（在 `notify()` 前新增两个函数）、`wifi-loc-detect.sh:253`、`:273`、`:278-283`
- Test: `/tmp/wlc-state-test.sh`（临时，不提交）

**Interfaces:**
- Consumes: 现有的 `log()`、`notify()`、以及 `APPLY`/`NOTIFY` 两个布尔量。
- Produces: 环境变量 `WLC_STATE`（状态文件路径覆盖）、函数 `read_state`（打印状态，可能为空）、`write_state <ok|away>`（写状态；失败只记日志）。路径默认 `$HOME/.wifi-loc-control/state`。

- [ ] **Step 1: 写验证脚本（此时必然失败）**

创建 `/tmp/wlc-state-test.sh`。它用临时配置 + **桩 `osascript`**（放进临时 `PATH`），这样能精确数出通知次数且不会真的弹通知：

```bash
#!/bin/bash
# V2 from the spec: the notification transition state machine.
set -u
cd $(git rev-parse --show-toplevel) || exit 1
T=$(mktemp -d); STUB="$T/bin"; mkdir -p "$STUB"
cat > "$STUB/osascript" <<'STUBEOF'
#!/bin/sh
echo called >> "$WLC_NOTIFY_LOG"
STUBEOF
chmod +x "$STUB/osascript"

# a live device for the "matched" case, an unroutable address for "away"
IP=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' \
     | grep -vE '^(224|239)\.| ff:ff:ff:ff:ff:ff' | head -1 | awk '{print $1}')
MAC=$(arp -n "$IP" | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$IP" "$MAC" > "$T/here.env"
printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="203.0.113.7"\nLOCATION_1_MAC="de:ad:be:ef:00:01"\n' > "$T/away.env"

export WLC_STATE="$T/state" WLC_NOTIFY_LOG="$T/notify.log"
: > "$WLC_NOTIFY_LOG"
pass=0; fail=0
check_eq()  { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS  $1";
              else fail=$((fail+1)); echo "FAIL  $1 (want [$2], got [$3])"; fi; }
check_has() { if grep -q "$3" "$2" 2>/dev/null; then pass=$((pass+1)); echo "PASS  $1";
              else fail=$((fail+1)); echo "FAIL  $1 (no /$3/ in $2)"; fi; }
count()     { wc -l < "$WLC_NOTIFY_LOG" | tr -d ' '; }
runs() { WLC_CONFIG="$T/$1.env" WLC_DEFAULT=Nowhere PATH="$STUB:$PATH" \
         ./wifi-loc-detect.sh --apply --notify > "$T/out.$2" 2>&1; }

runs away 1
check_eq  "1st away notifies"                 1 "$(count)"
check_eq  "1st away records state=away"       away "$(cat "$WLC_STATE" 2>/dev/null)"
runs away 2
check_eq  "2nd away does not notify"          1 "$(count)"
check_has "2nd away logs the suppression"     "$T/out.2" 'away already reported'

runs here 3
check_eq  "matching network resets state=ok"  ok "$(cat "$WLC_STATE" 2>/dev/null)"

# A manual run (no --notify) must not swallow the notice the agent would send.
: > "$WLC_NOTIFY_LOG"; rm -f "$WLC_STATE"
WLC_CONFIG="$T/away.env" WLC_DEFAULT=Nowhere PATH="$STUB:$PATH" \
  ./wifi-loc-detect.sh --apply > "$T/out.4" 2>&1
check_eq  "manual away does not notify"       0 "$(count)"
check_eq  "manual away leaves state unset"    "" "$(cat "$WLC_STATE" 2>/dev/null)"
runs away 5
check_eq  "agent notifies after a manual run" 1 "$(count)"

# A failed delivery must not be recorded as delivered, or the notice is lost.
BADSTUB="$T/badbin"; mkdir -p "$BADSTUB"
printf '#!/bin/sh\nexit 1\n' > "$BADSTUB/osascript"; chmod +x "$BADSTUB/osascript"
: > "$WLC_NOTIFY_LOG"; rm -f "$WLC_STATE"
WLC_CONFIG="$T/away.env" WLC_DEFAULT=Nowhere PATH="$BADSTUB:$PATH" \
  ./wifi-loc-detect.sh --apply --notify > "$T/out.6" 2>&1
check_eq  "failed delivery leaves state unset" "" "$(cat "$WLC_STATE" 2>/dev/null)"
check_has "failed delivery is logged"          "$T/out.6" 'notification failed'
runs away 7
check_eq  "a later successful run notifies"    1 "$(count)"

rm -rf "$T"
echo "=== $pass passed, $fail failed ==="
```

- [ ] **Step 2: 运行它，确认失败**

Run: `bash /tmp/wlc-state-test.sh`
Expected: FAIL。此时脚本还不认 `WLC_STATE`，状态文件从不生成，第 2 次离家会照旧通知，所以 `2nd away does not notify` 与 `state=away` 两条必挂。

- [ ] **Step 3: 加状态文件路径**

在 `wifi-loc-detect.sh` 的 `PROBE_PORT=33445` 那一行下面插入：

```bash
STATE="${WLC_STATE:-$HOME/.wifi-loc-control/state}"
```

- [ ] **Step 4: 加读写函数，并让 `notify()` 报告投递失败**

在 `notify()` 之前插入（注意注释是英文，符合约定 11）：

```bash
# The state file records whether the user has already been told that the
# current network cannot be identified, so a repeatedly triggered agent does
# not repeat the notice. Only the literal value "away" counts: a missing,
# empty or unknown value reads as "not told yet", so the failure direction is
# one notice too many rather than one silently swallowed.
# See docs/2026-09-16-launchagent-design.md.
read_state() {
  [[ -f "$STATE" ]] || return 0
  head -n 1 "$STATE" 2>/dev/null
}

write_state() {
  printf '%s\n' "$1" > "$STATE" 2>/dev/null || log "could not write state file: $STATE"
}
```

然后把现有的 `notify()` 整体替换为下面这版——唯一的区别是投递失败时**返回非零**，而不再把失败吞掉：

```bash
# Print the notice to the log and, with --notify, deliver it. Returning
# non-zero for a failed delivery lets the caller avoid recording a notice the
# user never received, so the next trigger tries again.
notify() {
  local message="$1"
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
```

- [ ] **Step 5: 在两条「不需要打扰用户」的路径上重置状态**

把 `wifi-loc-detect.sh:253` 起的 `if [[ -n "$matched_location" ]]; then` 改成（只多一行）：

```bash
if [[ -n "$matched_location" ]]; then
  write_state ok
  if [[ "$matched_location" == "$current" ]]; then
```

并在 `:273` 起的默认位置分支里同样加一行：

```bash
if [[ "$current" == "$DEFAULT_LOCATION" ]]; then
  write_state ok
  log "no characteristic device found; already in '$DEFAULT_LOCATION', nothing to do"
  exit 0
fi
```

`write_state ok` 放在 `matched_location` 判定之后、分支之前，是为了让「命中但 `scselect` 失败」那条 `exit 1` 也重置状态——命中了就说明不在「离家」状态。

- [ ] **Step 6: 改写离家分支**

把 `wifi-loc-detect.sh:278-283` 整段替换为：

```bash
# No characteristic device answered and the current location is not the
# default one: the user is away from every network we know about. Say so
# once per departure.
if [[ "$identity_mismatch" == 1 ]]; then
  away_message="A configured address answered with an unexpected MAC. Check the network settings."
else
  away_message="Cannot identify the current network; the network settings may not match this environment."
fi

if [[ "$NOTIFY" == 1 && "$(read_state)" == "away" ]]; then
  log "away already reported, not notifying again"
else
  if notify "$away_message"; then
    # Remember it only when the user was actually told: a manual run without
    # --notify must not swallow the notice the agent would send later, and a
    # failed delivery must be retried rather than recorded as delivered.
    [[ "$NOTIFY" == 1 ]] && write_state away
  fi
fi
exit 0
```

- [ ] **Step 7: 更新用法注释**

把 `wifi-loc-detect.sh:38-39` 的两行改成（保持总行数不变，`HELP_LAST_LINE=41` 不受影响）：

```bash
#   ./wifi-loc-detect.sh --apply --notify   # notify once when the network
#                                           # cannot be identified
```

- [ ] **Step 8: 语法检查并重跑状态机验证**

Run: `bash -n wifi-loc-detect.sh && bash /tmp/wlc-state-test.sh`
Expected: `bash -n` 静默通过；状态机 **11 passed, 0 failed**。注意离家的四次运行每次约 7 秒（4 次重试），整个脚本约 45 秒。

- [ ] **Step 9: 回归——确认旧行为没被破坏**

Run:

```sh
cd $(git rev-parse --show-toplevel)
T=$(mktemp -d); IP=203.0.113.7
S=$(mktemp -d)
IPL=$(arp -an | sed -n 's/^? (\([0-9.]*\)) at \([0-9a-fA-F:]*\) on [a-z0-9]* .*/\1 \2/p' | grep -vE '^(224|239)\.' | head -1 | awk '{print $1}')
MACL=$(arp -n "$IPL" | sed -n 's/.* at \([0-9a-fA-F:]*\) on .*/\1/p')
printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$IPL" "$MACL" > "$T/here.env"
printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="de:ad:be:ef:00:01"\n' "$IPL" > "$T/mismatch.env"
printf 'LOCATION_1_NAME="Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$IP" "$MACL" > "$T/away.env"
printf 'LOCATION_1_NAME="My Home"\nLOCATION_1_IP="%s"\nLOCATION_1_MAC="%s"\n' "$IPL" "$MACL" > "$T/other.env"
q() { printf '  %-34s ' "$1"; shift; out=$(WLC_STATE="$S/state" "$@" 2>&1); rc=$?; echo "rc=$rc"; }
q "matched, already there"   env WLC_CONFIG="$T/here.env"     ./wifi-loc-detect.sh
q "matched, elsewhere"       env WLC_CONFIG="$T/other.env"    ./wifi-loc-detect.sh
q "identity mismatch"        env WLC_CONFIG="$T/mismatch.env" ./wifi-loc-detect.sh
q "absent, not default"      env WLC_CONFIG="$T/away.env" WLC_DEFAULT=Nowhere ./wifi-loc-detect.sh
q "absent, already default"  env WLC_CONFIG="$T/away.env" WLC_DEFAULT=Home    ./wifi-loc-detect.sh
q "missing config"           env WLC_CONFIG="$T/nope.env"     ./wifi-loc-detect.sh
q "--help"                   ./wifi-loc-detect.sh --help
q "--print-mac without arg"  ./wifi-loc-detect.sh --print-mac
rm -rf "$T" "$S"
```

Expected: 依次 `rc=0`、`rc=0`、`rc=0`、`rc=0`、`rc=0`、`rc=3`、`rc=0`、`rc=2`；且 `matched, already there` 的输出含 `already in 'Home'`，`matched, elsewhere` 含 `would switch to 'My Home'`，`identity mismatch` 含 `identity mismatch`。

- [ ] **Step 10: 提交**

```bash
git add wifi-loc-detect.sh
git commit -m "feat: report an unidentifiable network once per departure

A LaunchAgent triggers on every network change, so the away notice needed
to become idempotent. A state file records whether the user has already
been told; only the literal value away counts, so a missing or unreadable
file means one notice too many rather than one swallowed.

The state moves to away only when the notice was actually delivered, so
neither a manual --apply run without --notify nor a failed osascript call
can suppress the agent's later notice."
```

---

### Task 2: plist 与装机文档

**Files:**
- Create: `com.yayadesu.auto-network-location.plist`
- Modify: `README.md`（Usage 一节、新增 Automatic operation 一节）、`AGENTS.md`（第 1 节文件清单、第 2 节新增约定）

**Interfaces:**
- Consumes: Task 1 的 `WLC_STATE` 行为（state 文件由探测器自己创建）。
- Produces: 一个可 `launchctl bootstrap` 的 plist，label `com.yayadesu.auto-network-location`。

- [ ] **Step 1: 写 plist**

创建 `com.yayadesu.auto-network-location.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.yayadesu.auto-network-location</string>

	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>__REPO__/wifi-loc-detect.sh</string>
		<string>--apply</string>
		<string>--notify</string>
	</array>

	<!-- Network state lives here, so a change means "decide again". -->
	<key>WatchPaths</key>
	<array>
		<string>/Library/Preferences/SystemConfiguration</string>
	</array>

	<!-- Safety net: WatchPaths events can be missed (see man launchd.plist). -->
	<key>StartInterval</key>
	<integer>300</integer>

	<key>RunAtLoad</key>
	<true/>

	<key>ThrottleInterval</key>
	<integer>60</integer>

	<key>ProcessType</key>
	<string>Background</string>

	<!-- So osascript notifications land in the GUI session. -->
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>

	<!-- A string, not an integer: launchd reads plist integers as decimal, so
	     the leading zero is the only way to express octal 077 here. -->
	<key>Umask</key>
	<string>077</string>

	<key>StandardOutPath</key>
	<string>__HOME__/.wifi-loc-control/agent.log</string>
	<key>StandardErrorPath</key>
	<string>__HOME__/.wifi-loc-control/agent.log</string>
</dict>
</plist>
```

- [ ] **Step 2: 校验 plist**

Run: `plutil -lint com.yayadesu.auto-network-location.plist && plutil -p com.yayadesu.auto-network-location.plist`
Expected: `OK`；`-p` 输出里 `Umask => "077"`（**带引号的字符串**，不是数字 77）。

- [ ] **Step 3: README 增加「自动运行」一节**

在 `## Usage` 之后、`## Known limitations` 之前插入（英文）：

````markdown
## Running automatically

A LaunchAgent can apply the decision whenever the network changes, so you do
not have to run the script yourself:

```sh
touch ~/.wifi-loc-control/agent.log && chmod 600 ~/.wifi-loc-control/agent.log
cp com.yayadesu.auto-network-location.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
launchctl print gui/$(id -u)/com.yayadesu.auto-network-location
```

The first line pre-creates the log with mode 600. launchd creates the
`StandardOutPath` file itself and the plist's `Umask` key does not apply to it,
so a pre-existing file is the only way to keep the log private.
```

To remove it again:

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

The job watches `/Library/Preferences/SystemConfiguration` and also runs every
300 seconds as a safety net. It switches only when a known network is entered;
when the current network cannot be identified it notifies **once per
departure**, not once per trigger.

Two prerequisites and two caveats:

- `~/.wifi-loc-control/` must already exist; the job logs to
  `~/.wifi-loc-control/agent.log` there.
- The plist holds the absolute path to this checkout. Move the repo and you
  must reinstall; edit the plist and you must `bootout` then `bootstrap`
  again, because launchd does not re-read it.
- `WatchPaths` can miss events (`man launchd.plist` says it is "highly
  discouraged"), and the 300-second fallback does not fire while the system
  is asleep. Expect the switch to happen on the next event or within five
  minutes of waking.
- The log file grows without bound and is safe to delete; the state file that
  tracks the away notice is separate.
````

- [ ] **Step 4: README 更新 `--notify` 的说明**

把 `## Usage` 代码块里 `--apply --notify` 那一行改成：

```text
./wifi-loc-detect.sh --apply --notify   also notify when the current network
                                        cannot be identified, once per departure
```

- [ ] **Step 5: AGENTS.md 第 1 节补文件清单**

把第 1 节的代码块改成：

```text
wifi-loc-detect.sh                    探测器（判定 + 可选切换，唯一代码文件，纯 bash 3.2 兼容）
com.yayadesu.auto-network-location.plist  LaunchAgent 定义（触发层，第 2 阶段）
README.md                             面向用户的设计与用法说明（英文）
docs/                                 设计与实施文档（中文）
```

- [ ] **Step 6: AGENTS.md 第 2 节新增约定 12**

在第 11 条之后追加：

```markdown
12. **通知去重靠状态文件，其含义是「用户是否已被告知离家」，不是「上次判定」。** 判定 `ok` 一律重置；只有**真的通知出去**了才写 `away`。这样手动跑（不带 `--notify`）不会污染状态，也就不会让 agent 漏掉本该发的通知。改动这段逻辑前先读 `docs/2026-09-16-launchagent-design.md` 第 3 节的状态转移表。
```

- [ ] **Step 7: 提交**

```bash
git add com.yayadesu.auto-network-location.plist README.md AGENTS.md
git commit -m "feat: add the LaunchAgent definition and installation docs

The job watches the SystemConfiguration directory, falls back to a 300
second interval, and invokes the detector with --apply --notify. Umask is a
string because plist integers are decimal, so 77 would have set octal 115
instead of 077."
```

---

### Task 3: 装载、进入方向端到端、自触发收敛、文件权限

**Files:**
- 仓库无改动（除非发现问题）；运行时产物：`~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist`、`~/.wifi-loc-control/agent.log`

**Interfaces:**
- Consumes: Task 1 的探测器、Task 2 的 plist。
- Produces: 一个已装载的 job；以及「进入方向由 agent 自动完成」的实测证据。

- [ ] **Step 1: 安装**

先预置日志文件（`Umask` 管不到 launchd 创建的 `StandardOutPath`，实测是 644；先建好 600 的文件，launchd 打开时不会改权限）：

```sh
touch ~/.wifi-loc-control/agent.log && chmod 600 ~/.wifi-loc-control/agent.log
cp __REPO__/com.yayadesu.auto-network-location.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
echo "bootstrap rc=$?"
```

Expected: `rc=0`。**不要给 `bootstrap` 加 `2>/dev/null`**：在受限沙箱里它失败的形式是 `Bootstrap failed: 5: Input/output error`，被吞掉后你会误以为 agent 已装载（2026-09-16 实际踩过，白等 88 秒）。若确实报 5，先 `bootout` 再 `bootstrap`；若仍报 5 且沙箱模式为 workspace-write，说明该操作需要提权。

- [ ] **Step 2: 确认已装载并已跑过一轮**

Run: `launchctl print gui/$(id -u)/com.yayadesu.auto-network-location | sed -n '1,25p'; echo ---; tail -12 ~/.wifi-loc-control/agent.log`
Expected: `print` 输出里有 `state = not running`（或 `running`）与 `program = /bin/bash`；日志里已有一条 `RunAtLoad` 引起的运行，末行是 `already in 'Home', nothing to do` 或 `switched to 'Home'`。

- [ ] **Step 3: 验证文件权限**

Run: `stat -f '%Sp %Su %N' ~/.wifi-loc-control/state ~/.wifi-loc-control/agent.log`
Expected: `state` 是 `-rw-------`；`agent.log` 若在 Step 1 预置过也应是 `-rw-------`。若日志是 `-rw-r--r--`，那不是 `Umask` 写错了（2026-09-16 实测字符串 `"077"` 下 `launchctl print` 显示 `umask = 77`、`state` 确实是 600），而是 launchd 创建的日志文件不受 `Umask` 约束——补做 Step 1 的预置即可。

- [ ] **Step 4: 端到端——不手动运行脚本，让 agent 自己切回来（重复 3 轮）**

先等 **65 秒**：`ThrottleInterval 60` 从**上一次启动**起算，而 Step 1 的 `bootstrap` 已因 `RunAtLoad` 跑过一轮。

**`ThrottleInterval` 是延后补跑，不是丢弃**（2026-09-16 实测）：落在窗口内的 `WatchPaths` 事件不会被丢掉，而是等窗口一过就补跑一次——实测事件被推迟约 48–50 秒后仍然执行了。所以**观察窗口必须长于 60 秒**、**轮与轮之间也要隔开 60 秒以上**，否则你会把「被推迟」误读成「没反应」。（第一版配方用 45 秒窗口 + 70 秒间隔，三轮里两轮因此误判。）

**开始前必须满足两个前提**，否则本轮作废：设备在邻居表里（`arp -n "$TARGET_IP"` 有 ` at `），以及**这期间没有人手动改 Wi-Fi 网络或关 Wi-Fi**。2026-09-16 曾因为忽略后者，把一次「设备真的不在场」的正确判断误读成探测缺陷。注意下面从本地配置推导目标地址——**不要把真机地址写进本文件**（AGENTS.md 第 8 节）。

```sh
TARGET_IP=$(sed -n 's/^LOCATION_1_IP="\(.*\)"/\1/p' ~/.wifi-loc-control/locations.env)
for round in 1 2 3; do
  echo "=== Round $round ==="
  [ "$(scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p')" = Home ] || { scselect Home >/dev/null; sleep 90; }
  echo "  设备: $(arp -n "$TARGET_IP" | grep -q ' at ' && echo 在场 || echo 不在场)"
  before=$(grep -c 'current location:' ~/.wifi-loc-control/agent.log)
  t0=$(date +%s); scselect Automatic >/dev/null; switched=no
  for i in $(seq 1 30); do
    sleep 3
    if [ "$(scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p')" = Home ]; then
      switched=yes; echo "  → 切回 Home，用时 ≈ $(( $(date +%s) - t0 ))s"; break; fi
  done
  [ "$switched" = no ] && echo "  → 90s 内未切回；结束时设备: $(arp -n "$TARGET_IP" | grep -q ' at ' && echo 在场 || echo 不在场)"
  grep -c 'current location:' ~/.wifi-loc-control/agent.log | sed 's/^/  累计轮数: /'
  [ "$round" != 3 ] && sleep 130
done
```

Expected: 每轮都在 90 秒内切回 `Home`（实测正常情况是 1–6 秒，被节流时约 50–60 秒），日志显示是 agent 触发的。**若某轮没切回**，先看那一刻设备是否在场：不在场说明本轮被中断（作废），在场则是真的没动作——记录时间与日志，作为第 7 节那个待查项的复发证据。**若某轮新增运行轮数 >=3，说明自触发没有收敛**，停下来记录日志，不要继续后面的任务。

- [ ] **Step 5: 确认幂等（不出现连续多轮）**

Run: 用 Step 4 里累计轮数的变化即可判断；再 `sleep 20; scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p'; grep -c 'switched to' ~/.wifi-loc-control/agent.log`
Expected: 位置仍是 `Home`；`switched to` 的累计行数**不再增长**。

- [ ] **Step 6: 确认 kickstart 可用**

Run: `launchctl kickstart gui/$(id -u)/com.yayadesu.auto-network-location; sleep 10; tail -3 ~/.wifi-loc-control/agent.log`
Expected: 日志多出一条 `already in 'Home', nothing to do`，位置不变。注意 `kickstart -k` 会给正在运行的实例发 SIGTERM（`launchctl print` 里会留下 `last terminating signal = Terminated: 15`），所以只用不带 `-k` 的形式。

- [ ] **Step 7: 确定日志是追加还是截断（V10）**

Run: `a=$(wc -l < ~/.wifi-loc-control/agent.log); launchctl kickstart gui/$(id -u)/com.yayadesu.auto-network-location; sleep 10; b=$(wc -l < ~/.wifi-loc-control/agent.log); echo "$a -> $b"`
Expected: `b > a`，确认**追加**（2026-09-16 实测如此：同样的那 5 行旧内容保留着）。把这个结论记进 Task 6 的文档更新；若相反（截断），同样如实记录。

- [ ] **Step 8: 记下回滚方式**

确认这两条命令已写进 Task 6 要更新的文档里（本步不执行）：

```sh
launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location
rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist
```

若后续任何一步出现意外切换，第一条立即停掉触发层。**在 Task 4/5 开始前不要卸载。**

---

### Task 4: 离家去重（需要使用者连一次手机热点）

**Files:** 仓库无改动（除非发现问题）

**Interfaces:**
- Consumes: Task 3 已装载的 job。
- Produces: 「只通知一次」的实测证据。

- [ ] **Step 1: 请使用者操作**

告诉使用者，并等他确认：**位置保持在 `Home`，把 Wi-Fi 连到手机热点。** 说明预期是「连上后没有网络」——`Home` 位置会把静态地址带到热点的网段上。

- [ ] **Step 2: 等 agent 自己通知一次**

换网事件同样可能撞上 `ThrottleInterval 60` 的窗口。先等最多 120 秒；若始终没有新一轮运行，说明事件被抑制了，改用 `kickstart` 主动触发，并在记录里注明「这一步是手动触发的，不是事件触发的」。

```sh
before=$(grep -c 'current location:' ~/.wifi-loc-control/agent.log)
for i in $(seq 1 12); do
  sleep 10
  [ "$(grep -c 'current location:' ~/.wifi-loc-control/agent.log)" -gt "$before" ] && break
done
if [ "$(grep -c 'current location:' ~/.wifi-loc-control/agent.log)" -le "$before" ]; then
  echo "事件未触发（可能被 ThrottleInterval 抑制），手动 kickstart"
  launchctl kickstart -k gui/$(id -u)/com.yayadesu.auto-network-location
  sleep 12
fi
tail -12 ~/.wifi-loc-control/agent.log
cat ~/.wifi-loc-control/state
scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p'
```

Expected: 日志里有 `no answer from ...` 与一次 `NOTIFY: Cannot identify...`；`state` 是 `away`；位置**仍是 `Home`**（不切换）。

- [ ] **Step 3: 再触发一次，确认不重复通知**

Run: `launchctl kickstart -k gui/$(id -u)/com.yayadesu.auto-network-location; sleep 12; tail -6 ~/.wifi-loc-control/agent.log`
Expected: 出现 `away already reported, not notifying again`，**没有**新的 `NOTIFY:` 行，通知不弹第二次。

- [ ] **Step 4: 请使用者连回家里的 Wi-Fi**

告诉使用者连回去，然后：

Run:

```sh
sleep 20
cat ~/.wifi-loc-control/state
tail -8 ~/.wifi-loc-control/agent.log
scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p'
```

Expected: `state` 变回 `ok`；日志显示识别出 `Home` 且 `already in 'Home', nothing to do`；位置是 `Home`。

---

### Task 5: 唤醒行为测量（需要一次真实睡眠）

**Files:** 仓库无改动

**Interfaces:**
- Consumes: Task 3 已装载的 job。
- Produces: 设计文档第 7 节那个未知数的答案。

- [ ] **Step 1: 记录基线**

Run: `date '+%Y-%m-%d %H:%M:%S'; wc -l < ~/.wifi-loc-control/agent.log; scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p'`
Expected: 记下当前时间、日志行数、位置（应为 `Home`）。

- [ ] **Step 2: 告知使用者并睡眠**

告诉使用者即将让机器睡眠若干分钟、期间不要合盖也要避免操作，然后：

Run: `pmset sleepnow`
Expected: 机器睡眠。**本步骤会中断当前会话的本地命令**，唤醒后由使用者告知，再继续。若 `pmset sleepnow` 被拒绝（需要权限），改由使用者直接合盖或从苹果菜单选「睡眠」。

- [ ] **Step 3: 唤醒后立刻检查**

由使用者唤醒，然后立刻运行（越接近唤醒越好）：

```sh
date '+%Y-%m-%d %H:%M:%S'
wc -l < ~/.wifi-loc-control/agent.log
tail -14 ~/.wifi-loc-control/agent.log
scselect | sed -n 's/^ \* .*(\(.*\))$/\1/p'
```

Expected: 三种可能，都要如实记录——

1. 唤醒后立刻多出 `current location:` 那行的运行 → `WatchPaths` 在重新关联时触发了，方案 1 成立。
2. 唤醒后数分钟内多出一轮 → 只有 `StartInterval` 兜底生效。
3. 唤醒后长时间没有新运行 → 两条路都没覆盖睡眠，需要退回常驻轮询方案。

- [ ] **Step 4: 判断是否需要改方案**

若结论是第 3 种（或第 2 种且使用者不接受最长 5 分钟静默期）：**停下来，不要自行实现常驻方案**。设计文档第 7 节已写明这是要「带数据退回方案 2」的决策点，先把证据交给使用者，由他决定是否开工。

---

### Task 6: 把实测结果写回文档

**Files:**
- Modify: `README.md`（`## Known limitations`、`## Roadmap`）、`AGENTS.md`（第 5 节新增 launchd 陷阱、第 6 节新增验证配方与已验证项）

**Interfaces:**
- Consumes: Task 3、4、5 的实测输出。
- Produces: 与代码一致、不靠推理的文档记录。

- [ ] **Step 1: AGENTS.md 第 5 节追加 launchd 陷阱**

在「受限沙箱内……」那条之后追加下面 5 条。其中第一条里那句实测结论，按 Task 5 的结果**从下面三句里选一句原样写入**（不要留 `<>`，日期用实际测量日）：

- Task 5 第 1 种结果 → `本机实测：唤醒后立刻多出一轮运行，重新关联触发了 WatchPaths。`
- Task 5 第 2 种结果 → `本机实测：唤醒后没有立刻触发，是 StartInterval 兜底在数分钟内补上的。`
- Task 5 第 3 种结果 → `本机实测：唤醒后长时间没有新运行，两条路都没覆盖睡眠。`

```markdown
- **launchd 的两个触发键都不可靠**：`man launchd.plist` 对 `WatchPaths` 写着「highly discouraged …… entirely possible for modifications to be missed」，对 `StartInterval` 写着睡眠期间错过的那次是**直接跳过**、不是延后补发。所以兜底不覆盖睡眠。本机实测唤醒后的行为是：<上面选定的那一句>。
- **plist 里的 `Umask` 必须写成字符串**（如 `"077"`）：属性列表的整数按十进制解释，写成整数 `77` 会得到八进制 115。实测写成字符串后 `agent.log` 与 `state` 都是 600。
- **`ThrottleInterval` 既不延后、也不排队**：它是「距上次启动不足 N 秒就不再启动」，默认 10、本项目设 60。所以测试时若不先等过这个窗口，`scselect` 引起的事件可能被整个丢掉，得出「agent 没反应」的错误结论。切换自己触发的那一轮被抑制是可接受的——幂等本来就保证不会再 `scselect` 一次。
- **改 plist 后必须 `bootout` 再 `bootstrap`**，launchd 不会自动重读；仓库移动后 plist 里的绝对路径失效，必须重装。
- **`launchctl` 的 `load`/`unload` 已被自己标为待替代**，用 `bootstrap`/`bootout`。
```

- [ ] **Step 2: AGENTS.md 第 6 节加入状态机验证配方**

在 `bash -n wifi-loc-detect.sh` 那段代码块之后追加一段说明与代码块，内容就是 Task 1 Step 1 里那份脚本（原样收入，供后续会话直接复用），并注明：它用临时 `WLC_STATE` 与**桩 `osascript`**，所以能精确数通知次数且不会真的弹通知。

- [ ] **Step 3: AGENTS.md 第 6 节更新已验证/尚未验证**

把「尚未验证」一节改写成实测结论。`--apply` 的进入方向那一项改为「已由 agent 自动完成，无需手动运行」，离家去重那一项改为「已实测只通知一次」，唤醒那一项按 Task 5 的结果三选一：

- 第 1 种 → 「唤醒后立即触发，已实测」；
- 第 2 种 → 「唤醒后由 StartInterval 在数分钟内补上，已实测」；
- 第 3 种 → 「唤醒不被覆盖，已实测；下一步是常驻轮询方案」，并在第 7 节路线图里把常驻方案列为第 2b 项。

- [ ] **Step 4: README 更新已知限制与路线图**

- `## Known limitations` 里删掉「自动触发尚不存在（no LaunchAgent yet）」的表述，改成实测到的唤醒行为与静默期上限。若 Task 5 是第 1 种结果，写成 "A network change is acted on as it happens; the 300-second interval is only a safety net."；若是第 2 或第 3 种，写成 "Expect the switch on the next event or within five minutes of waking, because neither WatchPaths nor StartInterval is reliable across sleep."
- `## Roadmap` 第 2 项标记完成（`*(done)*`）；若 Task 5 需要常驻方案，追加第 2b 项 "**Resident poller** — if wake proves unreliable"。

- [ ] **Step 5: 提交**

把 `wake` 那句换成上面选定的结论，再提交：

```bash
git add README.md AGENTS.md
git commit -m "docs: record the measured LaunchAgent behaviour

Replaces the reasoning-only claims about triggering with what the loaded
agent actually did: the entry direction runs unattended, the away notice
fires once per departure, and wake behaviour was measured rather than
assumed."
```

- [ ] **Step 6: 最终核对**

Run: `cd $(git rev-parse --show-toplevel) && git status --short --branch && git log --oneline -6 && bash -n wifi-loc-detect.sh && plutil -lint com.yayadesu.auto-network-location.plist`
Expected: 工作区干净；`bash -n` 静默；plist `OK`。

---

## 收尾

- **回滚**：`launchctl bootout gui/$(id -u)/com.yayadesu.auto-network-location` 立即停掉触发层；再 `rm ~/Library/LaunchAgents/com.yayadesu.auto-network-location.plist` 彻底卸载。删 `~/.wifi-loc-control/state` 只会让下次离家重新通知一次。
- **提交前必查**：`git diff` 与提交信息里不得出现真机 IP/MAC（Global Constraints）。
