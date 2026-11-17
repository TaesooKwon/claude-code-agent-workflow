#!/usr/bin/env bash
# git-hooks-installed-guard.sh 회귀 테스트 — 임시 레포에서만 돈다(실레포 .git 무접촉).
#   이 파일 옆의 가드·lib/git-cmd.sh·git/ 디스패처와 ../scripts/install-git-hooks.sh 를 임시 레포의 .claude 로 복사해 쓴다.
# 사용: bash .claude/hooks/git-hooks-installed-guard.test.sh   (HOOKS_DIR_OVERRIDE=<훅 디렉터리> 로 다른 사본을 검사)
set -u
HD="${HOOKS_DIR_OVERRIDE:-$(cd "$(dirname "$0")" && pwd)}"
SD="$(cd "$HD/.." && pwd)/scripts"
for f in "$HD/git-hooks-installed-guard.sh" "$HD/lib/git-cmd.sh" "$HD/git/pre-commit" "$HD/git/pre-push" "$HD/git/pre-merge-commit" "$SD/install-git-hooks.sh"; do
  [ -f "$f" ] || { echo "전제 파일 없음: $f"; echo "Tests run: 0, Passed: 0, Failures: 1"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "jq 필요"; echo "Tests run: 0, Passed: 0, Failures: 1"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/installed-guard-test.XXXXXX") || { echo '임시 디렉터리 생성 실패 — 실행하지 않았다'; exit 2; }
T=$(cd "$T" && pwd -P) || exit 2
trap 'case "$T" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$T" ;; esac' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
run=0; pass=0
_ok() { run=$((run+1)); pass=$((pass+1)); echo "ok    $1"; }
_ng() { run=$((run+1)); echo "FAIL  $1${2:+ — $2}"; }

mkrepo() { # $1 이름 $2 = install|noinstall|noscript → 레포 경로
  local r="$T/$1"
  mkdir -p "$r"; git -C "$r" init -q
  mkdir -p "$r/.claude/hooks/lib" "$r/.claude/hooks/git" "$r/.claude/scripts"
  cp "$HD/git-hooks-installed-guard.sh" "$r/.claude/hooks/"; cp "$HD/lib/git-cmd.sh" "$r/.claude/hooks/lib/"
  cp "$HD/git/pre-commit" "$HD/git/pre-push" "$HD/git/pre-merge-commit" "$r/.claude/hooks/git/"
  [ "$2" = noscript ] || cp "$SD/install-git-hooks.sh" "$r/.claude/scripts/"
  printf '.claude/\n' >> "$r/.git/info/exclude"
  if [ "$2" = install ]; then (cd "$r" && bash .claude/scripts/install-git-hooks.sh >/dev/null 2>&1) || echo "   (설치 실패: $r)"; fi
  printf '%s' "$r"
}
# $1 기대(deny|allow) $2 이름 $3 레포(=CLAUDE_PROJECT_DIR) $4 명령 [$5 cwd] [$6 PATH] [$7 가드 경로]
_case() {
  local exp="$1" name="$2" proj="$3" c="$4" cwd="${5:-$3}" p="${6:-$PATH}" g="${7:-$3/.claude/hooks/git-hooks-installed-guard.sh}" out got
  out=$(jq -n --arg c "$c" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
        | (cd "$proj" && PATH="$p" CLAUDE_PROJECT_DIR="$proj" bash "$g") 2>/dev/null)
  if [ -z "$out" ]; then got=allow
  else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null) || got=invalid-json
  fi
  if [ "$got" = "$exp" ]; then _ok "$name"; else _ng "$name" "기대 $exp, 실제 ${got:-빈 값}"; fi
  LAST_OUT="$out"
}

echo "== 설치 여부 판정 =="
U=$(mkrepo uninst noinstall)
I=$(mkrepo inst install)
N=$(mkrepo noscript noscript)
_case deny  "미설치 레포에서 git commit → deny" "$U" "git commit -m x"
_case allow "설치 레포에서 git commit → 통과" "$I" "git commit -m x"
_case deny  "--check 스크립트 없음 → deny" "$N" "git commit -m x"
printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q '설치 스크립트 부재' \
  && _ok "스크립트 부재 사유를 싣는다" || _ng "스크립트 부재 사유를 싣는다"
