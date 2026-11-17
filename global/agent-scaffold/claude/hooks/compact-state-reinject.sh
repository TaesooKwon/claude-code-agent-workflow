#!/usr/bin/env bash
# SessionStart(compact) 상태 재주입 — 컨텍스트 압축 뒤 요약에서 빠질 수 있는 커밋 게이트 "상태"를
# 기록 파일에서 결정론적으로 다시 읽어 평문 stdout 으로 넣는다(exit 0 stdout = 컨텍스트 주입).
# 규칙 재서술이 아니다 — CLAUDE.md 는 압축 뒤에도 재로드된다. 여기는 기록값만 옮긴다.
#
# 읽는 기록(전부 읽기 전용, 이 훅은 어떤 파일도 쓰지 않는다):
#   .claude/.last-review     "<날짜> <지문>"            ← mark-review.sh
#   .claude/.last-mvn-test   "<시작 epoch> <status> <모듈> <건수> <범위>" ← mvn-test-record.sh
#                            (구 형식 "<종료 epoch> <status> <모듈> <건수>" 도 읽는다)
#   .claude/.last-jsharness  "<epoch> <N> <F>"          ← jsharness-record.sh
#   .claude/.last-roundtrip  "<날짜> <지문>"            ← mark-roundtrip.sh
# 지문 대조는 lib/review-diff.sh 의 review_diff_hash 하나로 한다(검문·기록과 같은 정본).
#
# 하한선: 입력 = stdin JSON 의 .source 가 "compact" 일 때만 출력(그 밖은 무출력) · 출력은 경로·해시 앞 12자·건수만
#   (diff 본문·파일 내용 금지 — 기록 필드는 형식 허용목록에 맞을 때만 옮긴다) · 각 줄은 개별 실패해도 "확인 불가"로 두고 계속.
# 안전: jq 부재 · JSON 파싱 실패 · git 레포 아님 → 조용히 exit 0(fail-open). 외부 명령은 개별 2초 상한.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
src=$(printf '%s' "$input" | jq -r 'if type == "object" then (.source // empty) else empty end' 2>/dev/null) || exit 0
[ "$src" = "compact" ] || exit 0

proj="${CLAUDE_PROJECT_DIR:-}"
[ -n "$proj" ] || exit 0
git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || exit 0

here=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
NA="확인 불가"

# 외부 명령 상한(전체 5초 예산) — timeout 이 없으면 그대로 실행한다.
lim() { if command -v timeout >/dev/null 2>&1; then timeout 2 "$@"; else "$@"; fi; }

# epoch → 사람 읽는 시각(BSD/GNU date 양쪽)
hm() { date -r "$1" '+%F %T' 2>/dev/null || date -d "@$1" '+%F %T' 2>/dev/null || printf 'epoch %s' "$1"; }

# 기록 파일 첫 줄을 읽는다 — 없으면 rc 1, 제어문자는 걷어낸다.
rec() { [ -f "$1" ] || return 1; head -n 1 "$1" 2>/dev/null | tr -d '\000-\037\177'; }

echo "[압축 후 상태 재주입 — 기록이 정본, 요약과 다르면 이쪽을 믿는다]"

# 2) 브랜치·HEAD
br=$(lim git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null) || br=""
hd=$(lim git -C "$proj" rev-parse --short=12 HEAD 2>/dev/null) || hd=""
echo "- 브랜치/HEAD: ${br:-$NA} / ${hd:-$NA}"

# 3) staged·unstaged
if staged=$(lim git -C "$proj" diff --cached --name-only 2>/dev/null); then
  sn=$(printf '%s' "$staged" | grep -c . 2>/dev/null); sn=${sn:-0}
  if [ "$sn" -eq 0 ]; then
    echo "- staged: 0개"
  else
    names=$(printf '%s\n' "$staged" | head -n 15 | tr '\n' ' ' | sed 's/ $//')
    more=""; [ "$sn" -gt 15 ] && more=" 외 $((sn - 15))"
    echo "- staged: ${sn}개 — ${names}${more}"
  fi
