#!/usr/bin/env bash
# delegation-floor-reminder.sh 계약 테스트 — Agent·Workflow stdin JSON 을 태워 경고 유무·빠진 라벨·exit code 를 본다.
# 실행: bash ~/.claude/hooks/delegation-floor-reminder.test.sh
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/delegation-floor-reminder.sh"
[ -f "$HOOK" ] || { echo "훅 파일 없음: $HOOK"; exit 2; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/deleg-floor-test.XXXXXX") || exit 2
trap 'rm -rf "$TMPD"' EXIT

run=0
passed=0

FULL='①트러스트 경계 입력검증: jq 로만 파싱
②데이터손실 방지 에러처리: 실패 시 롤백
③보안: 시크릿 미출력
④접근성: N/A(UI 없음)
⑤명시요청 기능: 사양 전부'
NO34='①트러스트 경계 입력검증: jq 로만 파싱
②데이터손실 방지 에러처리: 실패 시 롤백
⑤명시요청 기능: 사양 전부
이 문장은 원문 유출 탐지용 표식이다 SECRET-SENTINEL-7731'

# $1=tool_name $2=tool_input JSON → PreToolUse stdin JSON
_payload() {
  jq -nc --arg t "$1" --argjson i "$2" '{session_id:"test",cwd:"/tmp",hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i}'
}

# $1=설명 $2=stdin 원문 $3=기대(silent|warn) $4=경고에 있어야 할 라벨(공백 구분, 선택) $5=없어야 할 문자열(| 구분, 선택)
_check() {
  local desc="$1" raw="$2" want="$3" must="${4:-}" mustnot="${5:-}" out rc ctx why=""
  run=$((run + 1))
  out=$(printf '%s' "$raw" | bash "$HOOK" 2>/dev/null)
  rc=$?
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [ "$rc" -ne 0 ]; then
    why="exit=$rc(항상 0 이어야 한다)"
  elif [ "$want" = silent ] && [ -n "$out" ]; then
    why="무출력 기대, 출력 있음"
  elif [ "$want" = warn ]; then
    if [ -z "$ctx" ]; then why="경고 기대, 없음"
    elif [ "${ctx#\[delegation-floor\] }" = "$ctx" ]; then why="태그 누락"
    elif [ "${#out}" -gt 10000 ]; then why="출력 10000자 초과"
    else
      local l
      for l in $must; do
        case "$ctx" in *"$l"*) ;; *) why="${why}라벨 없음:$l " ;; esac
      done
      local IFS='|'
      for l in $mustnot; do
        [ -n "$l" ] || continue
        case "$ctx" in *"$l"*) why="${why}있으면 안 됨:$l " ;; esac
      done
    fi
  fi
  if [ -z "$why" ]; then
    passed=$((passed + 1))
    printf 'ok    %s\n' "$desc"
  else
    printf 'FAIL  %s — %s\n' "$desc" "$why"
  fi
}

echo "== Agent =="
_check "ⓐ 5항목 다 있는 Agent → 무출력" \
  "$(_payload Agent "$(jq -nc --arg p "$FULL" '{prompt:$p,subagent_type:"general-purpose"}')")" silent
_check "ⓑ ③④ 빠진 Agent → ③④ 라벨만 경고" \
  "$(_payload Agent "$(jq -nc --arg p "$NO34" '{prompt:$p}')")" warn '③보안 ④접근성' '①|②|⑤'
_check "ⓒ N/A 로 적힌 항목은 충족(④접근성: N/A)" \
  "$(_payload Agent "$(jq -nc --arg p "$FULL" '{prompt:$p}')")" silent
# 한 항목만 빠진 프롬프트 = FULL 에서 그 줄만 지운 것
_only_missing() { printf '%s\n' "$FULL" | grep -v "^$1"; }
_check "① 하나만 빠진 Agent → ①만 경고" \
  "$(_payload Agent "$(jq -nc --arg p "$(_only_missing ①)" '{prompt:$p}')")" warn '①트러스트' '②|③|④|⑤'
_check "② 하나만 빠진 Agent → ②만 경고" \
  "$(_payload Agent "$(jq -nc --arg p "$(_only_missing ②)" '{prompt:$p}')")" warn '②데이터손실' '①|③|④|⑤'
_check "⑤ 하나만 빠진 Agent → ⑤만 경고" \
  "$(_payload Agent "$(jq -nc --arg p "$(_only_missing ⑤)" '{prompt:$p}')")" warn '⑤명시요청' '①|②|③|④'

echo "== Workflow =="
_check "ⓓ Workflow 인라인 script 누락 → 경고" \
  "$(_payload Workflow "$(jq -nc --arg s "export const meta={name:'x'}; agent('$NO34')" '{script:$s}')")" warn '③보안 ④접근성' '①|②|⑤'
printf '%s\n' "agent(\`$NO34\`)" > "$TMPD/wf-missing.js"
_check "ⓔ scriptPath 파일 누락 → 경고" \
  "$(_payload Workflow "$(jq -nc --arg s "$TMPD/wf-missing.js" '{scriptPath:$s}')")" warn '③보안 ④접근성' '①|②|⑤'
printf '%s\n' "agent(\`$FULL\`)" > "$TMPD/wf-full.js"
_check "scriptPath 파일 5항목 충족 → 무출력" \
  "$(_payload Workflow "$(jq -nc --arg s "$TMPD/wf-full.js" '{scriptPath:$s}')")" silent
_check "ⓕ 존재하지 않는 scriptPath → 무출력" \
  "$(_payload Workflow "$(jq -nc --arg s "$TMPD/nope.js" '{scriptPath:$s}')")" silent
_check "scriptPath 가 디렉터리 → 무출력" \
  "$(_payload Workflow "$(jq -nc --arg s "$TMPD" '{scriptPath:$s}')")" silent
{ printf '%s\n' "agent(\`$NO34\`)"; head -c 1100000 /dev/zero | tr '\0' 'a'; } > "$TMPD/wf-big.js"
_check "scriptPath 1MB 초과 → 무출력" \
  "$(_payload Workflow "$(jq -nc --arg s "$TMPD/wf-big.js" '{scriptPath:$s}')")" silent

echo "== 예외·입력 방어 =="
_check "ⓖ claude-code-guide → 무출력" \
  "$(_payload Agent "$(jq -nc --arg p "$NO34" '{prompt:$p,subagent_type:"claude-code-guide"}')")" silent
_check "statusline-setup → 무출력" \
  "$(_payload Agent "$(jq -nc --arg p "$NO34" '{prompt:$p,subagent_type:"statusline-setup"}')")" silent
_check "ⓗ 깨진 JSON → 무출력" 'not a json {' silent
_check "빈 stdin → 무출력" '' silent
_check "prompt·script·scriptPath 없음 → 무출력" "$(_payload Agent '{"description":"x"}')" silent
_check "prompt 가 문자열 아님 → 무출력" "$(_payload Agent '{"prompt":42}')" silent

echo "== 원문 비노출 =="
_check "ⓘ 출력에 프롬프트 원문 문장이 없음" \
  "$(_payload Agent "$(jq -nc --arg p "$NO34" '{prompt:$p}')")" warn '③보안' 'SECRET-SENTINEL-7731|원문 유출 탐지용|jq 로만 파싱|실패 시 롤백'

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -eq "$passed" ] || exit 1
