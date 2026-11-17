#!/usr/bin/env bash
# SessionStart — 월 1회 memory 위생 스윕 리마인더(memory-hygiene 스킬 실행 권장 주입).
# 배경: stale 진행표시 방치가 후속 세션 오독 유발(CLAUDE.md "완료 기록 = 회수 동반").
#       수동 스윕 3회 반복(0702·0710·0716) → 승격사다리 적용(경험→교훈→절차): 스킬+리마인더로 정례화.
# 동작: 그달 첫 발동만 컨텍스트 주입, 마커로 이후 침묵. memory 없는 프로젝트는 침묵. 차단 아님. fail-open.
set -u

proj="${CLAUDE_PROJECT_DIR:-}"
[ -n "$proj" ] || exit 0

slug=$(printf '%s' "$proj" | sed 's#/#-#g')
[ -f "$HOME/.claude/projects/$slug/memory/MEMORY.md" ] || exit 0

marker="$proj/.claude/.last-hygiene-reminder"
month=$(date +%Y-%m)
[ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$month" ] && exit 0
printf '%s' "$month" > "$marker" 2>/dev/null || true

command -v jq >/dev/null 2>&1 || exit 0
ctx="[메모리 위생] 이번 달(${month}) 첫 세션 — memory-hygiene 스킬로 memory 스윕 1회를 권장합니다(구식 진행표시 치환·완료 pending 은퇴·죽은 링크·인덱스 다이어트). 지금 작업을 막지 말고, 현재 요청 처리 후 한가한 시점에 사용자에게 제안하세요."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
