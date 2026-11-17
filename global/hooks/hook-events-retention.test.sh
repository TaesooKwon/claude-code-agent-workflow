#!/bin/bash
# hook-events-retention.sh 계약 테스트 — 임시 디렉터리(HOOK_EVENTS_DIR 덮어쓰기)에서만 돈다.
# 실제 ~/.claude/hook-events 는 건드리지 않는다. 실행: bash ~/.claude/hooks/hook-events-retention.test.sh
# RET 환경변수로 검사 대상 스크립트를 바꿀 수 있다(변이 반증용 사본).
set -u

RET="${RET:-$(cd "$(dirname "$0")" && pwd)/hook-events-retention.sh}"
[ -f "$RET" ] || { echo "대상 없음: $RET"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/hook-ret-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

run=0; pass=0
ok()   { run=$((run + 1)); pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
fail() { run=$((run + 1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# k 개월 전의 YYYY-MM(스크립트와 같은 월 인덱스 산술)
ym() {
  local y m i
  y=$(date +%Y); m=$(date +%m)
  i=$(( 10#$y * 12 + 10#$m - 1 - $1 ))
  printf '%04d-%02d' $(( i / 12 )) $(( i % 12 + 1 ))
}
M0=$(ym 0); M1=$(ym 1); M2=$(ym 2); M3=$(ym 3)

newdir() { local d="$T/$1"; mkdir -p "$d"; for n in "${@:2}"; do printf '{}\n' > "$d/$n.jsonl"; done; printf '%s' "$d"; }
# 실행 → OUT·RC 전역
go() { OUT=$(HOOK_EVENTS_DIR="$1" "${@:2}" bash "$RET" 2>&1); RC=$?; }
have() { [ -e "$1/$2.jsonl" ] || [ -L "$1/$2.jsonl" ]; }

# $1=설명 $2=디렉터리 $3=남아야 할 월(공백) $4=지워져야 할 월(공백)
expect() {
  local desc="$1" d="$2" n why=""
  [ "$RC" -eq 0 ] || why="exit=$RC "
  for n in $3; do have "$d" "$n" || why="${why}지워짐:$n "; done
  for n in $4; do have "$d" "$n" && why="${why}남음:$n "; done
  if [ -z "$why" ]; then ok "$desc"; else fail "$desc" "$why"; fi
}

echo "== 보존 =="
d=$(newdir t1 "$M3" "$M1" "$M0"); go "$d" env
expect "T1 3개월 전·지난달·이번달 → 3개월 전만 삭제" "$d" "$M1 $M0" "$M3"
case "$OUT" in *'1개 삭제'*) ok "T1-출력: 삭제 개수 한 줄" ;; *) fail "T1-출력: 삭제 개수 한 줄" "[$OUT]" ;; esac

d=$(newdir t2 "$M2" "$M1" "$M0"); go "$d" env
expect "T2 경계: 보존 2 → 2개월 전 삭제" "$d" "$M1 $M0" "$M2"

d=$(newdir t3 "$M0"); go "$d" env
expect "T3 이번 달만 → 무삭제" "$d" "$M0" ""
[ -z "$OUT" ] && ok "T3-출력: 무삭제면 무출력" || fail "T3-출력: 무삭제면 무출력" "[$OUT]"

echo "== 허용 목록 =="
d=$(newdir t4 "$M0")
printf '{}\n' > "$d/notes.jsonl"; printf '{}\n' > "$d/2020-13.jsonl"; printf '{}\n' > "$d/2020-01.jsonl.bak"
printf '{}\n' > "$d/x2020-01.jsonl"; mkdir "$d/2020-02.jsonl"
go "$d" env
miss=""
for n in notes.jsonl 2020-13.jsonl 2020-01.jsonl.bak x2020-01.jsonl 2020-02.jsonl; do [ -e "$d/$n" ] || miss="$miss $n"; done
[ -z "$miss" ] && [ "$RC" -eq 0 ] && ok "T4 다른 이름 파일·월 이름 디렉터리 보존" || fail "T4 다른 이름 파일·월 이름 디렉터리 보존" "사라짐:$miss rc=$RC"

d=$(newdir t5 "$M0"); printf '{}\n' > "$T/t5-target"; ln -s "$T/t5-target" "$d/2020-01.jsonl"
go "$d" env
[ -L "$d/2020-01.jsonl" ] && [ -f "$T/t5-target" ] && ok "T5 오래된 월 이름 심링크·대상 보존" || fail "T5 오래된 월 이름 심링크·대상 보존" "rc=$RC"

echo "== 하루 1회 마커 =="
d=$(newdir t6 "$M0"); mkdir "$d/.retention-20000101"; go "$d" env
[ -d "$d/.retention-$(date +%Y%m%d)" ] && [ ! -e "$d/.retention-20000101" ] \
  && ok "T6 오늘 마커 생성·지난 마커 정리" || fail "T6 오늘 마커 생성·지난 마커 정리" "$(ls -a "$d" | tr '\n' ' ')"
printf '{}\n' > "$d/$M3.jsonl"; go "$d" env
expect "T7 같은 날 2회째 → 무동작(3개월 전도 보존)" "$d" "$M3 $M0" ""

d=$(newdir t8 "$M3" "$M0")
for i in 1 2 3 4 5 6; do (HOOK_EVENTS_DIR="$d" bash "$RET" > "$T/t8-$i.out" 2>&1) & done; wait
lines=$(cat "$T"/t8-*.out | grep -c '삭제')
! have "$d" "$M3" && have "$d" "$M0" && [ "$lines" -eq 1 ] \
  && ok "T8 병행 6개 동시 실행 → 한 번만 동작" || fail "T8 병행 6개 동시 실행 → 한 번만 동작" "요약 줄 $lines"

echo "== 보존 개월 =="
d=$(newdir t9 "$M3" "$M2" "$M0"); go "$d" env HOOK_EVENTS_KEEP_MONTHS=3
expect "T9 KEEP=3 → 2개월 전 보존·3개월 전 삭제" "$d" "$M2 $M0" "$M3"
d=$(newdir t10 "$M2" "$M0"); go "$d" env HOOK_EVENTS_KEEP_MONTHS=abc
expect "T10 KEEP=abc → 2 로 간주(2개월 전 삭제)" "$d" "$M0" "$M2"
d=$(newdir t11 "$M1" "$M0"); go "$d" env HOOK_EVENTS_KEEP_MONTHS=0
expect "T11 KEEP=0 → 2 로 간주(지난달 보존)" "$d" "$M1 $M0" ""
d=$(newdir t12 "$M1" "$M0"); go "$d" env HOOK_EVENTS_KEEP_MONTHS=1
expect "T12 KEEP=1 → 지난달 삭제·이번 달 보존" "$d" "$M0" "$M1"
d=$(newdir t13 "$M2" "$M0"); go "$d" env HOOK_EVENTS_KEEP_MONTHS=08
expect "T13 KEEP=08(앞자리 0) → 8 로 인정(2개월 전 보존)" "$d" "$M2 $M0" ""

echo "== 입력 방어 =="
go "$T/nope" env
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "T14 디렉터리 없음 → 무출력·exit 0" || fail "T14 디렉터리 없음 → 무출력·exit 0" "rc=$RC [$OUT]"

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ] || exit 1
