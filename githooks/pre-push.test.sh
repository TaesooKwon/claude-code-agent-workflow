#!/usr/bin/env bash
# githooks/pre-push 시험 — mktemp 레포 + bare 원격에 실제 git push(훅은 임시 레포의 core.hooksPath 로만 건다).
# 실명 목록은 SCRUB_NAMES_FILE 로 임시 파일을 주입하고 HOME 도 임시로 바꾼다(실제 목록을 읽거나 쓰지 않는다).
# 시크릿 토큰은 실행 시점에 조립한다(이 파일 자체가 가드에 걸리지 않게). 실명 더미(Zorblax·홍길동)는 가공의 이름 리터럴이다.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/.." && pwd)
HOOK="$HERE/pre-push"
GUARD_REL='global/agent-scaffold/claude/hooks/secret-commit-guard.sh'
LIB_REL='global/agent-scaffold/claude/hooks/lib/git-cmd.sh'
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR CLAUDECODE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export LC_ALL=C

ROOT=$(mktemp -d /tmp/pre-push-test.XXXXXX) || exit 1
trap 'case "$ROOT" in /tmp/pre-push-test.*) chmod 700 "$ROOT/lockd" 2>/dev/null; rm -rf "$ROOT" ;; esac' EXIT
export HOME="$ROOT/home" TMPDIR="$ROOT/tmp"; mkdir -p "$HOME" "$TMPDIR"
NAMES="$ROOT/names.txt"; printf 'Zorblax\n홍길동\n' > "$NAMES"
export SCRUB_NAMES_FILE="$NAMES"
TOK="gh""p_$(printf '%036d' 0 | tr 0 A)"
OUT="$ROOT/out"
G() { command git "$@"; }

T=0; P=0; F=0
pass() { T=$((T+1)); P=$((P+1)); }
fail() { T=$((T+1)); F=$((F+1)); printf 'FAIL %s\n' "$1"; [ -f "$OUT" ] && sed 's/^/    | /' "$OUT"; }
leaks() { command grep -aqF -e "$TOK" -e Zorblax -e zorblax -e 홍길동 "$OUT"; }
expect_block() {  # $1 = 이름, $2 = 기대 사유 부분 문자열, 나머지 = 명령
  local name=$1 want=$2; shift 2
  if "$@" >"$OUT" 2>&1; then fail "$name (통과함 — 차단 기대)"; return; fi
  command grep -aqF '[pre-push 검사]' "$OUT" || { fail "$name (훅 차단이 아닌 실패)"; return; }
  command grep -aqF -- "$want" "$OUT" || { fail "$name (사유 '$want' 없음)"; return; }
  leaks && { fail "$name (값 노출)"; return; }
  pass
}
expect_pass() { local name=$1; shift; if "$@" >"$OUT" 2>&1; then pass; else fail "$name (차단됨 — 통과 기대)"; fi; }

HOOKDIR="$HERE"
new_repo() {  # $1 = 이름 → bare 원격 + 클론(가드·lib·seed 를 --no-verify 로 공개한 상태) 으로 cd
  local r="$ROOT/$1"
  G init -q --bare "$r.git" && G init -q -b main "$r" || exit 1
  mkdir -p "$r/$(dirname "$LIB_REL")"
  cp "$KIT/$GUARD_REL" "$r/$GUARD_REL" && cp "$KIT/$LIB_REL" "$r/$LIB_REL" || exit 1
  echo seed > "$r/README"
  G -C "$r" add -A && G -C "$r" commit -qm seed && G -C "$r" remote add origin "$r.git" \
    && G -C "$r" push -q --no-verify origin main 2>/dev/null || exit 1
  G -C "$r" config core.hooksPath "$HOOKDIR"
  cd "$r" || exit 1
}
cf() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; G add -- "$1" && G commit -qm "${3:-c $1}"; }
push() { G push -q "$@"; }

