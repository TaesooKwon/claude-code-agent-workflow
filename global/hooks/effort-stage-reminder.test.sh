#!/usr/bin/env bash
# effort-stage-reminder.sh — 진입 신호에만 1회 상기, 그 밖은 무출력
H="${1:-$(dirname "$0")/effort-stage-reminder.sh}"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT; pass=0; fail=0
run(){ printf '%s' "$1" | TMPDIR="$T" bash "$H"; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3"; fi; }
emp(){ if [ -z "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(무출력 기대): $2"; fi; }
sk(){ jq -nc --arg s "$1" --arg i "$2" '{tool_name:"Skill",tool_input:{skill:$s},session_id:$i}'; }
has "$(run "$(sk harness s1)")" "/effort high" "harness 진입 상기"
emp "$(run "$(sk harness s1)")" "같은 세션 2회째"
has "$(run "$(sk regress-example s2)")" "effort 단계" "regress-* 상기"
has "$(run "$(sk playwright-verify s3)")" "effort 단계" "playwright-verify 상기"
emp "$(run "$(sk memory-hygiene s4)")" "무관 스킬"
has "$(run "$(jq -nc '{tool_name:"Workflow",tool_input:{scriptPath:"/r/.claude/workflows/commit-review.js"},session_id:"s5"}')")" "리뷰 워크플로" "commit-review 워크플로"
emp "$(run "$(jq -nc '{tool_name:"Workflow",tool_input:{script:"export const meta={name:\"x\"}"},session_id:"s6"}')")" "무관 워크플로"
emp "$(run "$(jq -nc '{tool_name:"Bash",tool_input:{command:"ls"},session_id:"s7"}')")" "Bash"
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
