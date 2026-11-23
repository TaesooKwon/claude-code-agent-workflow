#!/usr/bin/env bash
# compact-state-reinject.sh 자체검사.
# 실행: bash .claude/hooks/compact-state-reinject.test.sh
#
# 샌드박스 git 레포를 mktemp 로 만들어 실물 훅에 SessionStart stdin JSON 을 먹인다. 이 레포의 기록 파일은
# 읽지 않는다(CLAUDE_PROJECT_DIR 을 샌드박스로 덮어쓴다). 정리는 trap EXIT.
set -u

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS_DIR/compact-state-reinject.sh"
LIB="$HOOKS_DIR/lib/review-diff.sh"
[ -f "$HOOK" ] || { echo "선행조건 실패: $HOOK 없음"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }
. "$LIB"

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/compact-reinject-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

run=0; pass=0
assert_eq() { # 설명 기대 실제
  run=$((run + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s\n        기대: [%s]\n        실제: [%s]\n' "$1" "$2" "$3"
  fi
}

mkrepo() {
  r="$SANDBOX/repo$1"
  mkdir -p "$r/.claude"
  git -C "$r" init -q >/dev/null 2>&1
  git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init >/dev/null 2>&1
  printf '%s' "$r"
}
stage() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2" >/dev/null 2>&1; }

ss_json() { jq -n --arg s "$1" '{hook_event_name:"SessionStart",session_id:"x",source:$s}'; }

# hook stdin원문 repo [PATH] → stdout 원문(+ 마지막 줄 "rc=<exit>")
hook_raw() {
  local out rc
  if [ -n "${3:-}" ]; then
    out=$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="$2" PATH="$3" /bin/bash "$HOOK" 2>/dev/null); rc=$?
  else
    out=$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="$2" bash "$HOOK" 2>/dev/null); rc=$?
  fi
  printf '%s\nrc=%s' "$out" "$rc"
}
hook() { hook_raw "$(ss_json "$1")" "$2"; }
line_of() { printf '%s\n' "$1" | grep -m1 -- "^- $2:" ; }

echo "── 입력 게이트 ──────────────────────────────────────"
r=$(mkrepo 1)
assert_eq "G1 음성: source=startup → 무출력·exit 0" $'\nrc=0' "$(hook startup "$r")"
assert_eq "G2 음성: source=resume → 무출력·exit 0" $'\nrc=0' "$(hook resume "$r")"
assert_eq "G3 음성: 깨진 JSON → 무출력·exit 0" $'\nrc=0' "$(hook_raw 'not a json {' "$r")"
assert_eq "G4 음성: JSON 배열(객체 아님) → 무출력·exit 0" $'\nrc=0' "$(hook_raw '["compact"]' "$r")"
assert_eq "G5 음성: source 가 대문자 COMPACT → 무출력(허용값 정확일치)" $'\nrc=0' "$(hook COMPACT "$r")"