# T0 음성 대조 — 깨끗한 push 는 통과
new_repo t0; cf a.txt hello; expect_pass "T0 깨끗한 push" push origin main
# T1 중간 커밋에 넣었다 지운 토큰
new_repo t1; cf k.txt "$TOK"; cf k.txt clean; expect_block "T1 중간 커밋 토큰" "시크릿 패턴" push origin main
# T2 cherry-pick
new_repo t2; G checkout -qb side; cf k.txt "$TOK"; G checkout -q main; G cherry-pick side >/dev/null 2>&1
expect_block "T2 cherry-pick" "시크릿 패턴" push origin main
# T3 revert 로 되살아난 토큰(넣고 지운 이력은 이미 공개)
new_repo t3; cf k.txt "$TOK"; G rm -q k.txt; G commit -qm rm; push --no-verify origin main 2>/dev/null
G revert --no-edit HEAD >/dev/null 2>&1; expect_block "T3 revert" "시크릿 패턴" push origin main
# T4 git am
new_repo t4; G checkout -qb tmp; cf k.txt "$TOK"; G format-patch -1 --stdout > "$ROOT/p.patch"; G checkout -q main; G branch -qD tmp
G am -q "$ROOT/p.patch" >/dev/null 2>&1; expect_block "T4 am" "시크릿 패턴" push origin main
# T5 rebase 충돌을 토큰으로 해소(새 브랜치)
new_repo t5; cf a 1; push --no-verify origin main 2>/dev/null; G checkout -qb side; cf a 2; G checkout -q main; cf a 3
push --no-verify origin main 2>/dev/null; G checkout -q side; G rebase main >/dev/null 2>&1
printf '%s\n' "$TOK" > a; G add a; GIT_EDITOR=true G rebase --continue >/dev/null 2>&1
expect_block "T5 rebase 충돌 해소" "시크릿 패턴" push origin side
# T6 ff 병합
new_repo t6; G checkout -qb feat; cf k.txt "$TOK"; G checkout -q main; G merge -q --ff-only feat
expect_block "T6 ff 병합" "시크릿 패턴" push origin main
# T7 evil merge — 토큰은 병합 커밋에만
new_repo t7; G checkout -qb side; cf s.txt s; G checkout -q main; cf m.txt m; G merge -q --no-ff --no-commit side >/dev/null 2>&1
printf '%s\n' "$TOK" > m.txt; G add m.txt; G commit -qm merge
expect_block "T7 evil merge" "시크릿 패턴" push origin main
# T8 새 브랜치(remote sha 0) — 깨끗하면 통과, 토큰이면 차단, 이어서 기존 브랜치 갱신도 차단
new_repo t8; G checkout -qb nb; cf a.txt a; expect_pass "T8a 새 브랜치 깨끗" push origin nb
cf k.txt "$TOK"; expect_block "T8b 기존 브랜치 갱신 토큰" "시크릿 패턴" push origin nb
G checkout -qb nb2 main; cf k2.txt "$TOK"; expect_block "T8c 새 브랜치 토큰" "시크릿 패턴" push origin nb2
# T9 루트 커밋(orphan) — 기존 원격 브랜치 위 강제 push 로 루트가 범위에 든다
new_repo t9; G checkout -qb side; cf s.txt s; push --no-verify origin side 2>/dev/null
G checkout -q --orphan orph; cf o.txt o; expect_pass "T9a orphan 루트 깨끗" push -f origin orph:side
G checkout -q --orphan orph2; cf k.txt "$TOK"; expect_block "T9b orphan 루트 토큰" "시크릿 패턴" push -f origin orph2:side
expect_block "T9c orphan 새 브랜치(공통 조상 없음)" "공통 조상" push origin orph2:newb
# T9d 실명이 든 ref 이름은 차단 안내(die)에서도 자리표시 — expect_block 의 leaks 가 이름 노출을 본다
G checkout -q --orphan zorblax-orph; cf o2.txt o; expect_block "T9d orphan 실명 브랜치(이름 미출력)" "공통 조상" push origin zorblax-orph
# T10 삭제 push
new_repo t10; G checkout -qb d; cf a a; push --no-verify origin d 2>/dev/null; expect_pass "T10 삭제 push" push origin --delete d
# T11 링크 worktree 에서 push — 그 worktree·메인의 HEAD·status 불변, 임시 worktree 잔존 없음
wt_check() {  # $1 = 이름, $2 = 기대(pass|block)
  local wt="$ROOT/t11-wt" h0 s0 r0 m0 h1 s1 r1 m1
  h0=$(G -C "$wt" symbolic-ref -q HEAD); r0=$(G -C "$wt" rev-parse HEAD); s0=$(G -C "$wt" status --porcelain); m0=$(G symbolic-ref -q HEAD)
  if [ "$2" = pass ]; then expect_pass "$1" G -C "$wt" push -q origin wtb; else expect_block "$1" "시크릿 패턴" G -C "$wt" push -q origin wtb; fi
  h1=$(G -C "$wt" symbolic-ref -q HEAD); r1=$(G -C "$wt" rev-parse HEAD); s1=$(G -C "$wt" status --porcelain); m1=$(G symbolic-ref -q HEAD)
  if [ "$h0|$r0|$s0|$m0" = "$h1|$r1|$s1|$m1" ] && [ "$(G worktree list --porcelain | command grep -c '^worktree ')" = 2 ]; then pass
  else : > "$OUT"; fail "$1 — HEAD·status·worktree 수 변화(전 $h0 $r0 [$s0] / 후 $h1 $r1 [$s1])"; fi
}
new_repo t11; G worktree add -q -b wtb "$ROOT/t11-wt" main 2>/dev/null
( cd "$ROOT/t11-wt" && cf w1 1 && cf w2 2 ); wt_check "T11a 링크 worktree push 깨끗" pass
( cd "$ROOT/t11-wt" && cf w3 3 && cf k.txt "$TOK" ); wt_check "T11b 링크 worktree push 토큰" block
# T12 실명 — 내용(대소문자 무시)·+++ 꼴 내용 줄·한글 경로·메시지·annotated tag
new_repo t12; cf n.txt "hi zorblax"; expect_block "T12a 내용 실명" "추가 줄에 실명" push origin main
new_repo t12b; cf n.txt "++ b/Zorblax"; expect_block "T12b +++ 꼴 내용 줄" "추가 줄에 실명" push origin main
new_repo t12c; cf "docs/홍길동.md" clean; expect_block "T12c 한글 경로 실명" "경로에 실명" push origin main
new_repo t12d; cf m.txt clean "fix for Zorblax"; expect_block "T12d 메시지 실명" "커밋 메시지에 실명" push origin main
new_repo t12e; G tag -a v1 -m "Zorblax release"; expect_block "T12e annotated tag 메시지" "태그 메시지에 실명" push origin v1
command grep -aqF 'git tag -d v1`' "$OUT" && pass || fail "T12e 태그 조치 줄(git tag -d v1) 없음"
G tag -a v2 -m "release"; expect_pass "T12f 깨끗한 annotated tag" push origin v2
GIT_COMMITTER_NAME=Zorblax G tag -a v3 -m "release"; expect_pass "T12g tagger 만 실명(메시지 깨끗)" push origin v3
G tag -a zorblax-v4 -m "Zorblax"; expect_block "T12h 태그 이름·메시지 실명(이름 미출력)" "태그 메시지에 실명" push origin zorblax-v4
# T12i 중첩 태그 — 바깥 메시지는 깨끗, 안쪽 태그 메시지에 실명(안쪽 ref 는 지워 바깥만 push)
G tag -a inner -m "Zorblax inner"; G tag -a outer -m clean inner 2>/dev/null; G tag -d inner >/dev/null
expect_block "T12i 중첩 태그 안쪽 메시지 실명" "안쪽 태그" push origin outer
# T12j·T12k 서명 블록 — 블록 안 우연한 문자열(대소문자 무시로 이름과 같음)은 통과, 블록 앞 메시지의 실명은 차단
sigtag() {  # $1 = 태그 이름, $2 = 메시지 → 서명 블록을 붙인 태그 객체를 만들어 refs/tags/$1 에 건다
  local o; o=$(printf 'object %s\ntype commit\ntag %s\ntagger t <t@example.invalid> 1700000000 +0000\n\n%s\n-----BEGIN PGP SIGNATURE-----\n\niQEzBAABCAAdFiEEzORBLAXabc\n-----END PGP SIGNATURE-----\n' \
    "$(G rev-parse HEAD)" "$1" "$2" | G mktag) && G update-ref "refs/tags/$1" "$o"
}
sigtag s1 release; expect_pass "T12j 서명 블록 안의 우연한 문자열" push origin s1
sigtag s2 "Zorblax release"; expect_block "T12k 서명 블록 앞 메시지 실명" "태그 메시지에 실명" push origin s2
G tag -a e1 -m ""; expect_pass "T12l 빈 메시지 태그" push origin e1
# T12m 태그 메시지와 가리키는 커밋이 둘 다 걸림 → 조치는 "고친 커밋에 고친 메시지로 다시 태그" 한 줄(옛 커밋에 다시 태그하라는 줄 없음)
new_repo t12m; cf b.txt Zorblax; G tag -a v9 -m "Zorblax rel"
expect_block "T12m 태그 메시지+커밋 둘 다 실명" "태그 메시지에 실명" push origin v9
if command grep -aqF '고친 커밋에 고친 메시지로 다시 태그' "$OUT" && ! command grep -aqF '를 다시 만들어 push' "$OUT"; then pass
else fail "T12m 조치가 한 줄로 합쳐지지 않음"; fi
# T13 목록 정제 — BOM·CR·공백·빈 줄
printf '\357\273\277Zorblax\r\n\r\n   \n  홍길동  \r\n' > "$ROOT/dirty.txt"
new_repo t13; cf a.txt clean; SCRUB_NAMES_FILE="$ROOT/dirty.txt" expect_pass "T13a 지저분한 목록 + 깨끗한 push" push origin main
cf b.txt "Zorblax here"; SCRUB_NAMES_FILE="$ROOT/dirty.txt" expect_block "T13b BOM 첫 줄 실명" "추가 줄에 실명" push origin main
G reset -q --hard HEAD~1; cf c.txt "홍길동"; SCRUB_NAMES_FILE="$ROOT/dirty.txt" expect_block "T13c 공백 trim 실명" "추가 줄에 실명" push origin main
# T14 .public-snapshot + 목록 부재 → 차단 / 마커 없으면 경고 후 통과 / 원격 판에만 마커 → 차단
new_repo t14; cf .public-snapshot 1; SCRUB_NAMES_FILE="$ROOT/none" expect_block "T14a 공개 마커+목록 부재" "공개 레포" push origin main
new_repo t14b; cf a.txt a
if SCRUB_NAMES_FILE="$ROOT/none" push origin main >"$OUT" 2>&1 && command grep -aqF '경고' "$OUT"; then pass; else fail "T14b 마커 없음 경고 통과"; fi
new_repo t14c; cf .public-snapshot 1; push --no-verify origin main 2>/dev/null; G rm -q .public-snapshot; G commit -qm rm
SCRUB_NAMES_FILE="$ROOT/none" expect_block "T14c 원격 판에만 공개 마커" "공개 레포" push origin main
# T15 이진 — 허용 목록 밖 확장자 차단 · png 통과 · 커밋된 .gitattributes -diff(체크아웃 안 된 브랜치) 차단
new_repo t15; printf 'a\000b' > x.dat; G add x.dat; G commit -qm bin; expect_block "T15a 낯선 확장자 이진" "이진 파일" push origin main
new_repo t15b; printf 'a\000b' > i.png; G add i.png; G commit -qm png; expect_pass "T15b png 이진" push origin main
new_repo t15d; printf 'a\000Zorblax' > n.png; G add n.png; G commit -qm png; expect_block "T15d 허용 목록 이진 안 실명" "추가 줄에 실명" push origin main
new_repo t15e; printf 'PK\003\004\000' > a.zip; G add a.zip; G commit -qm zip; expect_block "T15e zip(허용 목록 밖)" "이진 파일" push origin main
new_repo t15c; G checkout -qb attr; printf 'leak.txt -diff\n' > .gitattributes; printf '%s\n' "$TOK" > leak.txt
G add .gitattributes leak.txt; G commit -qm attr; G checkout -q main; expect_block "T15c 커밋된 .gitattributes -diff" "이진 파일" push origin attr
# T16 범위 안에서 가드를 약화(맨 앞 exit 0)해도 원격 판 가드로 차단
new_repo t16; { head -1 "$GUARD_REL"; echo 'exit 0'; tail -n +2 "$GUARD_REL"; } > "$ROOT/g" && cat "$ROOT/g" > "$GUARD_REL"
printf '%s\n' "$TOK" > k.txt; G add -A; G commit -qm weaken; expect_block "T16 가드 약화 커밋" "원격 판 가드" push origin main
# T17 jq 만 뺀 PATH(심링크 shim) → 차단
SHIM="$ROOT/shim"; mkdir -p "$SHIM"
for t in bash git sed tr awk mktemp rm cat mkdir dirname grep head sort env; do p=$(PATH=/usr/bin:/bin command -v "$t") && ln -s "$p" "$SHIM/$t"; done
new_repo t17; cf a.txt a; printf 'refs/heads/main %s refs/heads/main %s\n' "$(G rev-parse HEAD)" "$(G rev-parse origin/main)" > "$ROOT/in17"
# 훅이 덧붙이는 경로(PRE_PUSH_EXTRA_PATH)를 비워야 jq 가 그쪽에 있는 머신에서도 jq 없는 PATH 가 된다
expect_block "T17 jq 없는 PATH" "jq" env PATH="$SHIM" PRE_PUSH_EXTRA_PATH= /bin/bash "$HOOK" origin "$ROOT/t17.git" < "$ROOT/in17"
# 양성 대조 — 덧붙인 경로에만 jq 가 있으면 통과(shim 이 jq 말고는 충분하고, 덧붙이기가 동작함)
JQD="$ROOT/jqdir"; mkdir -p "$JQD"; ln -s "$(command -v jq)" "$JQD/jq"
expect_pass "T17b 덧붙인 경로의 jq" env PATH="$SHIM" PRE_PUSH_EXTRA_PATH="$JQD" /bin/bash "$HOOK" origin "$ROOT/t17.git" < "$ROOT/in17"
# T18 여러 ref push — 두 번째 ref 에만 시크릿
new_repo t18; G checkout -qb a1; cf a.txt a; G checkout -qb b1 main; cf k.txt "$TOK"
G checkout -q a1; expect_block "T18 여러 ref(현재 아닌 둘째만 시크릿)" "시크릿 패턴" push origin a1 b1
command grep -aqF 'git switch b1`' "$OUT" && pass || fail "T18 조치 줄에 git switch b1 없음"
# T19 remote sha 가 로컬에 없음 · T20 낯선 stdin
new_repo t19; cf a.txt a; printf 'refs/heads/main %s refs/heads/main %s\n' "$(G rev-parse HEAD)" "$(printf '%040d' 7)" > "$ROOT/in19"
expect_block "T19 원격 sha 로컬 부재" "fetch" bash "$HOOK" origin "$ROOT/t19.git" < "$ROOT/in19"
printf 'garbage line\n' > "$ROOT/in20"; expect_block "T20 낯선 stdin" "형식" bash "$HOOK" origin "$ROOT/t19.git" < "$ROOT/in20"
# T19b·T21b URL 인자의 자격 증명은 표시·안내 명령에서 가린다 / T21c URL 에 든 실명은 자리표시(leaks 가 본다)
CRED="u:fake$(printf cred)Tok123"; CURL="https://$CRED@example.invalid/r.git"
nocred() { if command grep -aqF "$CRED" "$OUT"; then fail "$1 (자격 증명 노출)"; else pass; fi; }
expect_block "T19b URL 원격 sha 로컬 부재" '`git fetch <원격>`' bash "$HOOK" "$CURL" "$CURL" < "$ROOT/in19"; nocred T19b
printf 'refs/heads/main %s refs/heads/main %040d\n' "$(G rev-parse HEAD)" 0 > "$ROOT/in21"
expect_block "T21b URL 추적 ref 없음" "추적 ref" bash "$HOOK" "$CURL" "$CURL" < "$ROOT/in21"; nocred T21b
expect_block "T21c URL 에 실명" '원격 <원격>' bash "$HOOK" https://example.invalid/Zorblax/r.git https://example.invalid/Zorblax/r.git < "$ROOT/in21"
# T21 추적 ref 가 없는 새 원격(fetch 전)
new_repo t21; G init -q --bare "$ROOT/fresh.git"; G remote add fresh "$ROOT/fresh.git"
expect_block "T21 새 원격(추적 ref 없음)" "추적 ref" push fresh main
# T22 실명 목록이 있는데 읽을 수 없음(권한 000) → 차단(없음으로 치지 않는다)
printf 'Zorblax\n' > "$ROOT/locked.txt"; chmod 000 "$ROOT/locked.txt"
new_repo t22; cf a.txt a; SCRUB_NAMES_FILE="$ROOT/locked.txt" expect_block "T22 읽을 수 없는 실명 목록" "실명 목록을 읽을 수 없" push origin main
chmod 600 "$ROOT/locked.txt"
# T22b 실명 목록의 상위 디렉터리를 탐색할 수 없음(x 없음) → 차단(없음으로 치지 않는다)
mkdir -p "$ROOT/lockd"; printf 'Zorblax\n' > "$ROOT/lockd/n.txt"; chmod 600 "$ROOT/lockd"
new_repo t22b; cf a.txt a; SCRUB_NAMES_FILE="$ROOT/lockd/n.txt" expect_block "T22b 상위 디렉터리 탐색 불가" "상위 디렉터리를 탐색할 수 없" push origin main
chmod 700 "$ROOT/lockd"
# T23 셸 특수문자가 든 ref 이름 — 안내 명령을 eval 해도 명령 치환 없이 원래 이름 그대로
qcheck() {  # $1 = 이름, $2 = 명령 접두(sed 패턴), $3 = 기대 인자
  local name=$1 want=$3 a; a=$(sed -n "s/.*\`$2 \([^\`]*\)\`.*/\1/p" "$OUT" | head -1)
  if [ -n "$a" ] && eval "set -- $a" && [ "$1" = "$want" ]; then pass; else fail "$name (안내 명령 인용 — 인자 [$a])"; fi
}
new_repo t23; G checkout -qb 'fix$(id)'; cf k.txt "$TOK"; expect_block "T23a 브랜치 이름에 \$(…)" "시크릿 패턴" push origin 'fix$(id)'
qcheck "T23a git switch 인용" 'git switch' 'fix$(id)'
G tag -a 't$(id)' -m "Zorblax"; expect_block "T23b 태그 이름에 \$(…)" "태그 메시지에 실명" push origin 'refs/tags/t$(id)'
qcheck "T23b git tag -d 인용" 'git tag -d' 't$(id)'
# 임시 디렉터리 잔존 없음(trap 정리)
[ -z "$(ls -A "$TMPDIR")" ] && pass || { : > "$OUT"; fail "훅 임시 디렉터리 잔존: $(ls -A "$TMPDIR" | tr '\n' ' ')"; }
# 임시 worktree 등록 잔존 없음 — 마지막 검사 커밋이 루트(unborn HEAD)인 T9 레포에서도
[ -z "$(ls -A "$ROOT/t9/.git/worktrees" 2>/dev/null)" ] && pass || { : > "$OUT"; fail "T9 임시 worktree 등록 잔존"; }

