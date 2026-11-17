#!/usr/bin/env bash
# write-overwrite-guard.sh 자체 테스트 — 샘플 stdin JSON 을 훅에 먹여 판정(deny/침묵)을 단언한다.
# 실행: bash __HOME__/.claude/hooks/write-overwrite-guard.test.sh
# 원칙: 양성(차단되어야 하는 것)·음성(통과해야 하는 것)·우회를 모두 단언하고, 마지막 줄에 총계를 낸다.
# 정리는 trap(teardown)으로 — 임시 트리는 남기지 않는다.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/write-overwrite-guard.sh"
[ -f "$HOOK" ] || { echo "FAIL: 훅 파일 없음: $HOOK"; echo "Tests run: 0, Passed: 0"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq 필요"; echo "Tests run: 0, Passed: 0"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wog-test.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

RUN=0; PASS=0

# 훅 실행 → 표준출력을 돌려준다. $1=file_path, $2=cwd, $3=tool_name, $4=ALLOW_WRITE_OVERWRITE 값("" = 미설정)
run_hook() {
  local json
  json=$(jq -n --arg fp "$1" --arg cwd "$2" --arg tn "$3" \
    '{tool_name:$tn, cwd:$cwd, tool_input:{file_path:$fp, content:"새 내용"}}')
  if [ -n "${4:-}" ]; then
    printf '%s' "$json" | ALLOW_WRITE_OVERWRITE="$4" bash "$HOOK"
  else
    printf '%s' "$json" | env -u ALLOW_WRITE_OVERWRITE bash "$HOOK"
  fi
}

# $1=설명 $2=기대(deny|silent) $3=실제출력
assert_decision() {
  local desc="$1" want="$2" out="$3" got
  RUN=$((RUN + 1))
  if [ -z "$out" ]; then
    got="silent"
  else
    got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo "malformed")
    local ev
    ev=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
    [ "$ev" = "PreToolUse" ] || got="bad-event($ev)"
  fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1)); echo "  PASS  $desc  [기대=$want]"
  else
    echo "  FAIL  $desc  기대=$want 실제=$got"
    printf '%s\n' "$out" | head -3
  fi
}

# --- 픽스처 ---------------------------------------------------------------
mkdir -p "$WORK/plain"
printf 'line1\nline2\n' > "$WORK/plain/existing.txt"   # 내용 있는 기존 파일
: > "$WORK/plain/empty-untracked.txt"                   # 빈 + 미추적
mkdir -p "$WORK/repo"
git -C "$WORK/repo" init -q >/dev/null 2>&1
: > "$WORK/repo/empty-tracked.txt"                      # 빈 + 추적(인덱스 등재)
git -C "$WORK/repo" add empty-tracked.txt >/dev/null 2>&1
: > "$WORK/repo/empty-not-added.txt"                    # 빈 + 같은 저장소지만 미추적

# --- 양성(차단) -----------------------------------------------------------
assert_decision "양성1: 내용 있는 기존 파일(절대경로)" deny \
  "$(run_hook "$WORK/plain/existing.txt" "$WORK" Write "")"

assert_decision "양성2: 상대경로 + cwd 해석" deny \
  "$(run_hook "plain/existing.txt" "$WORK" Write "")"

assert_decision "양성3: 빈 파일이지만 git 추적 중" deny \
  "$(run_hook "$WORK/repo/empty-tracked.txt" "$WORK/repo" Write "")"

# --- 음성(통과) -----------------------------------------------------------
assert_decision "음성1: 신규(부재) 파일" silent \
  "$(run_hook "$WORK/plain/brand-new.txt" "$WORK" Write "")"

assert_decision "음성2: 빈 파일 + 미추적" silent \
  "$(run_hook "$WORK/plain/empty-untracked.txt" "$WORK" Write "")"

assert_decision "음성3: 저장소 안이지만 인덱스에 없는 빈 파일" silent \
  "$(run_hook "$WORK/repo/empty-not-added.txt" "$WORK/repo" Write "")"

assert_decision "음성4: Write 가 아닌 도구(Edit)는 관여하지 않는다" silent \
  "$(run_hook "$WORK/plain/existing.txt" "$WORK" Edit "")"

assert_decision "음성5: 디렉터리 경로" silent \
  "$(run_hook "$WORK/plain" "$WORK" Write "")"

# --- 우회 -----------------------------------------------------------------
assert_decision "우회1: ALLOW_WRITE_OVERWRITE=1 이면 기존 파일도 통과" silent \
  "$(run_hook "$WORK/plain/existing.txt" "$WORK" Write "1")"

assert_decision "우회2: ALLOW_WRITE_OVERWRITE=0 은 우회가 아니다" deny \
  "$(run_hook "$WORK/plain/existing.txt" "$WORK" Write "0")"

# --- 이유 문구 계약 --------------------------------------------------------
out=$(run_hook "$WORK/plain/existing.txt" "$WORK" Write "")
RUN=$((RUN + 1))
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)
if printf '%s' "$reason" | grep -q 'ALLOW_WRITE_OVERWRITE=1' \
   && printf '%s' "$reason" | grep -q 'Edit' \
   && printf '%s' "$reason" | grep -Fq "$WORK/plain/existing.txt"; then
  PASS=$((PASS + 1)); echo "  PASS  계약1: 이유에 우회 방법·Edit 권유·대상 경로가 모두 들어 있다"
else
  echo "  FAIL  계약1: 이유 문구 누락 → $reason"
fi

# --- 안전(fail-open) -------------------------------------------------------
RUN=$((RUN + 1))
out=$(printf '%s' '{"tool_name":"Write","tool_input":{}}' | env -u ALLOW_WRITE_OVERWRITE bash "$HOOK"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS + 1)); echo "  PASS  안전1: file_path 없는 입력은 조용히 통과(exit 0)"
else
  echo "  FAIL  안전1: rc=$rc out=$out"
fi

RUN=$((RUN + 1))
out=$(printf '%s' 'not-json-at-all' | env -u ALLOW_WRITE_OVERWRITE bash "$HOOK"); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  PASS=$((PASS + 1)); echo "  PASS  안전2: JSON 아닌 입력도 조용히 통과(exit 0)"
else
  echo "  FAIL  안전2: rc=$rc out=$out"
fi

echo "Tests run: $RUN, Passed: $PASS"
[ "$RUN" -eq "$PASS" ]
