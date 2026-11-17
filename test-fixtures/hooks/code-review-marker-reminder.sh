#!/usr/bin/env bash
# 커밋 내용 게이트(층 A — 호출부 조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`) — "커밋 전 코드리뷰" 게이트(**diff 지문 대조형**, 2026-08-05 강화).
#
# 통과 조건: `.claude/.last-review` 에 기록된 지문이 **지금 커밋될 diff 의 지문과 일치**할 때만.
#   구버전(당일 1회 넛지)은 날짜만 봐서 "오늘 아무 diff나 리뷰했으면 통과"였고,
#   다른 세션이 아침에 마커를 소진하면 그날 나머지 커밋이 전부 무검문 통과했다
#   (2026-08-05 실측: 07:54 소진 → 11시 커밋 통과, 리뷰 없이 14파일 커밋).
#
# 마커 기록 = `bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON>`
#              또는 `bash .claude/hooks/mark-review.sh --skip-reason "<사유>"` (리뷰 수행 직후 에이전트가 실행).
#   ※ 인자 없는 호출은 더 이상 마커를 찍지 않는다(mark-review.sh 가 fail-closed) — 안내 문구를 바꿀 때
#     이 주석과 아래 deny 문구를 같이 고칠 것(안내가 죽은 호출형을 가리키면 '시킨 대로 했는데 안 되는' 루프가 된다).
#   ※ 마커는 에이전트가 찍으므로 "리뷰했다는 증거"가 아니라 **리뷰 단계를 diff 단위로 강제**하는 장치다.
#     리뷰를 건너뛰고 마커만 찍는 우회는 막지 못한다(규율의 문제 — CLAUDE.md 규약이 정본).
#
# 안전: shasum 부재 · 비커밋 명령 · git 저장소 아님 · 스테이징 변경 없음 → 조용히 exit 0(fail-open).
#   PreToolUse 경로의 jq 부재·판정기 부재·허용 형태 밖 커밋 호출 = deny(fail-closed — 아래 분기). 층 A 경로의 도구 부재 판정은 디스패처 몫이다.
set -u

input=$(cat 2>/dev/null || true)
# 층 A(git pre-commit 디스패처)가 부른 호출인가 — GATE_LAYER=git 은 git 이 훅에 넘기는 GIT_INDEX_FILE 이 함께 있을 때만 믿는다
#   (PreToolUse 경로에서 환경변수 하나로 아래 허용 형태 판정을 건너뛰지 못하게).
# ponytail: GATE_LAYER·GIT_INDEX_FILE 은 환경 입력이다 — 둘 다 settings env 로 넣으면 형태 판정을 건너뛴다 /
#   업그레이드 = 층 A 설치(권위 = 실제 커밋 내용을 보는 git 훅)
_layer_a=0; [ "${GATE_LAYER:-}" = git ] && [ -n "${GIT_INDEX_FILE:-}" ] && _layer_a=1
if ! command -v jq >/dev/null 2>&1; then
  [ "$_layer_a" -eq 1 ] && exit 0   # 층 A — 종전 동작 그대로(도구 부재 판정은 층 A 디스패처 몫)
  # PreToolUse — 명령을 꺼낼 수 없다. 이스케이프를 공백으로 편 stdin 에 git·commit 낱말이 함께 보이면 차단(fail-closed).
  _flat=$(printf '%s' "$input" | sed -E 's/\\(u[0-9A-Fa-f]{4}|[\\"\/bfnrt])/ /g')
  printf '%s' "$_flat" | grep -qE '(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)' \
    && printf '%s' "$_flat" | grep -qE '(^|[^[:alnum:]_-])commit([^[:alnum:]_-]|$)' \
    && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[커밋 전 코드리뷰 게이트] jq 가 없어 커밋 호출 형태를 판정할 수 없어 막습니다(jq 설치 후 재시도)."}}\n'
  exit 0
