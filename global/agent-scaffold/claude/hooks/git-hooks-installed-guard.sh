#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=차단
# PreToolUse(Bash) — 층 A(git 훅) 미설치·무효 프로젝트의 에이전트 커밋을 막는 fail-closed 보조 가드. 우회 변수 없음.
#   커밋 내용 게이트는 층 A 의 pre-commit 디스패처가 부르는 역할이다(조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`)
#   → 층 A 가 없으면 에이전트 커밋은 게이트 없이 통과한다. 이 가드가 막는 것 = 그 '설치 누락'. 커밋 내용은 보지 않는다(권위 = 층 A).
# 판정 축 = 이 프로젝트(CLAUDE_PROJECT_DIR — 없으면 이 파일이 놓인 프로젝트)의 층 A 설치 상태.
#   명령 문자열로 대상 레포를 추정하지 않는다(`git -C`·`cd` 는 복합 명령·메시지 본문으로 위조된다).
#   `git commit` 으로 보이는 명령이면 이 프로젝트에서 `.claude/scripts/install-git-hooks.sh --check` 를 돌린다:
#   rc 0 = 통과(층 A 가 권위 — 이 가드는 아무것도 하지 않는다) / 그 밖(스크립트 부재·rc≠0·점검 실행 불가) = deny.
#   층 A 가 없는 동안은 커밋 대상이 다른 레포여도 막는다(설치하면 풀린다).
#   이 프로젝트 디렉터리에 .git 항목이 없으면 deny — 층 A 가 설치된 상위 레포 안에 놓여 있어도 같다('지킬 것 없음'이 아니라 '층 A 설치 전'.
#   같은 명령 안의 git init 뒤 첫 커밋이 게이트 없이 들어가는 형태를 막는다). .git 이 있는데 판정이 안 되어도 deny.
# fail-closed: jq 부재 → stdin 원문(JSON 이스케이프 \n·\t·\r·\"·\\·\/·\b·\f·\uXXXX 를 공백으로 편 사본)에
#   git·commit 낱말이 함께 보이면 커밋으로 본다(펴지 않으면 `\ngit` 의 n 이 낱말 경계를 지워 놓친다).
#   lib/git-cmd.sh 부재 → 명령에 git·commit 낱말이 함께 보이면 커밋으로 본다. 오탐은 감수한다(설치하면 사라진다).
# 사용자 터미널은 무관하다 — 이 훅은 에이전트의 Bash 도구 호출에만 걸린다.
# ponytail: 커밋 탐지는 명령 문자열 판정이다 — 저장 별칭(git config alias.ci commit)·변수 조립·스크립트 파일 안 커밋·
#   다음 호출에서 실행은 못 본다 / 업그레이드 경로 없음: 권위는 층 A, 설치 뒤 무효화는 git-hooks-check(SessionStart)와 우회 가드가 맡는다.
# ponytail: commit 밖에서 커밋을 만드는 하위 명령(merge·pull·revert·cherry-pick·rebase·am)은 보지 않는다 /
#   업그레이드 = 그 하위 명령도 같은 판정에 넣는다.
# ponytail: 오탐(층 A 미설치 프로젝트에서만) — 따옴표 안 문구(echo·grep·gh --body 의 'git commit')와 commit-tree 도 커밋으로 본다,
#   jq 부재 모드는 stdin 전체(description 포함)를 낱말로 본다 / 업그레이드 = 따옴표 인자를 걷어 낸 판정.
# ponytail: --check 는 메인 작업트리의 설정을 읽는다 — extensions.worktreeConfig 로 linked worktree 에만 건
#   훅 경로 설정(`git config --worktree`)은 못 본다 / 업그레이드 = 입력 cwd 가 같은 레포의 worktree 면 그 자리 설정도 조회.
# ponytail: 커밋 탐지는 lib git_has_subcommand 에 맡긴다 — 따옴표·역슬래시로 감싼 하위 명령(git "commit"·git com\mit)은
#   lib 가 commit 으로 읽지 않아 미설치 프로젝트에서도 통과한다 / 업그레이드 = lib 가 셸 인용을 풀어 하위 명령을 읽는다(공유 lib — 그 소비자 가드와 함께).
# ponytail: separate-git-dir(.git 이 gitfile 이고 저장소가 작업트리 밖) 프로젝트는 common dir/.. 가 작업트리가 아니라
#   설치 스크립트를 찾지 못해 커밋을 계속 deny 한다(오탐 — fail-closed) / 업그레이드 = rev-parse --show-toplevel 로 작업트리를 잡는다.
# ponytail: 프로젝트 디렉터리(CLAUDE_PROJECT_DIR)에 .git 항목이 없으면 상위 레포에 층 A 가 있어도 deny 한다 — 레포 하위 디렉터리를
#   프로젝트로 연 세션의 커밋도 막힌다(오탐 — fail-closed, 중첩 저장소 첫 커밋과 구별 불가) / 업그레이드 = 레포 루트에서 세션을 연다.
# ponytail: 등록 timeout 을 넘겼을 때의 처리는 하네스 몫이다(미확인) / 업그레이드 = --check 를 파일 검사만으로 줄인 내장 점검.
set -u

