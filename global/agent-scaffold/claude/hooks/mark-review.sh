#!/usr/bin/env bash
# audit: unregistered-ok — 훅 이벤트에 걸지 않고 에이전트가 직접 호출하는 CLI(게이트 훅의 통과 마커를 찍는다).
# 커밋 전 코드리뷰 완료 마커 기록 — code-review-marker-reminder.sh 게이트의 통과 조건.
# 근거 처분: project:검증:20 (리뷰 결과가 **완결**일 때만 마커를 찍는다 — reviewComplete 를 눈으로 읽고
#            찍는 규약 문장은 잊혔고, 미완결 결과로 마커가 찍힌 채 커밋이 통과한 적이 있다).
#
# 사용(둘 중 하나는 반드시 있어야 한다 — 인자 없는 호출은 더 이상 마커를 찍지 않는다. 언제 어느 쪽인지 = --help):
#   bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON 파일>
#   bash .claude/hooks/mark-review.sh --skip-reason "<리뷰를 생략·대체한 사유>"
#   위 둘에 --amend|--all|-a 를 덧붙이면 워킹트리까지 커밋하는 경우의 지문으로 기록한다 — 현 인덱스를 임시 인덱스로
#   복사해 `git add -u`(= commit -a 가 커밋 직전에 하는 일)를 한 뒤 그 `diff --cached` 지문을 찍는다. 층 A(git pre-commit)가
#   그 커밋에서 보는 인덱스와 같은 내용이라 지문이 일치한다. 실제 인덱스는 건드리지 않는다.
# ponytail: --amend 도 -a 와 같은 지문(워킹트리 추적 변경 포함)으로 찍는다 — `-a` 없는 amend 에 워킹트리 미스테이징 변경이
#   남아 있으면 층 A 지문과 어긋나 막힌다(안전 측) / 업그레이드 = --amend 를 별도 플래그(인덱스 그대로)로 분리.
#
# --result 통과 조건(**허용 목록** — 하나라도 어긋나면 찍지 않는다):
#   ① .reviewComplete 가 JSON true (문자열 "true" 는 불가)
#   ② .lensStatus 가 배열이고 비어 있지 않으며 **모든 원소의 .status 가 "ok"**
#      (엔진이 내는 status 값의 정본 = commit-review.js — 여기선 "ok" 하나만 허용한다.
#       금지 목록으로 적으면 엔진에 새 상태값이 생겼을 때 조용히 통과한다 → 허용 목록으로 쓴다)
#   ③ .unverified 가 배열이고 비어 있음 (미판정은 기각이 아니다)
#   ④ .uncoveredFiles 가 배열이고 비어 있음 (status ok 인 어느 관점도 읽지 않은 스테이징 파일 — 필드 의미의 정본 = commit-review.js 반환부.
#      필드가 없으면 판정 불가로 거부한다 — 허용 목록 원칙)
#
# 우회 = --skip-reason 하나뿐(환경변수 우회 없음). 소형 A 델타형 리뷰처럼 워크플로 JSON 이 없는 리뷰,
#   사용자가 리뷰 생략을 지시한 경우가 여기에 해당한다. 사유는 `.claude/.review-marker.log` 에 누적되고
#   호출자에게 "사용자에게 알리라"는 문구를 출력한다(CLAUDE.md: 생략 판단은 침묵 통과 금지).
#
# 기록 형식: "<YYYY-MM-DD> <리뷰 대상 diff 의 sha256>"  (게이트는 두 번째 필드만 대조)
#   지문 산출은 lib/review-diff.sh 가 단일 정본 — 검문(code-review-marker-reminder.sh)과 같은 값을 쓴다.
#   리뷰 후 코드를 더 고치면 지문이 달라져 게이트가 다시 막는다 — 그때는 다시 리뷰하고 다시 찍는다.
#
# 한계: 결과 JSON 이 **정말 이 diff 를 리뷰한 것인지**는 검사하지 않는다(파일을 지어내면 통과한다).
#   이 스크립트가 막는 것은 "미완결 결과를 완결로 읽는 사고"이지 의도적 우회가 아니다 — 규약이 정본.
# ponytail: 결과 JSON 과 지문의 결속(리뷰 대상 diff 해시를 결과에 실어 대조)은 하지 않는다 /
#           업그레이드 경로 = commit-review.js 가 반환에 대상 diff 지문을 실으면 여기서 대조 추가.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
proj="${CLAUDE_PROJECT_DIR:-$(cd "$here/../.." && pwd)}"

