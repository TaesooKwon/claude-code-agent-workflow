#!/usr/bin/env bash
# audit: unregistered-ok — 훅 이벤트에 걸지 않고 에이전트가 직접 호출하는 CLI(게이트 훅의 통과 마커를 찍는다).
# 다층 관통 변경의 '실물 왕복 검증' 완료 마커 — roundtrip-verify-reminder.sh 리마인더의 통과 조건.
# 사용: bash .claude/hooks/mark-roundtrip.sh          (왕복 E2E 를 실제로 돌린 직후)
#
# 기록 형식: "<YYYY-MM-DD> <스테이징 diff 의 sha256>"  (리마인더는 두 번째 필드만 대조)
# 왕복을 돌린 뒤 코드를 더 고치면 지문이 달라져 리마인더가 다시 뜬다 — 그때는 다시 돌리고 다시 찍는다.
#
# ⚠️ 이 마커는 "왕복을 돌렸다는 증거"가 아니라 **그 단계를 diff 단위로 상기시키는 장치**다.
#    돌리지 않고 찍는 우회는 막지 못한다(규율의 문제 — CLAUDE.md 🧪 검증 절이 정본).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
proj="${CLAUDE_PROJECT_DIR:-$(cd "$here/../.." && pwd)}"

_rlib="$here/lib/review-diff.sh"
[ -f "$_rlib" ] || { echo "review-diff.sh 없음: $_rlib" >&2; exit 1; }
. "$_rlib"

set +e
hash=$(review_diff_hash "$proj" "")
rc=$?
set -e

case "$rc" in
  1) echo "git 저장소가 아니거나 shasum 이 없습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;;
  2) echo "스테이징된 변경이 없습니다 — 먼저 git add 로 커밋 대상을 확정하세요." >&2; exit 1 ;;
esac

mkdir -p "$proj/.claude"
printf '%s %s\n' "$(date +%F)" "$hash" > "$proj/.claude/.last-roundtrip"
echo "왕복 검증 마커 기록: $(date +%F) ${hash:0:12}… ($proj/.claude/.last-roundtrip)"