_case allow "미설치 레포라도 비커밋 명령은 통과" "$U" "git status"
_case allow "미설치 레포라도 커밋 낱말 없는 명령은 통과" "$U" "ls -la"
_case deny  "래핑된 커밋(sh -c) → deny" "$U" "sh -c 'git commit -m x'"
_case deny  "전역 옵션 낀 커밋(git -c k=v commit) → deny" "$U" "git -c user.name=t commit -m x"
_case allow "문서 히어독 본문의 git commit 문구 → 통과" "$U" "cat > note.md <<'EOF'
git commit -m x
EOF"

echo "== 대상 레포를 명령 문자열로 추정하지 않는다(미설치 프로젝트 = 대상 무관 deny) =="
O=$(mkrepo other noinstall)
_case deny  "미설치 프로젝트: git -C <다른 레포> commit → deny" "$U" "git -C $O commit -m x"
_case deny  "미설치 프로젝트: cd <다른 레포> && git commit → deny" "$U" "cd $O && git commit -m x"
_case deny  "미설치 프로젝트: 입력 cwd 가 다른 레포여도 deny" "$U" "git commit -m x" "$O"
_case deny  "git -C \"\$X\"(변수 경로) commit → deny" "$U" 'git -C "$X" commit -m x'
mkdir -p "$U/sub"
_case deny  "상대 경로 cd sub && git commit → deny" "$U" "cd sub && git commit -m x"
_case deny  "cwd 가 다른 레포여도 git -C <이 프로젝트> 이면 deny" "$U" "git -C $U commit -m x" "$O"
# 반증(gate0 사냥)이 찾은 fail-open 형태 — 옛 판은 명령 안의 마지막 git -C·첫 cd 로 '남의 레포'를 오판해 통과시켰다.
_case deny  "A17 git -C <다른 레포> log && git commit → deny" "$U" "git -C $O log --oneline -1 && git commit -m x"
_case deny  "A18 git -C <다른 레포> status; git commit → deny" "$U" "git -C $O status; git commit -m x"
_case deny  "A19 cd <다른 레포> && git log; cd <이 프로젝트> && git commit → deny" "$U" "cd $O && git log -1; cd $U && git commit -m x"
_case deny  "A20 메시지 본문의 git -C <다른 레포> 문구 → deny" "$U" "git commit -m \"fix: see git -C $O for ref\""
_case deny  "A21 cd <다른 레포> && git status && cd - && git commit → deny" "$U" "cd $O && git status && cd - && git commit -m x"
_case deny  "A25 git commit && git -C <다른 레포> status → deny" "$U" "git commit -qm x && git -C $O status"
_case deny  "A30 cd <다른 레포>; cd <이 프로젝트>; git commit → deny" "$U" "cd $O; cd $U; git commit -m x"
_case deny  "M03 다줄 cd 다른 레포 → cd 이 프로젝트 → git commit → deny" "$U" $'cd '"$O"$'\ngit status\ncd '"$U"$'\ngit commit -m x'
# hunt3 종단 증명의 다섯 형태(그 스크립트의 명령 문자열 그대로)
_case deny  "hunt3 A17 → deny" "$U" "git -C $O log --oneline -1 && git commit -qm leak"
_case deny  "hunt3 A19 → deny" "$U" "cd $O && git log -1 >/dev/null; cd $U && git commit -qm leak"
_case deny  "hunt3 A21 → deny" "$U" "cd $O && git status >/dev/null && cd - >/dev/null && git commit -qm leak"
_case deny  "hunt3 A25 → deny" "$U" "git commit -qm leak && git -C $O status >/dev/null"
_case deny  "hunt3 M03 → deny" "$U" $'cd '"$O"$'\ngit status >/dev/null\ncd '"$U"$'\ngit commit -qm leak'
# 설치 프로젝트에선 같은 형태가 전부 통과(층 A 가 권위 — 가드는 아무것도 하지 않는다)
_case allow "설치 프로젝트: A17 형태 → 통과" "$I" "git -C $O log --oneline -1 && git commit -m x"
_case allow "설치 프로젝트: 미설치 레포 대상 git -C 커밋 → 통과" "$I" "git -C $O commit -m x"
_case allow "설치 프로젝트: cwd 가 미설치 레포 → 통과" "$I" "git commit -m x" "$O"
NG="$T/notgit"; mkdir -p "$NG/.claude/hooks/lib"; cp "$HD/git-hooks-installed-guard.sh" "$NG/.claude/hooks/"; cp "$HD/lib/git-cmd.sh" "$NG/.claude/hooks/lib/"
_case deny  "프로젝트가 아직 git 저장소가 아니면(.git 없음) deny" "$NG" "git commit -m x"
printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'git init 을 먼저 따로' \
  && _ok ".git 없음 사유에 git init → 설치 → 다음 호출 커밋 안내를 싣는다" || _ng ".git 없음 사유에 git init → 설치 → 다음 호출 커밋 안내를 싣는다"
