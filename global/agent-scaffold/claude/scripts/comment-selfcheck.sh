#!/usr/bin/env bash
# 주석 셀프체크 — 참/거짓을 판정하지 않는다. 이번 diff 에서 "내가 추가한 주석" 중
# 사람이 반드시 근거를 세어봐야 할 문장만 목록으로 뽑는다(CLAUDE.md 커밋 게이트 ③ 주석 셀프체크).
# 사용: comment-selfcheck.sh [--repair] [<git diff 인자…>]   기본 = --cached
#   --repair = 리뷰 지적 수리분(작업 트리 − 인덱스)을 본다. 수리를 `git add` 하기 전에 돌린다 —
#              수리로 새로 쓴 주석 문장 전부(ⓓ)와 지운 주석 줄 수를 보여준다.
# 종료 코드: 0 = 검사함(후보 유무 무관) / 2 = 대상 diff 0건이라 미실행(통과로 읽지 마라)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
REPAIR=0
if [ "${1:-}" = "--repair" ]; then REPAIR=1; shift; fi
if [ "$REPAIR" -eq 0 ] && [ $# -eq 0 ]; then set -- --cached; fi

# ⚠️ 대상 diff 가 비면 '주석 없음'이 아니라 '미실행'이다 — 스테이징 전에 기본(--cached)으로 돌려 나온
#    빈 결과를 통과로 보고한 사고가 반복됐다(2026-09-11 두 커밋 연속). 결과 0 과 미실행을 종료 코드로 가른다.
if git diff --quiet "$@" -- '*.java' '*.xml' '*.js' '*.html' '*.sql'; then
  if [ "$REPAIR" -eq 1 ]; then
    echo "수리분 diff 0건(git diff $*) — 미실행: 결과 0 이 아니다. --repair 는 아직 스테이징하지 않은 수리만 본다 — 수리를 git add 했다면 그 전에 돌렸어야 한다"
  else
    echo "대상 diff 0건(git diff $*) — 미실행: 결과 0 이 아니다. 인자 없이 돌리면 --cached(스테이징분)만 본다 — 스테이징 후 다시 돌리거나 범위 인자를 준다(예: HEAD~1 HEAD)"
  fi
  exit 2
fi

ADDED=$(git diff "$@" -U5 -- '*.java' '*.xml' '*.js' '*.html' '*.sql' \
  | awk '
    /^\+\+\+ b\// { f=substr($0,7); inx=0; injd=0; next }
    /^(---|diff |index |@@)/ { next }
    {
      c1 = substr($0,1,1)
      add = (c1 == "+")
      # 삭제 라인은 <b>이전 버전</b>의 내용이라 새 버전의 블록 상태를 바꾸면 안 된다 —
      # 닫는 --> 가 삭제분에 있으면 뒤따르는 추가 라인이 주석 밖으로 오인된다(2026-09-09 실측).
      if (c1 == "-") next
      t = substr($0,2); sub(/^[ \t]*/,"",t); sub(/[ \t]*$/,"",t)
      # 블록 상태는 컨텍스트 라인으로도 갱신한다 — 여러 줄 주석의 시작(<!-- , /*)이
      # 변경되지 않은 채 컨텍스트로만 보이면, 본문 라인만 보고는 주석인 줄 알 수 없다.
      wasin = (inx || injd)
      if (t ~ /^<!--/) inx=1
      if (t ~ /^\/\*/) injd=1
      iscmt = wasin || inx || injd || (t ~ /^(\/\/|\*|--[^-])/)
      if (t ~ /-->/) inx=0
      if (t ~ /\*\//) injd=0
      if (!add || !iscmt) next
      if (t ~ /^(\/\*+|\*+\/|\*|<!--|-->)$/ || t ~ /^\* *@/) next
      body=t; sub(/^(\/\/+|\/\*+|\*|<!--|--)[ \t]*/,"",body); sub(/[ \t]*-->$/,"",body)
      if (length(body) < 8) next
      printf "%s\t%s\n", f, body
    }')

if [ "$REPAIR" -eq 1 ]; then
  # 지운 주석 줄 — 삭제 라인의 첫머리가 주석 표지인 것만 센다.
  # ponytail: 여러 줄 <!-- --> 의 본문 줄은 안 세진다 / 정확히 세려면 위 awk 의 블록 상태 추적을 삭제 라인에도 적용
  DELETED=$(git diff "$@" -- '*.java' '*.xml' '*.js' '*.html' '*.sql' \
    | awk '/^---/ { next } /^-/ { t=substr($0,2); sub(/^[ \t]*/,"",t); if (t ~ /^(\/\/|\/\*|\*|<!--|--[^-])/) n++ } END { print n+0 }')
  [ -z "$ADDED" ] && { echo "수리가 새 주석 문장을 들이지 않았다(지운 주석 ${DELETED}줄) — 지우는 방향이라 셀프체크 대상 없음"; exit 0; }
fi
[ -z "$ADDED" ] && { echo "추가된 서술형 주석 없음 — 셀프체크 대상 없음"; exit 0; }
TOTAL=$(printf '%s\n' "$ADDED" | wc -l | tr -d ' ')
echo "== 이번 diff 가 추가한 서술형 주석 ${TOTAL}줄 — 아래는 근거를 세어야 할 후보 =="; echo

# ⚠️ 매치는 본문 필드($2)에만 건다 — 파일 경로에는 Mapper·.java 가 늘 들어 있어 전건이 걸린다.
pick() { printf '%s\n' "$ADDED" | awk -F'\t' -v re="$1" '$2 ~ re'; }
A=$(pick '[0-9]+ *(곳|개|건|종|가지|군데)|뿐|유일|오직|항상|절대|전수|모두|전부|둘 다|양쪽|하나만|만 (있|쓴|건드|사용|호출|본|남)')
B=$(pick '\.(java|xml|js|html|sql)([^A-Za-z0-9]|$)|\{@(code|link)|[A-Z][A-Za-z0-9]{2,}(Mapper|ServiceImpl|Service|Controller|Test|Filter|Guard|Util|Catalog)|다른 (곳|화면|파일|모듈|층)|(먼저|이후에|나중에|순서로) ')
# ⓒ 복제 — 같은 문장이 두 파일 이상에 추가됐다(원본에서만 참인 문장이 복제본에서 거짓이 된다)
C=$(printf '%s\n' "$ADDED" | awk -F'\t' '{cnt[$2]++; where[$2]=where[$2]" "$1} END{for(k in cnt) if(cnt[k]>1) printf "%s\t(%d곳:%s)\n", k, cnt[k], where[k]}')

show() { [ -n "$2" ] || return 0
  n=$(printf '%s\n' "$2" | wc -l | tr -d ' ')
  echo "--- $1 (${n}건) ---"
  printf '%s\n' "$2" | awk -F'\t' '{printf "  [%s]\n    %s\n", $1, $2}'
  echo "  ⇒ $3"; echo; }

if [ "$REPAIR" -eq 1 ]; then
  show "ⓓ 수리로 새로 쓴 주석 문장 — 지운 주석 ${DELETED}줄" "$ADDED" "주석 수리는 단언을 지우는 방향이 기본이다 — 역할·불변식만 남기고 새 사실(전칭·범위·다른 파일 동작)을 들이지 않는다. 남기는 문장은 그 문장 자체를 ⓐⓑ 기준으로 근거를 센다."
fi
show "ⓐ 개수·배타 단언" "$A" "소스 형태로 앵커해 grep -c 로 센다(자기 diff 의 주석이 모집단에 섞이지 않게). 못 세면 불변식·역할 서술로 낮춘다."
show "ⓑ 코드 밖 사실 단언(다른 파일·클래스·계층)" "$B" "근거 명령 1개를 친다. 못 치면 단언을 빼고 역할로 서술한다."
show "ⓒ 복제된 주석 — 두 곳 이상에 같은 문장" "$C" "원본에서만 참인 문장이 복제본에서 거짓이 된다. 자리마다 다시 판정한다."

[ -z "$A$B$C" ] && echo "ⓐⓑⓒ 해당 없음 — 그래도 이 diff 로 거짓이 된 기존 주석이 있는지는 눈으로 본다."
echo "※ 판정은 사람이 한다. 이 목록은 '빠뜨릴 수 없게' 하는 장치일 뿐이다."
