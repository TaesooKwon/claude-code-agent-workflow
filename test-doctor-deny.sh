#!/usr/bin/env bash
# doctor.sh [5g] 전역 deny 대조 시험 — 가짜 킷(doctor.sh 사본 + 가짜 템플릿·등록 파일)과 가짜 HOME 으로 doctor 를 돌려 [5g] 구간만 본다.
# 실제 ~/.claude·킷 등록 파일은 읽지 않는다. 기대 문자열은 리터럴.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/doctor-deny.XXXXXX") || exit 1
trap 'case "$ROOT" in */doctor-deny.*) rm -rf "$ROOT" ;; esac' EXIT
T=0; P=0; F=0
OUT="$ROOT/out"

# $1 = 케이스 이름, $2 = 라이브 settings.json 내용(없으면 '-' → 파일 안 만듦), $3 = 템플릿 내용, $4 = 등록 파일 내용 → $OUT 에 [5g] 구간
run5g() {
  local c="$ROOT/$1" k h
  k="$c/kit"; h="$c/home"; mkdir -p "$k/global" "$h/.claude"
  cp "$HERE/doctor.sh" "$k/doctor.sh"
  printf '%s\n' "$3" > "$k/global/settings.json.template"
  printf '%s\n' "$4" > "$k/settings-deny-kit-only.txt"
  [ "$2" = - ] || printf '%s\n' "$2" > "$h/.claude/settings.json"
  HOME="$h" SCRUB_NAMES_FILE="$c/none" bash "$k/doctor.sh" 2>&1 | sed -n '/=== \[5g\]/,/=== \[6\]/p' | sed '1d;$d' > "$OUT"
}
has()  { T=$((T+1)); if grep -qF -- "$2" "$OUT"; then P=$((P+1)); else F=$((F+1)); printf 'FAIL %s (기대 [%s] 없음)\n' "$1" "$2"; sed 's/^/    | /' "$OUT"; fi; }
hasnt(){ T=$((T+1)); if grep -qF -- "$2" "$OUT"; then F=$((F+1)); printf 'FAIL %s ([%s] 있으면 안 됨)\n' "$1" "$2"; sed 's/^/    | /' "$OUT"; else P=$((P+1)); fi; }

TM='{"permissions":{"deny":["Bash(a)","Bash(b)","Bash(c)"]}}'
REG='# 주석
Bash(c)
'
# ⓓ 정합 — 라이브 ⊂ 템플릿, 차이 = 등록 그대로
run5g d '{"permissions":{"deny":["Bash(a)","Bash(b)"]}}' "$TM" "$REG"
has "ⓓ 정합 ok" "✓ 전역 deny 정합(라이브 2 · 템플릿 3 · 등록된 의도 차이 1)"; hasnt "ⓓ 경고 없음" "⚠"
# ⓐ 라이브에만 — 홈 절대경로는 ~ 로
run5g a "{\"permissions\":{\"deny\":[\"Bash(a)\",\"Bash(b)\",\"Read($ROOT/a/home/.ssh/**)\"]}}" "$TM" "$REG"
has "ⓐ 라이브에만 경고" "⚠ deny 라이브에만: [Read(~/.ssh/**)]"; hasnt "ⓐ 홈 절대경로 미출력" "$ROOT/a/home"
# ⓑ 템플릿에만 + 미등록
run5g b '{"permissions":{"deny":["Bash(a)"]}}' "$TM" "$REG"
has "ⓑ 미등록 경고" "⚠ deny 템플릿에만(의도 차이 미등록): [Bash(b)]"
# ⓒ 등록돼 있는데 템플릿에 없음 = 경고 / 등록 항목이 라이브에도 있음 = ✓ 정보(경고 아님)
run5g c '{"permissions":{"deny":["Bash(a)","Bash(b)","Bash(c)"]}}' "$TM" "$REG
Bash(zz)"
has "ⓒ 등록 낡음(템플릿에 없음)" "⚠ deny 등록이 낡음(템플릿에 없음): [Bash(zz)]"
has "ⓒ 등록 항목이 라이브에 = 정보 줄" "✓ 등록된 의도 차이 중 이 머신 라이브에 있는 것: [Bash(c)] — 킷 기본값 그대로(새 머신이면 정상)"
hasnt "ⓒ 라이브에 있음은 경고 아님" "(라이브에 있음)"
# 등록·라이브에 있으나 템플릿에서 빠진 규칙 — ✓ 정보 줄(킷 기본값 그대로)에 넣지 않는다
run5g x '{"permissions":{"deny":["Bash(a)","Bash(X)"]}}' '{"permissions":{"deny":["Bash(a)"]}}' 'Bash(X)'
hasnt "템플릿 밖 등록 항목은 정보 줄 아님" "✓ 등록된 의도 차이 중"
has "템플릿 밖: 라이브에만 경고" "⚠ deny 라이브에만: [Bash(X)]"
has "템플릿 밖: 등록 낡음 경고" "⚠ deny 등록이 낡음(템플릿에 없음): [Bash(X)]"
# 새 머신 — 라이브 = 템플릿 전체(등록 항목 전부 라이브에 있음) → 경고 없이 정보 줄 + 정합
run5g nm '{"permissions":{"deny":["Bash(a)","Bash(b)","Bash(c)"]}}' "$TM" "$REG"
hasnt "새 머신 경고 없음" "⚠"
has "새 머신 정보 줄" "✓ 등록된 의도 차이 중 이 머신 라이브에 있는 것: [Bash(c)]"
has "새 머신 정합" "✓ 전역 deny 정합(라이브 3 · 템플릿 3 · 등록된 의도 차이 1)"
# 판정 불가 — 라이브 없음 · deny 배열 아님 · permissions 없음 · JSON 깨짐 · 문자열 아닌 원소
run5g n1 - "$TM" "$REG"; has "불가: 라이브 없음" "⚠ 라이브 settings.json 없음 — 전역 deny 대조 판정 불가"
for x in 'n2|{"permissions":{"deny":"Bash(a)"}}' 'n3|{"theme":"dark"}' 'n4|{"permissions":' 'n5|{"permissions":{"deny":["Bash(a)",3]}}'; do
  run5g "${x%%|*}" "${x#*|}" "$TM" "$REG"
  has "불가: ${x%%|*}" "못 읽음(키 없음·형식·JSON) — 전역 deny 대조 판정 불가"; hasnt "불가 ${x%%|*}: ok 아님" "✓"
done
# 읽기 전용 — doctor 실행 전후 라이브 settings.json 불변
L="$ROOT/d/home/.claude/settings.json"; s0=$(cksum < "$L")
HOME="$ROOT/d/home" SCRUB_NAMES_FILE="$ROOT/none" bash "$ROOT/d/kit/doctor.sh" >/dev/null 2>&1
T=$((T+1)); if [ "$(cksum < "$L")" = "$s0" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL 라이브 settings.json 이 바뀜"; fi

echo "Tests run: $T, passed: $P, failed: $F"
[ "$T" -gt 0 ] && [ "$F" = 0 ]
