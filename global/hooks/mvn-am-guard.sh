#!/usr/bin/env bash
# PreToolUse(Bash) 소프트 경고 — `mvn … -pl <모듈>` 에 `-am`(--also-make) 이 없을 때(승격 대기열 2회, 2026-09-03).
#   멀티모듈에서 웹 모듈만 `-pl` 로 빌드·테스트하면 의존 모듈(Core)은 **로컬 저장소의 옛 jar** 로 해석돼
#   방금 고친 Core 변경이 반영되지 않은 채 초록/빨강이 뜬다(stale jar 오진 — 실측 2회: 테스트가 없는 메서드를
#   찾다 실패, 반대로 고친 버그가 안 고쳐진 채 통과). 처방 = `-am` 을 붙이거나 Core 를 먼저 install.
#   리프 모듈(다른 내부 모듈에 의존하지 않는 모듈)은 예외 — LEAF_MODULES_REGEX 로 판정(기본 = 이름에 core/common).
#   차단하지 않는다(additionalContext). 안전: jq 부재·비대상 명령 → 조용히 exit 0(fail-open).
set -u

# 내부 의존이 없어 -am 이 무의미한 모듈 이름 패턴(모듈 하나가 이 패턴이면 그 모듈은 경고에서 제외).
LEAF_MODULES_REGEX="${LEAF_MODULES_REGEX:-[Cc]ore|[Cc]ommon}"

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# mvn 호출이 아니면 침묵(mvnw 포함). 따옴표 안 문자열은 제외(설명 라벨 오탐 방지).
noquote=$(printf '%s' "$cmd" | sed -e "s/'[^']*'/''/g" -e 's/"[^"]*"/""/g')
printf '%s' "$noquote" | grep -Eq '(^|[|;&[:space:]/])(mvn|mvnw|\./mvnw)[[:space:]]' || exit 0

# -pl 값 추출(-pl X · -pl=X · --projects X · --projects=X). 여러 mvn 호출이면 각각 본다.
warn=""
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -Eq '(^|[[:space:]/])(mvn|mvnw)[[:space:]]' || continue
  printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(-pl|--projects)(=|[[:space:]]+)[^[:space:]]' || continue
  printf '%s' "$seg" | grep -Eq '(^|[[:space:]])(-am|--also-make)([[:space:]]|$)' && continue
  mods=$(printf '%s' "$seg" | grep -oE '(^|[[:space:]])(-pl|--projects)(=|[[:space:]]+)[^[:space:]]+' | head -1 \
         | sed -E 's/^[[:space:]]*(-pl|--projects)(=|[[:space:]]+)//' | tr ',' '\n')
  nonleaf=$(printf '%s\n' "$mods" | sed -E 's#^:##; s#^!##' | grep -Ev "$LEAF_MODULES_REGEX" || true)
  [ -n "$nonleaf" ] || continue
  warn="$warn$(printf '%s' "$nonleaf" | tr '\n' ' ')"$'\n'
done <<EOF_SEG
$(printf '%s' "$noquote" | tr ';|&' '\n\n\n')
EOF_SEG
[ -n "$warn" ] || exit 0

reason="[mvn -am 경고] -pl 대상에 -am 이 없습니다: $(printf '%s' "$warn" | tr '\n' ' ')
이 모듈이 의존하는 내부 모듈(Core 등)은 로컬 저장소의 **옛 jar** 로 해석됩니다 — 방금 고친 Core 변경이 빠진 채 초록/빨강이 떠 오진합니다(실측 2회).
⇒ \`-am\` 을 붙이거나(예: mvn -pl <모듈> -am test) 의존 모듈을 먼저 install 하세요. 리프 모듈(${LEAF_MODULES_REGEX})은 예외입니다. (이 경고는 차단이 아닙니다.)"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
