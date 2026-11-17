#!/usr/bin/env bash
# SessionStart — 그날 첫 세션에서 팀 커밋 유입 감지(CLAUDE.md "pull 후 스모크" 보완). (agent-scaffold 범용판)
# 배경: pull-smoke-reminder(PostToolUse)는 세션 안에서 pull했을 때만 발동 → 밤새 쌓인
#       팀 커밋으로 main이 깨진 걸 뒤늦게 발견하는 구멍. 고정 시각 크론은 머신 상시
#       미가동 환경에 부적합 → 세션 시작 시점 감지로 대체.
# 동작: 오늘 첫 발동만 git fetch(1~2초) → 원격 대비 behind면 리마인더를 컨텍스트에 주입.
#       같은 날 이후 세션은 마커로 침묵. 차단 아님·정보 주입만. fail-open.
set -u

proj="${CLAUDE_PROJECT_DIR:-}"
[ -n "$proj" ] && [ -d "$proj/.git" ] || exit 0

marker="$proj/.claude/.last-daily-fetch"
today=$(date +%F)
[ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$today" ] && exit 0

# 마커는 fetch 성공 '이후'에만 기록한다.
#   이전 순서(마커 먼저)에서는 오프라인·VPN 미접속으로 fetch 가 실패하면 아무것도 주입하지 못한 채
#   그날 마커만 소진되어, 남은 모든 세션이 영구 침묵했다 — 훅이 메우려던 바로 그 구멍이 재현된다(2026-08-05 감사).
#   low-speed 임계로 도달 불가 원격에서의 행(hang)을 5초로 제한(SessionStart 타임아웃 보호).
git -C "$proj" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=5 fetch --quiet 2>/dev/null || exit 0
printf '%s' "$today" > "$marker" 2>/dev/null || true

behind=$(git -C "$proj" rev-list --count 'HEAD..@{upstream}' 2>/dev/null)
case "$behind" in ''|*[!0-9]*|0) exit 0;; esac

recent=$(git -C "$proj" log --oneline 'HEAD..@{upstream}' 2>/dev/null | head -5)

command -v jq >/dev/null 2>&1 || exit 0
ctx="[아침 스모크] 오늘 첫 세션 — 원격에 팀 커밋 ${behind}건이 쌓여 있습니다. CLAUDE.md 규칙에 따라 작업 착수 전 git pull 후 harness 스킬로 스모크 1회를 돌려 팀발 빌드 깨짐을 조기 확인하세요. 팀 md(AGENTS.md·Design.md 등) 변경이 섞여 있으면 규약 대조·흡수 검토도 함께.
유입 커밋(최근 5건):
${recent}"

# 사용자 화면 요약(systemMessage) — 마커가 그날 첫 세션에서 소진되므로 모델이 전하지 않으면 경고가 샌다.
# 수치와 다음 행동만 싣는다(커밋 제목·경로 없음). 레포명은 basename 의 제어문자를 걷어 한 줄을 지킨다.
rname=$(basename "$proj" | tr -d '[:cntrl:]')
msg="[일일 fetch] ${rname}: 원격보다 ${behind}커밋 뒤 — 작업 전 pull 후 스모크 1회"
jq -n --arg c "$ctx" --arg s "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}, systemMessage:$s}'
exit 0
