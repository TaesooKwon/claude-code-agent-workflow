#!/usr/bin/env bash
# code-review-marker-reminder.sh 의 linked worktree 계약 테스트 — 층 A(git pre-commit 디스패처)로 **실제 커밋**을 쳐서 본다.
# 실행: bash .claude/hooks/code-review-marker-worktree.test.sh
#   HOOKS_BASE_DIR   = 임시 레포에 미러할 hooks 디렉터리(기본 = 이 파일이 있는 디렉터리)
#   HOOKS_DIR_OVERRIDE = 그 위에 덮을 파일들의 디렉터리(스테이징 사본 검증용, 선택)
#   SCRIPTS_DIR      = install-git-hooks.sh 가 있는 디렉터리(기본 = <hooks>/../scripts)
# 격리: 전부 mktemp 아래 임시 레포. 실레포·실 .git·실 마커는 건드리지 않는다.
# ⚠️ 커밋 명령 문구는 이 파일 안에만 둔다 — Bash 도구 명령줄에 직접 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${HOOKS_BASE_DIR:-$HERE}"
SCRIPTS="${SCRIPTS_DIR:-$BASE/../scripts}"
for t in git jq shasum python3; do command -v "$t" >/dev/null 2>&1 || { echo "전제 도구 없음($t) — 실행하지 않았다"; exit 2; }; done
[ -f "$BASE/git/pre-commit" ] && [ -f "$SCRIPTS/install-git-hooks.sh" ] || { echo "디스패처·설치 스크립트 없음 — 실행하지 않았다"; exit 2; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE CLAUDE_PROJECT_DIR ALLOW_TEST_COUNT_DROP ALLOW_UNTESTED_COMMIT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/crm-wt-test.XXXXXX") || exit 2
trap 'case "$WORK" in /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$WORK" ;; esac' EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"; mkdir -p "$HOME"
run=0; passed=0
_ok() { run=$((run + 1)); if [ "$2" = 0 ]; then passed=$((passed + 1)); echo "ok    $1"; else echo "FAIL  $1${3:+ — $3}"; fi; }

M="$WORK/main"; mkdir -p "$M"; git -C "$M" init -q
git -C "$M" config user.name t; git -C "$M" config user.email t@example.invalid; git -C "$M" config commit.gpgsign false
mkdir -p "$M/.claude/scripts"; cp -R "$BASE" "$M/.claude/hooks"
if [ -n "${HOOKS_DIR_OVERRIDE:-}" ]; then
  (cd "$HOOKS_DIR_OVERRIDE" && find . -type f -name '*.sh' ! -name '*.test.sh' -print0 | while IFS= read -r -d '' f; do
    mkdir -p "$M/.claude/hooks/$(dirname "$f")" && cp -p "$f" "$M/.claude/hooks/$f"; done)
fi
cp -p "$SCRIPTS/install-git-hooks.sh" "$M/.claude/scripts/"
rm -f "$M/.claude/.last-review"
printf '.claude/\n' > "$M/.git/info/exclude"
printf 'x\n' > "$M/README"; git -C "$M" add README; env -u CLAUDECODE git -C "$M" commit -qm init
(cd "$M" && bash .claude/scripts/install-git-hooks.sh >/dev/null) || { echo "설치 실패 — 실행하지 않았다"; exit 2; }
WT="$WORK/wt"; git -C "$M" worktree add -q "$WT" -b wtb >/dev/null 2>&1 || { echo "worktree 생성 실패"; exit 2; }
MR="$M/.claude/hooks/mark-review.sh"
GATE="$M/.claude/hooks/code-review-marker-reminder.sh"

_commit() { # $1=작업트리 → rc(0 통과 / 1 거부). stderr 는 $ERR 에.
  ERR=$(cd "$1" && CLAUDECODE=1 git commit -qm t 2>&1 >/dev/null); [ $? -eq 0 ] && return 0 || return 1
}
_blocked_by_review() { printf '%s' "$ERR" | grep -qF '[커밋 전 코드리뷰 게이트]'; }

echo "== linked worktree 커밋 =="
printf 'plain wt\n' > "$WT/p.txt"; git -C "$WT" add p.txt
_commit "$WT"; rc=$?
_ok "T1 worktree 커밋 + 마커 없음 → 리뷰 게이트 차단" "$([ $rc = 1 ] && _blocked_by_review; echo $?)" "rc=$rc"
WT_P=$(cd "$WT" && pwd -P)
_ok "T4 worktree 거부 안내에 worktree 마커 레시피" "$(printf '%s' "$ERR" | grep -qE "CLAUDE_PROJECT_DIR='($WT|$WT_P)'"; echo $?)" "$(printf '%s' "$ERR" | grep -o 'CLAUDE_PROJECT_DIR=[^ ]*' | head -1)"
for _m in --begin --builtin --skip-reason; do
  _ok "T4b worktree 거부 안내의 ${_m} 도 CLAUDE_PROJECT_DIR 전체 호출형" "$(printf '%s' "$ERR" | grep -qE "CLAUDE_PROJECT_DIR='($WT|$WT_P)' bash '[^']+' ${_m}"; echo $?)"
done

