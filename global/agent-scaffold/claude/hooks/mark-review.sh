#!/usr/bin/env bash
# hook-policy: 강제=보조 · 도구부재=-
# audit: unregistered-ok — 훅 이벤트에 걸지 않고 에이전트가 직접 호출하는 CLI(게이트 훅의 통과 마커를 찍는다).
# 커밋 전 코드리뷰 완료 마커 기록 — code-review-marker-reminder.sh 게이트의 통과 조건.
# 근거 처분: project:검증:20 (리뷰 결과가 **완결**일 때만 마커를 찍는다 — reviewComplete 를 눈으로 읽고
#            찍는 규약 문장은 잊혔고, 미완결 결과로 마커가 찍힌 채 커밋이 통과한 적이 있다).
#
# 사용(판정 근거 플래그 없이 부르면 마커를 찍지 않는다. 언제 어느 쪽인지 = --help):
#   bash .claude/hooks/mark-review.sh --begin                       (빌트인 리뷰 직전 — 리뷰 대상 지문을 .claude/.review-pending 에 기록)
#   bash .claude/hooks/mark-review.sh --builtin <빌트인 결과 JSON 파일> (대체 엔진 = 빌트인 Skill(code-review) 결과 — --begin 뒤에만)
#   bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON 파일>  (commit-review.js 워크플로 결과 — A티어 기본 엔진)
#   bash .claude/hooks/mark-review.sh --skip-reason "<리뷰를 생략했거나 결과 JSON 이 없는 사유>"
#   위에 --amend|--all|-a 를 덧붙이면 워킹트리까지 커밋하는 경우의 지문으로 기록한다 — 현 인덱스를 임시 인덱스로
#   복사해 `git add -u`(= commit -a 가 커밋 직전에 하는 일)를 한 뒤 그 `diff --cached` 지문을 찍는다. 층 A(git pre-commit)가
#   그 커밋에서 보는 인덱스와 같은 내용이라 지문이 일치한다. 실제 인덱스는 건드리지 않는다.
# ponytail: --amend 도 -a 와 같은 지문(워킹트리 추적 변경 포함)으로 찍는다 — `-a` 없는 amend 에 워킹트리 미스테이징 변경이
#   남아 있으면 층 A 지문과 어긋나 막힌다(안전 측) / 업그레이드 = --amend 를 별도 플래그(인덱스 그대로)로 분리.
#
# 결과 파일 판독(공통): `jq -e -s` — 파일 안 JSON 값이 정확히 하나이고 jq 가 0 으로 끝나며 판정식이 true 일 때만 통과.
#   정상 JSON 뒤 후행 텍스트·값 여러 개·빈 파일은 판정 불가로 거부한다.
# ponytail: 중복 키는 jq 가 마지막 값으로 읽어 감지하지 못한다(`{"severity":"important","severity":"nit"}` = nit) /
#   업그레이드 = python3 json object_pairs_hook 로 중복 키 거부.
#
# 두 지문: 인덱스 지문(실제 인덱스의 diff --cached)과 -a 지문(임시 인덱스 + add -u). 마커는 호출 모드의 지문으로 찍는다.
#   builtin-ng 는 두 지문을 쌍으로 기록하고(`<날짜> <모드 지문> builtin-ng important=N idx=<인덱스 지문> all=<-a 지문>`),
#   대조는 호출 모드의 지문만 그 모드 칸과 비교한다(인덱스 모드 = idx, -a 모드 = all). ng 를 받은 순간의 두 지문이 함께 남으므로
#   모드만 바꿔서는 같은 칸이 일치해 막히고, -a 모드에서 미스테이징 파일을 고치면 all 지문이 바뀌어 재리뷰로 통과할 수 있다.
#   idx=/all= 칸이 없는 이전 형식 줄(`<날짜> <지문> builtin-ng important=N`)은 그 지문을 두 칸 모두로 읽는다(안전 측).
#   칸이 있어도 값이 비면(ng 순간 그 모드 지문을 못 냈음 — 예: 스테이징 0 에서 -a 로 ng) 그 칸을 <모드 지문> 으로 읽는다(안전 측).
# ponytail: 인덱스 모드 ng 가 미스테이징 파일 지적이면 그 파일을 고쳐도 idx 지문이 그대로라 계속 막힌다 /
#   업그레이드 = ng 지적 파일이 스테이징 경로에 없으면 idx 결속 생략.
# ponytail: ng 결속 = 지문 완전일치 — 한 바이트만 바꿔도 새 지문이다 / 업그레이드 = ng 이후 같은 경로집합 커밋은
#   --builtin 재통과 또는 --skip-reason 만 허용.
#
# 거부 시 마커 무효화: 판정 거부(builtin-ng 대조·important·--result 미완결) 때 .claude/.last-review 의
#   지문이 두 지문 중 하나와 같으면 지운다 — 같은 diff 에 먼저 찍힌 마커가 뒤의 거부 판정을 무력화하지 못하게.
#   절차 거부(인자·경로·빌트인 결과 형식 판정 불가·pending·지문 불일치·mtime·미스테이징 겹침)는 판정이 아니라 마커를 건드리지 않는다
#   (경로를 잘못 넘긴 것만으로 정상 마커가 지워지지 않게).
#
# --result 통과 조건(**허용 목록** — 하나라도 어긋나면 찍지 않는다):
#   ① .reviewComplete 가 JSON true (문자열 "true" 는 불가)
#   ② .lensStatus 가 배열이고 비어 있지 않으며 **모든 원소의 .status 가 "ok"**
#      (엔진이 내는 status 값의 정본 = commit-review.js — 여기선 "ok" 하나만 허용한다.
#       금지 목록으로 적으면 엔진에 새 상태값이 생겼을 때 조용히 통과한다 → 허용 목록으로 쓴다)
#   ③ .unverified 가 배열이고 비어 있음 (미판정은 기각이 아니다)
#   ④ .uncoveredFiles 가 배열이고 비어 있음 (status ok 인 어느 관점도 읽지 않은 스테이징 파일 — 필드 의미의 정본 = commit-review.js 반환부.
#      필드가 없으면 판정 불가로 거부한다 — 허용 목록 원칙)
#   ⑤ 호출 모드 지문에 builtin-ng 기록(.claude/.review-marker.log)이 없음 — 빌트인이 important 로 막은 diff 를
#      결과 형식만 바꿔 통과시키지 못하게. 그 지문에서 남는 길은 수리 후 재리뷰 또는 --skip-reason.
#
# --builtin 통과 조건(**허용 목록**):
#   ① 결과 파일 = 정규 파일(심볼릭 링크 불가) · 임시 디렉터리(${TMPDIR:-/tmp}·/tmp·/private/tmp 의 실경로) 아래 ·
#      레포 작업 트리 밖이고 같은 git common dir 의 다른 작업 트리(linked worktree)도 아니며, 어떤 git 작업 트리 안도 아님
#      (임시 디렉터리 아래 다른 레포의 추적 파일을 지우지 않게). 위치 판정은 문자열 접두가 아니라
#      상위로 올라가며 `-ef`(같은 파일) 비교 — 대소문자 무시 파일시스템에서 경로 표기만 바꿔 빠져나가지 못하게.
#   ② 최상위 = 배열(빈 배열 허용) · 모든 원소 = 객체이고 .severity ∈ {"important","nit","pre_existing"}
#   ③ 호출 모드 지문에 builtin-ng 기록 없음(재제출·모드 전환으로 ng 를 덮지 못하게 — 대조 규칙은 「두 지문」)
#   ④ .claude/.review-pending 이 있고 그 지문 == 현재 지문, 결과 파일 mtime ≥ 그 epoch
#   ⑤ severity=="important" 원소 0 — 파일 위치 무관(스테이징 밖 파일에 붙은 important 도 막는다)
#   거부(⑤) 시 builtin-ng 를 두 지문 쌍으로 로그에 남기고 pending 을 지운다(같은 pending 으로 결과만 바꿔 재제출하지 못하게).
# ponytail: mtime 대조는 실수 방지용이다(touch·미래 시각으로 통과) / 업그레이드 = --begin 이 결과 파일 경로를 발급하고
#   "발급 경로 + 발급 뒤 첫 쓰기"로 결속.
# 결과 파일 삭제: ① 위치 검사와 ② 형식 판정을 **둘 다** 통과한 뒤부터만 삭제 대상으로 잡고, 그 뒤 성공·실패 모두 trap 으로 지운다.
#   형식 판정 전에 지우지 않는 이유 = 임시 디렉터리 아래에도 다른 작업의 파일(스크래치패드 문서 등)이 있다 — 빌트인 결과 배열로
#   판독된 파일만 지워 경로를 잘못 넘겼을 때의 손실을 막는다. 지우지 않은 거부에는 직접 지우라고 안내한다.
#   (결과 원문에 비밀이 옮겨 적힐 수 있다 — 그래서 진단 출력도 건수·`파일:줄`만 낸다.)
# ponytail: TMPDIR 밖에서 mktemp 한 결과 파일은 거부된다(안전 측) / 업그레이드 = --begin 이 결과 파일을 직접 mktemp 해
#   pending 에 경로를 적고 --builtin 은 그 경로만 받기.
# ponytail: 결과 원문을 에이전트가 Skill 출력에서 파일로 옮겨 적는 단계가 있다(옮기며 빠뜨리거나 고칠 수 있다) /
#   업그레이드 = PostToolUse(Skill) 훅으로 결과를 직접 캡처(미검증).
# ponytail: 빈 배열 = "다 봤는데 0건"과 "리뷰 실패로 0건"을 구분하지 못한다(빌트인 결과에 완결성 신호가 없다) /
#   업그레이드 = 빌트인이 완결성 필드를 내면 허용 목록에 추가. 지금은 통과시키되 사용자 보고 문구를 낸다.
#
# 미스테이징 겹침 검사(--begin·--builtin): 스테이징 경로 중 워킹트리에 미스테이징 변경이 더 있는 경로가 있으면 거부한다 —
#   빌트인은 워킹트리 diff 를 읽으므로 그 경로는 리뷰한 내용과 커밋될 내용이 다르다.
#   --amend|--all|-a 와 함께면 이 검사를 하지 않는다: 그 모드의 지문은 워킹트리 추적 변경까지 담은 임시 인덱스로 산출되어
#   커밋될 내용 = 워킹트리 내용이고, --begin·--builtin 사이 변경은 지문 대조가 잡는다.
#
# 우회 = --skip-reason 하나뿐(환경변수 우회 없음). 소형 A 델타형 리뷰처럼 결과 JSON 이 없는 리뷰,
#   사용자가 리뷰 생략을 지시한 경우가 여기에 해당한다. 사유는 `.claude/.review-marker.log` 에 누적되고
#   호출자에게 "사용자에게 알리라"는 문구를 출력한다(CLAUDE.md: 생략 판단은 침묵 통과 금지).
#
# 기록 형식: "<YYYY-MM-DD> <리뷰 대상 diff 의 sha256>"  (게이트는 두 번째 필드만 대조)
#   지문 산출은 lib/review-diff.sh 가 단일 정본 — 검문(code-review-marker-reminder.sh)과 같은 값을 쓴다.
#   리뷰 후 코드를 더 고치면 지문이 달라져 게이트가 다시 막는다 — 그때는 다시 리뷰하고 다시 찍는다.
#
# 한계: --result 결과 JSON 이 **정말 이 diff 를 리뷰한 것인지**는 검사하지 않는다(파일을 지어내면 통과한다).
#   --builtin 의 pending 대조도 "리뷰 시작 시점의 스테이징 = 지금 스테이징"까지만 보증한다.
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
  bash .claude/hooks/mark-review.sh --begin [--amend|--all|-a]
  bash .claude/hooks/mark-review.sh --builtin <빌트인 결과 JSON 파일> [--amend|--all|-a]
  bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON 파일> [--amend|--all|-a]
  bash .claude/hooks/mark-review.sh --skip-reason "<사유>" [--amend|--all|-a]
  (--begin·--builtin·--result·--skip-reason 중 정확히 하나)

  --begin       빌트인 리뷰 직전에 현재 스테이징 지문을 .claude/.review-pending 에 기록한다(마커는 찍지 않음).
  --builtin     빌트인 Skill(code-review) 결과 JSON 배열을 그대로 저장한 파일 — 임시 디렉터리(mktemp, ${TMPDIR:-/tmp}) 아래,
                레포 작업 트리 밖. 빌트인 Result 가 `(none)` 이면 `[]` 로 옮긴다. 그 밖의 배열 아닌 텍스트 = 리뷰 실패 → 기본 엔진(워크플로 → --result)으로 리뷰.
                --begin 지문 == 현재 지문 · 파일이 --begin 뒤에 쓰임 · 원소 severity 가 important/nit/pre_existing 뿐 ·
                important 0건 · 이 지문에 builtin-ng 기록 없음일 때만 마커를 찍는다. 결과 배열로 판독된 파일은 판정 뒤 지운다.
  --result      commit-review.js(워크플로)가 돌려준 결과를 그대로 저장한 JSON 파일.
                reviewComplete=true · lensStatus 전부 ok · unverified·uncoveredFiles 빈 배열일 때만 마커를 찍는다.
                같은 지문이 빌트인에서 important 로 거부됐으면 쓸 수 없다.
  --skip-reason 리뷰 결과 파일 없이 찍는 유일한 경로. 사유는 .claude/.review-marker.log 에 남고
                그 사실을 사용자에게 알려야 한다.
  --amend|--all|-a  commit -a·--amend 처럼 워킹트리 추적 변경까지 커밋할 때 그 지문으로 찍는다(--begin·--builtin 에도 같이).

