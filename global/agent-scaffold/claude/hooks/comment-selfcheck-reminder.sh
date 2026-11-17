#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PreToolUse(Bash) — 커밋 직전 '주석 셀프체크' 후보 목록을 상기시키는 **경고형** 리마인더(차단하지 않는다).
#
# 왜 있나: 프로젝트 CLAUDE.md 커밋 게이트 ③ 의 주석 셀프체크가 <b>절차로만</b> 적혀 있어,
#   에이전트가 건너뛰면 아무 층도 검사하지 않았다. 실제로 같은 문장의 개수를 3연속 틀린 적이 있고
#   (2026-09-08), 그중 마지막은 grep 을 치고도 틀렸다 — 자기 diff 의 주석을 모집단에 넣고 셌기 때문이다.
#
# ⚠️ 2026-09-07 에 기각된 lint 안과 <b>다르다</b>. 그때는 참/거짓 '판정'을 자동화하려다 재현율 1/4·
#   정밀도 0/3 으로 기각됐다. 이 훅은 판정하지 않는다 — 사람이 근거를 세어야 할 문장을 <b>목록으로 뽑기만</b>
#   한다(판정은 에이전트가). 그래서 차단도 하지 않는다.
#
# 통과 조건 없음(마커 없음): 후보가 0건이면 조용히 지나가고, 있으면 건수만 알린다.
# 안전(fail-open): jq/스크립트 부재 · 비커밋 명령 · 남의 레포 · 스테이징 없음 · 후보 0건 → 조용히 exit 0.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" commit || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# 이 프로젝트의 커밋만 본다(세션 스코프 훅이라 다른 레포 커밋에도 발동한다 — 형제 훅과 같은 계약).
_target_dir="$cwd"
_gc=$(printf '%s' "$cmd" | sed -n 's/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -1)
_cd=$(printf '%s' "$cmd" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}\([^&;|]\{1,\}\).*/\1/p' | head -1)
[ -n "$_cd" ] && _target_dir=$(printf '%s' "$_cd" | sed 's/[[:space:]]*$//' | sed "s|^~|$HOME|")
[ -n "$_gc" ] && _target_dir=$(printf '%s' "$_gc" | sed "s|^~|$HOME|")
if [ -d "$_target_dir" ]; then
  _t_top=$(git -C "$_target_dir" rev-parse --show-toplevel 2>/dev/null)
  _p_top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$_t_top" ] && [ -n "$_p_top" ] && [ "$_t_top" != "$_p_top" ] && exit 0
fi

command -v git >/dev/null 2>&1 || exit 0
[ -n "$(git -C "$proj" diff --cached --name-only 2>/dev/null)" ] || exit 0

script="$proj/.claude/scripts/comment-selfcheck.sh"
[ -x "$script" ] || exit 0

out=$(cd "$proj" && bash "$script" --cached 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0

# 카테고리별 건수만 뽑는다(전문은 에이전트가 직접 명령으로 본다 — 훅이 컨텍스트를 먹지 않게).
counts=$(printf '%s\n' "$out" | sed -n 's/^--- \(.*\) ---$/\1/p' | tr '\n' ' ')
[ -n "$counts" ] || exit 0

ctx="[주석 셀프체크 리마인더] 이번 스테이징 diff 가 추가한 주석 중 <b>근거를 세어야 할 후보</b>가 있습니다 — ${counts}. 판정은 훅이 하지 않습니다(2026-09-07 에 판정형 lint 는 기각됐습니다). 목록을 직접 보고 각 줄을 판정하세요: \`bash .claude/scripts/comment-selfcheck.sh --cached\`. 판정 기준 = ⓐ개수·배타 단언은 <b>소스 형태로 앵커해</b> grep -c 로 세거나(자기 diff 의 주석이 모집단에 섞이지 않게) 불변식·역할 서술로 낮춘다 ⓑ다른 파일·계층의 동작을 단언했다면 그 파일에서 근거 명령 1개를 치고, 못 치면 역할로 서술한다 ⓒ복제해 온 주석은 '왜 이 자리에 필요한가'가 자리마다 다르므로 원본 문장을 그대로 옮기지 않는다. 애초에 <b>개수를 쓰지 않는 것이 기본값</b>입니다. 확인을 마쳤거나 후보가 전부 무해하다고 판단했다면 그대로 진행하되, 그 판단을 사용자에게 알리세요."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
