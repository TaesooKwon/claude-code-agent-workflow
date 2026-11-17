#!/bin/bash
# hook-obs.sh 회귀 테스트 — 명세 v2 「테스트」 ①~⑭.
# 사용: bash hook-obs.test.sh
#   HOOKOBS_W=<래퍼 경로>  다른 래퍼(변이본)로 실행
#   HOOKOBS_FLIP=<단언명>  그 단언의 기대를 일부러 틀리게(반증 — 빨간불이 나야 정상)
# 실패 시 exit 1, 마지막 줄 = "Tests run: N, Failures: F"

W=${HOOKOBS_W:-$HOME/.claude/hooks/hook-obs.sh}
FLIP=${HOOKOBS_FLIP:-}
RUN=0; FAIL=0

T=$(mktemp -d "${TMPDIR:-/tmp}/hookobs-test.XXXXXX") || { echo "mktemp 실패"; exit 1; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
TH="$T/home"; mkdir -p "$TH/.claude/hooks"
cp "$W" "$TH/.claude/hooks/hook-obs.sh"
WH="$TH/.claude/hooks/hook-obs.sh"
LOGD="$TH/.claude/hook-events"
F="$T/fx"; mkdir -p "$F"

# 단언: name expected actual
check() {
  local name=$1 exp=$2 act=$3
  RUN=$((RUN+1))
  [ "$FLIP" = "$name" ] && exp="__flipped__${exp}"
  if [ "$exp" = "$act" ]; then echo "  PASS $name"
  else echo "  FAIL $name — 기대 [$exp] 실제 [$act]"; FAIL=$((FAIL+1)); fi
}

fx() { printf '#!/bin/bash\n%s\n' "$2" >"$F/$1"; chmod +x "$F/$1"; }

# 래퍼로 실행: run_w <stdin파일> <명령...> → $T/w.out $T/w.err $WRC, 직접 실행 → $T/d.out $T/d.err $DRC
run_both() {
  local in=$1; shift
  HOME="$TH" CLAUDE_CONFIG_DIR= CLAUDE_PROJECT_DIR=/x/myproj bash "$WH" "$@" <"$in" >"$T/w.out" 2>"$T/w.err"; WRC=$?
  "$@" <"$in" >"$T/d.out" 2>"$T/d.err"; DRC=$?
}
same() { cmp -s "$1" "$2" && echo same || echo diff; }
lastlog() { cat "$LOGD"/*.jsonl 2>/dev/null | tail -1; }
field() { lastlog | jq -r ".$1 | if . == null then \"null\" else tostring end" 2>/dev/null; }

IN="$T/in.json"
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo SECRET_CMD"},"cwd":"/y/cwdproj"}' >"$IN"
: >"$T/empty"

echo "① exit code 보존"
for c in 0 1 2; do
  fx "rc$c.sh" "exit $c"
  run_both "$IN" "$F/rc$c.sh"
  check "rc_$c" "$c" "$WRC"
done
check "rc_2_action" "block" "$(field action)"
run_both "$IN" "$F/rc1.sh"
check "rc_1_action" "error" "$(field action)"

echo "② stdout 바이트 동일"
fx out_nonl.sh "printf 'no-newline'"
fx out_multi.sh "printf 'a\nb\n\nc\n'"
fx out_nul.sh "printf 'x\\000y'"
for h in out_nonl out_multi out_nul; do
  run_both "$IN" "$F/$h.sh"
  check "stdout_$h" same "$(same "$T/w.out" "$T/d.out")"
done
check "stdout_nul_bytes" 3 "$(wc -c <"$T/w.out" | tr -d ' ')"

echo "③ stderr 동일"
fx err.sh "printf 'e1\ne2' >&2; printf 'o'"
run_both "$IN" "$F/err.sh"
check "stderr_same" same "$(same "$T/w.err" "$T/d.err")"
check "stderr_stdout_same" same "$(same "$T/w.out" "$T/d.out")"

echo "④ stdin 전달"
fx echo_in.sh "cat"
run_both "$IN" "$F/echo_in.sh"
check "stdin_passthru" same "$(same "$T/w.out" "$IN")"

echo "⑤ jq deny → block + [태그]"
fx deny.sh "jq -n '{hookSpecificOutput:{hookEventName:\"PreToolUse\",permissionDecision:\"deny\",permissionDecisionReason:\"[태그] 이유\"}}'"
run_both "$IN" "$F/deny.sh"
check "deny_action" block "$(field action)"
check "deny_reason" "[태그]" "$(field reason)"
check "deny_event" PreToolUse "$(field event)"
check "deny_tool" Bash "$(field tool)"
check "deny_project" myproj "$(field project)"
check "deny_hook" deny.sh "$(field hook)"
check "deny_exit_code" 0 "$(field exit_code)"
check "deny_dur_numeric" yes "$(lastlog | jq -r '(.duration_ms|type=="number") and (.out_bytes > 0) | if . then "yes" else "no" end')"
check "deny_ts_iso" yes "$(field ts | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' && echo yes || echo no)"

echo "⑥ python json.dump 형식 deny → block"
fx deny_py.sh "printf '%s' '{\"hookSpecificOutput\": {\"hookEventName\": \"PreToolUse\", \"permissionDecision\": \"deny\", \"permissionDecisionReason\": \"no tag here\"}}'"
run_both "$IN" "$F/deny_py.sh"
check "deny_py_action" block "$(field action)"
check "deny_py_reason_null" null "$(field reason)"

echo "⑦ Stop decision:block → block"
printf '{"hook_event_name":"Stop","cwd":"/y/cwdproj"}' >"$T/stop.json"
fx stop_block.sh "printf '%s' '{\"decision\": \"block\",\"reason\":\"[기록누락] 5줄 없음\"}'"
run_both "$T/stop.json" "$F/stop_block.sh"
check "stop_action" block "$(field action)"
check "stop_reason" "[기록누락]" "$(field reason)"
check "stop_tool_null" null "$(field tool)"

echo "⑧ additionalContext → warn"
fx ctx.sh "jq -n '{hookSpecificOutput:{hookEventName:\"PostToolUse\",additionalContext:\"[세팅 배치] 확인\"}}'"
run_both "$IN" "$F/ctx.sh"
check "ctx_action" warn "$(field action)"
check "ctx_reason" "[세팅 배치]" "$(field reason)"
fx ask.sh "jq -n '{hookSpecificOutput:{hookEventName:\"PreToolUse\",permissionDecision:\"ask\"}}'"
run_both "$IN" "$F/ask.sh"
check "ask_action" ask "$(field action)"

echo "⑨ 무출력 → allow"
run_both "$IN" "$F/rc0.sh"
check "silent_action" allow "$(field action)"
check "silent_bytes" "0/0" "$(field out_bytes)/$(field err_bytes)"

echo "①-b 비JSON stdin·빈 stdin → 폴백 판정"
printf 'not json {{{' >"$T/bad.json"
run_both "$T/bad.json" "$F/out_multi.sh"
check "badin_action" warn "$(field action)"
check "badin_project_env" myproj "$(field project)"
run_both "$T/empty" "$F/rc0.sh"
check "emptyin_action" allow "$(field action)"
check "emptyin_event_null" null "$(field event)"

echo "⑩ 로그 디렉터리 쓰기 불가 → rc·출력 동일"
n_before=$(cat "$LOGD"/*.jsonl | wc -l | tr -d ' ')
chmod 400 "$LOGD"/*.jsonl; chmod 500 "$LOGD"
fx w10.sh "printf 'keep'; printf 'kerr' >&2; exit 1"
run_both "$IN" "$F/w10.sh"
chmod 700 "$LOGD"; chmod 600 "$LOGD"/*.jsonl
check "ro_rc" "$DRC" "$WRC"
check "ro_stdout" same "$(same "$T/w.out" "$T/d.out")"
check "ro_stderr" same "$(same "$T/w.err" "$T/d.err")"
check "ro_no_line" "$n_before" "$(cat "$LOGD"/*.jsonl | wc -l | tr -d ' ')"

echo "⑪ 등록 형태 sh -c — 래퍼 정상/없음/문법오류"
fx reg.sh "cat >/dev/null; printf 'R-out'; printf 'R-err' >&2; exit 2"
REG='W=$HOME/.claude/hooks/hook-obs.sh; bash -n "$W" 2>/dev/null && exec bash "$W" '"$F/reg.sh"' || exec '"$F/reg.sh"
"$F/reg.sh" <"$IN" >"$T/d.out" 2>"$T/d.err"; DRC=$?
for mode in ok missing broken; do
  case $mode in
    ok) cp "$W" "$WH";;
    missing) rm -f "$WH";;
    broken) printf 'if then fi (\n' >"$WH";;
  esac
  HOME="$TH" sh -c "$REG" <"$IN" >"$T/w.out" 2>"$T/w.err"; WRC=$?
  check "reg_${mode}_rc" "$DRC" "$WRC"
  check "reg_${mode}_out" same "$(same "$T/w.out" "$T/d.out")"
  check "reg_${mode}_err" same "$(same "$T/w.err" "$T/d.err")"
done
cp "$W" "$WH"
# 프로젝트 등록 형태(bash <경로>) — 마지막 인자가 훅 이름
REGP='W=$HOME/.claude/hooks/hook-obs.sh; bash -n "$W" 2>/dev/null && exec bash "$W" bash "$CLAUDE_PROJECT_DIR/reg.sh" || exec bash "$CLAUDE_PROJECT_DIR/reg.sh"'
HOME="$TH" CLAUDE_PROJECT_DIR="$F" sh -c "$REGP" <"$IN" >"$T/w.out" 2>"$T/w.err"; WRC=$?
check "regp_rc" 2 "$WRC"
check "regp_hook" reg.sh "$(field hook)"
check "regp_project" fx "$(field project)"

echo "⑫ TERM 전달"
fx sleeper.sh "sleep 30; echo done"
HOME="$TH" bash "$WH" "$F/sleeper.sh" </dev/null >/dev/null 2>&1 &
wpid=$!
kids=
for _ in 1 2 3 4 5 6 7 8 9 10; do kids=$(pgrep -P "$wpid"); [ -n "$kids" ] && break; sleep 0.1; done
sleep 0.2
gkids=; for k in $kids; do gkids="$gkids $(pgrep -P "$k")"; done
kill -TERM "$wpid"
sleep 1
alive=0
for p in $kids $gkids; do kill -0 "$p" 2>/dev/null && alive=$((alive+1)); done
wait "$wpid"; trc=$?
check "term_child_found" yes "$([ -n "$kids" ] && echo yes || echo no)"
check "term_children_gone" 0 "$alive"
check "term_rc" 143 "$trc"
check "term_action" killed "$(field action)"
check "term_hook" sleeper.sh "$(field hook)"
for p in $kids $gkids; do kill -9 "$p" 2>/dev/null; done

echo "⑬ 비밀·경로 비기록"
fx leak.sh "cat >/dev/null; echo 'password=hunter2 /Users/someone/secret.txt'; echo 'token=abc123' >&2"
run_both "$IN" "$F/leak.sh"
check "leak_reason_null" null "$(field reason)"
check "leak_no_secret" 0 "$(cat "$LOGD"/*.jsonl | grep -cE 'hunter2|abc123|secret\.txt|SECRET_CMD')"
fx longtag.sh "echo '[$(printf 'x%.0s' $(seq 1 41))] too long'"
run_both "$IN" "$F/longtag.sh"
check "tag_over40_null" null "$(field reason)"

echo "⑮ session 필드(입력 .session_id 문자열만)"
printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"sess-abc-123","cwd":"/y/cwdproj"}' >"$T/sess.json"
run_both "$T/sess.json" "$F/rc0.sh"
check "session_present" "sess-abc-123" "$(field session)"
check "session_key_order" '["ts","hook","event","tool","project","seat","action","exit_code","duration_ms","out_bytes","err_bytes","reason","session"]' "$(lastlog | jq -c 'keys_unsorted')"
run_both "$IN" "$F/rc0.sh"
check "session_absent_null" null "$(field session)"
check "session_absent_key_exists" true "$(lastlog | jq -c 'has("session")')"
printf '{"hook_event_name":"PreToolUse","session_id":42}' >"$T/sessnum.json"
run_both "$T/sessnum.json" "$F/rc0.sh"
check "session_number_null" null "$(field session)"
run_both "$T/bad.json" "$F/rc0.sh"
check "session_badin_null" null "$(field session)"

echo "⑭ bash -n"
check "syntax_ok" 0 "$(bash -n "$W" >/dev/null 2>&1; echo $?)"

echo "⓪ 인자 0개 → exit 0"
HOME="$TH" bash "$WH" </dev/null; check "noargs_rc" 0 "$?"

echo "Tests run: $RUN, Failures: $FAIL"
[ "$FAIL" = 0 ]