# jq 없는 PATH — 시스템 bin 의 jq 를 뺀 심링크 디렉터리
nojq="$SANDBOX/nojq-bin"; mkdir -p "$nojq"
for d in /usr/bin /bin /usr/sbin /sbin; do
  for f in "$d"/*; do
    b=$(basename "$f"); [ "$b" = jq ] && continue
    [ -e "$nojq/$b" ] || ln -s "$f" "$nojq/$b" 2>/dev/null
  done
done
assert_eq "G6 음성: jq 없음(PATH 조작) → 무출력·exit 0" $'\nrc=0' "$(hook_raw "$(ss_json compact)" "$r" "$nojq")"
assert_eq "G6-대조: 같은 PATH 조작 디렉터리에 jq 가 정말 없다" "1" "$(PATH="$nojq" command -v jq >/dev/null 2>&1; echo $?)"

nr="$SANDBOX/notrepo"; mkdir -p "$nr/.claude"
assert_eq "G7 음성: git 레포 아님 → 무출력·exit 0" $'\nrc=0' "$(hook compact "$nr")"

echo "── 출력 9항목 ──────────────────────────────────────"
r=$(mkrepo 2)
out=$(hook compact "$r")
assert_eq "O1 머리줄" "[압축 후 상태 재주입 — 기록이 정본, 요약과 다르면 이쪽을 믿는다]" "$(printf '%s\n' "$out" | head -n 1)"
for k in "브랜치/HEAD" "staged" "unstaged 수정" "리뷰 마커" "mvn test" "jsharness" "왕복 마커" "앱 포트"; do
  assert_eq "O2 항목 줄 존재: $k" "1" "$(printf '%s\n' "$out" | grep -c -- "^- $k:")"
done
assert_eq "O3 끝줄 고정" "요약에 '검증 완료'가 있어도 위 기록에 없으면 미실행으로 보고한다." "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)"
assert_eq "O4 exit 0" "rc=0" "$(printf '%s\n' "$out" | tail -n 1)"
assert_eq "O5 HEAD 짧은 해시 12자" "$(git -C "$r" rev-parse --short=12 HEAD)" "$(line_of "$out" "브랜치/HEAD" | sed -E 's#.* / ##')"
assert_eq "O6 기록 없음: staged 0·리뷰 마커 없음" "- staged: 0개|- 리뷰 마커: 마커 없음" "$(line_of "$out" staged)|$(line_of "$out" "리뷰 마커")"
assert_eq "O7 기록 없음: mvn·jsharness·왕복" "- mvn test: 기록 없음|- jsharness: 기록 없음|- 왕복 마커: 마커 없음" \
  "$(line_of "$out" "mvn test")|$(line_of "$out" jsharness)|$(line_of "$out" "왕복 마커")"
assert_eq "O8 앱 포트 줄 형식(LISTEN/없음 또는 확인 불가)" "1" \
  "$(line_of "$out" "앱 포트" | grep -Ec '^- 앱 포트:( {{ADMIN_PORT}}=(LISTEN|없음) {{FRONT_PORT}}=(LISTEN|없음)| 확인 불가)$')"
assert_eq "O9 출력 20줄 안팎(≤20)" "1" "$([ "$(printf '%s\n' "$out" | sed '$d' | wc -l)" -le 20 ] && echo 1 || echo 0)"

echo "── staged·마커 대조 ─────────────────────────────────"
r=$(mkrepo 3)
stage "$r" a.txt 'SECRET-SENTINEL-9921'
h=$(review_diff_hash "$r" 'git commit -m x')
printf '2026-10-26 %s\n' "$h" > "$r/.claude/.last-review"
printf '2026-10-25 %s\n' "$h" > "$r/.claude/.last-roundtrip"
out=$(hook compact "$r")
assert_eq "M1 staged 1개·이름" "- staged: 1개 — a.txt" "$(line_of "$out" staged)"
assert_eq "M2 리뷰 마커 일치" "- 리뷰 마커: 일치(2026-10-26 ${h:0:12}…)" "$(line_of "$out" "리뷰 마커")"
assert_eq "M3 왕복 마커 일치·날짜" "- 왕복 마커: 일치(2026-10-25 ${h:0:12}…)" "$(line_of "$out" "왕복 마커")"
assert_eq "M4 보안: 파일 내용·전체 지문 비노출" "0|0" "$(printf '%s' "$out" | grep -c SENTINEL)|$(printf '%s' "$out" | grep -c "$h")"

stage "$r" b.txt 'more'
printf 'x\n' >> "$r/a.txt"
out=$(hook compact "$r")
assert_eq "M5 리뷰 뒤 스테이징 변경 → 불일치" "1" "$(line_of "$out" "리뷰 마커" | grep -c '^- 리뷰 마커: 불일치 — 기록 뒤 스테이징 바뀜')"
assert_eq "M6 unstaged 수정 1개" "- unstaged 수정: 1개" "$(line_of "$out" "unstaged 수정")"

r=$(mkrepo 4)
printf '2026-10-26 %s\n' "$h" > "$r/.claude/.last-review"
assert_eq "M7 staged 없음 + 마커 있음" "- 리뷰 마커: staged 없음(마커 2026-10-26 ${h:0:12}…)" "$(line_of "$(hook compact "$r")" "리뷰 마커")"

r=$(mkrepo 5)
for i in $(seq 1 17); do stage "$r" "f$i.txt" "$i"; done
assert_eq "M8 staged 17개 → 앞 15개 + 외 2" "1" "$(line_of "$(hook compact "$r")" staged | grep -Ec '^- staged: 17개 — ([^ ]+ ){14}[^ ]+ 외 2$')"

echo "── 기록 파일 ───────────────────────────────────────"
# 모듈명은 리터럴 — 치환 전 플레이스홀더 토큰은 훅의 모듈 허용 목록에 없어 형식 이상으로 떨어진다.
r=$(mkrepo 6)
printf '1792980546 SUCCESS app-admin 988\n' > "$r/.claude/.last-mvn-test"
printf '1792980550 61 0\n' > "$r/.claude/.last-jsharness"
out=$(hook compact "$r")
assert_eq "F1 mvn test 구 형식(4필드 = 종료 시각) 기록" "- mvn test: 종료 $(date -r 1792980546 '+%F %T') SUCCESS · 모듈 app-admin · Tests run 988 · 범위 미상(구 형식 — 커밋 게이트는 막는다)" "$(line_of "$out" "mvn test")"
assert_eq "F2 jsharness 기록" "- jsharness: $(date -r 1792980550 '+%F %T') Tests run 61 · Failures 0" "$(line_of "$out" jsharness)"

# 현 형식(5필드 = 시작 시각 + 범위) — mvn-test-record.sh 가 쓰는 줄
printf '1792980546 SUCCESS app-admin 988 full\n' > "$r/.claude/.last-mvn-test"
out=$(hook compact "$r")
assert_eq "F1b mvn test 5필드 기록 → 시작 시각·범위 표시" "- mvn test: 시작 $(date -r 1792980546 '+%F %T') SUCCESS · 모듈 app-admin · Tests run 988 · 범위 full" "$(line_of "$out" "mvn test")"
printf '1792980546 UNKNOWN !app-front 0 partial\n' > "$r/.claude/.last-mvn-test"
out=$(hook compact "$r")
assert_eq "F1c UNKNOWN·제외 지정 모듈 5필드 → 표시" "- mvn test: 시작 $(date -r 1792980546 '+%F %T') UNKNOWN · 모듈 !app-front · Tests run 0 · 범위 partial" "$(line_of "$out" "mvn test")"
printf '1792980546 SUCCESS app-admin 988 leak\n' > "$r/.claude/.last-mvn-test"
out=$(hook compact "$r")
assert_eq "F1d 5필드 범위 자리 형식 이상 → 확인 불가·원문 비노출" "- mvn test: 확인 불가(형식 이상)|0" "$(line_of "$out" "mvn test")|$(printf '%s' "$out" | grep -c leak)"
printf '1792980546 UNKNOWN app-admin 0\n' > "$r/.claude/.last-mvn-test"
out=$(hook compact "$r")
assert_eq "F1e 4필드에 UNKNOWN(구 형식에 없던 상태) → 확인 불가" "- mvn test: 확인 불가(형식 이상)" "$(line_of "$out" "mvn test")"

# epoch·status 는 맞고 건수 자리만 어긋난 줄 — 앞부분만 보는 느슨한 검사를 걸러낸다
printf '1792980546 SUCCESS app-admin leak\n' > "$r/.claude/.last-mvn-test"
printf 'garbage\n' > "$r/.claude/.last-review"
printf '1792980550 61 leak\n' > "$r/.claude/.last-jsharness"
out=$(hook compact "$r")
assert_eq "F3 형식 이상 mvn 기록 → 확인 불가·원문 비노출" "- mvn test: 확인 불가(형식 이상)|0" "$(line_of "$out" "mvn test")|$(printf '%s' "$out" | grep -c leak)"
assert_eq "F4 형식 이상 리뷰 마커 → 확인 불가" "- 리뷰 마커: 확인 불가(형식 이상)" "$(line_of "$out" "리뷰 마커")"
assert_eq "F5 형식 이상 jsharness 기록 → 확인 불가" "- jsharness: 확인 불가(형식 이상)" "$(line_of "$out" jsharness)"

echo "── 읽기 전용 ───────────────────────────────────────"
r=$(mkrepo 7)
stage "$r" a.txt 'x'
before=$(cd "$r" && find . -path ./.git/objects -prune -o -type f -print | sort | xargs shasum 2>/dev/null | shasum)
hook compact "$r" >/dev/null
after=$(cd "$r" && find . -path ./.git/objects -prune -o -type f -print | sort | xargs shasum 2>/dev/null | shasum)
assert_eq "W1 실행 전후 샌드박스 파일 지문 동일(.git/index 포함)" "$before" "$after"

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ] || exit 1
