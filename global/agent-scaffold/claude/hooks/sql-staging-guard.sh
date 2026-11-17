#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=차단
# 커밋 내용 게이트(층 A) — CLAUDE.md "SQL 커밋 금지"(untracked .sql 초안 스테이징 금지) 규칙의 강제화.
# git commit 시점에 인덱스를 검사해 '신규 추가(A)·복사(C)·이름 변경(R) — 새 경로가 생기는 상태' .sql 이 있으면 커밋을 deny 로 차단한다.
#   - A·C·R 만 대상(새 경로가 생기는 상태 전부 — 복사 감지 설정이면 C 로 나온다) → 팀이 이미 tracked 로 관리하는 정본 덤프(project_dump_*.sql 등) 수정(M)은 통과(예외).
#   - add 가 아니라 commit 을 게이트 지점으로: add 는 인덱스 확정 전이지만 commit 은 확정 후라 정확히 판정.
#   - 역할 = 층 A pre-commit 디스패처가 합성 PreToolUse 꼴 stdin 으로 부르는 게이트(호출부 조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`).
#     settings 의 PreToolUse(Bash)에 등록한 레포에서는 명령 문자열이 허용 형태(단독 커밋 — lib git_commit_call_form)일 때만 통과시킨 뒤 인덱스를 본다.
# 안전: git 부재·commit 아님·신규 .sql 없음 → 조용히 exit 0. PreToolUse 경로의 jq·판정기 부재·허용 형태 밖 커밋 호출 = deny(fail-closed).
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
    && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[SQL 커밋 가드] jq 가 없어 커밋 호출 형태를 판정할 수 없어 막습니다(jq 설치 후 재시도)."}}\n'
  exit 0
fi
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git commit 계열만 관여. 탐지 정규식은 공용 라이브러리로 일원화(붙임형 -C/path·공백-값형 --git-dir /x 포함).
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ "$_layer_a" -eq 1 ]; then   # 층 A — 현행 판정 그대로(합성 명령 `[<우회 변수>=1 ; ]git commit` 은 허용 형태 판정이면 막힐 꼴이다)
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_heredoc "$cmd")" commit || exit 0   # 히어독 판정 = lib 허용 목록 규칙
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
      jq -n --arg r "[SQL 커밋 가드] 허용 형태가 아닌 커밋 호출이라 막습니다. ${_guide} 사유: ${_why:-판정 불가}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0 ;;
  esac
fi

# 인덱스의 A·C·R·D 목록. diff 표시 설정(color·외부 diff·textconv)은 끈다 — 이름 목록이 설정에 흔들리지 않게.
#   -z(NUL 구분 — 상태\0경로\0, R·C 는 상태\0옛\0새\0)라 파일명 속 공백·개행·비ASCII 도 그대로 읽힌다
#   (core.quotepath=false 는 -z 가 없는 출력 형태 대비로 함께 둔다 — 비ASCII 경로가 8진 이스케이프로 나와 .sql 판정이 빗나가던 2026-08-05 감사 실측).
#   -M 으로 이름 변경을 짝지어 R 의 옛 경로를 안다.
# 차단 판정 = 새 경로가 생기는 A·C·R 중 새 경로가 .sql 인 것(대소문자 무시). D 는 안내문(되돌릴 경로)에만 쓴다.
_new=(); _old=(); _del=()
while IFS= read -r -d '' _st; do
  case "$_st" in
    R*|C*) IFS= read -r -d '' _o || break; IFS= read -r -d '' _f || break ;;
    *) IFS= read -r -d '' _f || break; _o="" ;;
  esac
  case "$(printf '%s' "$_f" | tr 'A-Z' 'a-z')" in
    *.sql)
      case "$_st" in
        D*) _del+=("$_f") ;;
        R*) _new+=("$_f"); _old+=("$_o") ;;
        *) _new+=("$_f") ;;
      esac ;;
  esac
done < <(git -C "$cwd" -c core.quotepath=false diff --cached --no-color --no-ext-diff --no-textconv -M --name-status -z --diff-filter=ACRD 2>/dev/null)
[ ${#_new[@]} -gt 0 ] || exit 0

# 되돌리기 안내(워킹트리는 그대로 두고 인덱스만) — 경로는 셸 인용(printf %q)으로 붙여 넣을 수 있게 낸다.
#   HEAD 가 있으면 restore --staged: 새 경로 + R 의 옛 경로(옛 경로의 삭제가 함께 커밋되지 않게) + 같은 인덱스의 .sql 삭제(D —
#   이름 변경이 유사도 미달로 삭제+추가로 갈라진 경우의 옛 경로일 수 있다). HEAD 가 없으면(첫 커밋 전) restore 가 실패하므로 rm --cached.
_q() { local a; for a in "$@"; do printf ' %q' "$a"; done; }
if git -C "$cwd" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  fix_line="  git restore --staged --$(_q "${_new[@]}" ${_old[@]+"${_old[@]}"} ${_del[@]+"${_del[@]}"})"
  [ ${#_del[@]} -gt 0 ] && fix_line="${fix_line}
  (D — 삭제로 스테이징된 .sql 도 함께 되돌립니다. 그 삭제가 의도한 것이면 그 경로는 빼세요.)"
else
  fix_line="  git rm --cached --$(_q "${_new[@]}")"
fi
reason="[SQL 커밋 가드] 신규 .sql 파일이 스테이징된 채 커밋하려 합니다(팀 규칙: untracked .sql 초안·시드는 커밋 금지). 워킹트리는 보존한 채 언스테이징 후 다시 커밋하세요(되돌리기와 커밋은 따로 호출):

${fix_line}

예외: 팀이 이미 tracked 로 관리하는 정본 덤프(.sql)의 수정(M)은 이 가드에 걸리지 않습니다. 정말 새 .sql 을 커밋해야 하는 상황이면 사용자 확인 후 진행하세요."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
