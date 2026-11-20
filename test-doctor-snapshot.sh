#!/usr/bin/env bash
# doctor.sh [5f] 공개 스냅샷 클론 hooksPath 점검 시험 — 가짜 킷(git 레포 + githooks/pre-push + doctor.sh 사본 + machine.env)과
# 가짜 HOME 으로 doctor 를 돌려 [5f] 구간만 본다. 실제 ~/.claude·실명 목록·공개 클론은 읽지 않는다. 기대 문자열은 리터럴.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/doctor-snap.XXXXXX") || exit 1
trap 'case "$ROOT" in */doctor-snap.*) rm -rf "$ROOT" ;; esac' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset PUBLIC_SNAPSHOT_DIR
T=0; P=0; F=0
OUT="$ROOT/out"

# $1 = 케이스 이름, $2 = 공개 클론 준비(none|nogit|repo), $3 = 클론 hooksPath(빈 값·want = 그 클론 githooks·kit = 킷 githooks·그 밖 문자열), $4 = .public-snapshot(1|0), $5 = machine.env 에 키를 쓸지(1|0)
run5f() {
  local c="$ROOT/$1" k h s
  k="$c/kit"; h="$c/home"; s="$h/snap"; mkdir -p "$k/githooks" "$h/.claude"
  git init -q "$k"; cp "$HERE/doctor.sh" "$k/doctor.sh"; printf '#!/bin/sh\n' > "$k/githooks/pre-push"; chmod 755 "$k/githooks/pre-push"
  git -C "$k" config core.hooksPath "$k/githooks"
  case "$2" in nogit) mkdir -p "$s" ;; repo) git init -q "$s"; mkdir -p "$s/githooks"; printf '#!/bin/sh\n' > "$s/githooks/pre-push"; chmod 755 "$s/githooks/pre-push"
    [ "$4" = 1 ] && : > "$s/.public-snapshot" ;; esac
  case "$3" in "") ;; want) git -C "$s" config core.hooksPath "$(cd "$s/githooks" && pwd -P)" ;; kit) git -C "$s" config core.hooksPath "$(cd "$k/githooks" && pwd -P)" ;;
    *) git -C "$s" config core.hooksPath "$3" ;; esac
  [ "$5" = 1 ] && printf 'PUBLIC_SNAPSHOT_DIR="%s"\n' "$s" > "$k/machine.env"
  HOME="$h" SCRUB_NAMES_FILE="$c/none" bash "$k/doctor.sh" 2>&1 | sed -n '/=== \[5f\]/,/=== \[5g\]/p' | sed '1d;$d' > "$OUT"
  SNAP_ABS="$s"
}
has()  { T=$((T+1)); if grep -qF -- "$2" "$OUT"; then P=$((P+1)); else F=$((F+1)); printf 'FAIL %s (기대 [%s] 없음)\n' "$1" "$2"; sed 's/^/    | /' "$OUT"; fi; }
hasnt(){ T=$((T+1)); if grep -qF -- "$2" "$OUT"; then F=$((F+1)); printf 'FAIL %s ([%s] 있으면 안 됨)\n' "$1" "$2"; sed 's/^/    | /' "$OUT"; else P=$((P+1)); fi; }

run5f s1 none "" 0 0
has "키 미설정 → 확인 안 함 정보" "✓ 공개 스냅샷 클론 hooksPath 확인 안 함(정보) — machine.env 의 PUBLIC_SNAPSHOT_DIR 미설정"
run5f s2 nogit "" 0 1
has "git 클론 아님 → 경고(~ 표시)" "⚠ PUBLIC_SNAPSHOT_DIR(~/snap)가 git 클론이 아님"
hasnt "홈 절대경로 미출력" "$SNAP_ABS"
run5f s3 repo "" 1 1
has "hooksPath 미설정 → 경고" "⚠ 공개 스냅샷 클론(~/snap) core.hooksPath 미설정 — push 검사 없음"
run5f s4 repo want 1 1
has "hooksPath = 그 클론 githooks → ok" "✓ 공개 스냅샷 클론 core.hooksPath = 그 클론 원본 체크아웃 githooks 절대경로"
hasnt "정상이면 공개 클론 경고 없음" "⚠ 공개 스냅샷"
run5f s5 repo /elsewhere/githooks 1 1
has "다른 절대경로 → 경고" "⚠ 공개 스냅샷 클론 core.hooksPath(/elsewhere/githooks)가 그 클론 원본 체크아웃 githooks(~/snap/githooks)가 아님"
run5f s5k repo kit 1 1
has "킷 githooks 를 가리켜도 그 클론 것이 아니면 경고" "가 그 클론 원본 체크아웃 githooks(~/snap/githooks)가 아님"
run5f s6 repo githooks 1 1
has "상대경로 → 경고" "⚠ 공개 스냅샷 클론 core.hooksPath 가 상대경로(githooks) — githooks 가 없는 worktree 에서 무검사 push(절대경로 ~/snap/githooks 로)"
run5f s7 repo want 0 1
has ".public-snapshot 없음 → 경고" "⚠ 공개 스냅샷 클론(~/snap) 루트에 .public-snapshot 없음"

echo "Tests run: $T, passed: $P, failed: $F"
[ "$T" -gt 0 ] && [ "$F" = 0 ]
