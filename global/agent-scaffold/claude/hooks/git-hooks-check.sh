#!/usr/bin/env bash
# SessionStart — 층 A(git 훅) 설치 점검. 커밋 내용 게이트는 git 훅 층에서 돌기 때문에, 스텁이 없거나(새 clone·.git/hooks 초기화)
# 실행 비트가 빠졌거나 core.hooksPath 로 무효화되면 에이전트 커밋이 게이트 없이 조용히 통과한다 → 세션 머리에 알린다.
# 판정 = install-git-hooks.sh --check 의 rc(0 = 설치됨). 차단 아님. 점검 자체를 못 하면(레포 아님·jq 없음) 무출력 exit 0.
# 설치 스크립트 자체가 없으면 미설치로 알린다 — 커밋 게이트를 settings(PreToolUse)에서 층 A 로 옮긴 레포에선
#   스크립트 누락(훅 디렉터리만 복사한 부트스트랩)이 곧 커밋 게이트 0 이다.
set -u
proj="${CLAUDE_PROJECT_DIR:-}"
[ -n "$proj" ] || exit 0
chk="$proj/.claude/scripts/install-git-hooks.sh"
command -v jq >/dev/null 2>&1 || exit 0
git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || exit 0

if [ -f "$chk" ]; then
  err=$(cd "$proj" 2>/dev/null && bash "$chk" --check 2>&1 >/dev/null) && exit 0
else
  err="설치 스크립트 부재: .claude/scripts/install-git-hooks.sh (킷 agent-scaffold/claude/scripts/ 에서 복사한 뒤 실행)"
fi
# 사유 첫 줄만 싣는다(경로·설정 이름 수준 — 제어문자 제거·길이 상한).
why=$(printf '%s\n' "$err" | head -n 1 | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c1-300)
ctx="[층 A git 훅 미설치·무효] 에이전트 커밋이 커밋 내용 게이트(git pre-commit 층)를 거치지 않는 상태입니다. 사유: ${why:-(점검 출력 없음)}
조치: bash .claude/scripts/install-git-hooks.sh (core.hooksPath·남의 훅·깨진 링크가 사유면 그 원인을 사용자와 먼저 정리). 커밋 전에 사용자에게 이 상태를 알리세요."
msg="[층 A git 훅] 미설치·무효 — bash .claude/scripts/install-git-hooks.sh"
jq -n --arg c "$ctx" --arg s "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}, systemMessage:$s}' 2>/dev/null || true
exit 0
