#!/usr/bin/env bash
# PreToolUse(Bash) — 다층 관통 변경에 '실물 왕복 검증'을 상기시키는 **경고형** 리마인더(차단하지 않는다).
#
# ⚠️ 이식 사본 — 부트스트랩 재추출 필수: 아래 FILE_REGEX·CONTENT_REGEX 와 안내 문구의 왕복 계약을
#    **대상 레포 실측으로 채워야** 발동한다(플레이스홀더가 남으면 정규식이 아무것도 매치하지 않아
#    조용히 무기능이 된다 — 설치 후 훅 디렉터리에 미치환 플레이스홀더(중괄호 2개 형태)가 남지 않았는지 확인.
#    ※ 그 확인 명령은 여기 적지 않는다 — 명령을 주석에 적으면 자기 자신이 검출돼 0건 판정이 영원히 안 난다.
#
# 왜 있나(원 레포 2026-09-07 실측): 게시판 에디터 본문 이미지 한 건에서 결함이 5단계로 연쇄했다 —
#   ①컨텍스트패스 누락(전 화면 404) ②Jsoup 이 상대 src 제거 ③FO 필터가 관리자 경로를 복사해 매치 0건
#   ④상대링크 개방이 만든 XSS 표면 ⑤clean/normalize 순서 역전(src 소실).
#   ⑤는 코드 리뷰 3라운드가 전부 놓쳤고 **왕복 E2E 1회가 잡았다**. 층 사이 접합부는
#   목·lint·컴파일·단위테스트가 원리적으로 못 본다(CLAUDE.md 🧪 검증 절 · 전역 [[walking-skeleton-before-layers]]).
#
# 대상(좁게): 그 사고가 실제로 난 파일군 + diff 내용에 왕복 계약 심볼이 나타날 때만.
#   넓은 경로 패턴(js/develop/** 전체 등)은 넣지 않는다 — 오탐이 잦으면 우회가 습관이 되어 리마인더가 죽는다.
#
# 통과: `.claude/.last-roundtrip` 지문 == 지금 커밋될 diff 지문 (= `bash .claude/hooks/mark-roundtrip.sh`)
# 안전(fail-open): jq/shasum 부재 · 비커밋 명령 · 남의 레포 · 스테이징 없음 · 대상 무관 diff → 조용히 exit 0.
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

_rlib="$(dirname "$0")/lib/review-diff.sh"
[ -f "$_rlib" ] && . "$_rlib" || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# 이 프로젝트의 커밋만 본다(세션 스코프 훅이라 다른 레포 커밋에도 발동한다 — 대상 판정 = 아래 show-toplevel 비교라 linked worktree 안 커밋은 넛지 대상 밖).
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

# ── 대상 판정 ───────────────────────────────────────────────────────────────
# 축1: 사고가 난 파일 자체(업로드 URL 계약·HTML 정제·요청 필터)
FILE_REGEX='{{ROUNDTRIP_FILE_REGEX}}'   # 예: '(HtmlSanitizer|EditorHtmlHelper|FileUrlUtil|HTMLTagFilter|FileServiceImpl)\.java$'
# 축2: diff 내용에 왕복 계약 심볼이 등장(컨트롤러·JS·템플릿은 파일명이 아니라 내용으로 좁힌다)
CONTENT_REGEX='{{ROUNDTRIP_CONTENT_REGEX}}'   # 예: 'sanitizeForSave|insertEditorImage|createEditorImage|/upload/|allowedDirNms'

staged_files=$(git -C "$proj" diff --cached --name-only 2>/dev/null)
[ -n "$staged_files" ] || exit 0

hit=""
printf '%s\n' "$staged_files" | grep -Eq "$FILE_REGEX" && hit="파일"
if [ -z "$hit" ]; then
  # 추가·삭제된 라인만 본다(문맥 라인이 우연히 걸려 오탐 나는 것을 막는다).
  git -C "$proj" diff --cached -U0 2>/dev/null \
    | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' \
    | grep -Eq "$CONTENT_REGEX" && hit="내용"
fi
[ -n "$hit" ] || exit 0
# ────────────────────────────────────────────────────────────────────────────

cur=$(review_diff_hash "$proj" "$cmd") || exit 0
[ -n "$cur" ] || exit 0

marker="$proj/.claude/.last-roundtrip"
recorded=$(awk '{print $2}' "$marker" 2>/dev/null | head -1)
[ "$recorded" = "$cur" ] && exit 0

if [ -n "$recorded" ]; then
  detail="왕복 마커의 지문(${recorded:0:12}…)이 지금 커밋될 diff(${cur:0:12}…)와 다릅니다 — 왕복 검증 이후 코드가 바뀌었습니다."
else
  detail="이 diff 에 대한 왕복 검증 기록이 없습니다."
fi

ctx="[왕복 검증 리마인더 — ${hit} 축 적중] ${detail} 이 변경은 여러 층(브라우저 JS → 서블릿 필터 → 컨트롤러 → HTML 정제 → DB → 템플릿 → 정적 서빙)을 관통합니다. 층 사이 접합부는 목·lint·컴파일·단위테스트가 원리적으로 보지 못하므로, 커밋 전에 **실물 왕복 1회**({{ROUNDTRIP_CONTRACT}})를 돌리세요. 스위트 = {{ROUNDTRIP_SUITE}} (앱은 {{RUN_SKILL}} 로 {{ADMIN_PORT}}/{{FRONT_PORT}} 재기동 — Java·JS 변경이면 재빌드 필수). 돌린 뒤 \`bash .claude/hooks/mark-roundtrip.sh\` 로 마커를 찍으면 이 안내가 사라집니다. 왕복이 불필요한 변경(주석·테스트만 등)이라고 판단했다면 같은 명령으로 마커만 찍고 진행하되, 그 판단을 사용자에게 알리세요."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