input=$(cat 2>/dev/null || true)

_deny() { # $1 = 사유 한 줄(경로·설정 이름 수준)
  local why r
  why=$(printf '%s\n' "$1" | head -n 1 | LC_ALL=C tr -d '\000-\010\013-\037\177"\\' | cut -c1-300)
  r="[층 A git 훅 미설치·무효] 이 프로젝트는 커밋 내용 게이트(git pre-commit 층)가 깔려 있지 않아 에이전트 커밋을 막습니다(커밋 대상 레포와 무관). 사유: ${why:-(점검 출력 없음)} 조치: 이 프로젝트 루트에서 bash .claude/scripts/install-git-hooks.sh 를 실행한 뒤 --check 가 rc 0 인지 확인하고 다시 커밋하세요(core.hooksPath·남의 훅·깨진 링크가 사유면 그 원인을 사용자와 먼저 정리). 커밋은 일어나지 않았습니다."
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg r "$r" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$r"
  fi
  exit 0
}

_words_commit() { # $1 = 문자열 → git 과 commit 이 낱말로 함께 보이면 rc 0
  printf '%s' "$1" | grep -qE '(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)' \
    && printf '%s' "$1" | grep -qE '(^|[^[:alnum:]_-])commit([^[:alnum:]_-]|$)'
}

# ① 커밋으로 보이는가(아니면 즉시 통과 — 점검 비용을 커밋 호출에만 쓴다)
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || exit 0
  _lib="$(dirname "$0")/lib/git-cmd.sh"
  if [ -f "$_lib" ] && . "$_lib" && command -v git_has_subcommand >/dev/null 2>&1 && command -v git_strip_heredoc >/dev/null 2>&1; then
    git_has_subcommand "$(git_strip_heredoc "$cmd")" commit || exit 0
  else
    _words_commit "$cmd" || exit 0
  fi
else
  # 이스케이프는 앞에서부터 한 번에 짝짓는다(\\\\ 를 먼저 소비해 `\\\\n` 을 개행으로 오인하지 않는다).
  _words_commit "$(printf '%s' "$input" | sed -E 's/\\(u[0-9A-Fa-f]{4}|[\\"\/bfnrt])/ /g')" || exit 0
fi

# ② 이 프로젝트의 층 A 설치 상태(명령 문자열·입력 cwd 는 쓰지 않는다)
proj="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$proj" ]; then
  proj=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd -P) || _deny "프로젝트 경로 판정 실패"
fi
[ -d "$proj" ] || _deny "프로젝트 경로가 디렉터리가 아님"
# .git 부재는 rev-parse 보다 먼저 직접 본다 — rev-parse 는 상위 디렉터리로 올라가 감싸는 레포를 잡으므로,
# 그 결과로 판정하면 '층 A 설치 상위 레포 안의 .git 없는 프로젝트'가 상위의 --check 로 통과한다(같은 명령의 git init 이 만든 중첩 저장소 첫 커밋 = 게이트 0).
if [ ! -e "$proj/.git" ] && [ ! -L "$proj/.git" ]; then
  # 아직 git 저장소가 아니다 = 층 A 설치 전(같은 명령의 git init 뒤 첫 커밋도 여기서 막는다)
  _deny "이 프로젝트에 .git 이 없음(층 A 설치 전). git init 을 먼저 따로 실행하고 install-git-hooks.sh 설치·--check rc 0 을 확인한 뒤 다음 호출에서 커밋"
fi
_p_common=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$proj" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ -n "$_p_common" ] || _deny "git common dir 판정 실패(.git 은 있음)"
_main_top=$(cd "$_p_common/.." 2>/dev/null && pwd -P) || _deny "메인 작업트리 경로 판정 실패"
chk="$_main_top/.claude/scripts/install-git-hooks.sh"
[ -f "$chk" ] || _deny "설치 스크립트 부재: .claude/scripts/install-git-hooks.sh"
err=$(cd "$_main_top" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE bash "$chk" --check 2>&1 >/dev/null) && exit 0
_deny "${err:-install-git-hooks.sh --check 실패}"
