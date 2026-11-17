#!/usr/bin/env bash
# memory-hygiene 스캔 — 현재 프로젝트 memory의 위생 후보를 리포트(판단·수정은 하지 않음).
# 사용: bash scan.sh [프로젝트경로]   (생략 시 $CLAUDE_PROJECT_DIR → $PWD)
set -u

proj="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
slug=$(printf '%s' "$proj" | sed 's#/#-#g')
MEM="$HOME/.claude/projects/$slug/memory"
IDX="$MEM/MEMORY.md"

# cwd 가 이미 memory 디렉터리면 슬러그를 다시 씌우지 않는다 — 씌우면 존재하지 않는 경로가 되어
# "memory 없음"으로 즉시 종료하고, 그 미실행이 호출자에게는 "위생 문제 0건"으로 보인다
# (2026-09-09 실측: 그 1줄 출력을 탐지력 손실로 오독해 스크립트를 의심했다).
if [ ! -f "$IDX" ] && [ -f "$proj/MEMORY.md" ]; then
  MEM="$proj"
  IDX="$MEM/MEMORY.md"
fi

if [ ! -f "$IDX" ]; then
  echo "✗ memory 없음: $MEM (프로젝트 경로 확인: $proj)"; exit 1
fi

echo "=== memory-hygiene 스캔: $MEM ==="
total=$(ls "$MEM"/*.md 2>/dev/null | grep -cv 'MEMORY\.md')
echo "파일 ${total}개 · 인덱스 $(grep -c '^- \[' "$IDX" 2>/dev/null)라인"

echo
echo "--- [1] 인덱스 죽은 링크(파일 부재) ---"
found=0
grep -oE '\]\([^)]+\.md\)' "$IDX" | sed 's/^](//;s/)$//' | sort -u | while IFS= read -r f; do
  case "$f" in /*) p="$f";; *) p="$MEM/$f";; esac
  [ -f "$p" ] || { echo "  ✗ $f"; }
done
echo "  (출력 없으면 정상)"

echo
echo "--- [2] 본문 죽은 [[위키링크]] (미래 마킹 의도일 수 있음 — 판단 대상) ---"
# 링크 대상은 프로젝트 memory 만이 아니다 — 전역 규약이 조항 근거를 rules-rationale 로 빼면서
# `[[슬러그]]` 가 그쪽 파일을 가리킨다(전역 CLAUDE.md 머리말: "정본 = ~/.claude/rules-rationale/<이름>.md").
# 그 디렉터리를 보지 않으면 정상 포인터가 죽은 링크로 무더기 오탐되고(2026-09-09 실측 37건 중 실제 0건),
# 목록이 무용해져 다음 사람이 [2] 절을 통째로 건너뛴다.
RATIONALE="${CLAUDE_RULES_RATIONALE:-$HOME/.claude/rules-rationale}"
for f in "$MEM"/*.md; do
  [ "$(basename "$f")" = "MEMORY.md" ] && continue
  # 유효 위키링크는 슬러그 형식만 — 코드 스니펫의 [[ ]] 리터럴(Thymeleaf 등) 오탐 제외.
  grep -oE '\[\[[^]|]+\]\]' "$f" 2>/dev/null | sed 's/^\[\[//;s/\]\]$//' | grep -E '^[A-Za-z0-9._-]+$' | sort -u | while IFS= read -r l; do
    [ -f "$MEM/$l.md" ] && continue
    [ -f "$RATIONALE/$l.md" ] && continue
    echo "  ? $(basename "$f"): [[$l]]"
  done
done
echo "  (출력 없으면 정상)"

echo
echo "--- [3] 진행표시 마커 잔존(완료됐다면 3곳 동기 치환 대상) ---"
MARK='🔴|🟡|⛔|미검증|검증중|미커밋|커밋 대기|보류|재개 시|잔여|pending|대기$'
echo "  [인덱스]"
idx_hits=$(grep -nE "$MARK" "$IDX")
if [ -n "$idx_hits" ]; then printf '%s\n' "$idx_hits" | sed 's/^/    /'; else echo "    (없음)"; fi
echo "  [파일 description]"
for f in "$MEM"/*.md; do
  [ "$(basename "$f")" = "MEMORY.md" ] && continue
  sed -n '1,10p' "$f" | grep -E '^description:' | grep -qE "$MARK" && echo "    $(basename "$f")"
done
echo "  [본문(파일당 건수)]"
for f in "$MEM"/*.md; do
  [ "$(basename "$f")" = "MEMORY.md" ] && continue
  n=$(sed -n '11,$p' "$f" | grep -cE "$MARK")
  [ "$n" -gt 0 ] && echo "    $(basename "$f"): ${n}건"
done

echo
echo "--- [4] pending·next-* 파일(완료 시 은퇴 대상) ---"
pending_files=$(ls "$MEM"/next-*.md "$MEM"/*-pending*.md 2>/dev/null)
if [ -n "$pending_files" ]; then printf '%s\n' "$pending_files" | sed 's/^/  /'; else echo "  (없음)"; fi

echo
echo "--- [5] 인덱스 비대 라인(>200자 — 훅 초과 여부 판단 대상) ---"
awk 'length > 200 && /^- \[/ {printf "  %d자: %.80s...\n", length, $0}' "$IDX"
echo
echo "=== 스캔 끝 — 처분은 SKILL.md §2 판단 기준으로 ==="
