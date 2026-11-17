#!/usr/bin/env bash
# mirror-history.sh 자체검사.
# 실행: bash mirror-history.test.sh   (사본 검증: HOOKS_DIR_OVERRIDE=<사본 디렉터리> bash mirror-history.test.sh)
#
# 샌드박스 HOME 을 mktemp 로 만들어 그 아래에 memory 원본·미러 git 레포를 꾸미고, 실물 훅에 PostToolUse stdin JSON 을
# 먹인다. 실제 ~/.claude 는 건드리지 않는다(HOME 을 샌드박스로 덮어쓴다). 정리는 trap EXIT.
# 잠금 = 잠금 파일(LOCKF)의 flock. 잠금 상태 판정은 python3 로 LOCK_NB 를 시도해 본다(lock_free).
set -u

HOOK="${HOOKS_DIR_OVERRIDE:-$(cd "$(dirname "$0")" && pwd)}/mirror-history.sh"
[ -f "$HOOK" ] || { echo "선행조건 실패: $HOOK 없음"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "선행조건 실패: python3 없음(잠금 판정용)"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/mirror-hist-XXXXXX") || exit 1
trap 'chmod -R u+rwx "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1
unset MIRROR_PUSH
# 자격증명 제외 계약은 env 로 주입한다(킷 훅의 기본값은 비어 있다 — 레포마다 등재).
export MIRROR_MEMORY_EXCLUDE=verify-login.md

run=0; pass=0
check() { # 설명 조건결과(0=참)
  run=$((run + 1))
  if [ "$2" = "0" ]; then pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s\n' "$1"; fi
}

# 새 HOME 하나 = 사례 하나. 전역 H·MEM·DEST·PROJ·LOCKF·OLDL 을 세팅한다.
fresh() {
  H="$SANDBOX/h$1"; mkdir -p "$H"
  MEM="$H/.claude/projects/{{ENCODED_CWD}}/memory"
  DEST="$H/.claude/history-backups/{{PROJECT_NAME}}"
  PROJ="$H/proj"
  LOCKF="$H/.claude/history-backups/.{{PROJECT_NAME}}.mirror.flock"   # 수리판 잠금 파일
  OLDL="$H/.claude/history-backups/.{{PROJECT_NAME}}.mirror.lock"      # 다른 판(mkdir 잠금 구현)이 남겼을 수 있는 잠금 디렉터리 자리
  mkdir -p "$MEM/online/.obsidian" "$MEM/.obsidian" "$DEST" "$PROJ/docs"
  for i in $(seq 1 40); do printf 'note %s\n' "$i" > "$MEM/n$i.md"; done
  echo idx > "$MEM/MEMORY.md"
  echo secret > "$MEM/verify-login.md"
  echo nested-secret > "$MEM/online/verify-login.md"
  echo '{}' > "$MEM/.obsidian/app.json"
  echo w > "$MEM/online/w.md"
  git -C "$DEST" init -q
}
hook() { # file_path
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" >/dev/null 2>&1
}
# 잠금이 비었는가 — 다른 판(mkdir 잠금 구현)의 잠금 디렉터리가 없고, 잠금 파일이 없거나 flock 을 바로 얻을 수 있으면 0
lock_free() {
  [ -d "$OLDL" ] && return 1
  [ -e "$LOCKF" ] || return 0
  python3 -I -c 'import fcntl,os,sys
fd=os.open(sys.argv[1],os.O_RDONLY)
try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: sys.exit(1)' "$LOCKF" 2>/dev/null
}
settle() { # 백그라운드 커밋 종료 대기(잠금·index.lock 해제 + 워크트리 깨끗)
  for _ in $(seq 1 150); do
    if lock_free \
       && [ ! -e "$DEST/.git/index.lock" ] \
       && [ -z "$(git -C "$DEST" status --porcelain 2>/dev/null)" ]; then
      sleep 0.3
      [ -z "$(git -C "$DEST" status --porcelain 2>/dev/null)" ] && [ ! -e "$DEST/.git/index.lock" ] && return 0
    fi
    sleep 0.1
  done
  # 직전 백그라운드 커밋이 index.lock 경합으로 실패한 경우 등 — 마지막 상태를 한 번 기록해 둔다
  git -C "$DEST" add -A >/dev/null 2>&1; git -C "$DEST" commit -qm settle >/dev/null 2>&1
  return 0
}
hist() { git -C "$DEST" log --all --pretty=format: --name-only 2>/dev/null | sort -u; }
# 미러·형제 경로의 잔여물(미러 본체와 수리판 잠금 파일은 상주가 정상이라 뺀다)
leftovers() { ls -A "$H/.claude/history-backups" | grep -v -e '^{{PROJECT_NAME}}$' -e '^\.{{PROJECT_NAME}}\.mirror\.flock$'; }
# 훅 stdout 이 사용자(systemMessage)·모델(additionalContext) 양쪽에 [mirror-history] 알림을 싣는가
notice_ok() {
  jq -e -s 'length >= 1 and all(.[]; (.systemMessage | startswith("[mirror-history]"))
    and .hookSpecificOutput.hookEventName == "PostToolUse"
    and (.hookSpecificOutput.additionalContext | startswith("[mirror-history]")))' "$1" >/dev/null 2>&1
}
kill_tree() { # 신호 pid — 자손부터 깊이 우선으로
  for _c in $(pgrep -P "$2" 2>/dev/null); do kill_tree "$1" "$_c"; done
  kill "-$1" "$2" 2>/dev/null
}

