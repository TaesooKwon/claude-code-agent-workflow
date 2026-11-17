#!/usr/bin/env bash
# jsharness-record.sh 자체검사.
# 실행: bash .claude/hooks/jsharness-record.test.sh
#
# 샌드박스 git 레포를 mktemp 로 만들어 실물 훅에 PostToolUse·PostToolUseFailure stdin JSON 을 먹인다. 이 레포의
# .claude/.last-jsharness 는 건드리지 않는다(CLAUDE_PROJECT_DIR 을 샌드박스로 덮어쓴다). 정리는 trap EXIT.
set -u

# HOOKS_DIR_OVERRIDE = 사본 훅 디렉터리 검증용(기본 = 라이브 경로).
REC="${HOOKS_DIR_OVERRIDE:-{{ROOT}}/.claude/hooks}/jsharness-record.sh"
[ -f "$REC" ] || { echo "선행조건 실패: $REC 없음"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/jsharness-rec-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

RUN_CMD='node .claude/jsharness/run.js'
GREEN=$'== js/develop/x.spec.js\n  PASS a\n\nTests run: 12, Failures: 0, Specs: 3\n'
RED=$'== js/develop/x.spec.js\n  FAIL a  << detail\n\nTests run: 12, Failures: 1, Specs: 3\n'

run=0; pass=0
assert_eq() { # 설명 기대 실제
  run=$((run + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s\n        기대: [%s]\n        실제: [%s]\n' "$1" "$2" "$3"
  fi
}

mkrepo() {
  r="$SANDBOX/repo$1"
  mkdir -p "$r/{{MODULE_CORE}}/src/main/java" "$r/.claude"
  git -C "$r" init -q >/dev/null 2>&1
  printf '%s' "$r"
}

post_json() { jq -n --arg c "$1" --arg d "$2" --arg o "$3" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:$o,stderr:""}}'; }

# record_raw stdin원문 repo → "<기록 중 epoch 를 뺀 나머지 | NONE>|<exit>"
record_raw() {
  local rc
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$2" bash "$REC" >/dev/null 2>&1; rc=$?
  if [ -f "$2/.claude/.last-jsharness" ]; then
    printf '%s|%s' "$(sed -E 's/^[0-9]+ //' "$2/.claude/.last-jsharness")" "$rc"
  else
    printf 'NONE|%s' "$rc"
  fi
}
record() { record_raw "$(post_json "$1" "$2" "$3")" "$2"; }

echo "── 기록기(PostToolUse) ──────────────────────────────"
r=$(mkrepo 1)
assert_eq "R1 양성: 초록 출력 → 'N F' 기록" "12 0|0" "$(record "$RUN_CMD" "$r" "$GREEN")"
assert_eq "R1-형식: '<epoch> <N> <F>' 정확히 한 줄" "1|1" "$(grep -Ec '^[0-9]+ 12 0$' "$r/.claude/.last-jsharness")|$(wc -l < "$r/.claude/.last-jsharness" | tr -d ' ')"
assert_eq "R1-임시파일: 잔존 없음" "0" "$(ls "$r/.claude" | grep -c 'tmp')"

r=$(mkrepo 2)
assert_eq "R2 양성: Failures>0 → 'N F' 그대로 기록" "12 1|0" "$(record "$RUN_CMD" "$r" "$RED")"

r=$(mkrepo 3)
assert_eq "R3 양성: 두 번 실행(빨강→초록) → 마지막으로 교체" "12 0|0" \
  "$(record "$RUN_CMD" "$r" "$RED" >/dev/null; record "$RUN_CMD" "$r" "$GREEN")"

r=$(mkrepo 4)
assert_eq "R4 양성: 단언 0건 → '0 0' 기록(판정은 게이트)" "0 0|0" \
  "$(record "$RUN_CMD" "$r" $'Tests run: 0, Failures: 0, Specs: 0\nFAIL — 단언 0건\n')"

r=$(mkrepo 5)
assert_eq "R5 음성: Tests run 줄 없음 → 기록 없음" "NONE|0" "$(record "$RUN_CMD" "$r" $'Error: Cannot find module\n')"

r=$(mkrepo 6)
assert_eq "R6 음성: 다른 node 명령(같은 출력) → 기록 없음" "NONE|0" "$(record 'node scripts/other.js' "$r" "$GREEN")"

r=$(mkrepo 7)
assert_eq "R7 음성: run.js 를 cat 만 함(node 없음) → 기록 없음" "NONE|0" "$(record 'cat .claude/jsharness/run.js' "$r" "$GREEN")"

r=$(mkrepo 8)
assert_eq "R8 음성: tool_response 가 문자열 → 기록 없음" "NONE|0" \
  "$(record_raw "$(jq -n --arg c "$RUN_CMD" --arg d "$r" --arg o "$GREEN" '{cwd:$d,tool_input:{command:$c},tool_response:$o}')" "$r")"

r=$(mkrepo 9)
assert_eq "R9 음성: 깨진 JSON → 기록 없음·exit 0" "NONE|0" "$(record_raw 'not a json {' "$r")"

r="$SANDBOX/notrepo"; mkdir -p "$r/.claude"; git -C "$r" init -q >/dev/null 2>&1
assert_eq "R10 음성: 이 레포가 아님({{MODULE_CORE}} 없음) → 기록 없음" "NONE|0" "$(record "$RUN_CMD" "$r" "$GREEN")"

r=$(mkrepo 11)
assert_eq "R11 양성: 경로 접두 node·cwd 가 .claude(node jsharness/run.js) → 기록" "12 0|0" \
  "$(record '/usr/local/bin/node jsharness/run.js' "$r" "$GREEN")"

r=$(mkrepo 12)
out=$(record "$RUN_CMD" "$r" $'secret-SENTINEL-4417\nTests run: 3, Failures: 0, Specs: 1\n')
assert_eq "R12 원문 비기록: 기록에 출력 원문 없음" "0" "$(grep -c 'SENTINEL' "$r/.claude/.last-jsharness")"

fail_json() { jq -n --arg c "$1" --arg d "$2" --arg e "$3" \
  '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",cwd:$d,tool_input:{command:$c},error:$e}'; }
frecord() { record_raw "$(fail_json "$1" "$2" "$3")" "$2"; }

echo "── 기록기(PostToolUseFailure — exit≠0) ─────────────"
r=$(mkrepo 13)
assert_eq "R13 양성: 초록 기록 뒤 실패 이벤트(요약 줄 F>0) → 빨간불로 교체" "12 2|0" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; frecord "$RUN_CMD" "$r" $'Exit code 1\n== x\n\nTests run: 12, Failures: 2, Specs: 3')"

r=$(mkrepo 14)
assert_eq "R14 양성: 실패 이벤트·요약 줄 없음(절단) → '0 1'" "0 1|0" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; frecord "$RUN_CMD" "$r" $'Exit code 1\n... [truncated] ...')"

