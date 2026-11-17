#!/usr/bin/env bash
# skill-usage-report.sh — 양성(호출 수)·음성(0회 표시)·빈 로그(관측 불가 문구)
H="${1:-$(dirname "$0")/skill-usage-report.sh}"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT; pass=0; fail=0
has(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3"; fi; }
not(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then fail=$((fail+1)); echo "FAIL: $3"; else pass=$((pass+1)); fi; }
mkdir -p "$T/p/a" "$T/s/harness" "$T/s/idle" "$T/empty"; : > "$T/s/harness/SKILL.md"; : > "$T/s/idle/SKILL.md"
sk(){ printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"%s"}}]}}\n' "$1"; }
{ sk harness; sk harness; sk other; printf '{"type":"user","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"ghost"}}]}}\n'; printf '{"type":"assistant","message":{"content":[{"type":"text","text":"secret body"}]}}\n'; } > "$T/p/a/x.jsonl"
o=$(SKILL_USAGE_PROJECTS="$T/p" SKILL_USAGE_SKILL_DIRS="$T/s" bash "$H" 30)
has "$o" "2 harness" "harness 2회"; has "$o" "1 other" "other 1회"; not "$o" "ghost" "user 줄은 세지 않음"
has "$o" "- idle" "0회 스킬 표시"; not "$o" "- harness" "호출된 스킬은 0회 목록 제외"; not "$o" "secret body" "본문 미출력"
o=$(SKILL_USAGE_PROJECTS="$T/empty" SKILL_USAGE_SKILL_DIRS="$T/s" bash "$H" 30); has "$o" "관측 불가" "빈 로그 = 관측 불가"
SKILL_USAGE_PROJECTS="$T/p" bash "$H" abc >/dev/null 2>&1; [ $? -eq 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: 잘못된 일수 exit 2"; }
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