echo "== T1 단일 실행 — 동기화 내용 = 원본 − 제외 대상 (깨질 이름: sync_equals_source_minus_exclude)"
fresh 1; hook "$MEM/n1.md"; settle
exp=$(cd "$MEM" && find . -type f ! -name verify-login.md | sort)
act=$( [ -d "$DEST/memory" ] && cd "$DEST/memory" && find . -type f | sort)
[ "$exp" = "$act" ]; check "sync_equals_source_minus_exclude" $?

echo "== T2 하위 디렉터리의 제외 대상도 트리·이력에 없음 (깨질 이름: exclude_applies_at_any_depth)"
[ -z "$(find "$DEST" -path "$DEST/.git" -prune -o -name verify-login.md -print)" ] && ! hist | grep -q 'verify-login\.md'
check "exclude_applies_at_any_depth" $?

echo "== T3 원본 삭제가 미러에 전파 (깨질 이름: deletion_propagates)"
rm "$MEM/n2.md"; hook "$MEM/n1.md"; settle
[ ! -e "$DEST/memory/n2.md" ] && [ -e "$DEST/memory/n1.md" ]; check "deletion_propagates" $?

echo "== T4 병행 실행 — memory/memory 중첩·제외 파일이 트리·이력에 없음 (깨질 이름: concurrent_no_nesting, concurrent_no_exclude_leak, concurrent_final_tree_equals_source)"
fresh 4
for r in 1 2 3 4 5; do
  for k in $(seq 1 12); do hook "$MEM/n$k.md" & done; wait
done
settle
{ [ ! -e "$DEST/memory/memory" ] && ! hist | grep -q '^memory/memory/'; }; check "concurrent_no_nesting" $?
! hist | grep -q 'verify-login\.md'; check "concurrent_no_exclude_leak" $?
exp=$(cd "$MEM" && find . -type f ! -name verify-login.md | sort)
act=$( [ -d "$DEST/memory" ] && cd "$DEST/memory" && find . -type f | sort)
[ "$exp" = "$act" ]; check "concurrent_final_tree_equals_source" $?

echo "== T5 복사 실패 시 기존 백업 보존 + 알림 (깨질 이름: copy_failure_keeps_previous_backup, copy_failure_notice)"
fresh 5; hook "$MEM/n1.md"; settle
chmod 000 "$MEM/n3.md"
printf '{"tool_input":{"file_path":"%s"}}' "$MEM/n1.md" | HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" >"$H/out5" 2>/dev/null; settle
chmod 644 "$MEM/n3.md"
[ "$(cat "$DEST/memory/n3.md" 2>/dev/null)" = "note 3" ]; check "copy_failure_keeps_previous_backup" $?
notice_ok "$H/out5"; check "copy_failure_notice" $?

