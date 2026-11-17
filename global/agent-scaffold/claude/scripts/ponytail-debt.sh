#!/usr/bin/env bash
# ponytail 부채 장부 — 소스의 `ponytail:` 마커를 한 줄씩 모아 출력한다(/ponytail-debt 대체, 읽기 전용).
# 사용: bash .claude/scripts/ponytail-debt.sh [모듈 경로…]   (기본 = {{MODULE_CORE}}/src {{MODULE_ADMIN}}/src {{MODULE_FRONT}}/src)
# 판정: 마커 블록(아래 marker_block) 안에 구분자 ' / '(줄 끝 ' /' 포함)가 있으면 통과, 없으면 트리거 어휘
#       (TRIGGER_WORDS) 중 하나라도 있으면 통과, 둘 다 없으면 no-trigger.
# 마커 블록 = 마커 줄 + 뒤 2줄(무조건 — 바깥 블록 주석 안의 마커는 접두 없는 줄로 이어진다) + 그 뒤로 이어지는 주석 줄
#   (마커 줄 안에서 주석이 닫히면 마커 줄만). 마커 줄이 닫히지 않은 /* 또는 <!-- 를 열면 닫힐 때까지, 아니면 주석 접두(// # * <!--)로 시작하는 연속 줄.
#   3줄째부터는 빈 주석 줄·javadoc 태그(* @)·닫는 */ --> 에서 멈추고, 다음 ponytail: 마커에서는 언제나 멈춘다.
# ponytail: 블록은 최대 8줄(BLOCK_MAX)까지만 본다 — 그보다 긴 문단의 9줄째 이후 업그레이드 경로는 no-trigger 로 오탐 / 필요해지면 상한을 올린다.
# ponytail: 어휘는 2026-11-17 대표 레포 마커에서 실측한 표현 목록이다 — 다른 표현의 트리거는 오탐 / 오탐이 보이면 TRIGGER_WORDS 에 더한다.
set -euo pipefail
BLOCK_MAX=8
TRIGGER_WORDS='업그레이드|전환|재검토|필요해지면|생기면|붙으면|되면|바꾼다|바꾸고|바꿀 것|확장할 것|추가할 것|올린다|조인다|좁힌다|흡수|지운다|확정 시|확정 후|붙이려면'
marker_block(){ # $1 = 파일, $2 = 마커 줄 번호 → 마커 블록 줄들을 출력
  awk -v n="$2" -v max="$BLOCK_MAX" '
    NR < n { next }
    NR == n { print; open = ($0 ~ /\/\*|<!--/) && ($0 !~ /\*\/|-->/); c = 1; if ($0 ~ /\*\/|-->/) exit; next }
    {
      if (c >= max || $0 ~ /ponytail:/) exit
      if (c < 3) { print; c++; next }
      if (!open) {
        if ($0 !~ /^[[:space:]]*(\/\/|#|\*|<!--)/) exit
        if ($0 ~ /^[[:space:]]*(\/\/|#|\*)[[:space:]]*$/ || $0 ~ /^[[:space:]]*\*[[:space:]]*@/) exit
      }
      print; c++
      if ($0 ~ /\*\/|-->/) exit
    }' "$1"
}
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
roots=("$@"); [ ${#roots[@]} -eq 0 ] && roots=({{MODULE_CORE}}/src {{MODULE_ADMIN}}/src {{MODULE_FRONT}}/src)
total=0; notrig=0
# 소유 판정 불변식(퍼블 소유 = 읽기 전용 자산은 장부 밖):
#  - 모듈의 src/main/resources/static/ 아래는 resources/js/develop/·resources/css/develop/ 아래만 넣는다(html·js/design·css·images = 퍼블 소유).
#  - 그 밖의 경로는 개발 소유로 보고 넣는다 — java·templates 와 src/main 밖의 static(예: src/test/resources/static)도 여기에 든다.
#  - 앵커는 grep 에 넘긴 루트 아래 상대 경로에서 먼저 찾는다(첫 src/main/resources/static/ — 그 안에 든 같은 이름 폴더는 안쪽 경로).
#    상대 경로에 앵커가 없으면 전체 경로의 마지막 src/main/ 바로 뒤가 resources/static/ 인지 본다 — 루트를 static 안쪽으로 준 경우를 위한 갈래다.
# ponytail: 루트가 모듈 src 밖 폴더이고 그 위에 src/main/resources/static 이 있으면(예: <static>/M/docs) 상위 static 으로 판정한다 / 필요해지면 pom.xml 위치로 모듈 경계를 잡도록 전환.
static_inner(){ # $1 = 루트(끝 / 제거), $2 = grep 이 낸 경로 → static 안쪽 경로를 출력, static 밖이면 1
  local rel full
  case "$2" in "$1"/*) rel=${2#"$1"} ;; *) rel="" ;; esac
  case "$rel" in */src/main/resources/static/*) printf '%s' "${rel#*/src/main/resources/static/}"; return 0 ;; esac
  full="/$2"
  case "${full##*/src/main/}" in resources/static/*) printf '%s' "${full##*/src/main/resources/static/}"; return 0 ;; esac
  return 1
}
for root in "${roots[@]}"; do
root_n=$root; while [ "$root_n" != / ] && [ "${root_n%/}" != "$root_n" ]; do root_n=${root_n%/}; done
while IFS= read -r hit; do
  f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}
  if inner=$(static_inner "$root_n" "$f"); then
    # ponytail: 개발 소유 경로를 static/resources/{js,css}/develop 로 고정 — 정적 레이아웃이 다른 레포는 이 case 를 그 경로로 고친다 / 업그레이드 = 경로를 설정 변수로
    case "$inner" in resources/js/develop/*|resources/css/develop/*) ;; *) continue ;; esac
  fi
  ctx=$(marker_block "$f" "$n")
  tag=""
  if ! grep -qE ' /( |$)' <<<"$ctx" && ! grep -qE -- "$TRIGGER_WORDS" <<<"$ctx"; then tag=" [no-trigger]"; notrig=$((notrig+1)); fi
  total=$((total+1))
  printf '%s:%s%s\n  %s\n' "$f" "$n" "$tag" "$(sed -E 's/^[[:space:]]*(\/\/|#|\/\*|\*|<!--)[[:space:]]*//' <<<"${rest#*:}")"
done < <(grep -rnE --include='*.java' --include='*.xml' --include='*.html' --include='*.js' --include='*.css' \
          --exclude-dir=target -e '(//|#|\*|<!--) ?ponytail:' -- "$root" || true)
done
echo "----"; echo "$total markers, $notrig with no trigger."
