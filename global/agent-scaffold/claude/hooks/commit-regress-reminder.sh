#!/usr/bin/env bash
# audit: unregistered-ok — 사용자 결정(2026-09-18)으로 존치하되 settings 에 등록하지 않는다(발동하지 않음).
# (미등록 옵트인 — 위 줄) 등록하면 PreToolUse(Bash) — "커밋 전 회귀" 소프트 리마인더(당일 1회 차단 후 통과).
# CLAUDE.md "커밋 전 regress" 규칙의 반자동 승격: 하드 차단 대신, 회귀 마커가 오늘자가
# 아니면 커밋을 1회 deny(리마인더)하고 같은 날 재시도는 통과시킨다(회귀 불필요 판단은
# 에이전트·사용자 몫 — 문서·설정만 바꾼 커밋 등).
# 마커: regress 러너(run_regression.sh)가 전체 스위트 PASS 시 .claude/.last-regress에 날짜 기록.
# 안전: jq 부재·비커밋·마커 오늘자·이미 리마인드 → 조용히 exit 0(fail-open).
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git commit 계열만 관여(공용 라이브러리 — 다른 가드와 동일 계약).
# 넛지형이라 따옴표 스트립본으로 판정한다 — 안내문에 'git commit' 을 인용한 턴이 그날의 1회를
# 태워버리면 정작 진짜 커밋 때 침묵한다(2026-08-05 감사). 셸 래퍼는 lib 가 원문을 돌려준다.
_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" commit || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"
today=$(date +%F)

last=$(cat "$proj/.claude/.last-regress" 2>/dev/null || true)
[ "$last" = "$today" ] && exit 0

reminded="$proj/.claude/.regress-reminded"
[ "$(cat "$reminded" 2>/dev/null)" = "$today" ] && exit 0
# 마커를 남기지 못하면 '당일 1회'가 성립하지 않아 매 커밋이 영구 차단된다(소프트 리마인더가 하드
# 블로커로 변질). 디렉터리를 먼저 만들고, 그래도 기록 실패면 deny 하지 말고 통과시킨다(fail-open).
mkdir -p "$proj/.claude" 2>/dev/null || true
printf '%s' "$today" > "$reminded" 2>/dev/null || exit 0
[ "$(cat "$reminded" 2>/dev/null)" = "$today" ] || exit 0

reason="[회귀 리마인더] 오늘 전체 회귀 스위트 실행 기록이 없습니다(마커 .claude/.last-regress: ${last:-없음}). CLAUDE.md 규칙: 커밋 전 regress 스킬로 누적 E2E 회귀 1회. 회귀를 돌린 뒤 커밋하거나, 이번 커밋이 회귀 불필요(문서·설정·스크립트만 등)라고 판단되면 같은 커밋을 그대로 재시도하세요 — 오늘은 다시 차단하지 않습니다."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