# 반증(r2 사냥 N1d): .git 이 없을 때 init·add·commit 을 한 명령으로 — 옛 판은 '.git 없음 = 통과'라 첫 커밋이 게이트 없이 들어갔다
_case deny  "N1d git init && git add && git commit(한 명령) → deny" "$NG" "git init -q && git config commit.gpgsign false && git add README app.properties && git commit -qm init"
_case allow ".git 없음이라도 비커밋 명령(git init 단독)은 통과" "$NG" "git init -q"
[ ! -e "$NG/.git" ] && _ok "(전제) 가드 실행 뒤에도 NG 에 .git 이 없다(가드는 명령을 실행하지 않는다)" || _ng "(전제) NG 에 .git 이 생겼다"
# 반증(r3 델타 P1): 층 A 가 설치된 상위 레포 안의 .git 없는 하위 프로젝트 — 옛 판은 rev-parse 가 상위를 잡아 상위 --check 로 통과했다
NI="$I/nested-proj"; mkdir -p "$NI/.claude/hooks/lib"; cp "$HD/git-hooks-installed-guard.sh" "$NI/.claude/hooks/"; cp "$HD/lib/git-cmd.sh" "$NI/.claude/hooks/lib/"
[ "$(git -C "$NI" rev-parse --show-toplevel 2>/dev/null)" = "$I" ] && [ ! -e "$NI/.git" ] \
  && _ok "(전제) 하위 프로젝트에 .git 이 없고 rev-parse 는 층 A 설치 상위 레포를 잡는다" || _ng "(전제) 중첩 하위 프로젝트 준비 실패"
_case deny  "층 A 설치 상위 레포 안의 .git 없는 하위 프로젝트: git init && git add && git commit(한 명령) → deny" "$NI" "git init -q && git config commit.gpgsign false && git add README app.properties && git commit -qm init"
_case allow "층 A 설치 상위 레포 안의 .git 없는 하위 프로젝트: 비커밋 명령(git init 단독) → 통과" "$NI" "git init -q"
BG="$T/brokengit"; mkdir -p "$BG/.claude/hooks/lib"; cp "$HD/git-hooks-installed-guard.sh" "$BG/.claude/hooks/"; cp "$HD/lib/git-cmd.sh" "$BG/.claude/hooks/lib/"
printf 'gitdir: %s\n' "$T/없는-gitdir" > "$BG/.git"
_case deny  ".git 은 있는데 저장소 판정 실패 → deny" "$BG" "git commit -m x"

echo "== CLAUDE_PROJECT_DIR 없음 → 가드가 놓인 프로젝트로 판정 =="
_case_noenv() { # $1 기대 $2 이름 $3 가드가 놓인 프로젝트 $4 명령 $5 cwd(=입력 cwd·실행 위치)
  local out got
  out=$(jq -n --arg c "$4" --arg d "$5" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
        | (cd "$5" && env -u CLAUDE_PROJECT_DIR bash "$3/.claude/hooks/git-hooks-installed-guard.sh") 2>/dev/null)
  if [ -z "$out" ]; then got=allow; else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null) || got=invalid-json; fi
  if [ "$got" = "$1" ]; then _ok "$2"; else _ng "$2" "기대 $1, 실제 ${got:-빈 값}"; fi
}
_case_noenv deny  "env 없음 + 미설치 프로젝트의 가드 + cwd=설치 레포 → deny" "$U" "git commit -m x" "$I"
_case_noenv allow "env 없음 + 설치 프로젝트의 가드 + cwd=미설치 레포 → 통과" "$I" "git commit -m x" "$U"

