#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=통과
# PreToolUse(Bash) 가드 — 병행 세션이 워킹트리·인덱스를 공유하는 레포에서 <b>일괄 스테이징</b>을 차단한다.
#   차단: git add -A / --all / -u / --update / . / :/  ,  git commit -a / --all(-am 등 묶음 플래그 포함)
#   통과: git add <명시 경로…>(파일·디렉터리), git add -p/-f <경로>, git commit --amend, 비 git 명령
# 왜: `git commit` 은 인덱스 전체를 가져간다. 한 세션이 `git add -A` 하면 다른 세션의 untracked·수정 파일이
#     그 커밋에 휩쓸린다(2026-09-02 병행 3세션 실측 — CLAUDE.md "병행 세션과 인덱스를 공유할 땐" 조항의 강제화).
# 안전: jq 부재·git add/commit 아님 → 조용히 exit 0(fail-open). 다른 Bash 호출 방해 금지.
# 예외: 단독 세션임을 확신하면 ALLOW_GIT_ADD_ALL=1 을 명령 앞에 붙인다.
# 한계: 따옴표 안의 문자열(echo "git add -A")도 잡는다 — 실검사형이 아니라 명령 텍스트 판정이라 보수적으로 둔다.
#       셸을 정규식으로 완전 파싱할 수는 없으므로 실수 방지용이지 의도적 우회 차단이 아니다(lib/git-cmd.sh 주석 참조).
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# 명시 예외
printf '%s' "$cmd" | grep -qE '(^|[;&| ])ALLOW_GIT_ADD_ALL=1([ ;&|]|$)' && exit 0

# 서브커맨드 탐지는 공용 라이브러리(전역옵션 -C /path·--git-dir 등 포함) — 세 커밋 가드와 같은 정규식.
_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0

hit=""
# 세그먼트(;|&) 단위로 본다 — 한 세그먼트에 add 와 commit 이 함께 올 수 없으므로 판정이 단순해진다.
# ⚠️ 끝에 개행을 붙인다 — 없으면 `read` 가 마지막 세그먼트에서 EOF 를 만나 루프 본문을 건너뛴다
#    (단일 명령 `git add -A` 가 통째로 통과하던 결함, 2026-09-02 반증검사에서 적발).
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  if git_has_subcommand "$seg" add; then
    rest=$(printf '%s' "$seg" | sed -E 's/.*[[:space:]]add([[:space:]]|$)//')
    # 종결자에 따옴표·괄호도 인정한다 — sh -c "git add -A" 처럼 래핑된 명령은 옵션 뒤가 공백이 아니라 따옴표다.
    if printf ' %s ' "$rest" | grep -qE '[[:space:]](-A|--all|-u|--update|--no-ignore-removal|\.|:/|:/\.)([[:space:]"'"'"')]|$)' \
       || printf '%s' "$rest" | grep -qE '(^|[[:space:]])-[a-zA-Z]*[Au][a-zA-Z]*([[:space:]"'"'"')]|$)'; then
      hit="$seg"; break
    fi
  fi
  if git_has_subcommand "$seg" commit; then
    rest=$(printf '%s' "$seg" | sed -E 's/.*[[:space:]]commit([[:space:]]|$)//')
    if printf ' %s ' "$rest" | grep -qE '[[:space:]]--all([[:space:]"'"'"')]|$)' \
       || printf '%s' "$rest" | grep -qE '(^|[[:space:]])-[a-zA-Z]*a[a-zA-Z]*([[:space:]"'"'"')]|$)'; then
      hit="$seg"; break
    fi
  fi
done < <(printf '%s\n' "$(git_strip_heredoc "$cmd")" | tr ';|&' '\n\n\n')   # 히어독 판정 = lib 허용 목록 규칙

[ -n "$hit" ] || exit 0

reason="[일괄 스테이징 가드] 이 레포는 병행 세션이 워킹트리·인덱스를 공유합니다. \`git add -A/--all/-u/.\`·\`git commit -a\` 는 다른 세션의 untracked·수정 파일을 내 커밋에 휩쓸어 넣습니다(git commit 은 인덱스 전체를 가져갑니다).

차단된 명령: ${hit}

내 변경분만 명시 경로로 올리세요: git add <파일|디렉터리> … (신규 디렉터리는 디렉터리 경로로). 커밋 직전 \`git status --short\` 로 인덱스에 남의 파일이 없는지 재확인하세요(commit-scope-staged-files-check).
단독 세션임을 확신하는 예외 상황이면 ALLOW_GIT_ADD_ALL=1 을 명령 앞에 붙여 다시 실행하세요."

reason="${reason}

※ 일괄 스테이징하려던 게 아니라 히어독 본문(<<EOF … EOF)의 문구 때문에 막힌 것이라면: 히어독 본문은 **데이터 싱크(cat·tee 등)가 문서·데이터 확장자 파일(.md·.txt·.json 등)로 쓸 때만** 판정에서 빠집니다 — 스크립트 파일로 쓰거나 파이프·인터프리터·ssh 로 넘기는 본문은 실행될 수 있어 그대로 판정합니다. 문서 확장자로 쓰거나 Write 도구로 파일을 쓰세요."
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
