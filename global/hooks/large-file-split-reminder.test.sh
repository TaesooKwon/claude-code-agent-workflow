#!/usr/bin/env bash
# large-file-split-reminder.sh 반증검사 — 양성(1,001줄 발화)·음성(1,000줄 경계 미발화)·
# 우회(동일 세션·동일 파일 2회째 마커 억제) 3종 + 마지막 줄에 "Tests run: N, Passed: M".
# 임시 파일은 이 스크립트의 스크래치 디렉터리에만 만들고 종료 시 정리한다(trap).
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/large-file-split-reminder.sh"
[ -x "$HOOK" ] || { echo "훅 파일이 없거나 실행권한이 없습니다: $HOOK" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lfsr-test.XXXXXX")
# 정리(teardown) — 스크래치 디렉터리 + 이 테스트가 찍은 dedup 마커(세션ID 접두 sess-* 로 한정,
# 실제 Claude Code 세션 ID(UUID)와 겹치지 않아 다른 세션의 마커를 건드리지 않는다).
cleanup() { rm -rf "$WORK"; rm -f "${TMPDIR:-/tmp}"/large-file-split-sess-*; }
trap cleanup EXIT

run=0
pass=0

assert() {
  # assert <label> <expr-description already checked as 0/1>
  label="$1"; ok="$2"
  run=$((run + 1))
  if [ "$ok" -eq 0 ]; then
    pass=$((pass + 1))
    echo "PASS: $label"
  else
    echo "FAIL: $label"
  fi
}

mk_lines() {
  # mk_lines <path> <n>
  awk -v n="$2" 'BEGIN{for(i=0;i<n;i++) print "line" i}' > "$1"
}

stdin_json() {
  # stdin_json <file_path> <session_id>
  jq -n --arg fp "$1" --arg sid "$2" \
    '{tool_input:{file_path:$fp}, session_id:$sid, cwd:"'"$WORK"'"}'
}

# ---- 양성: 1,001줄 → additionalContext 발화 ----
big="$WORK/big.txt"
mk_lines "$big" 1001
out_pos=$(stdin_json "$big" "sess-pos" | "$HOOK")
case "$out_pos" in
  *additionalContext*"1001줄"*) assert "양성(1001줄 → 발화)" 0 ;;
  *) assert "양성(1001줄 → 발화) — 실제출력: $out_pos" 1 ;;
esac

# ---- 음성: 정확히 1,000줄(경계) → 미발화(빈 출력) ----
boundary="$WORK/boundary.txt"
mk_lines "$boundary" 1000
out_neg=$(stdin_json "$boundary" "sess-neg" | "$HOOK")
if [ -z "$out_neg" ]; then
  assert "음성(1000줄 경계 → 미발화)" 0
else
  assert "음성(1000줄 경계 → 미발화) — 실제출력: $out_neg" 1
fi

# ---- 우회: 동일 세션·동일 파일 2회째는 마커로 억제(스팸 방지) ----
dup="$WORK/dup.txt"
mk_lines "$dup" 1500
first=$(stdin_json "$dup" "sess-dup" | "$HOOK")
second=$(stdin_json "$dup" "sess-dup" | "$HOOK")
if [ -n "$first" ] && [ -z "$second" ]; then
  assert "우회(동일 세션 2회째 마커 억제)" 0
else
  assert "우회(동일 세션 2회째 마커 억제) — 1회차: $first / 2회차: $second" 1
fi

echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ]
