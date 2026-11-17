#!/usr/bin/env bash
# PreToolUse(Bash) 경고 — CLAUDE.md 🧪검증 "화면 JS 로직(개발 소유 JS)을 바꾸면 jsharness 스펙 + 변이 반증 1회,
# Tests run: N 을 보고(0건 = 미실행)"의 기계화 후반부. 짝 = jsharness-record.sh(PostToolUse·PostToolUseFailure 기록기)가 남기는
# .claude/.last-jsharness("<epoch> <N> <F>"). 구조는 mvn-test-result-gate.sh 와 같고, **경고만 한다**(그림자 기간 —
# deny/ask 를 내지 않는다).
#
# 판정: 커밋 명령이고 스테이징(레포 루트 기준)에 개발 JS 경로(아래 DEV_JS_PATH_REGEX)에 맞는 파일이 있는데,
# 다음 중 하나면 additionalContext 경고.
#   ①.claude/.last-jsharness 가 없거나 형식이 깨졌다
#   ②기록된 Failures 가 0 보다 크다
#   ③기록된 Tests run 이 0 이다(미실행 = 미반증)
#   ④기록 시각이 스테이징된 개발 JS 중 가장 최근 mtime 보다 오래됐다
# 커밋 명령 판정은 공용 lib/git-cmd.sh 를 mvn-test-result-gate.sh 와 같은 방식으로 쓴다.
# 출력은 고정 문구 + 숫자·시각·스테이징 경로 하나뿐이다(명령 원문은 내지 않는다).
#
# 한계(수용):
#   - 신선도 축이 작업트리 mtime 이다(스테이징 후 같은 파일을 더 고치면 경고 — 보수적 오탐).
#   - 변이 반증을 실제로 했는지는 기록으로 알 수 없다(기록기 주석 참조) — 경고문으로 상기만 한다.
#   - mvn-test-result-gate.sh 와 같은 범위 한계: toplevel 이 CLAUDE_PROJECT_DIR 과 같을 때만 발화(worktree 커밋 미검사).
# ponytail: 경고 전용 / 업그레이드 경로 = 그림자 기간 오탐 표본을 본 뒤 permissionDecision:"deny" + 우회 변수로 승격.
# 안전: jq/git 부재 · 커밋 아님 · 남의 레포 · 스테이징된 개발 JS 없음 · 어떤 실패든 → 조용히 exit 0.
set -u

# 개발 JS 경로(레포 루트 기준 경로에 grep -E 로 대조) — 레포마다 이 줄의 값만 바꾼다(kit-drift-check 는 VAR= 줄을 비교에서 뺀다).
# 비어 있으면 기본값. 정규식이 깨져 grep 이 실패하면 대상 0건으로 보고 조용히 끝난다.
DEV_JS_PATH_REGEX='(^|/)js/develop/.+\.js$'
[ -n "$DEV_JS_PATH_REGEX" ] || DEV_JS_PATH_REGEX='(^|/)js/develop/.+\.js$'

input=$(cat 2>/dev/null || true)
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_heredoc "$cmd")" commit || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"
[ -d "$proj/{{MODULE_CORE}}/src/main" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$top" ] || exit 0
[ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$proj" 2>/dev/null && pwd -P)" ] || exit 0

# 스테이징된 개발 JS(존재하는 것만). 경로는 레포 루트 기준이다.
staged=$(git -C "$cwd" -c core.quotepath=false diff --cached --name-only -z --diff-filter=ACMR 2>/dev/null \
  | tr '\0' '\n' | grep -E -- "$DEV_JS_PATH_REGEX")
[ -n "$staged" ] || exit 0

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

newest=0
newest_f=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  p="$top/$f"
  [ -f "$p" ] || continue
  m=$(_mtime "$p")
  case "${m:-x}" in *[!0-9]*) continue ;; esac
  if [ "$m" -gt "$newest" ]; then newest="$m"; newest_f="$f"; fi
done <<EOF
$staged
EOF
[ "$newest" -gt 0 ] || exit 0

# 기록은 "<epoch> <N> <F>" 정확히 한 줄 형식일 때만 믿는다.
mark="$proj/.claude/.last-jsharness"
line=""
[ -f "$mark" ] && line=$(head -n 1 "$mark" 2>/dev/null)
rec_epoch=""; rec_n=""; rec_f=""
if printf '%s' "$line" | grep -Eq '^[0-9]+ [0-9]+ [0-9]+$'; then
  IFS=' ' read -r rec_epoch rec_n rec_f <<EOF
$line
EOF
fi

_fmt() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'epoch %s' "$1"; }

why=""
if [ -z "$rec_epoch" ]; then
  why="jsharness 실행 기록이 없습니다(.claude/.last-jsharness 부재 또는 형식 불량)."
elif [ "$rec_f" -gt 0 ]; then
  why="마지막 jsharness 결과가 빨간불입니다(Tests run: ${rec_n}, Failures: ${rec_f}, $(_fmt "$rec_epoch"))."
elif [ "$rec_n" -eq 0 ]; then
  why="마지막 jsharness 실행의 Tests run 이 0 입니다($(_fmt "$rec_epoch")) — 미실행은 초록이 아닙니다."
elif [ "$rec_epoch" -lt "$newest" ]; then
  why="마지막 jsharness 초록($(_fmt "$rec_epoch")) 이후 스테이징된 JS 가 바뀌었습니다 — 가장 최근 변경: ${newest_f} ($(_fmt "$newest"))."
fi
[ -n "$why" ] || exit 0

msg="[jsharness-commit] ${why}
규약: 화면 JS(개발 소유 경로)를 바꾸면 커밋 전 node .claude/jsharness/run.js 초록 → 변이 빨간불 1회 → 원복, Tests run: N 을 보고(0건 = 미실행). (경고 전용 — 차단하지 않음)"
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}' 2>/dev/null
exit 0