_rlib="$here/lib/review-diff.sh"
[ -f "$_rlib" ] || { echo "review-diff.sh 없음: $_rlib" >&2; exit 1; }
. "$_rlib"

usage() {
  cat >&2 <<'USAGE'
사용법:
  bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON 파일> [--amend|--all|-a]
  bash .claude/hooks/mark-review.sh --skip-reason "<사유>" [--amend|--all|-a]

  --result      commit-review.js(또는 델타 리뷰)가 돌려준 결과를 그대로 저장한 JSON 파일.
                reviewComplete=true · lensStatus 전부 ok · unverified·uncoveredFiles 빈 배열일 때만 마커를 찍는다.
  --skip-reason 리뷰 결과 파일 없이 찍는 유일한 경로. 사유는 .claude/.review-marker.log 에 남고
                그 사실을 사용자에게 알려야 한다.
  --amend|--all|-a  commit -a·--amend 처럼 워킹트리 추적 변경까지 커밋할 때 그 지문으로 찍는다.

언제:
  --result      = 리뷰 워크플로(commit-review.js)·델타 재리뷰를 돌려 결과 JSON 이 있을 때(A티어 기본).
  --skip-reason = 결과 JSON 이 없는 리뷰(B티어 인라인 셀프리뷰·소형 델타 인라인)·사용자가 리뷰 생략을 지시·문서/설정만 변경일 때.
USAGE
}

all_mode=0
result_file=""
skip_reason=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage 2>&1; exit 0 ;;
    --amend|--all|-a)
      all_mode=1 ;;
    --result)
      shift
      [ $# -gt 0 ] || { echo "--result 뒤에 결과 JSON 파일 경로가 필요합니다." >&2; usage; exit 1; }
      result_file="$1" ;;
    --result=*)
      result_file="${1#--result=}" ;;
    --skip-reason)
      shift
      [ $# -gt 0 ] || { echo "--skip-reason 뒤에 사유 문자열이 필요합니다." >&2; usage; exit 1; }
      skip_reason="$1" ;;
    --skip-reason=*)
      skip_reason="${1#--skip-reason=}" ;;
    *)
      echo "알 수 없는 인자: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [ -n "$result_file" ] && [ -n "$skip_reason" ]; then
  echo "--result 와 --skip-reason 은 함께 쓸 수 없습니다 — 판정 근거가 둘이면 어느 쪽으로 찍혔는지 알 수 없습니다." >&2
  exit 1
fi

if [ -z "$result_file" ] && [ -z "$skip_reason" ]; then
  echo "리뷰 결과(--result) 도 생략 사유(--skip-reason) 도 없습니다 — 마커를 찍지 않습니다." >&2
  usage
  exit 1
fi