echo "== T6 file_path 의 .. 경로로 다른 디렉터리를 끌어오지 않음 (깨질 이름: traversal_not_mirrored)"
fresh 6; mkdir -p "$H/.claude/evil/memory"; echo pwn > "$H/.claude/evil/memory/pwn.md"
hook "$MEM/../../../evil/memory/pwn.md"; settle
[ ! -e "$DEST/memory/pwn.md" ]; check "traversal_not_mirrored" $?

echo "== T7 작업로그 미러 + 무관 경로 무시 + 잔여물 없음 (깨질 이름: history_mirrored, unrelated_ignored, no_leftovers)"
fresh 7; echo log1 > "$PROJ/docs/agent_history.md"; hook "$PROJ/docs/agent_history.md"; settle
[ "$(cat "$DEST/agent_history.md" 2>/dev/null)" = "log1" ]; check "history_mirrored" $?
hook "$PROJ/other.md"; settle
[ ! -e "$DEST/memory" ]; check "unrelated_ignored" $?
[ -z "$(leftovers)" ]; check "no_leftovers" $?

# ---- 잠금 실물 검증용 shim: PATH 앞에 두면 cp·git 호출마다 임계 구역 진입을 기록하고 겹침을 적는다 ----
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
REAL_GIT=$(command -v git)
cat > "$SHIM/cp" <<'EOS'
#!/bin/bash
n=${0##*/}
case "$n" in cp) real=/bin/cp; sl=${SHIM_SLEEP_CP:-0.3} ;; *) real=$SHIM_REAL_GIT; sl=${SHIM_SLEEP_GIT:-0.3} ;; esac
M=$SHIM_MARK
mkdir "$M/in.$$"; echo "$n" >> "$M/entries"
[ "$(ls "$M" | grep -c '^in\.')" -gt 1 ] && echo "$n $$" >> "$M/overlaps"
[ "$n" = git ] && echo "$PPID" > "$M/git.ppid"
[ "$n" = cp ] && echo "$PPID" > "$M/cp.ppid"
sleep "$sl"
"$real" "$@"; rc=$?
rmdir "$M/in.$$"; exit $rc
EOS
cp "$SHIM/cp" "$SHIM/git"; chmod +x "$SHIM/cp" "$SHIM/git"
shimenv() { env HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" PATH="$SHIM:$PATH" SHIM_MARK="$MARK" SHIM_REAL_GIT="$REAL_GIT" "$@"; }
wait_gone() { # pid 초 — 기한 안에 끝나면 0, 아니면 자식까지 죽이고 1
  _n=$(( $2 * 10 ))
  while [ "$_n" -gt 0 ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; _n=$((_n - 1)); done
  kill_tree KILL "$1"; return 1
}
setup_case() { # 이름 — fresh + 표시 디렉터리 + 훅 입력(n1.md)
  fresh "$1"; MARK="$SANDBOX/mark$1"; mkdir -p "$MARK"
  printf '{"tool_input":{"file_path":"%s"}}' "$MEM/n1.md" > "$MARK/in"
}
# 죽은 보유자 만들기: 훅 한 회차를 cp 도중(잠금 보유 중)에 자손까지 SIGKILL 한다 — trap 이 돌 틈이 없다.
#   돌아올 때 잠금 자리는 그 회차가 남긴 상태 그대로다(mkdir 잠금 구현 = 잠금 디렉터리, 이 판 = 잠금 파일).
kill9_holder() {
  rm -f "$MARK/cp.ppid"
  shimenv SHIM_SLEEP_CP=30 bash "$HOOK" < "$MARK/in" >/dev/null 2>&1 & _hp=$!
  for _ in $(seq 1 50); do [ -s "$MARK/cp.ppid" ] && break; sleep 0.1; done
  kill_tree KILL "$_hp"; wait "$_hp" 2>/dev/null
  rm -f "$MARK/entries" "$MARK/overlaps"; rmdir "$MARK"/in.* 2>/dev/null
  for _t in "$H/.claude/history-backups"/.{{PROJECT_NAME}}.memory.tmp.*; do [ -e "$_t" ] && rm -rf "$_t"; done   # SIGKILL 회차의 임시본(trap 미발화) — 잔여물 판정에서 뺀다
}
# 동시 4회차를 돌리고 겹침·실행 수·잔여물·알림을 센다(인자 = 반복 접두). 결과 = 전역 fails_*
four_rounds() {
  for k in 1 2 3 4; do shimenv bash "$HOOK" < "$MARK/in" >"$MARK/out$k" 2>/dev/null & done; wait; settle
  [ -e "$MARK/overlaps" ] && { fails_ov=$((fails_ov+1)); echo "   $1 overlaps: $(tr '\n' ' ' < "$MARK/overlaps")"; }
  c=$(grep -cx cp "$MARK/entries" 2>/dev/null); [ "$c" = 4 ] || { fails_all=$((fails_all+1)); echo "   $1 cp entries=$c"; }
  lo=$(leftovers); [ -z "$lo" ] || { fails_left=$((fails_left+1)); echo "   $1 leftover: $lo"; }
  cat "$MARK"/out? | grep -q . && { fails_note=$((fails_note+1)); echo "   $1 notice: $(cat "$MARK"/out? | head -c 300)"; }
}

echo "== T8 죽은 보유자(SIGKILL)가 남긴 잠금은 다음 회차를 막지 않음 — 기다림 없이 실행·알림 없음 (깨질 이름: dead_holder_not_blocking, dead_holder_no_notice)"
setup_case 8; kill9_holder
t0=$(date +%s); shimenv bash "$HOOK" < "$MARK/in" >"$MARK/out" 2>/dev/null; el=$(( $(date +%s) - t0 )); settle
{ [ "$el" -lt 3 ] && [ "$(grep -cx cp "$MARK/entries" 2>/dev/null)" = 1 ] && [ -e "$DEST/memory/n1.md" ]; }; check "dead_holder_not_blocking" $?
[ ! -s "$MARK/out" ]; check "dead_holder_no_notice" $?

echo "== T9 동시 회차는 잠금으로 직렬화 — 임계 구역 겹침 없음·모든 회차 복사·중첩 없음 (깨질 이름: lock_serializes_rounds, lock_rounds_all_ran, lock_no_nesting)"
setup_case 9
for k in 1 2 3 4; do shimenv bash "$HOOK" < "$MARK/in" >/dev/null 2>&1 & done; wait; settle
[ ! -e "$MARK/overlaps" ]; check "lock_serializes_rounds" $?
[ "$(grep -cx cp "$MARK/entries" 2>/dev/null)" = "4" ]; check "lock_rounds_all_ran" $?
{ [ ! -e "$DEST/memory/memory" ] && ! hist | grep -q '^memory/memory/'; }; check "lock_no_nesting" $?

echo "== T10 잠금 경로가 일반 파일이 아님(디렉터리·심볼릭 링크) → 기한 안에 건너뛰고 JSON 알림, 그 자리·링크 대상 불변, 복사 없음 (깨질 이름: lockpath_dir_bounded, lockpath_symlink_bounded)"
for kind in dir symlink; do
  setup_case "10$kind"
  if [ "$kind" = dir ]; then mkdir "$LOCKF"; echo 123 > "$LOCKF/pid"; else ln -s "$H/victim" "$LOCKF"; fi
  HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" < "$MARK/in" >"$MARK/out" 2>/dev/null & p=$!
  wait_gone "$p" 15; ok=$?
  wait "$p" 2>/dev/null; rc=$?
  if [ "$kind" = dir ]; then intact=1; [ "$(cat "$LOCKF/pid" 2>/dev/null)" = 123 ] && intact=0
  else intact=1; [ -L "$LOCKF" ] && [ ! -e "$H/victim" ] && intact=0; fi
  { [ "$ok" = 0 ] && [ "$rc" = 0 ] && [ "$intact" = 0 ] && [ ! -e "$DEST/memory" ] && notice_ok "$MARK/out"; }
  check "lockpath_${kind}_bounded" $?
done

echo "== T11 전경이 잠금 보유 중 TERM → 잠금 해제·임시본 정리, 기존 백업 보존 (깨질 이름: term_foreground_releases_lock, term_foreground_no_leftover, term_foreground_keeps_backup)"
setup_case 11; hook "$MEM/n1.md"; settle
echo changed > "$MEM/n1.md"
env HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" PATH="$SHIM:$PATH" SHIM_MARK="$MARK" SHIM_REAL_GIT="$REAL_GIT" SHIM_SLEEP_CP=30 \
  bash "$HOOK" < "$MARK/in" >/dev/null 2>&1 & p=$!   # 함수로 감싸면 $! 가 훅이 아니라 서브셸이 된다
for _ in $(seq 1 50); do grep -qx cp "$MARK/entries" 2>/dev/null && break; sleep 0.1; done
kill_tree TERM "$p"; wait_gone "$p" 5; wait "$p" 2>/dev/null
for _ in $(seq 1 30); do lock_free && break; sleep 0.1; done
lock_free; check "term_foreground_releases_lock" $?
[ -z "$(leftovers)" ]; check "term_foreground_no_leftover" $?
[ "$(cat "$DEST/memory/n1.md" 2>/dev/null)" = "note 1" ]; check "term_foreground_keeps_backup" $?

echo "== T12 백그라운드 커밋 서브셸이 잠금 보유 중 TERM → 잠금 해제 (깨질 이름: term_background_releases_lock)"
setup_case 12
shimenv SHIM_SLEEP_GIT=30 bash "$HOOK" < "$MARK/in" >/dev/null 2>&1
for _ in $(seq 1 50); do [ -s "$MARK/git.ppid" ] && break; sleep 0.1; done
sub=$(cat "$MARK/git.ppid" 2>/dev/null); held=1; ! lock_free && held=0
[ -n "$sub" ] && kill_tree TERM "$sub"
for _ in $(seq 1 50); do lock_free && break; sleep 0.1; done
{ [ "$held" = 0 ] && lock_free; }; check "term_background_releases_lock" $?

# ---- 잠금 경합 반증 공격(N1·N2·N1x) 회귀 ----
echo "== N1 죽은 보유자 + 동시 4회차(6회 반복) — 겹침 없음·4회 모두 실행·잔여 없음·알림 없음 (깨질 이름: n1_no_overlap, n1_all_ran, n1_no_leftover, n1_no_notice)"
fails_ov=0; fails_all=0; fails_left=0; fails_note=0
for rep in 1 2 3 4 5 6; do setup_case "n1r$rep"; kill9_holder; four_rounds "rep$rep"; done
[ "$fails_ov" = 0 ]; check n1_no_overlap $?
[ "$fails_all" = 0 ]; check n1_all_ran $?
[ "$fails_left" = 0 ]; check n1_no_leftover $?
[ "$fails_note" = 0 ]; check n1_no_notice $?

echo "== N1x mkdir 잠금 구현의 잠금 자리 잔존(죽은 owner 기록 디렉터리 · owner 없는 2분 경과 빈 디렉터리) + 동시 4회차 — 겹침 없음·4회 모두 실행·알림 없음 (깨질 이름: n1x_owner_no_overlap, n1x_owner_all_ran, n1x_stale_no_overlap, n1x_stale_all_ran, n1x_no_notice)"
fails_note=0
for mode in owner stale; do
  fails_ov=0; fails_all=0; fails_left=0
  for rep in 1 2 3; do
    setup_case "x$mode$rep"
    if [ "$mode" = owner ]; then sh -c 'exit 0' & dp=$!; wait "$dp" 2>/dev/null; mkdir "$OLDL"; echo "$dp 9.dead.9" > "$OLDL/owner"
    else mkdir "$OLDL"; touch -t 202001010000 "$OLDL"; fi
    # mkdir 잠금 자리는 이 판이 보지 않는 경로라 잔여물·lock_free 판정에서 뺀다(이 판은 지우지도 않는다)
    _keep="$OLDL"; OLDL="$SANDBOX/none"
    for k in 1 2 3 4; do shimenv bash "$HOOK" < "$MARK/in" >"$MARK/out$k" 2>/dev/null & done; wait; settle
    OLDL="$_keep"
    [ -e "$MARK/overlaps" ] && { fails_ov=$((fails_ov+1)); echo "   $mode$rep overlaps: $(tr '\n' ' ' < "$MARK/overlaps")"; }
    c=$(grep -cx cp "$MARK/entries" 2>/dev/null); [ "$c" = 4 ] || { fails_all=$((fails_all+1)); echo "   $mode$rep cp entries=$c"; }
    cat "$MARK"/out? | grep -q . && { fails_note=$((fails_note+1)); echo "   $mode$rep notice: $(cat "$MARK"/out? | head -c 200)"; }
  done
  [ "$fails_ov" = 0 ]; check "n1x_${mode}_no_overlap" $?
  [ "$fails_all" = 0 ]; check "n1x_${mode}_all_ran" $?
done
[ "$fails_note" = 0 ]; check n1x_no_notice $?

echo "== N2 보유자 장기 실행(백그라운드 git 25초) 중 다음 회차 — 15초(등록 timeout) 안에 끝나고 JSON 알림, 보유자 잠금 유지·겹침 없음·복사 없음 (깨질 이름: n2_within_hook_timeout, n2_notice_json, n2_holder_lock_kept, n2_no_overlap, n2_no_copy)"
setup_case n2
shimenv SHIM_SLEEP_GIT=25 bash "$HOOK" < "$MARK/in" >/dev/null 2>&1
for _ in $(seq 1 50); do [ -s "$MARK/git.ppid" ] && break; sleep 0.1; done
t0=$(date +%s)
shimenv bash "$HOOK" < "$MARK/in" >"$MARK/out" 2>"$MARK/err" & p=$!
wait_gone "$p" 20; ok=$?; wait "$p" 2>/dev/null
el=$(( $(date +%s) - t0 )); echo "   elapsed=${el}s ok=$ok"
[ "$ok" = 0 ] && [ "$el" -lt 15 ]; check n2_within_hook_timeout $?
notice_ok "$MARK/out"; check n2_notice_json $?
! lock_free; check n2_holder_lock_kept $?
[ ! -e "$MARK/overlaps" ]; check n2_no_overlap $?
[ "$(grep -cx cp "$MARK/entries" 2>/dev/null)" = 1 ]; check n2_no_copy $?
sub=$(cat "$MARK/git.ppid" 2>/dev/null); [ -n "$sub" ] && kill_tree TERM "$sub"
for _ in $(seq 1 50); do lock_free && break; sleep 0.1; done

echo "== N3 python3 가 PATH 에 없음 → 백업 건너뜀 JSON 알림, 미러 불변 (깨질 이름: nopython_notice, nopython_no_sync)"
setup_case n3
NOPY="$SANDBOX/nopy"; mkdir -p "$NOPY"
for f in /usr/bin/*; do case "${f##*/}" in python3*) ;; *) ln -s "$f" "$NOPY/${f##*/}" 2>/dev/null ;; esac; done
_jq="$(command -v jq)"; [ -n "$_jq" ] && [ ! -e "$NOPY/jq" ] && ln -s "$_jq" "$NOPY/jq"   # jq 가 /usr/bin 밖(Homebrew 등)인 머신
env -i HOME="$H" CLAUDE_PROJECT_DIR="$PROJ" PATH="$NOPY:/bin" bash -c 'command -v python3 >/dev/null && exit 9; exec bash "$0"' "$HOOK" < "$MARK/in" >"$MARK/out" 2>/dev/null; prc=$?
[ "$prc" != 9 ] || echo "   선행조건: 격리 PATH 에 python3 가 남아 있음"
notice_ok "$MARK/out" && grep -q 'python3' "$MARK/out"; check nopython_notice $?
[ ! -e "$DEST/memory" ]; check nopython_no_sync $?

echo
echo "Tests run: $run, Passed: $pass, Failures: $((run - pass))"
[ "$run" = "$pass" ]
