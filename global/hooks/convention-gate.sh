#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=통과
# Convention gate (Stop hook) — F3(2026-06-26 하네스 #3).
# #1에서 만든 컨벤션 lint(check_conventions.py)를 "수동 harness"에서 "세션 종료 시 자동 차단"으로
# 끌어올린다. Stop 시 변경분을 --changed-only 로 검사해 위반이면 block(종료 전 수정 유도).
#
# 안전장치:
#   - jq/python3/checker 부재 → 침묵 대신 로그 후 fail-open(작업 안 막음).
#   - 체커가 rc=1 이라도 VIOLATIONS 헤더가 없으면(=예외/크래시) block 하지 않고 fail-open.
#   - 마커(.claude/conventions.enabled) 없는 레포는 체커가 스스로 skip(rc=0) → 형제 레포 무영향.
#   - stop_hook_active 루프가드(한 번 surface 후 트랩 방지).
# 로그 = ~/.claude/hooks/convention-gate.log (관측성).

input=$(cat)

LOG="$HOME/.claude/hooks/convention-gate.log"
log() { printf '%s [conv-gate] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null; }
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 1200 ]; then
  tail -n 800 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

command -v jq >/dev/null 2>&1 || { log "SKIP no-jq"; exit 0; }
command -v python3 >/dev/null 2>&1 || { log "SKIP no-python3"; exit 0; }

stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

base="__PROJECTS_DIR__"
case "$cwd" in
  "$base"/*) ;;
  *) exit 0 ;;
esac

rel="${cwd#"$base"/}"
proj="${rel%%/*}"
root="$base/$proj"

[ "$stop_active" = "true" ] && { log "$proj SKIP loop-guard"; exit 0; }

checker="$HOME/.claude/skills/harness/check_conventions.py"
[ -f "$checker" ] || { log "$proj SKIP no-checker"; exit 0; }

out=$(cd "$root" && python3 "$checker" --repo "$root" --changed-only 2>&1)
rc=$?

# 위반(rc=1 + VIOLATIONS 헤더)일 때만 block. rc=1 이지만 헤더 없으면 체커 예외 → fail-open.
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^VIOLATIONS'; then
  viol=$(printf '%s' "$out" | sed -n '/^VIOLATIONS/,$p')
  log "$proj BLOCK conventions"
  reason="[컨벤션 게이트] ${proj} 변경분에 규약 위반이 있습니다(harness check_conventions, 변경 라인 기준). 종료 전 수정하세요:

${viol}

규칙 정본 = CLAUDE.md. SELECT* 금지 / 매퍼 id 동작접두어(create·modify·delete·read) / AG Grid 신버전 rowSelection / 퍼블 공통 JS 수정금지."
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
  exit 0
fi

log "$proj PASS rc=$rc"
exit 0