fi

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git commit 계열만 관여(공용 라이브러리 — 다른 커밋 게이트와 같은 분기). 층 A 분기는 인용문(echo "git commit …")으로
# 발동하지 않도록 스트립본으로 판정하고, PreToolUse 분기는 허용 형태 판정기가 인용·히어독을 렉싱해 판정한다.
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ "$_layer_a" -eq 1 ]; then   # 층 A — 현행 판정 그대로(합성 명령 `[<우회 변수>=1 ; ]git commit` 은 허용 형태 판정이면 막힐 꼴이다)
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" commit || exit 0
else                             # PreToolUse — 허용 형태만(판정기 = lib/cmdform.py · 부재 시 lib 의 대체 판정)
  if [ -f "$_lib" ] && . "$_lib" && command -v git_commit_call_form >/dev/null 2>&1; then
    _form=$(git_commit_call_form "$cmd" "$cwd")
  else
    # ponytail: lib(또는 새 함수) 부재 창은 commit 낱말만 본다 — 커밋도, 낱말이 든 비커밋 호출도 막힌다 /
    #   업그레이드 = lib 선배치 배포 순서 준수(lib → 게이트)
    _form=NONE
    printf '%s' "$cmd" | tr -d '\042\047\134' | grep -Eq '(^|[^A-Za-z0-9_.-])commit(-tree)?([^A-Za-z0-9_.-]|$)' \
      && _form="DENY	판정기 부재(lib/git-cmd.sh — 복구 후 재시도)"
  fi
  case "$_form" in
    NONE) exit 0 ;;
    ALLOW) ;;
    *)
      _why=${_form#DENY}; _why=${_why#$'\t'}
      _guide=$(git_commit_form_guide 2>/dev/null) || _guide=""
      jq -n --arg r "[커밋 전 코드리뷰 게이트] 허용 형태가 아닌 커밋 호출이라 막습니다. ${_guide} 사유: ${_why:-판정 불가}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0 ;;
  esac
fi

_rlib="$(dirname "$0")/lib/review-diff.sh"
[ -f "$_rlib" ] && . "$_rlib" || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# ── 스코프 가드: **이 프로젝트의 커밋만** 검사한다 ────────────────────────────
# 이 훅은 세션 스코프라 다른 레포를 대상으로 한 `git commit` 에도 발동한다.
# 그때 proj(=이 프로젝트) 의 스테이징 지문으로 대조하면 **영원히 불일치**라 남의 레포 커밋을 못 하게 막는다
# (실측 2026-08-07: 개인 이식 킷 레포의 문서 커밋이 이 프로젝트 마커와 대조돼 차단됐다.
#  우회하려고 이 프로젝트 마커를 찍으면 미검토 diff 가 통과 처리돼 게이트 목적 자체가 깨진다).
# ⇒ 커밋 대상 레포를 판별해 이 프로젝트와 다르면 조용히 통과시킨다(그 레포는 그 레포의 게이트가 맡는다).
# 같은 레포 판정축 = git common dir(작업트리 최상위가 아니다) — linked worktree 는 최상위가 메인과 달라도 같은 레포다.
#   같은 레포면 지문·마커는 **커밋 대상 작업트리** 기준(<그 작업트리>/.claude/.last-review)으로 본다.
#   GIT_DIR·GIT_WORK_TREE 는 판정에서만 떼어 낸다 — git 이 worktree 훅에 GIT_DIR=<worktree gitdir> 를 넘기면
#   `git -C <아무 경로>` 가 전부 그 레포로 읽혀 남의 레포도 같은 레포로 보인다. 지문은 상속 env 그대로(실제 커밋될 인덱스).
_target_dir="$cwd"
# PreToolUse 경로는 대상 = cwd 고정이다 — 허용 형태가 `cd <cwd 와 같은 레포>` 만 인정하고 `git -C` 는 막는다.
if [ "$_layer_a" -eq 1 ]; then   # 층 A — 현행 그대로(합성 명령엔 -C·cd 가 없어 _gc·_cd 는 비고 대상은 cwd 다)
# `git -C <path> commit …` / 선행 `cd <path> && git commit …` 은 대상이 cwd 가 아니다.
_gc=$(printf '%s' "$cmd" | sed -n 's/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -1)
_cd=$(printf '%s' "$cmd" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}\([^&;|]\{1,\}\).*/\1/p' | head -1)
[ -n "$_cd" ] && _target_dir=$(printf '%s' "$_cd" | sed 's/[[:space:]]*$//' | sed "s|^~|$HOME|")
[ -n "$_gc" ] && _target_dir=$(printf '%s' "$_gc" | sed "s|^~|$HOME|")
fi

_common_of() { # $1=경로 → 그 경로가 속한 레포의 common dir(물리 경로). 판정 불가면 빈 출력.
  local _c
  _c=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$_c" ] && (cd "$_c" 2>/dev/null && pwd -P)
}
_gate_repo="$proj"   # 지문·마커 기준 작업트리(기본 = 이 프로젝트)
_wt_target=0
if [ -d "$_target_dir" ]; then
  _t_common=$(_common_of "$_target_dir")
  _p_common=$(_common_of "$proj")
  # 둘 다 확정됐고 서로 다르면 = 남의 레포 커밋 → 통과(하나라도 미확정이면 기존 경로 = 이 프로젝트 기준 검문).
  if [ -n "$_t_common" ] && [ -n "$_p_common" ] && [ "$_t_common" != "$_p_common" ]; then
    exit 0
  fi
  if [ -n "$_t_common" ] && [ "$_t_common" = "$_p_common" ]; then
    _t_top=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$_target_dir" rev-parse --show-toplevel 2>/dev/null)
    _p_top=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$proj" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$_t_top" ]; then
      _gate_repo="$_t_top"
      [ "$(cd "$_t_top" 2>/dev/null && pwd -P)" != "$(cd "${_p_top:-/nonexistent}" 2>/dev/null && pwd -P)" ] && _wt_target=1
    fi
  fi
fi
# ─────────────────────────────────────────────────────────────────────────────

# 지문 분기(review-diff.sh 의 -a 판정)에 넘길 명령 — PreToolUse 경로는 정규형 `git commit`(허용 형태가 -a 를 막으므로
#   의미 손실이 없고, 메시지 속 `-a` 낱말이 워킹트리 지문 분기를 건드리지 않는다). 층 A 는 원문 그대로.
_hash_cmd="git commit"; [ "$_layer_a" -eq 1 ] && _hash_cmd="$cmd"
cur=$(review_diff_hash "$_gate_repo" "$_hash_cmd") || exit 0   # rc1=저장소/도구 부재, rc2=검토할 변경 없음 → 통과
[ -n "$cur" ] || exit 0

marker="$_gate_repo/.claude/.last-review"
recorded=$(awk '{print $2}' "$marker" 2>/dev/null | head -1)
[ "$recorded" = "$cur" ] && exit 0

if [ -n "$recorded" ]; then
  detail="마커의 지문(${recorded:0:12}…)이 현재 커밋될 diff(${cur:0:12}…)와 다릅니다 — 리뷰 이후 코드가 바뀌었거나 다른 변경을 리뷰한 것입니다."
else
  detail="리뷰 마커가 없습니다."
fi

reason="[커밋 전 코드리뷰 게이트] ${detail} CLAUDE.md 규약: 스테이징을 확정한 뒤 **자체 리뷰 워크플로 1회**(finder 3~4 다각 → 적대적 verify, 스코프=스테이징 diff 한정·무관 dirty 제외 명시)를 돌리고, CONFIRMED 지적을 수정 → \`git add\` → 델타 재리뷰(템플릿 \`.claude/workflows/delta-review.md\`) → harness·단위테스트 재검증 → 리뷰 결과 JSON 을 파일로 저장한 뒤 \`bash .claude/hooks/mark-review.sh --result <그 JSON 파일>\` 로 마커를 찍고 커밋하세요(사용자 상시 지시라 별도 승인 불필요). **인자 없는 호출은 마커를 찍지 않습니다.** 리뷰 결과는 reviewComplete=true 일 때만 통과로 읽으세요 — confirmed 가 빈 배열이어도 lensStatus 에 status=ok 가 아닌 관점이 있거나(상태값 정본 = .claude/workflows/commit-review.js) uncoveredFiles 가 비어 있지 않으면 리뷰가 완결되지 않은 것이니 마커를 찍지 말고 재실행하세요 — uncoveredFiles 가 있으면 그 파일을 읽는 관점으로(mark-review.sh 가 그 조건을 검문해 거부합니다). 빌트인 code-review 스킬 자체는 호출 금지 — 그 결과가 필요하면 사용자에게 \`/code-review\` 실행을 요청하세요. 사용자가 리뷰 생략을 지시했거나 리뷰가 불필요한 변경(문서·설정만 등)이라면 \`bash .claude/hooks/mark-review.sh --skip-reason \"<사유>\"\` 로 사유를 남기고 진행하되, 그 판단과 사유를 사용자에게 알리세요."
if [ "$_wt_target" -eq 1 ]; then
  _mr="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/mark-review.sh"
  reason="${reason} [linked worktree 커밋] 이 커밋은 작업트리 ${_gate_repo} 의 인덱스로 검문하고 마커도 ${_gate_repo}/.claude/.last-review 에서 읽습니다 — 마커는 \`CLAUDE_PROJECT_DIR='${_gate_repo}' bash '${_mr}' --result <JSON>\`(또는 --skip-reason \"<사유>\")로 찍으세요."
fi

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
