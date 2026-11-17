#!/usr/bin/env bash
# hook-policy-report.sh(표·--tsv·--missing) + hook-obs-report.sh 은퇴 후보 필터(기록 제외·ask 는 건 것으로 셈·정책 없음 = ?)
D="$(cd "$(dirname "$0")" && pwd)"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT; pass=0; fail=0
has(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3"; fi; }
not(){ if printf '%s\n' "$1" | grep -qF -- "$2"; then fail=$((fail+1)); echo "FAIL: $3"; else pass=$((pass+1)); fi; }
H="$T/home/.claude/hooks"; mkdir -p "$H" "$T/ev" "$T/proj"
hk(){ printf '#!/bin/bash\n%s\nexit 0\n' "$2" > "$H/$1"; }
hk guard.sh '# hook-policy: 강제=차단 · 도구부재=차단'
hk rec.sh   '# hook-policy: 강제=기록 · 도구부재=통과'
hk warner.sh '# hook-policy: 강제=안내 · 도구부재=통과'
hk asker.sh '# hook-policy: 강제=확인 · 도구부재=통과'
hk nohdr.sh '# 정책 줄 없음'
hk bad.sh   '# hook-policy: 강제=엉터리 · 도구부재=통과'
hk skip.test.sh '# hook-policy: 강제=차단 · 도구부재=차단'
run(){ (cd "$T/proj" && HOME="$T/home" CLAUDE_PROJECT_DIR="$T/proj" HOOK_EVENTS_DIR="$T/ev" bash "$@"); }

o=$(run "$D/hook-policy-report.sh"); has "$o" "guard.sh" "표에 차단 훅"; has "$o" "강제=차단 도구부재=차단" "표 칸 값"
not "$o" "skip.test.sh" "*.test.sh 제외"; has "$o" "$H/nohdr.sh" "정책 줄 없음 보고"; has "$o" "$H/bad.sh" "허용 목록 밖 값 = 형식 오류"
o=$(run "$D/hook-policy-report.sh" --tsv); has "$o" "rec.sh	기록	통과" "tsv 행"; not "$o" "nohdr.sh" "tsv 에 정책 없는 훅 미포함"
o=$(run "$D/hook-policy-report.sh" --missing); [ "$(printf '%s\n' "$o" | grep -c .)" = 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: --missing 정확히 2건(nohdr·bad) — 실제: $o"; }

ts=$(date '+%Y-%m-%dT%H:%M:%S%z'); m=$(date +%Y-%m)
ev(){ printf '{"ts":"%s","hook":"%s","event":"PreToolUse","action":"%s","duration_ms":1}\n' "$ts" "$1" "$2"; }
S="$T/home/.claude/agent-scaffold/claude/hooks"; mkdir -p "$S"   # 실행 레포에 없는 스캐폴드 기록 훅(다른 레포에서 발화)
printf '#!/bin/bash\n# hook-policy: 강제=기록 · 도구부재=통과\nexit 0\n' > "$S/scaffoldlog.sh"
{ ev guard.sh allow; ev rec.sh allow; ev warner.sh warn; ev asker.sh ask; ev nohdr.sh allow; ev scaffoldlog.sh allow; } > "$T/ev/$m.jsonl"
o=$(run "$D/hook-obs-report.sh" 30 | sed -n '/은퇴 후보/,/killed/p')
has "$o" "guard.sh	PreToolUse	1건	강제=차단" "걸지 않은 차단 훅 = 후보(강제 표시)"
not "$o" "rec.sh" "기록 훅은 후보 제외"; not "$o" "warner.sh" "warn 한 훅은 후보 아님"
not "$o" "asker.sh" "ask 한 훅은 후보 아님"; not "$o" "scaffoldlog.sh" "스캐폴드에만 있는 기록 훅도 후보 제외"
has "$o" "nohdr.sh	PreToolUse	1건	강제=?" "정책 없는 훅 = 후보(?)"
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
