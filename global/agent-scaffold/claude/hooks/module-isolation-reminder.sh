#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PreToolUse(Write|Edit) 소프트 리마인더 — 멀티모듈 격리 위반 경고.
# CLAUDE.md 아키텍처: DB제어(mapper/entity/service impl)는 {{MODULE_CORE}}에만, web 모듈
# ({{MODULE_ADMIN}}/{{MODULE_FRONT}})은 컨트롤러 레이어만. 컨트롤러는 Mapper 직접호출 금지(Service 경유).
# 발동: 편집 대상 file_path 가 web 모듈이고 ①mapper/entity/service impl 경로 세그먼트
#       또는 ②*Controller.java 인데 본문이 Mapper 를 직접 import/필드로 보유.
# 비차단 리마인더. fail-open. (ArchUnit 미도입 레포의 경량 보완 — 도입 시 그쪽이 정본.)
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$fp" ] || exit 0

# web 모듈 경로만
printf '%s' "$fp" | grep -Eq '/({{MODULE_ADMIN}}|{{MODULE_FRONT}})/' || exit 0

hit=""
# 1) 잘못된 레이어 배치
if printf '%s' "$fp" | grep -Eq '/(mapper|entity)/|/service/impl/'; then
  hit="DB제어 레이어(mapper/entity/service impl)를 web 모듈에 배치 — {{MODULE_CORE}}로 옮기세요"
fi
# 2) 컨트롤러가 Mapper 직접 의존
if [ -z "$hit" ] && printf '%s' "$fp" | grep -Eq 'Controller\.java$'; then
  body=$(printf '%s' "$input" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null)
  if printf '%s' "$body" | grep -Eq 'import[[:space:]]+[a-z0-9_.]+\.mapper\.[A-Z][A-Za-z0-9]*Mapper[[:space:]]*;'; then
    hit="컨트롤러가 Mapper 를 직접 의존 — Service 경유로 바꾸세요"
  fi
fi
[ -n "$hit" ] || exit 0

reason="[모듈 격리 리마인더] $hit. CLAUDE.md 아키텍처(Strict Multi-Module): DB 제어 로직·MyBatis XML·entity·mapper·service impl 은 {{MODULE_CORE}} 에만, web 모듈엔 컨트롤러 레이어만. 의존 흐름 Controller→Service→ServiceImpl→Mapper, 컨트롤러의 Mapper 직접호출 금지. (오탐이면 무시.)"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