# ── --result 판정(허용 목록) ─────────────────────────────────────────────────
if [ -n "$result_file" ]; then
  [ -f "$result_file" ] || { echo "리뷰 결과 파일이 없습니다: $result_file" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || {
    echo "jq 가 없어 리뷰 결과를 판정할 수 없습니다 — 판정 없이 마커를 찍지 않습니다." >&2; exit 1; }

  set +e
  verdict=$(jq -r '
    if (.reviewComplete == true)
       and ((.lensStatus | type) == "array")
       and ((.lensStatus | length) > 0)
       and ((.lensStatus | map(.status) | all(. == "ok")))
       and ((.unverified | type) == "array")
       and ((.unverified | length) == 0)
       and ((.uncoveredFiles | type) == "array")
       and ((.uncoveredFiles | length) == 0)
    then "ok" else "ng" end' "$result_file" 2>/dev/null)
  set -e

  if [ "$verdict" != "ok" ]; then
    set +e
    detail=$(jq -r '
      "reviewComplete=" + (.reviewComplete | tostring)
      + " / lensStatus=" + (if (.lensStatus | type) == "array" and (.lensStatus | length) > 0
                            then (.lensStatus | map(((.lens // "?") | tostring) + ":" + ((.status // "?") | tostring)) | join(","))
                            else (.lensStatus | tostring) end)
      + " / unverified=" + (if (.unverified | type) == "array" then (.unverified | length | tostring) else (.unverified | tostring) end)
      + " / uncoveredFiles=" + (if (.uncoveredFiles | type) == "array" then (.uncoveredFiles | map(tostring) | join(",")) else (.uncoveredFiles | tostring) end)
    ' "$result_file" 2>/dev/null)
    set -e
    [ -n "$detail" ] || detail="(결과 JSON 을 읽지 못했습니다 — 유효한 JSON 인지 확인하세요)"
    {
      echo "[리뷰 미완결] 마커를 찍지 않습니다: $result_file"
      echo "  $detail"
      echo "  통과 조건: reviewComplete=true · lensStatus 전부 status=ok(ok 밖 상태값의 정본 = .claude/workflows/commit-review.js) · unverified·uncoveredFiles 빈 배열."
      echo "  uncoveredFiles 가 있으면 그 파일을 읽는 관점으로 재실행하세요(lenses 에 그 파일 종류를 보는 관점을 넣고 stagedFiles 를 넘긴다). 그 밖에는 리뷰를 재실행하세요."
      echo "  결과를 '지적 0건'으로 읽지 마세요. 리뷰 자체가 불필요·불가한 변경이면 --skip-reason 으로 사유를 남기고 사용자에게 알리세요."
    } >&2
    exit 1
  fi
fi

# ── 지문 산출(검문 훅과 동일 정본) ───────────────────────────────────────────
set +e
if [ "$all_mode" -eq 1 ]; then
  # 임시 인덱스 = 현 인덱스 사본 + `git add -u`. 어느 단계든 실패하면 지문을 내지 않는다(rc=1 → 마커 안 찍음).
  _tmpidx=$(mktemp "${TMPDIR:-/tmp}/mark-review-idx.XXXXXX") || { echo "임시 인덱스 생성 실패 — 마커를 찍지 않습니다." >&2; exit 1; }
  trap 'rm -f "$_tmpidx"' EXIT
  _idx=$(git -C "$proj" rev-parse --path-format=absolute --git-path index 2>/dev/null)
  if [ -n "$_idx" ] && [ -f "$_idx" ] && cp "$_idx" "$_tmpidx" \
     && GIT_INDEX_FILE="$_tmpidx" git -C "$proj" add -u >/dev/null 2>&1; then
    hash=$(export GIT_INDEX_FILE="$_tmpidx"; review_diff_hash "$proj" "")
    rc=$?
  else
    hash=""; rc=1
  fi
else
  hash=$(review_diff_hash "$proj" "")
  rc=$?
fi
set -e

case "$rc" in
  1) echo "git 저장소가 아니거나 shasum 이 없거나(--all 이면) 임시 인덱스 구성에 실패했습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;;
  2) echo "스테이징된 변경이 없습니다 — 먼저 git add 로 커밋 대상을 확정하세요." >&2; exit 1 ;;
esac

# ── 생략 사유 검증은 **마커를 쓰기 전에** ────────────────────────────────────
# 뒤에 두면 exit 1 로 거부해 놓고 마커는 이미 찍혀 있어, 사유가 기록되지 않은 채 커밋 게이트만
# 통과하는 상태가 남는다(2026-09-18 실측: `--skip-reason '   '` → rc=1 인데 .last-review 생성).
reason_1line=""
if [ -n "$skip_reason" ]; then
  # 로그는 한 줄 = 한 건. 줄바꿈·탭은 공백으로 접고 길이를 자른다(사유 문자열은 외부 입력이다).
  reason_1line=$(printf '%s' "$skip_reason" | tr '\n\r\t' '   ' | cut -c1-500)
  # 앞뒤 공백만 남은 사유는 사유가 아니다.
  case "$(printf '%s' "$reason_1line" | tr -d '[:space:]')" in
    "") echo "생략 사유가 비어 있습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;;
  esac
fi

mkdir -p "$proj/.claude"
printf '%s %s\n' "$(date +%F)" "$hash" > "$proj/.claude/.last-review"

if [ -n "$skip_reason" ]; then
  printf '%s %s skip-reason: %s\n' "$(date +%FT%T%z)" "${hash:0:12}" "$reason_1line" \
    >> "$proj/.claude/.review-marker.log"
  echo "리뷰 마커 기록(생략 경로): $(date +%F) ${hash:0:12}… ($proj/.claude/.last-review)"
  echo "⚠️ 리뷰 결과 파일 없이 마커를 찍었습니다 — 이 사실과 사유를 **사용자에게 알리세요**: ${reason_1line}"
  echo "   기록: $proj/.claude/.review-marker.log"
else
  echo "리뷰 마커 기록: $(date +%F) ${hash:0:12}… ($proj/.claude/.last-review)"
  echo "   근거: $result_file (reviewComplete=true · lensStatus 전부 ok · unverified 0 · uncoveredFiles 0)"
fi
