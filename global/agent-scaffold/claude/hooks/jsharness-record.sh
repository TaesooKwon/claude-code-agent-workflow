#!/usr/bin/env bash
# PostToolUse·PostToolUseFailure(Bash) 기록기 — CLAUDE.md 🧪검증 "화면 JS 로직(js/develop/**)을 바꾸면 jsharness 스펙 + 변이 반증 1회,
# Tests run: N 을 보고(0건 = 미실행)"의 기계화 전반부. 짝 = jsharness-commit-reminder.sh(PreToolUse 경고).
# 구조는 mvn-test-record.sh 와 같다(판정 재료 = stdin JSON 만, 이 레포에서만 기록, 원자적 교체).
#
# 하는 일: 명령에 node 호출과 jsharness/run.js 가 있고, 실행 출력에 러너 요약 줄(아래 형태)이
#   있으면 .claude/.last-jsharness 에 "<epoch> <N> <F>" 한 줄을 기록한다. 요약 줄이 여러 번이면 마지막 것을 쓴다.
#   요약 줄 = 줄 전체가 `Tests run: <N>, Failures: <F>, Specs: <S>` 인 줄(러너 고유 형태). 이 형태가 아닌 줄
#   (예: 같은 명령에 섞인 Surefire 줄 `[INFO] Tests run: N, Failures: F, Errors: …`)은 집계하지 않는다.
#   N=0(스펙 미실행)·F>0(빨간불)도 그대로 기록한다 — 판정은 짝 훅이 한다.
#   종료코드≠0 인 실행(PostToolUseFailure 이벤트)은 빨간불로 기록한다 — 아래 실패 분기 주석 참조.
# 판정 재료는 .hook_event_name / .tool_input.command / .cwd / .tool_response.stdout·stderr / .error 뿐이고,
#   PostToolUse 에서 tool_response 가 객체가 아니면(형식 변화·누락) 침묵한다. 명령·출력 원문은 기록하지 않는다(숫자만).
#   기록을 쓰지 못하면 기존 기록을 지운다(낡은 초록 잔존 방지 — 기록 없음은 짝 훅이 경고한다).
#
# 한계(수용):
#   - 출력 문자열로 판정한다 — 명령에 node 와 jsharness/run.js 가 들어 있고 출력에 요약 줄이 실린 다른 명령도
#     기록될 수 있다.
#   - 어느 스펙이 돌았는지는 기록하지 않는다(총계만). 변이 반증을 했는지도 이 기록으로는 알 수 없다 —
#     변이 실행(F>0) 뒤 원복 실행(F=0)을 하면 마지막 기록은 초록이다.
# ponytail: 요약 줄 형식은 jsharness/run.js 의 console.log 문구 가정이다(문구가 바뀌면 기록이 안 남아 짝 훅이
#           '기록 없음'으로 경고한다 = 보수 쪽) / 업그레이드 경로 = 러너가 결과 파일을 직접 쓰게 한다.
# 안전: jq/git 부재 · 대상 명령 아님 · 남의 레포 · 요약 줄 없음 → 조용히 exit 0. 쓰기 실패 → 기존 기록 삭제 후 exit 0
#   (삭제도 실패하면 stderr 알림 + exit 2).
#   아무것도 막지 않는다.
set -u

input=$(cat 2>/dev/null || true)
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# 이 레포에서만 기록한다 — 다른 레포의 초록을 이 레포 기록으로 남기면 거짓 초록이 된다.
[ -d "$proj/{{MODULE_CORE}}/src/main" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$top" ] || exit 0
[ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$proj" 2>/dev/null && pwd -P)" ] || exit 0

# 트리거: node 호출(경로 접두·셸 래핑 허용) + jsharness/run.js 인자
printf '%s' "$cmd" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?node([[:space:]]|\$)" || exit 0
printf '%s' "$cmd" | grep -Eq '(^|[/[:space:]"'"'"'])jsharness/run\.js([[:space:]"'"'"';&|)]|$)' || exit 0

mark="$proj/.claude/.last-jsharness"

# _parse <출력> → n·f 설정(러너 요약 줄 형태의 마지막 줄). 없거나 숫자가 아니면 비운다.
_parse() {
  n=""; f=""
  summary=$(printf '%s\n' "$1" | grep -E '^Tests run: [0-9]+, Failures: [0-9]+, Specs: [0-9]+$' | tail -n 1)
  [ -n "$summary" ] || return 0
  n=$(printf '%s' "$summary" | sed -E 's/^Tests run: ([0-9]+), Failures: ([0-9]+), Specs: [0-9]+$/\1/')
  f=$(printf '%s' "$summary" | sed -E 's/^Tests run: ([0-9]+), Failures: ([0-9]+), Specs: [0-9]+$/\2/')
  case "${n:-x}${f:-x}" in *[!0-9]*) n=""; f="" ;; esac
}