echo "== linked worktree =="
_common_of_t() { (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P); }
env -u CLAUDECODE git -C "$I" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init   # 준비 커밋 = 사용자 터미널 흉내
git -C "$I" worktree add -q "$T/inst-wt" -b wt 2>/dev/null
[ -d "$T/inst-wt" ] && [ "$(_common_of_t "$T/inst-wt")" = "$(_common_of_t "$I")" ] && _ok "(전제) inst-wt 는 같은 레포의 linked worktree" || _ng "(전제) inst-wt 는 같은 레포의 linked worktree"
_case allow "설치 레포의 linked worktree 커밋 → 통과" "$I" "git commit -m x" "$T/inst-wt"
env -u CLAUDECODE git -C "$U" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init   # 준비 커밋 = 사용자 터미널 흉내
git -C "$U" worktree add -q "$T/uninst-wt" -b wt 2>/dev/null
[ -d "$T/uninst-wt" ] && [ "$(_common_of_t "$T/uninst-wt")" = "$(_common_of_t "$U")" ] && _ok "(전제) uninst-wt 는 같은 레포의 linked worktree" || _ng "(전제) uninst-wt 는 같은 레포의 linked worktree"
_case deny  "미설치 레포의 linked worktree 커밋 → deny" "$U" "git commit -m x" "$T/uninst-wt"
# .claude 는 git 격리라 worktree 에 사본이 없다 — 가드는 메인 트리 것을 부른다(PROJECT_DIR 만 worktree)
_case deny  "CLAUDE_PROJECT_DIR = 미설치 레포의 linked worktree → deny" "$T/uninst-wt" "git commit -m x" "$T/uninst-wt" "$PATH" "$U/.claude/hooks/git-hooks-installed-guard.sh"

echo "== 설치 뒤 무효화 =="
I2=$(mkrepo inst2 install)
gcd=$(git -C "$I2" rev-parse --path-format=absolute --git-common-dir)
_case allow "(전제) 설치 직후 통과" "$I2" "git commit -m x"
git -C "$I2" config core.hooksPath "$T/elsewhere"
_case deny  "설치 뒤 core.hooksPath 설정 → deny" "$I2" "git commit -m x"
git -C "$I2" config --unset core.hooksPath
chmod -x "$gcd/hooks/pre-commit"
_case deny  "스텁 실행 비트 없음 → deny" "$I2" "git commit -m x"
chmod +x "$gcd/hooks/pre-commit"; rm -f "$gcd/hooks/pre-push"
_case deny  "스텁 하나 삭제 → deny" "$I2" "git commit -m x"
(cd "$I2" && bash .claude/scripts/install-git-hooks.sh >/dev/null 2>&1)
rm -f "$I2/.claude/hooks/git/pre-commit"
_case deny  "디스패처 본문 부재 → deny" "$I2" "git commit -m x"
: > "$I2/.claude/hooks/git/pre-commit"   # 부재에서 이어서 — 0바이트 본문(쓰기 실패·잘림 꼴)
_case deny  "G6 디스패처 본문 0바이트 → deny" "$I2" "git commit -m x"

echo "== 도구·lib 부재 =="
NOJQ="$T/nojq-bin"; mkdir -p "$NOJQ"
for t in bash sh git cat grep sed head cut tr env dirname pwd mktemp; do
  p=$(command -v "$t") && ln -sf "$p" "$NOJQ/$t"
done
_case deny  "jq 부재 + 미설치 + 커밋 → deny(유효 JSON)" "$U" "git commit -m x" "$U" "$NOJQ"
_case allow "jq 부재 + 설치 레포 → 통과" "$I" "git commit -m x" "$I" "$NOJQ"
_case allow "jq 부재 + 커밋 낱말 없음 → 통과" "$U" "ls" "$U" "$NOJQ"
# 2026-11-06 결함 사냥 G5 — jq 부재 폴백은 JSON 이스케이프를 펴고 본다(개행·탭 뒤 git/commit)
_case deny  "G5 jq 부재 + 개행 뒤 커밋 → deny" "$U" "$(printf 'cd /tmp\ngit commit -m x')" "$U" "$NOJQ"
_case deny  "G5 jq 부재 + 탭 구분 커밋 → deny" "$U" "$(printf 'git\tcommit -m x')" "$U" "$NOJQ"
_case allow "G5 대조: jq 부재 + 개행 뒤 비커밋 → 통과" "$U" "$(printf 'cd /tmp\ngit status')" "$U" "$NOJQ"
NL="$T/nolib"; mkdir -p "$NL"; cp "$HD/git-hooks-installed-guard.sh" "$NL/"
_case deny  "lib 부재 + 미설치 + 커밋 → deny" "$U" "git commit -m x" "$U" "$PATH" "$NL/git-hooks-installed-guard.sh"
_case allow "lib 부재 + 비커밋 → 통과" "$U" "git status" "$U" "$PATH" "$NL/git-hooks-installed-guard.sh"

echo "Tests run: $run, Passed: $pass, Failures: $((run-pass))"
[ "$run" -gt 0 ] && [ "$pass" -eq "$run" ]
