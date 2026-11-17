#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PostToolUse(Write|Edit) 전역 훅 — 전역 CLAUDE.md "편집 안전" 절 "1,000줄 넘는 파일은 줄을 더하기 전에
# 분해를 먼저 검토한다"(판정 = diff 크기가 아니라 파일 총 라인)의 상기 장치. 경고형(차단 없음).
# 근거 처분 id = global:편집안전:9.
#
# 트러스트 경계: stdin JSON 만 신뢰한다(.tool_input.file_path). 파일 경로는 항상 따옴표로 인용해 다룬다.
# 판정: PostToolUse 시점이므로 파일은 이미 디스크에 쓰인 뒤 — 그 시점 파일의 `wc -l` 총 라인이 1,000 초과면
#   additionalContext 로 1줄 리마인더만 낸다(경고형 — permissionDecision 없음, 편집을 막지 않는다).
# 스팸 억제: 같은 세션·같은 파일 조합은 1회만 발화(마커). shasum 이 없으면 마커 없이 매번 발화(fail-open
#   쪽으로— 핵심 기능인 "리마인더 발화"는 유지, "중복 억제"만 빠진다).
# 안전(fail-open): jq 부재 · file_path 빈값 · 대상 파일 부재/읽기불가 · 라인 수 비숫자 · 1,000 이하
#   → 조용히 exit 0. 절대 deny/ask 하지 않는다(다른 Write/Edit 를 방해하지 않는다).
# ponytail: 바이너리 파일도 `wc -l` 로 그대로 센다(텍스트/바이너리 구분 없음) — Write/Edit 툴은 통상
#   텍스트 파일에만 쓰이므로 실사용 영향은 없다고 보고 넘긴다 / 업그레이드 경로 = 필요해지면
#   `grep -Iq '' "$fp"` 로 바이너리를 걸러낸다.
set -u

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat 2>/dev/null || true)

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)
[ -n "$fp" ] || exit 0

case "$fp" in
  /*) ;;
  *) fp="$PWD/$fp" ;;
esac

[ -f "$fp" ] || exit 0

n=$(wc -l < "$fp" 2>/dev/null | tr -d '[:space:]')
case "$n" in ''|*[!0-9]*) exit 0 ;; esac
[ "$n" -gt 1000 ] || exit 0

if command -v shasum >/dev/null 2>&1; then
  fphash=$(printf '%s' "$fp" | shasum 2>/dev/null | cut -c1-16)
  if [ -n "$fphash" ]; then
    marker="${TMPDIR:-/tmp}/large-file-split-${sid}-${fphash}"
    [ -e "$marker" ] && exit 0
    : > "$marker" 2>/dev/null || true
  fi
fi

reason="[대형 파일 분해 리마인더] ${fp}: ${n}줄(1,000줄 초과) — 분해 검토 후 진행, 미루면 사유를 사용자에게 말하세요(전역 CLAUDE.md 편집안전: 판정은 diff 크기가 아니라 파일 총 라인)."

jq -n --arg c "$reason" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