else
  sn=""; echo "- staged: $NA"
fi
if un=$(lim git -C "$proj" diff --name-only 2>/dev/null); then
  echo "- unstaged 수정: $(printf '%s' "$un" | grep -c .)개"
else
  echo "- unstaged 수정: $NA"
fi

# 현재 staged 지문(리뷰·왕복 마커 대조 공용) — rc 2 = staged 없음
cur=""; crc=1
if [ -f "$here/lib/review-diff.sh" ]; then
  # shellcheck disable=SC1091
  . "$here/lib/review-diff.sh" 2>/dev/null
  if command -v review_diff_hash >/dev/null 2>&1; then
    cur=$(review_diff_hash "$proj" 'git commit -m x' 2>/dev/null); crc=$?
  fi
fi

# 마커 "<날짜> <지문>" 을 현재 지문과 대조 → 한 줄 판정
marker_cmp() {
  local line d h
  line=$(rec "$1") || { printf '마커 없음'; return; }
  d=${line%% *}; h=${line#* }
  printf '%s' "$d" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { printf '%s(형식 이상)' "$NA"; return; }
  printf '%s' "$h" | grep -Eq '^[0-9a-f]{64}$' || { printf '%s(형식 이상)' "$NA"; return; }
  case "$crc" in
    0) if [ "$h" = "$cur" ]; then printf '일치(%s %s…)' "$d" "${h:0:12}"
       else printf '불일치 — 기록 뒤 스테이징 바뀜(%s %s… ≠ 현재 %s…)' "$d" "${h:0:12}" "${cur:0:12}"; fi ;;
    2) printf 'staged 없음(마커 %s %s…)' "$d" "${h:0:12}" ;;
    *) printf '%s(지문 산출 실패, 마커 %s %s…)' "$NA" "$d" "${h:0:12}" ;;
  esac
}

# 4) 리뷰 마커
echo "- 리뷰 마커: $(marker_cmp "$proj/.claude/.last-review")"

# 5) mvn test 기록
if line=$(rec "$proj/.claude/.last-mvn-test"); then
  if printf '%s' "$line" | grep -Eq '^[0-9]+ (SUCCESS|FAILURE|UNKNOWN) [A-Za-z0-9._,:/!-]+ [0-9]+ (full|partial)$'; then
    set -- $line
    echo "- mvn test: 시작 $(hm "$1") $2 · 모듈 $3 · Tests run $4 · 범위 $5"
  elif printf '%s' "$line" | grep -Eq '^[0-9]+ (SUCCESS|FAILURE) [A-Za-z0-9._,:/-]+ [0-9]+$'; then
    set -- $line
    echo "- mvn test: 종료 $(hm "$1") $2 · 모듈 $3 · Tests run $4 · 범위 미상(구 형식 — 커밋 게이트는 막는다)"
  else
    echo "- mvn test: $NA(형식 이상)"
  fi
else
  echo "- mvn test: 기록 없음"
fi

# 6) jsharness 기록(jsharness-record.sh 형식 = "<epoch> <N> <F>")
if line=$(rec "$proj/.claude/.last-jsharness"); then
  if printf '%s' "$line" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$'; then
    set -- $line
    echo "- jsharness: $(hm "$1") Tests run $2 · Failures $3"
  else
    echo "- jsharness: $NA(형식 이상)"
  fi
else
  echo "- jsharness: 기록 없음"
fi

# 7) 왕복 마커
echo "- 왕복 마커: $(marker_cmp "$proj/.claude/.last-roundtrip")"

# 8) 앱 포트
ports=""
if command -v lsof >/dev/null 2>&1; then
  for p in {{ADMIN_PORT}} {{FRONT_PORT}}; do
    if lim lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then ports="$ports $p=LISTEN"; else ports="$ports $p=없음"; fi
  done
  echo "- 앱 포트:${ports}"
else
  echo "- 앱 포트: $NA"
fi

echo "요약에 '검증 완료'가 있어도 위 기록에 없으면 미실행으로 보고한다."
exit 0
