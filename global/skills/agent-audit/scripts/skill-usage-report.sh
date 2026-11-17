#!/usr/bin/env bash
# skill-usage-report.sh [일수=30] — 트랜스크립트의 Skill 도구 호출을 스킬별로 센다(새 훅 없이).
#   설치 스킬(전역 ~/.claude/skills + 현재 레포 .claude/skills) 중 호출 0 인 것을 따로 표시한다.
#   하한값이다: 슬래시로 직접 부른 스킬·서브에이전트 트랜스크립트는 빠질 수 있다.
#   출력 = 스킬 이름·건수만(트랜스크립트 본문은 출력하지 않는다).
#   관측창 상한 = settings 의 cleanupPeriodDays(그보다 오래된 트랜스크립트는 이미 지워졌다).
# 환경변수(테스트용): SKILL_USAGE_PROJECTS(기본 ~/.claude/projects) · SKILL_USAGE_SKILL_DIRS(콜론 구분, 기본 위 두 곳)
set -u
days="${1:-30}"
case "$days" in ''|*[!0-9]*) echo "사용법: $0 [일수]" >&2; exit 2;; esac
command -v jq >/dev/null 2>&1 || { echo "jq 없음 — 집계 불가" >&2; exit 2; }
proj_root="${SKILL_USAGE_PROJECTS:-$HOME/.claude/projects}"
skill_dirs="${SKILL_USAGE_SKILL_DIRS:-$HOME/.claude/skills:$PWD/.claude/skills}"

files=$(find "$proj_root" -maxdepth 2 -name '*.jsonl' -mtime "-$days" 2>/dev/null)
nfiles=$(printf '%s' "$files" | grep -c . )
echo "## 스킬 호출 집계 — 최근 ${days}일 · 트랜스크립트 ${nfiles}개 (${proj_root})"
if [ "$nfiles" -eq 0 ]; then
  echo "로그 없음 — 0건은 '안 쓰임'이 아니라 '관측 불가'다."
  exit 0
fi

counts=$(printf '%s\n' "$files" | while IFS= read -r f; do
  jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Skill") | .input.skill // empty' "$f" 2>/dev/null
done | sort | uniq -c | sort -rn)
if [ -n "$counts" ]; then printf '%s\n' "$counts"; else echo "(Skill 호출 0건)"; fi

echo "## 설치됐지만 호출 0"
IFS=':' read -r -a dirs <<< "$skill_dirs"
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  for s in "$d"/*/SKILL.md; do
    [ -f "$s" ] || continue
    n=$(basename "$(dirname "$s")")
    printf '%s\n' "$counts" | awk '{print $2}' | grep -qxF -- "$n" || echo "- $n ($d)"
  done
done
