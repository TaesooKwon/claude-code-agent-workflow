#!/bin/bash
# hook-events-retention.sh — SessionStart 훅. hook-obs.sh 가 쌓는 월별 관측 로그(hook-events/YYYY-MM.jsonl)의 보존 회전.
#   - 발동: 그날 첫 세션 1회. 하루 마커 = 로그 디렉터리 안 `.retention-YYYYMMDD` 디렉터리를 mkdir 로 원자 획득 —
#     병행 세션이 같은 날 동시에 떠도 mkdir 에 성공한 하나만 진행한다. 지난 날짜 마커는 rmdir 로 정리.
#   - 대상: 디렉터리 바로 아래, 이름이 `^[0-9]{4}-(0[1-9]|1[0-2])\.jsonl$` 이고 심링크가 아닌 정규 파일만(허용 목록).
#     이번 달부터 거슬러 HOOK_EVENTS_KEEP_MONTHS 개월(기본 2 — 이번 달·지난달)을 남기고 그보다 오래된 월 파일을 삭제.
#     이번 달 파일은 보존 개월 계산과 별개로 한 번 더 제외한다.
#   - 미발동: 디렉터리 없음 / 오늘 마커가 이미 있음.
#   - 보존 개월: 1~4자리 숫자이고 1 이상일 때만 인정, 그 밖은 2.
#   - 출력: 삭제했을 때만 개수 한 줄(로그 내용·파일명은 내지 않는다). 항상 exit 0.
# 테스트용 덮어쓰기: HOOK_EVENTS_DIR(기본 $HOME/.claude/hook-events).
# ponytail: 월 단위 회전이라 한 달 파일이 커지는 건 못 막는다(현재 하루 수십 MB 가능) /
#           업그레이드 경로 = hook-obs 쪽 일 단위 파일 + 여기서 일 단위 보존.
set -u

dir=${HOOK_EVENTS_DIR:-$HOME/.claude/hook-events}
dir=${dir%/}
[ -d "$dir" ] && [ ! -L "$dir" ] || exit 0

now=$(date '+%Y%m%d %Y %m' 2>/dev/null) || exit 0
today=${now%% *}; rest=${now#* }; y=${rest%% *}; m=${rest#* }
case "$today$y$m" in ''|*[!0-9]*) exit 0 ;; esac

mkdir "$dir/.retention-$today" 2>/dev/null || exit 0
for mk in "$dir"/.retention-*; do
  [ -d "$mk" ] && [ ! -L "$mk" ] || continue
  name=${mk##*/}
  [ "$name" = ".retention-$today" ] && continue
  [[ "$name" =~ ^\.retention-[0-9]{8}$ ]] && rmdir "$mk" 2>/dev/null
done

keep=${HOOK_EVENTS_KEEP_MONTHS:-2}
if [[ "$keep" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$keep))" -ge 1 ]; then keep=$((10#$keep)); else keep=2; fi

cur=$(( 10#$y * 12 + 10#$m - 1 ))
this_month="$y-$m.jsonl"
deleted=0
for f in "$dir"/*.jsonl; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  name=${f##*/}
  [[ "$name" =~ ^([0-9]{4})-(0[1-9]|1[0-2])\.jsonl$ ]] || continue
  [ "$name" = "$this_month" ] && continue
  idx=$(( 10#${BASH_REMATCH[1]} * 12 + 10#${BASH_REMATCH[2]} - 1 ))
  if [ "$idx" -le $(( cur - keep )) ]; then
    rm -f -- "$f" 2>/dev/null && deleted=$((deleted + 1))
  fi
done

[ "$deleted" -gt 0 ] && echo "[hook-events-retention] 오래된 월 로그 ${deleted}개 삭제(보존 ${keep}개월)"
exit 0