# 변이 — 판정 줄·환경 해제 줄을 망가뜨리면 해당 시험이 빨간불이어야 한다(시험이 실패할 수 있음을 확인)
MUT="$ROOT/mut"; mkdir -p "$MUT"
sed 's/\*) return 1 ;; esac   # judge-line/*) return 0 ;; esac   # judge-line/' "$HOOK" > "$MUT/pre-push"; chmod 755 "$MUT/pre-push"
if cmp -s "$HOOK" "$MUT/pre-push"; then : > "$OUT"; fail "M1 판정 줄 변이 적용 실패"
else
  HOOKDIR="$MUT"; new_repo m1; cf k.txt "$TOK"
  if push origin main >"$OUT" 2>&1; then pass; echo "MUTANT M1(판정 줄) — 시크릿 push 가 통과함 = T1 류 시험이 빨간불(검출)"
  else fail "M1 판정 줄 변이가 검출되지 않음(시험이 판정 줄을 보지 않는다)"; fi
fi
sed 's/^unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR$/:/' "$HOOK" > "$MUT/pre-push"
if cmp -s "$HOOK" "$MUT/pre-push"; then : > "$OUT"; fail "M2 환경 해제 줄 변이 적용 실패"
else
  HOOKDIR="$MUT"; new_repo m2; G worktree add -q -b wtb "$ROOT/m2-wt" main 2>/dev/null; ( cd "$ROOT/m2-wt" && cf w1 1 && cf w2 2 )
  h0=$(G -C "$ROOT/m2-wt" symbolic-ref -q HEAD); G -C "$ROOT/m2-wt" push -q origin wtb >"$OUT" 2>&1
  h1=$(G -C "$ROOT/m2-wt" symbolic-ref -q HEAD)
  if [ "$h0" != "$h1" ]; then pass; echo "MUTANT M2(환경 해제) — 링크 worktree HEAD 가 바뀜($h0 → ${h1:-detached}) = T11 이 빨간불(검출)"
  else fail "M2 환경 해제 변이가 검출되지 않음(T11 이 이 결함을 보지 못한다)"; fi
fi
HOOKDIR="$HERE"

echo "Tests run: $T, passed: $P, failed: $F"
[ "$F" = 0 ]