printf 'plain main\n' > "$M/q.txt"; git -C "$M" add q.txt
CLAUDE_PROJECT_DIR="$M" bash "$MR" --skip-reason test >/dev/null 2>&1
_ok "(전제) 메인 트리 마커 기록됨" "$([ -s "$M/.claude/.last-review" ]; echo $?)"
printf 'plain wt2\n' > "$WT/p2.txt"; git -C "$WT" add p2.txt   # T1 이 (결함으로) 통과했어도 스테이징이 남게
_commit "$WT"; rc=$?
_ok "T2 worktree 커밋 + 메인 트리 마커(다른 diff) → 차단" "$([ $rc = 1 ] && _blocked_by_review; echo $?)" "rc=$rc"

printf 'plain wt3\n' > "$WT/p3.txt"; git -C "$WT" add p3.txt
main_marker_before=$(cat "$M/.claude/.last-review")
CLAUDE_PROJECT_DIR="$WT" bash "$MR" --skip-reason test >/dev/null 2>&1
_ok "(전제) 레시피 마커 = worktree 쪽 파일, 메인 마커 불변" "$([ -s "$WT/.claude/.last-review" ] && [ "$(cat "$M/.claude/.last-review")" = "$main_marker_before" ]; echo $?)"
_commit "$WT"; rc=$?
_ok "T3 worktree 커밋 + 안내대로 찍은 worktree 마커 → 통과" "$([ $rc = 0 ]; echo $?)" "rc=$rc $(printf '%s' "$ERR" | head -1 | cut -c1-120)"

echo "== 메인 트리(대조) =="
_commit "$M"; rc=$?
_ok "T6 메인 트리 커밋 + 메인 마커 → 통과" "$([ $rc = 0 ]; echo $?)" "rc=$rc $(printf '%s' "$ERR" | head -1 | cut -c1-120)"
printf 'plain main2\n' > "$M/q2.txt"; git -C "$M" add q2.txt
cp "$WT/.claude/.last-review" "$M/.claude/.last-review"
_commit "$M"; rc=$?
_ok "T7 메인 트리 커밋 + 다른 diff 의 마커 → 차단" "$([ $rc = 1 ] && _blocked_by_review; echo $?)" "rc=$rc"
_ok "T5 메인 트리 거부 안내엔 worktree 문구 없음" "$(! printf '%s' "$ERR" | grep -qF 'linked worktree 커밋'; echo $?)"

echo "== 남의 레포(PreToolUse 형 stdin) =="
O="$WORK/other"; mkdir -p "$O"; git -C "$O" init -q
printf 'o\n' > "$O/o.txt"; git -C "$O" add o.txt
_in() { jq -cn --arg c "git -C $O commit -m x" --arg d "$M" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'; }
# 킷 가드 v2(2026-11-11) 계약 변경 — PreToolUse 경로는 허용 형태(단독 커밋)만 통과: `git -C <남의 레포> commit` 은
#   대상 추정 없이 deny 하고 "그 레포를 연 세션에서" 를 안내한다. 남의 레포 판정(_gc)은 층 A 분기에만 남아 T8b·T9b 가 본다.
_form_denied() { printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
  && printf '%s' "$1" | grep -qF '그 레포(작업트리)를 연 세션'; }
out=$(_in | CLAUDE_PROJECT_DIR="$M" bash "$GATE" 2>/dev/null)
_ok "T8 PreToolUse: 남의 레포 git -C 커밋 → 허용 형태 밖 deny(그 세션 안내)" "$(_form_denied "$out"; echo $?)" "out=$(printf '%s' "$out" | cut -c1-80)"
printf 'plain wt4\n' > "$WT/p4.txt"; git -C "$WT" add p4.txt   # GIT_DIR 쪽 레포에 검문할 변경이 있어야 오판이 deny 로 드러난다
out=$(_in | env GIT_DIR="$M/.git/worktrees/wt" CLAUDE_PROJECT_DIR="$M" bash "$GATE" 2>/dev/null)
_ok "T9 PreToolUse: GIT_DIR 상속 상태의 남의 레포 git -C 커밋 → 허용 형태 밖 deny" "$(_form_denied "$out"; echo $?)" "out=$(printf '%s' "$out" | cut -c1-80)"
out=$(_in | env GATE_LAYER=git GIT_INDEX_FILE="$M/.git/index" CLAUDE_PROJECT_DIR="$M" bash "$GATE" 2>/dev/null)
_ok "T8b 층 A 분기(GATE_LAYER=git + GIT_INDEX_FILE): 남의 레포 커밋 → 무출력 통과(현행 판정)" "$([ -z "$out" ]; echo $?)" "out=$(printf '%s' "$out" | cut -c1-80)"
out=$(_in | env GIT_DIR="$M/.git/worktrees/wt" GATE_LAYER=git GIT_INDEX_FILE="$M/.git/index" CLAUDE_PROJECT_DIR="$M" bash "$GATE" 2>/dev/null)
_ok "T9b 층 A 분기: GIT_DIR 상속 상태에서도 남의 레포 판정 유지" "$([ -z "$out" ]; echo $?)" "out=$(printf '%s' "$out" | cut -c1-80)"
out=$(_in | env GATE_LAYER=git CLAUDE_PROJECT_DIR="$M" bash "$GATE" 2>/dev/null)
_ok "T10 GATE_LAYER=git 위조(GIT_INDEX_FILE 없음) → PreToolUse 판정(deny)" "$(_form_denied "$out"; echo $?)" "out=$(printf '%s' "$out" | cut -c1-80)"

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -gt 0 ] || { echo "실행된 단언 0 — 미실행은 통과가 아니다"; exit 2; }
[ "$run" -eq "$passed" ]