언제:
  --result      = 리뷰 워크플로(commit-review.js) 결과 JSON 이 있을 때 — A티어 기본 엔진.
  --begin → --builtin = 레포 규약이 빌트인 Skill(code-review)을 대체 엔진으로 고른 경우(high, 소형 A 는 low). important 가 나오면 수리 → git add → --begin 부터 다시.
                결과가 JSON 배열(또는 `(none)`)이 아니면 기본 엔진(--result)으로 리뷰한다.
  --skip-reason = 결과 JSON 이 없는 리뷰(B티어 인라인 셀프리뷰·소형 델타 인라인)·사용자가 리뷰 생략을 지시·문서/설정만 변경·빌트인 important 를 오탐으로 판단했을 때.
USAGE
}

all_mode=0
mode=""
mode_count=0
result_file=""
builtin_file=""
skip_reason=""

set_mode() { mode="$1"; mode_count=$((mode_count + 1)); }

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage 2>&1; exit 0 ;;
    --amend|--all|-a)
      all_mode=1 ;;
    --begin)
      set_mode begin ;;
    --builtin)
      shift
      [ $# -gt 0 ] || { echo "--builtin 뒤에 빌트인 결과 JSON 파일 경로가 필요합니다." >&2; usage; exit 1; }
      set_mode builtin; builtin_file="$1" ;;
    --builtin=*)
      set_mode builtin; builtin_file="${1#--builtin=}" ;;
    --result)
      shift
      [ $# -gt 0 ] || { echo "--result 뒤에 결과 JSON 파일 경로가 필요합니다." >&2; usage; exit 1; }
      set_mode result; result_file="$1" ;;
    --result=*)
      set_mode result; result_file="${1#--result=}" ;;
    --skip-reason)
      shift
      [ $# -gt 0 ] || { echo "--skip-reason 뒤에 사유 문자열이 필요합니다." >&2; usage; exit 1; }
      set_mode skip; skip_reason="$1" ;;
    --skip-reason=*)
      set_mode skip; skip_reason="${1#--skip-reason=}" ;;
    *)
      echo "알 수 없는 인자: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

