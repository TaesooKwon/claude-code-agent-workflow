#!/usr/bin/env bash
# PreToolUse(Bash) 소프트 경고 — 인용 안 한 글롭 옵션값 감지(전역 규약 "grep 6판정 ⑤ 명령 실패와 결과 0 을 구분").
#   zsh 는 `--include=*.java` 처럼 인용 안 한 글롭이 현재 디렉터리에서 매칭되지 않으면 `no matches found` 로
#   **명령 전체를 실행하지 않는다** — 출력이 "0건"처럼 보여 부재 증명으로 오독된다(승격 대기열 3회째, 2026-09-03).
#   대상 옵션 = grep --include/--exclude/--exclude-dir · rg -g/--glob · find -name/-iname/-path.
#   값이 따옴표로 시작하지 않고(백슬래시 이스케이프도 인용으로 본다) 공백 전에 * ? [ 가 있으면 경고.
#   차단하지 않는다(additionalContext) — 오탐률을 관측한 뒤 deny 승격 여부를 정한다.
# 안전: jq 부재·비대상 명령 → 조용히 exit 0(fail-open).
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# heredoc 본문·주석은 셸이 글롭 확장하지 않으므로 검사에서 뺀다.
body=$(printf '%s\n' "$cmd" | awk '
  BEGIN { skip = "" }
  skip != "" { line = $0; sub(/^[ \t]+/, "", line); if (line == skip) skip = ""; next }
  { if (match($0, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
      d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*/, "", d); gsub(/["'"'"']/, "", d); skip = d }
    sub(/[ \t]#.*$/, ""); print }')

hits=$(printf '%s' "$body" \
  | grep -oE "(^|[[:space:]])(--include|--exclude|--exclude-dir|--glob|-g|-name|-iname|-path|-wholename)(=|[[:space:]]+)[^'\"\\\\[:space:]]*[*?[][^[:space:]]*" \
  | sed -E 's/^[[:space:]]+//' | sort -u || true)
[ -n "$hits" ] || exit 0

reason="[zsh 글롭 인용 경고] 인용 안 한 글롭 옵션값이 있습니다:
$(printf '%s\n' "$hits" | sed 's/^/  /')
zsh 는 이 글롭이 현재 디렉터리에서 매칭되지 않으면 'no matches found' 로 **명령 전체를 실행하지 않습니다** — 출력이 0건처럼 보여 부재 증명으로 오독됩니다.
⇒ 값을 인용하세요: --include='*.java' · -g '*.xml' · -name '*.sql'. (이 경고는 차단이 아닙니다.)"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
