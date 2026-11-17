#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PreToolUse(Skill|Workflow) 전역 훅 — 검증·리뷰 단계에 들어서면 effort 사다리를 세션당 1회 상기한다(경고형, 차단 없음).
#   진입 신호: 스킬 harness · regress-* · playwright-verify · commit-review / 워크플로 commit-review·delta-review(scriptPath·name·script 본문).
#   effort 전환은 사용자 명령(/effort)이라 에이전트는 권고만 한다. 근거 = ~/.claude/rules-rationale/effort-model-operation.md
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)
hit=""
case "$tool" in
  Skill)
    sk=$(printf '%s' "$input" | jq -r '.tool_input.skill // empty' 2>/dev/null)
    case "$sk" in harness|regress-*|playwright-verify|commit-review) hit="$sk" ;; esac ;;
  Workflow)
    wf=$(printf '%s' "$input" | jq -r '[.tool_input.scriptPath, .tool_input.name, .tool_input.script] | map(. // "") | join(" ")' 2>/dev/null)
    case "$wf" in *commit-review*|*delta-review*) hit="리뷰 워크플로" ;; esac ;;
esac
[ -n "$hit" ] || exit 0
marker="${TMPDIR:-/tmp}/effort-stage-${sid}"
[ -e "$marker" ] && exit 0
: > "$marker" 2>/dev/null || true
msg="[effort 단계] ${hit} — 검증·리뷰 단계 진입. 지금 작업이 기존 코드 버그 수리·경합·인가·보안 검증이면 사용자에게 \`/effort high\` 를 한 줄로 권고하라(같은 세션에서 바꿔도 캐시 유지, 끝나면 원래 단계로). 같은 버그 2회째 실패 = high, 그래도 실패하면 멈춤 보고 선택지에 xhigh/Fable. 근거 = ~/.claude/rules-rationale/effort-model-operation.md"
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
