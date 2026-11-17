#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PostToolUse(Bash) — CLAUDE.md "pull 후 스모크" 규칙의 리마인더 자동화.
# git pull 로 팀 커밋이 유입되면(Already up to date 가 아니면) additionalContext 로
# "작업 착수 전 harness 스모크 1회" 리마인더를 컨텍스트에 주입한다(차단 아님·정보 주입만).
# 계기: 팀 커밋發 빌드 깨짐을 뒤늦게 발견하는 사고 방지 — 규칙이 산문뿐이라 자동화.
# 안전: jq 부재·pull 아님·변경 없음 → 조용히 exit 0. fail-open.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git pull 계열만. 탐지 정규식은 공용 라이브러리로 일원화(붙임형 -C/path·공백-값형 --git-dir /x 포함).
# 정보 주입형이라 따옴표 스트립본으로 판정 — 문서·감사 스크립트 안의 'git pull' 문자열에 반응하던 오탐 차단.
_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" pull || exit 0

# tool_response 가 객체가 아니면(형식 변화·누락) 판정 불가 → 침묵한다.
#   이전에는 이 경우 'Already up to date' 판정 자체가 무력화돼 무조건 주입됐다.
[ "$(printf '%s' "$input" | jq -r '.tool_response | type' 2>/dev/null)" = "object" ] || exit 0

# 실행 결과에서 실제 유입 여부 판정: Already up to date 면 리마인더 불필요.
out=$(printf '%s' "$input" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")' 2>/dev/null)
printf '%s' "$out" | grep -qi 'Already up[ -]to[ -]date' && exit 0

# 최종 판정은 문자열이 아니라 '상태'로 — HEAD 가 실제로 움직였을 때만 주입한다.
#   충돌로 실패한 pull·pull 하지 않는 명령은 HEAD 가 그대로라 여기서 걸러진다.
command -v git >/dev/null 2>&1 || exit 0
head_now=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || exit 0
[ -n "$head_now" ] || exit 0
hmark="${CLAUDE_PROJECT_DIR:-$cwd}/.claude/.last-pull-head"
[ "$(cat "$hmark" 2>/dev/null)" = "$head_now" ] && exit 0
mkdir -p "$(dirname "$hmark")" 2>/dev/null || true
printf '%s' "$head_now" > "$hmark" 2>/dev/null || true

ctx="[pull 스모크 리마인더] git pull 로 팀 커밋이 유입됐습니다. CLAUDE.md 규칙에 따라 작업 착수 전 harness 스킬로 스모크 1회를 돌려 팀발 빌드 깨짐을 조기 확인하세요. 팀 문서 변경이 섞여 있으면 규약 대조·흡수 검토도 함께."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
