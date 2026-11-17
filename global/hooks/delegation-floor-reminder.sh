#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PreToolUse(Agent|Workflow) 소프트 리마인더 — "위임·워크플로 프롬프트엔 하한선 5항목을 라벨째 전사,
# 무의미하면 'N/A' 명시 — 침묵 누락 금지" 규칙의 기계화. 차단하지 않는다(그림자 기간 — 경고만).
#   - 판정 대상 텍스트: Agent = .tool_input.prompt / Workflow = .tool_input.script(인라인),
#     없으면 .tool_input.scriptPath 파일(존재·정규 파일·1MB 이하일 때만 읽는다).
#   - 판정: 항목마다 허용 목록 정규식 중 하나라도 있으면 충족(라벨이 있으면 값이 'N/A' 여도 충족).
#       ① 트러스트 경계|입력검증|입력 검증  ② 데이터손실|데이터 손실  ③ 보안  ④ 접근성  ⑤ 명시요청|명시 요청
#   - 발동: 하나라도 빠지면 additionalContext 로 빠진 라벨 목록 + 정본 경로를 주입.
#   - 미발동: 5항목 전부 있음 / 판정 텍스트 없음 / subagent_type 이 claude-code-guide·statusline-setup.
# 안전: jq 부재·JSON 파싱 실패·파일 읽기 실패 → 조용히 exit 0. 절대 deny/ask 하지 않음(fail-open).
#       프롬프트 원문·환경변수는 출력하지 않는다(빠진 라벨만).
# ponytail: 라벨 문자열 매칭이라 라벨 없이 풀어 쓴 문장(예: "권한 없는 사용자 차단")은 놓치고, 라벨이 다른 맥락에
#           우연히 나와도 충족으로 본다 / 업그레이드 경로 = 오탐·미탐 표본이 쌓이면 "①…:" 형태의 라벨+값 구조 판정
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

_field() {
  printf '%s' "$input" | jq -r "$1 | if type == \"string\" then . else empty end" 2>/dev/null
}

case "$(_field '.tool_input.subagent_type')" in
  claude-code-guide|statusline-setup) exit 0 ;;
esac

text="$(_field '.tool_input.prompt')$(_field '.tool_input.script')"
if [ -z "$text" ]; then
  path=$(_field '.tool_input.scriptPath')
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] || exit 0
  size=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || exit 0
  case "$size" in ''|*[!0-9]*) exit 0 ;; esac
  [ "$size" -le 1048576 ] || exit 0
  text=$(cat "$path" 2>/dev/null) || exit 0
fi
[ -n "$text" ] || exit 0

missing=""
_need() {
  grep -qE -- "$2" <<<"$text" 2>/dev/null || missing="${missing:+$missing, }$1"
}
_need '①트러스트 경계 입력검증'        '트러스트 경계|입력검증|입력 검증'
_need '②데이터손실 방지 에러처리'      '데이터손실|데이터 손실'
_need '③보안'                         '보안'
_need '④접근성'                       '접근성'
_need '⑤명시요청 기능'                 '명시요청|명시 요청'
[ -n "$missing" ] || exit 0

msg="[delegation-floor] 위임 프롬프트에 하한선 항목 라벨이 없다: ${missing}. 무의미하면 'N/A' 로 명시 — 정본 = ~/.claude/rules-rationale/delegation-prompt-transcribe-floor.md"
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null
exit 0
