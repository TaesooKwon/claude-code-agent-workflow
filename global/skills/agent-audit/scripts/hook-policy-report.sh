#!/bin/bash
# hook-policy-report.sh — 훅 파일 머리의 정책 줄을 모아 표로 낸다(강제 수준·도구 부재 시 동작).
# 정책 줄 형식(셔뱅 다음 줄): `# hook-policy: 강제=<차단|확인|안내|기록|보조> · 도구부재=<차단|통과|->`
#   강제: 차단 = deny/block 을 낸다 · 확인 = 사용자 승인(ask)을 묻는다 · 안내 = 경고·맥락 주입만 ·
#         기록 = 부수효과(기록·알림)만 · 보조 = 훅이 아닌 래퍼·라이브러리·수동 스크립트
#   도구부재: jq·판정기 같은 의존이 없을 때 차단하는가(fail-closed) 통과하는가(fail-open). 보조는 `-`.
# 사용: hook-policy-report.sh [--tsv | --missing] [디렉터리...]
#   기본 디렉터리 = ~/.claude/hooks 와 (있으면) 현재 프로젝트의 .claude/hooks. 각 디렉터리 바로 아래 *.sh 만 본다
#   (*.test.sh·하위 폴더 제외).
#   (기본) 표 + 정책 줄 없는 파일 목록 / --tsv = "파일명<TAB>강제<TAB>도구부재" 만(다른 스크립트 입력용) /
#   --missing = 정책 줄이 없거나 값이 허용 목록 밖인 파일 경로만.
# 항상 exit 0(보고 전용). 허용 목록 밖 값은 "형식 오류"로 보고한다.
set -u
mode=table
case "${1:-}" in --tsv) mode=tsv; shift;; --missing) mode=missing; shift;; esac
if [ "$#" -eq 0 ]; then
  set -- "$HOME/.claude/hooks"
  proj=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
  [ -d "$proj/.claude/hooks" ] && [ "$proj/.claude/hooks" != "$HOME/.claude/hooks" ] && set -- "$@" "$proj/.claude/hooks"
fi

rows=""; missing=""
for d in "$@"; do
  for f in "$d"/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in *.test.sh) continue;; esac
    line=$(head -5 "$f" | grep -m1 '^# hook-policy: ' || true)
    k=$(printf '%s' "$line" | sed -n 's/.*강제=\([^ ]*\).*/\1/p')
    t=$(printf '%s' "$line" | sed -n 's/.*도구부재=\([^ ]*\).*/\1/p')
    case "$k" in 차단|확인|안내|기록|보조) ;; *) missing="$missing$f"$'\n'; continue;; esac
    case "$t" in 차단|통과|-) ;; *) missing="$missing$f"$'\n'; continue;; esac
    rows="$rows${f##*/}"$'\t'"$k"$'\t'"$t"$'\n'
  done
done

case "$mode" in
  tsv) printf '%s' "$rows" | sort -u ;;
  missing) printf '%s' "$missing" ;;
  *)
    echo "=== 훅 정책 표 ($*) ==="
    printf '%s' "$rows" | sort -u | sort -t$'\t' -k2,2 -k1,1 | awk -F'\t' '{printf "  %-36s 강제=%-4s 도구부재=%s\n", $1, $2, $3}'
    echo "--- 강제 수준별 개수 ---"
    printf '%s' "$rows" | sort -u | cut -f2 | sort | uniq -c | sed 's/^/  /'
    echo "--- 정책 줄 없음·형식 오류 ---"
    if [ -n "$missing" ]; then printf '%s' "$missing" | sed 's/^/  /'; else echo "  (없음)"; fi
    ;;
esac
exit 0