if [ "$mode_count" -gt 1 ]; then
  echo "--begin·--builtin·--result·--skip-reason 은 함께 쓸 수 없습니다(같은 플래그 반복 포함) — 판정 근거가 둘이면 어느 쪽으로 찍혔는지 알 수 없습니다." >&2
  exit 1
fi

if [ "$mode_count" -eq 0 ]; then
  echo "리뷰 결과(--builtin·--result)도 생략 사유(--skip-reason)도 없습니다 — 마커를 찍지 않습니다." >&2
  usage
  exit 1
fi

_tmpidx=""
_del_result=""
cleanup() {
  [ -z "$_tmpidx" ] || rm -f "$_tmpidx"
  [ -z "$_del_result" ] || rm -f "$_del_result"
  return 0
}
trap cleanup EXIT

pending="$proj/.claude/.review-pending"
mlog="$proj/.claude/.review-marker.log"
marker="$proj/.claude/.last-review"

# under_dir <실경로 디렉터리> <기준 디렉터리> — 첫 인자 또는 그 상위 중 하나가 기준과 같은 파일(-ef)이면 0.
under_dir() {
  local d="$1"
  [ -d "$2" ] || return 1
  while :; do
    [ "$d" -ef "$2" ] && return 0
    [ "$d" = "/" ] && return 1
    d=$(dirname "$d")
  done
}