# _write <N> <F> — 병행 세션이 동시에 기록해도 반쪽 줄이 남지 않게 같은 디렉터리 임시파일 → mv 로 원자 교체한다.
# 쓰지 못하면 기존 기록을 지운다(새 결과를 못 쓴 채 낡은 초록이 남는 것이 최악 — 기록 없음은 짝 훅이 경고한다).
# 지우기도 실패하면 stderr + exit 2 로 알린다(PostToolUse 계열의 exit 2 는 이미 끝난 도구를 막지 못한다 — 알림만).
_write() {
  mkdir -p "$(dirname "$mark")" 2>/dev/null || true
  tmp=$(mktemp "$mark.tmp.XXXXXX" 2>/dev/null) || tmp=""
  if [ -n "$tmp" ] && printf '%s %s %s\n' "$(date +%s)" "$1" "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$mark" 2>/dev/null; then
    exit 0
  fi
  [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
  rm -f "$mark" 2>/dev/null
  if [ -e "$mark" ]; then
    echo "[jsharness 기록] 결과(Tests run: $1, Failures: $2)를 기록하지 못했고 이전 기록($mark)도 지우지 못했습니다 — 낡은 기록으로 커밋 리마인더가 오판할 수 있습니다. 그 파일을 직접 지우세요." >&2
    exit 2
  fi
  exit 0
}

# PostToolUseFailure(Bash 종료코드≠0) — PostToolUse 는 성공한 도구에만 불린다(공식 hooks 문서: 실패는
# PostToolUseFailure, 입력 = .error 문자열이고 tool_response 가 없다). run.js 는 빨간불이면 1, 단언 0건이면 2 로 끝나므로
# 파이프 없이 돌린 빨간불 실행은 이 이벤트로 들어온다(파이프로 exit 0 이면 위 PostToolUse 경로가 F>0 으로 기록). 종료코드≠0 은 출력과 무관하게 빨간불이다: .error 에서 요약 줄을 읽으면 N 은
# 그 값을 쓰고, 요약 줄이 없거나(중간 절단·형식 비보장 → "0 1") N>0 인데 F=0 이면 F=1 로 기록한다(짝 훅 ② 빨간불
# 경고). N=0 이면 F 를 그대로 둔다(짝 훅 ③ 미실행 경고 — 0 0 이든 0 1 이든 경고는 난다).
# ponytail: 명령 문자열에 node·jsharness/run.js 가 든 다른 실패 명령도 빨간불로 덮는다(경고 쪽 오탐 — run.js 재실행으로
#   풀린다) / 업그레이드 경로 = 러너가 결과 파일을 직접 쓰게 한다.
if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "PostToolUseFailure" ]; then
  _parse "$(printf '%s' "$input" | jq -r '.error // "" | tostring' 2>/dev/null)"
  if [ -z "$n" ]; then n=0; f=1          # 요약 줄 없음 → 빨간불
  elif [ "$n" -eq 0 ]; then :            # 단언 0건(exit 2) → "0 F" 그대로(짝 훅 ③ 미실행 경고)
  elif [ "$f" -eq 0 ]; then f=1; fi      # N>0·F=0 인데 실패 종료 → 빨간불
  _write "$n" "$f"
fi

[ "$(printf '%s' "$input" | jq -r '.tool_response | type' 2>/dev/null)" = "object" ] || exit 0
out=$(printf '%s' "$input" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")' 2>/dev/null)
[ -n "$out" ] || exit 0

_parse "$out"
[ -n "$n" ] || exit 0
_write "$n" "$f"
