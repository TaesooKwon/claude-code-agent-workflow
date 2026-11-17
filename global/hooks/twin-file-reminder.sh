#!/usr/bin/env bash
# PostToolUse(Write|Edit) 전역 훅 — 편집 파일이 <모듈>/src/main/<상대경로> 형태이고 같은 레포의
# 다른 최상위 모듈에 동일 상대경로 파일이 있으면(예: CMS-Admin↔CMS-Front) "복제본 존재" 를 1줄 상기.
#
# 왜 있나: 전역 CLAUDE.md 편집안전:10(대형·복제 파일) — "같은 파일이 두 모듈에 복제돼 있으면
# 한쪽만 고치지 마라, 편집 전 양쪽을 실측하고 한쪽만 고칠 거면 그 판단을 명시하라". 실측(도입 레포
# git status 2026-09-17): application.properties·application-dev.properties·
# application-prod.properties.sample 이 CMS-Admin·CMS-Front 양쪽 src/main/resources 에 동일
# 상대경로로 존재하고 값(계약)은 다르다 — 한쪽만 고치면 조용히 드리프트한다. 컴파일·테스트는 각 모듈이
# 독립 빌드 산출물이라 이 드리프트를 잡지 못한다.
#
# 판정(하드코딩 금지 — CMS-Admin/CMS-Front 를 이름으로 고정하지 않는다): 레포 루트 바로 아래의
# "*/src/main" 디렉토리를 전부 찾아 모듈 후보로 삼는다(Maven 멀티모듈 관례). 다른 레포에 이 구조가
# 없으면 자연히 미발동 — 스택 무관 전역 배치 안전.
#   ①편집 파일 절대경로가 <repo-root>/<모듈(1단)>/src/main/<sub> 형태일 때만 대상
#   ②다른 모듈(같은 <repo-root>/*/src/main)에 .../src/main/<sub> 가 파일로 실재
# 경고형(차단 없음, additionalContext 만) — 계약이 다를 수 있어 자동 동기화·차단은 하지 않는다.
#
# 안전(fail-open, 트러스트 경계 = stdin JSON 만 신뢰): jq/git 부재 · file_path 없음/파일로 미존재 ·
# git 레포 아님 · <repo-root>/<모듈>/src/main/<sub> 형태 아님(중첩 모듈 포함) · 다른 모듈에 트윈 부재
# → 조용히 exit 0. 모든 경로 변수는 인용해서 쓰고 파라미터 확장만으로 상대경로를 자른다(정규식 아님).
set -u
shopt -s nullglob 2>/dev/null || true

command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null || true)
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$fp" ] || exit 0
case "$fp" in /*) ;; *) fp="$PWD/$fp" ;; esac
[ -f "$fp" ] || exit 0

dir=$(dirname "$fp")
top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
[ -n "$top" ] || exit 0
# show-toplevel/show-prefix 를 함께 쓴다 — dirname/fp 문자열을 top 과 직접 접두 비교하면
# 심볼릭 링크 경로(예: macOS /tmp → /private/tmp)에서 fp 는 미해석·top 은 해석된 값이라
# 접두 불일치로 항상 미발동하는 결함이 난다(2026-09-17 테스트로 실측). git 자신의 계산이라
# 링크 해석 방식이 항상 일치한다.
prefix=$(git -C "$dir" rev-parse --show-prefix 2>/dev/null)
rel="${prefix}$(basename "$fp")"

case "$rel" in
  */src/main/*) ;;
  *) exit 0 ;;
esac
module="${rel%%/src/main/*}"
sub="${rel#*/src/main/}"
[ -n "$module" ] && [ -n "$sub" ] || exit 0
case "$module" in */*) exit 0 ;; esac  # 최상위(1단) 모듈만 대상 — 중첩 src/main 은 판정 밖

hits=""
for main_dir in "$top"/*/src/main; do
  [ -d "$main_dir" ] || continue
  other_dir="${main_dir%/src/main}"
  other_module="${other_dir#"$top"/}"
  [ "$other_module" = "$module" ] && continue
  cand="$other_dir/src/main/$sub"
  [ -f "$cand" ] || continue
  p="${cand#"$top"/}"
  if [ -z "$hits" ]; then hits="$p"; else hits="$hits, $p"; fi
done

[ -n "$hits" ] || exit 0

ctx="복제본 존재: ${hits} — 함께 실측(계약은 다를 수 있다)"
jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