if [ "$mode" = builtin ] || [ "$mode" = result ]; then
  command -v jq >/dev/null 2>&1 || {
    echo "jq 가 없어 리뷰 결과를 판정할 수 없습니다 — 판정 없이 마커를 찍지 않습니다." >&2; exit 1; }
fi

# ── --builtin 결과 파일 위치·형식 검사 — 둘 다 통과해야 삭제 대상(이유는 헤더) ──────
if [ "$mode" = builtin ]; then
  if [ -L "$builtin_file" ] || [ ! -f "$builtin_file" ]; then
    echo "빌트인 결과 파일이 정규 파일이 아닙니다(없음·디렉터리·심볼릭 링크): $builtin_file — 마커를 찍지 않습니다." >&2
    exit 1
  fi
  _top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null) && _top=$(cd "$_top" 2>/dev/null && pwd -P) || _top=""
  [ -n "$_top" ] || { echo "git 저장소가 아닙니다 — 마커를 찍지 않습니다." >&2; exit 1; }
  _bdir=$(cd "$(dirname "$builtin_file")" 2>/dev/null && pwd -P) || _bdir=""
  [ -n "$_bdir" ] || { echo "빌트인 결과 파일 경로를 해석하지 못했습니다: $builtin_file" >&2; exit 1; }
  _breal="$_bdir/$(basename "$builtin_file")"

  _inrepo=0
  under_dir "$_bdir" "$_top" && _inrepo=1
  if [ "$_inrepo" -eq 0 ]; then
    _gc_proj=$(git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    _gc_file=$(git -C "$_bdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [ -n "$_gc_proj" ] && [ -n "$_gc_file" ] && [ "$_gc_proj" -ef "$_gc_file" ]; then _inrepo=1; fi
  fi
  if [ "$_inrepo" -eq 1 ]; then
    {
      echo "빌트인 결과 파일이 레포 작업 트리(또는 같은 저장소의 다른 작업 트리) 안에 있습니다: $_breal — 마커를 찍지 않습니다."
      echo "  ⚠️ 결과 원문에 비밀이 들어 있을 수 있으니 이 파일을 **즉시 지우고**, 레포 밖 임시 파일(mktemp)에 다시 쓰세요(자동 삭제는 하지 않습니다)."
    } >&2
    exit 1
  fi

  if git -C "$_bdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "빌트인 결과 파일이 git 작업 트리 안에 있습니다: $_breal — 다른 저장소의 파일일 수 있어 거부합니다(파일은 그대로 둡니다). git 작업 트리 밖의 mktemp 파일에 다시 쓰세요(TMPDIR 자체가 작업 트리 안이면 \`mktemp /tmp/review.XXXXXX\`)." >&2
    # ponytail: TMPDIR 이 git 작업 트리 안이면 그 아래 결과 파일은 전부 거부된다(안전 측) / 업그레이드 = --begin 이 결과 파일을 발급
    exit 1
  fi

  _intmp=0
  for _r in "${TMPDIR:-/tmp}" /tmp /private/tmp; do
    _rr=$(cd "$_r" 2>/dev/null && pwd -P) || continue
    if under_dir "$_bdir" "$_rr"; then _intmp=1; break; fi
  done
  if [ "$_intmp" -eq 0 ]; then
    echo "빌트인 결과 파일이 임시 디렉터리(\${TMPDIR:-/tmp}·/tmp) 밖에 있습니다: $_breal — 판정 뒤 삭제할 수 없는 위치라 거부합니다(파일은 그대로 둡니다). mktemp 로 만든 파일에 다시 쓰세요." >&2
    exit 1
  fi

  set +e
  jq -e -s '
    length == 1
    and ((.[0] | type) == "array")
    and (.[0] | all(.[]; (type == "object")
                         and ((.severity | type) == "string")
                         and (.severity | IN("important", "nit", "pre_existing"))))
  ' "$_breal" >/dev/null 2>&1
  _fmt_rc=$?
  set -e
  # 형식 판정 통과 = 빌트인 결과 배열로 판독된 파일 → 이제부터 성공·실패 모두 삭제.
  [ "$_fmt_rc" -ne 0 ] || _del_result="$_breal"
fi
if [ "$mode" = result ]; then
  [ -f "$result_file" ] || { echo "리뷰 결과 파일이 없습니다: $result_file" >&2; exit 1; }
fi

# ── 미스테이징 겹침 검사(--begin·--builtin, -a 모드 제외 — 이유는 헤더) ────────────
if { [ "$mode" = begin ] || [ "$mode" = builtin ]; } && [ "$all_mode" -eq 0 ]; then
  set +e
  _overlap=$(LC_ALL=C comm -12 \
    <(git -C "$proj" diff --cached --name-only 2>/dev/null | LC_ALL=C sort -u) \
    <(git -C "$proj" diff --name-only 2>/dev/null | LC_ALL=C sort -u))
  set -e
  if [ -n "$_overlap" ]; then
    {
      echo "[미스테이징 변경] 스테이징된 경로에 워킹트리 변경이 더 있습니다 — 빌트인은 워킹트리를 읽으므로 리뷰 내용과 커밋 내용이 달라집니다. 마커를 찍지 않습니다."
      printf '%s\n' "$_overlap" | sed 's/^/  - /'
      echo "  그 변경을 git add 로 포함하거나 되돌린 뒤 --begin 부터 다시 하세요(커밋을 -a 로 할 거면 --begin·--builtin 에 -a 를 붙이세요)."
    } >&2
    exit 1
  fi
fi

# ── 지문 산출(검문 훅과 동일 정본) — 인덱스 지문·-a 지문 ─────────────────────
hash_idx=""; rc_idx=1; hash_all=""; rc_all=1
set +e
hash_idx=$(review_diff_hash "$proj" ""); rc_idx=$?
if [ "$all_mode" -eq 1 ] || [ "$mode" = builtin ] || [ "$mode" = result ]; then
  # 임시 인덱스 = 현 인덱스 사본 + `git add -u`. 어느 단계든 실패하면 -a 지문을 내지 않는다.
  _tmpidx=$(mktemp "${TMPDIR:-/tmp}/mark-review-idx.XXXXXX")
  if [ -n "$_tmpidx" ]; then
    _idx=$(git -C "$proj" rev-parse --path-format=absolute --git-path index 2>/dev/null)
    # cp -p: 인덱스 mtime 을 보존해야 git 의 racy-git 보호(인덱스와 같은 초에 바뀐 파일은 내용 재비교)가 유지된다 —
    #   새 mtime 이 찍히면 같은 초·같은 크기 변경이 -a 지문에서 빠진다(원 레포 델타 재리뷰에서 재현).
    #   chmod 600: cp -p 가 원본 인덱스 권한까지 옮겨 오므로 임시 파일 권한을 mktemp 기본값으로 되돌린다.
    if [ -n "$_idx" ] && [ -f "$_idx" ] && cp -p "$_idx" "$_tmpidx" && chmod 600 "$_tmpidx" \
       && GIT_INDEX_FILE="$_tmpidx" git -C "$proj" add -u >/dev/null 2>&1; then
      hash_all=$(export GIT_INDEX_FILE="$_tmpidx"; review_diff_hash "$proj" ""); rc_all=$?
    fi
  fi
fi
set -e
[ "$rc_idx" -eq 0 ] || hash_idx=""
[ "$rc_all" -eq 0 ] || hash_all=""

if [ "$all_mode" -eq 1 ]; then hash="$hash_all"; rc="$rc_all"; else hash="$hash_idx"; rc="$rc_idx"; fi
case "$rc" in
  0) ;;
  2) echo "스테이징된 변경이 없습니다 — 먼저 git add 로 커밋 대상을 확정하세요." >&2; exit 1 ;;
  *) echo "git 저장소가 아니거나 shasum 이 없거나(--all 이면) 임시 인덱스 구성에 실패했습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;;
esac

# 판정 거부 때 이 diff 에 먼저 찍힌 마커를 무효화한다(헤더 「거부 시 마커 무효화」).
invalidate_marker() {
  local rec
  rec=$(awk '{print $2}' "$marker" 2>/dev/null | head -1)
  [ -n "$rec" ] || return 0
  if [ "$rec" = "$hash_idx" ] || { [ -n "$hash_all" ] && [ "$rec" = "$hash_all" ]; }; then
    rm -f "$marker"
    echo "  같은 지문으로 먼저 찍혀 있던 리뷰 마커(${rec:0:12}…)를 지웠습니다." >&2
  fi
  return 0
}
# 호출 모드 지문이 그 모드 칸(idx·all)에 builtin-ng 로 기록돼 있으면 0(규칙은 헤더 「두 지문」).
ng_recorded() {
  [ -f "$mlog" ] || return 1
  local m=idx
  [ "$all_mode" -eq 0 ] || m=all
  awk -v m="$m" -v hi="$hash_idx" -v ha="$hash_all" '
    $3 == "builtin-ng" {
      i = $2; a = $2
      for (k = 4; k <= NF; k++) {
        if ($k ~ /^idx=/ && length($k) > 4) i = substr($k, 5)
        else if ($k ~ /^all=/ && length($k) > 4) a = substr($k, 5)
      }
      if ((m == "idx" && i == hi && hi != "") || (m == "all" && a == ha && ha != "")) f = 1
    }
    END { exit !f }' "$mlog"
}
ng_reject() { # ng_reject <경로 이름>
  {
    echo "[빌트인 important 기록] 이 diff(인덱스 ${hash_idx:0:12}… / -a ${hash_all:0:12}…)는 빌트인 리뷰에서 important 로 거부된 기록이 있습니다 — $1 로는 마커를 찍지 않습니다."
    echo "  important 를 수리해 git add → --begin → 빌트인 재리뷰 하거나, 오탐이라 판단하면 --skip-reason \"<사유>\" 로 남기고 사용자에게 알리세요."
  } >&2
  invalidate_marker
  exit 1
}

# ── --begin: 리뷰 대상 지문만 기록하고 끝 ────────────────────────────────────
if [ "$mode" = begin ]; then
  mkdir -p "$proj/.claude"
  _ptmp=$(mktemp "$proj/.claude/.review-pending.XXXXXX")
  printf '%s %s\n' "$(date +%s)" "$hash" > "$_ptmp"
  mv -f "$_ptmp" "$pending"
  _aflag=""; [ "$all_mode" -eq 1 ] && _aflag=" -a"
  echo "리뷰 대상 지문 기록: ${hash:0:12}… ($pending) — 마커는 아직 찍지 않았습니다."
  echo "   다음: 빌트인 Skill(code-review) 실행 → 결과 JSON 배열을 임시 파일(mktemp)에 그대로 저장(Result 가 \`(none)\` 이면 \`[]\`) →"
  echo "         bash .claude/hooks/mark-review.sh --builtin <그 파일>${_aflag}"
  echo "   리뷰 뒤 스테이징을 바꾸면 지문이 달라져 --builtin 이 거부합니다 — 그때는 --begin 부터 다시."
  exit 0
fi

# ── --builtin 판정(허용 목록) ────────────────────────────────────────────────
bi_imp=""; bi_nit=0; bi_pre=0; bi_staged_pre=""; p_line=""
if [ "$mode" = builtin ]; then
  if [ "$_fmt_rc" -ne 0 ]; then
    {
      echo "[빌트인 결과 판정 불가] 마커를 찍지 않습니다(결과 배열로 판독되지 않아 파일은 지우지 않습니다 — 비밀이 들어 있을 수 있으니 직접 지우세요: $_breal)."
      echo "  통과 형식: 파일 안 JSON 값 하나 · 최상위 배열 · 모든 원소가 객체이고 severity ∈ important/nit/pre_existing."
      echo "  빌트인 Result 가 \`(none)\` 이면 \`[]\` 로 옮기세요. 그 밖의 배열 아닌 텍스트는 리뷰 실패 — 결과를 '지적 0건'으로 읽지 말고 기본 엔진(commit-review.js → --result)으로 리뷰하세요."
    } >&2
    exit 1
  fi

  ng_recorded && ng_reject "--builtin"

  [ -f "$pending" ] || {
    echo "--begin 기록(.claude/.review-pending)이 없습니다 — 리뷰 직전에 --begin 을 먼저 실행하세요. 마커를 찍지 않습니다." >&2; exit 1; }
  p_line=$(head -1 "$pending" 2>/dev/null || true)
  p_epoch=""; p_hash=""
  read -r p_epoch p_hash _ <<EOF_PENDING || true
$p_line
EOF_PENDING
  if [ "$p_hash" != "$hash" ]; then
    echo "[지문 불일치] --begin 때 스테이징(${p_hash:0:12}…)과 지금(${hash:0:12}…)이 다릅니다 — 리뷰 뒤 스테이징이 바뀌었습니다. --begin → 리뷰를 다시 하세요. 마커를 찍지 않습니다." >&2
    exit 1
  fi
  _mt=$(stat -c %Y "$_breal" 2>/dev/null || stat -f %m "$_breal" 2>/dev/null || true)
  case "$_mt" in ''|*[!0-9]*) echo "결과 파일 수정 시각을 읽지 못했습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;; esac
  case "$p_epoch" in ''|*[!0-9]*) echo ".claude/.review-pending 형식이 잘못됐습니다 — --begin 을 다시 실행하세요." >&2; exit 1 ;; esac
  if [ "$_mt" -lt "$p_epoch" ]; then
    echo "[결과 시각] 결과 파일이 --begin 보다 먼저 쓰였습니다 — 이번 리뷰의 결과가 아닙니다. 마커를 찍지 않습니다." >&2
    exit 1
  fi

  read -r bi_imp bi_nit bi_pre < <(jq -r -s '.[0]
    | [ (map(select(.severity == "important")) | length),
        (map(select(.severity == "nit")) | length),
        (map(select(.severity == "pre_existing")) | length) ] | @tsv' "$_breal" 2>/dev/null || true)
  for _n in "${bi_imp:-}" "${bi_nit:-}" "${bi_pre:-}"; do
    case "$_n" in ''|*[!0-9]*) echo "빌트인 결과 건수를 세지 못했습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;; esac
  done

  # 진단 출력용 `파일<TAB>줄` — .file 은 문자열, .line 은 숫자일 때만 싣고 그 밖은 "?"(원문이 섞여 나오지 않게).
  bi_locs() { # bi_locs <severity>
    jq -r -s --arg s "$1" --arg top "$_top" '.[0][] | select(.severity == $s)
      | [ (if (.file | type) == "string"
           then (.file | gsub("[[:cntrl:]]"; " ") | ltrimstr($top + "/") | ltrimstr("./")) else "?" end),
          (if (.line | type) == "number" then (.line | tostring) else "?" end) ] | @tsv' "$_breal" 2>/dev/null \
      | cut -c1-300 | head -50
  }
  # pending 은 읽었을 때와 내용이 같을 때만 지운다(그 사이 다른 세션이 새로 --begin 한 기록을 지우지 않게).
  drop_pending() {
    [ "$(head -1 "$pending" 2>/dev/null || true)" = "$p_line" ] && rm -f "$pending"
    return 0
  }

  if [ "$bi_imp" -gt 0 ]; then
    mkdir -p "$proj/.claude"
    printf '%s %s builtin-ng important=%s idx=%s all=%s\n' "$(date +%F)" "$hash" "$bi_imp" "$hash_idx" "$hash_all" >> "$mlog"
    drop_pending
    {
      echo "[빌트인 important ${bi_imp}건] 마커를 찍지 않습니다(파일 위치 무관 — 스테이징 밖 파일의 important 도 막습니다)."
      bi_locs important | awk -F '\t' '{print "  - " $1 ":" $2}'
      echo "  수리 → git add → --begin → 빌트인 재리뷰 → --builtin 순으로 다시 하세요(.review-pending 은 지웠습니다)."
      echo "  이 diff 는 builtin-ng 로 기록되어 같은 지문으로는(모드를 바꿔도) --builtin·--result 모두 통과할 수 없습니다. 오탐이라 판단하면 --skip-reason \"<사유>\" 로 남기고 사용자에게 알리세요."
    } >&2
    invalidate_marker
    exit 1
  fi

  # 스테이징 경로에 붙은 pre_existing — 막지 않고 위치만 알린다.
  if [ "$bi_pre" -gt 0 ]; then
    _staged=$( { git -C "$proj" diff --cached --name-only 2>/dev/null
                 [ "$all_mode" -eq 0 ] || git -C "$proj" diff --name-only 2>/dev/null; } | LC_ALL=C sort -u)
    while IFS="$(printf '\t')" read -r _f _l; do
      [ -n "$_f" ] && [ "$_f" != "?" ] || continue
      if printf '%s\n' "$_staged" | grep -Fxq -- "$_f"; then
        bi_staged_pre="${bi_staged_pre}  - ${_f}:${_l}
"
      fi
    done < <(bi_locs pre_existing)
  fi
fi

# ── --result 판정(허용 목록) ─────────────────────────────────────────────────
if [ "$mode" = result ]; then
  ng_recorded && ng_reject "--result"

  set +e
  jq -e -s '
    length == 1
    and (.[0]
      | (.reviewComplete == true)
        and ((.lensStatus | type) == "array")
        and ((.lensStatus | length) > 0)
        and ((.lensStatus | map(.status) | all(. == "ok")))
        and ((.unverified | type) == "array")
        and ((.unverified | length) == 0)
        and ((.uncoveredFiles | type) == "array")
        and ((.uncoveredFiles | length) == 0))' "$result_file" >/dev/null 2>&1
  _jrc=$?
  set -e

  if [ "$_jrc" -ne 0 ]; then
    set +e
    detail=$(jq -r -s '
      if length != 1 then "JSON 값 개수=" + (length | tostring) + " (정확히 하나여야 합니다)"
      else .[0] |
      "reviewComplete=" + (.reviewComplete | tostring)
      + " / lensStatus=" + (if (.lensStatus | type) == "array" and (.lensStatus | length) > 0
                            then (.lensStatus | map(((.lens // "?") | tostring) + ":" + ((.status // "?") | tostring)) | join(","))
                            else (.lensStatus | tostring) end)
      + " / unverified=" + (if (.unverified | type) == "array" then (.unverified | length | tostring) else (.unverified | tostring) end)
      + " / uncoveredFiles=" + (if (.uncoveredFiles | type) == "array" then (.uncoveredFiles | map(tostring) | join(",")) else (.uncoveredFiles | tostring) end)
      end
    ' "$result_file" 2>/dev/null)
    set -e
    [ -n "$detail" ] || detail="(결과 JSON 을 읽지 못했습니다 — 파일 안이 JSON 값 하나뿐인지 확인하세요)"
    {
      echo "[리뷰 미완결] 마커를 찍지 않습니다: $result_file"
      echo "  $detail"
      echo "  통과 조건: reviewComplete=true · lensStatus 전부 status=ok(ok 밖 상태값의 정본 = .claude/workflows/commit-review.js) · unverified·uncoveredFiles 빈 배열."
      echo "  uncoveredFiles 가 있으면 그 파일을 읽는 관점으로 재실행하세요(lenses 에 그 파일 종류를 보는 관점을 넣고 stagedFiles 를 넘긴다). 그 밖에는 리뷰를 재실행하세요."
      echo "  결과를 '지적 0건'으로 읽지 마세요. 리뷰 자체가 불필요·불가한 변경이면 --skip-reason 으로 사유를 남기고 사용자에게 알리세요."
    } >&2
    invalidate_marker
    exit 1
  fi
fi

# ── 생략 사유 검증은 **마커를 쓰기 전에** ────────────────────────────────────
# 뒤에 두면 exit 1 로 거부해 놓고 마커는 이미 찍혀 있어, 사유가 기록되지 않은 채 커밋 게이트만
# 통과하는 상태가 남는다(2026-09-18 실측: `--skip-reason '   '` → rc=1 인데 .last-review 생성).
reason_1line=""
if [ "$mode" = skip ]; then
  # 로그는 한 줄 = 한 건. 줄바꿈·탭은 공백으로 접고 길이를 자른다(사유 문자열은 외부 입력이다).
  reason_1line=$(printf '%s' "$skip_reason" | tr '\n\r\t' '   ' | cut -c1-500)
  # 앞뒤 공백만 남은 사유는 사유가 아니다.
  case "$(printf '%s' "$reason_1line" | tr -d '[:space:]')" in
    "") echo "생략 사유가 비어 있습니다 — 마커를 찍지 않습니다." >&2; exit 1 ;;
  esac
fi

mkdir -p "$proj/.claude"
printf '%s %s\n' "$(date +%F)" "$hash" > "$marker"

case "$mode" in
  skip)
    printf '%s %s skip-reason: %s\n' "$(date +%FT%T%z)" "${hash:0:12}" "$reason_1line" >> "$mlog"
    echo "리뷰 마커 기록(생략 경로): $(date +%F) ${hash:0:12}… ($marker)"
    echo "⚠️ 리뷰 결과 파일 없이 마커를 찍었습니다 — 이 사실과 사유를 **사용자에게 알리세요**: ${reason_1line}"
    echo "   기록: $mlog" ;;
  builtin)
    drop_pending
    echo "리뷰 마커 기록(빌트인): $(date +%F) ${hash:0:12}… ($marker)"
    echo "   근거: 빌트인 결과 important 0 · nit ${bi_nit}건 · pre_existing ${bi_pre}건 — 이 건수를 사용자에게 보고하세요."
    if [ "$((bi_nit + bi_pre))" -eq 0 ]; then
      echo "⚠️ 빌트인 지적 0건 — 리뷰 실패와 구분되지 않으니 사용자에게 보고하세요."
    fi
    if [ -n "$bi_staged_pre" ]; then
      echo "   스테이징 경로에 붙은 pre_existing(막지 않음 — 이 변경과 관계있는지 확인):"
      printf '%s' "$bi_staged_pre"
    fi
    echo "   결과 파일은 삭제합니다: $_breal" ;;
  result)
    echo "리뷰 마커 기록: $(date +%F) ${hash:0:12}… ($marker)"
    echo "   근거: $result_file (reviewComplete=true · lensStatus 전부 ok · unverified 0 · uncoveredFiles 0)" ;;
esac