r=$(mkrepo 15)
assert_eq "R15 양성: 실패 이벤트·단언 0건(exit 2) → '0 0' 그대로" "0 0|0" \
  "$(frecord "$RUN_CMD" "$r" $'Exit code 2\nTests run: 0, Failures: 0, Specs: 0\nFAIL — 단언 0건')"

r=$(mkrepo 16)
assert_eq "R16 양성: 실패 이벤트·N>0 F=0(뒤 명령 실패) → F=1" "12 1|0" \
  "$(frecord "$RUN_CMD" "$r" $'Exit code 1\nTests run: 12, Failures: 0, Specs: 3')"

r=$(mkrepo 17)
assert_eq "R17 음성: 다른 명령의 실패 이벤트 → 초록 기록 유지" "12 0|0" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; frecord 'node scripts/other.js' "$r" $'Exit code 1')"

r=$(mkrepo 18)
assert_eq "R18 음성: 이벤트명 부정확(PostToolUseFailureX)·tool_response 없음 → 초록 유지" "12 0|0" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; record_raw "$(fail_json "$RUN_CMD" "$r" 'Exit code 1' | jq '.hook_event_name="PostToolUseFailureX"')" "$r")"

r=$(mkrepo 19)
assert_eq "R19 데이터손실: 기록·삭제 모두 불가(.claude 쓰기 불가) → exit 2 알림" "12 0|2" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; chmod a-w "$r/.claude"; o=$(frecord "$RUN_CMD" "$r" $'Exit code 1'); chmod u+w "$r/.claude"; printf '%s' "$o")"

# 쓰기만 실패하고 삭제는 되는 경로 — PATH 앞에 늘 실패하는 mv 스텁을 둬 원자 교체만 막는다(.claude 는 쓰기 가능).
MVFAIL="$SANDBOX/mvfail-bin"; mkdir -p "$MVFAIL"
printf '#!/bin/sh\nexit 1\n' > "$MVFAIL/mv"; chmod +x "$MVFAIL/mv"
r=$(mkrepo 20)
assert_eq "R20 데이터손실: 기록 쓰기만 실패(mv 실패) → 기존 초록 기록 삭제·exit 0" "NONE|0" \
  "$(record "$RUN_CMD" "$r" "$GREEN" >/dev/null; PATH="$MVFAIL:$PATH" record "$RUN_CMD" "$r" "$RED")"
assert_eq "R20-임시파일: 쓰기 실패 뒤 임시파일 잔존 없음" "0" "$(ls -A "$r/.claude" | grep -c 'tmp')"

echo "── 혼합 출력(러너 + Surefire) ───────────────────────"
MVN_GREEN=$'[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.1 s - in kr.X\nTests run: 5, Failures: 0, Errors: 0, Skipped: 0\n[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n'
MIX_CMD='node .claude/jsharness/run.js; mvn test -pl {{MODULE_CORE}}'
r=$(mkrepo 21)
assert_eq "R21 혼합: JS 빨간불 뒤 mvn 초록 줄 → 러너 줄(12 2) 기록" "12 2|0" \
  "$(record "$MIX_CMD" "$r" $'== x\n  FAIL a\nTests run: 12, Failures: 2, Specs: 3\n'"$MVN_GREEN")"

r=$(mkrepo 22)
assert_eq "R22 혼합 음성: 러너 요약 줄 없이 Surefire 줄만 → 기록 없음" "NONE|0" \
  "$(record "$MIX_CMD" "$r" $'Error: Cannot find module\n'"$MVN_GREEN")"

r=$(mkrepo 23)
assert_eq "R23 혼합(실패 이벤트): 러너 빨간불 뒤 Surefire 초록 줄 → 12 2" "12 2|0" \
  "$(frecord "$MIX_CMD" "$r" $'Exit code 1\nTests run: 12, Failures: 2, Specs: 3\n'"$MVN_GREEN")"

r=$(mkrepo 24)
assert_eq "R24 혼합 순서 반대: Surefire 빨간 줄 뒤 러너 초록 → 12 0" "12 0|0" \
  "$(record "$MIX_CMD" "$r" $'[INFO] Tests run: 5, Failures: 3, Errors: 0, Skipped: 0\n'"$GREEN")"

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ] || exit 1
