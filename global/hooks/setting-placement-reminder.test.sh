#!/usr/bin/env bash
# setting-placement-reminder.sh — 전역 규약 편집에만 좌석 사본(rules-lite) 상기가 붙는지
H="${1:-$(dirname "$0")/setting-placement-reminder.sh}"; T="$(mktemp -d)" || { echo '임시 디렉터리 생성 실패 — 실행하지 않았다'; exit 2; }; trap 'case "$T" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$T" ;; esac' EXIT; pass=0; fail=0
run(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$1" "$RANDOM$RANDOM" | TMPDIR="$T" bash "$H"; }
has(){ if printf '%s' "$1" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $3"; fi; }
not(){ if printf '%s' "$1" | grep -qF -- "$2"; then fail=$((fail+1)); echo "FAIL: $3"; else pass=$((pass+1)); fi; }
o=$(run "$HOME/.claude/CLAUDE.md");        has "$o" "rules-lite.md" "전역 규약 → 좌석 상기"; has "$o" "전역 규약 편집" "전역 규약 층 판정"
o=$(run "$HOME/.claude/settings.json");    not "$o" "rules-lite.md" "전역 settings 엔 좌석 상기 없음"; has "$o" "전역 settings" "settings 층 판정"
o=$(run "/x/repo/CLAUDE.md");              not "$o" "rules-lite.md" "레포 규약엔 좌석 상기 없음"; has "$o" "레포 규약" "레포 규약 층 판정"
o=$(run "$HOME/.claude-team/rules-lite.md"); has "$o" "팀 좌석 규약 편집" "좌석 규약 본문 → 좌석 층 판정"
o=$(run "$HOME/.claude-team/CLAUDE.md");     has "$o" "팀 좌석 규약 편집" "좌석 CLAUDE.md 링크 → 좌석 층 판정"; not "$o" "레포 규약 편집" "좌석 링크가 레포 규약으로 오분류되지 않음"
o=$(run "$HOME/.claude-team/lite.json");     has "$o" "팀 좌석 규약 편집" "좌석 lite.json → 좌석 층 판정"
o=$(run "$HOME/.claude-team/history.jsonl"); has "[$o]" "[]" "좌석 디렉터리의 세팅 밖 파일 무출력"
o=$(run "/x/repo/src/A.java");             has "[$o]" "[]" "세팅 밖 파일 무출력"
# 심링크 경로 편집 — 가짜 HOME 에 링크를 만들어 라이브 배치와 무관하게 검사한다.
F="$T/home"; mkdir -p "$F/.claude/hooks" "$F/.claude-team"; : > "$F/.claude/settings.json"; : > "$F/.claude/settings.local.json"
ln -s ../.claude/settings.json "$F/.claude-team/settings.json"                 # 상대 링크
ln -s "$F/.claude/settings.local.json" "$F/.claude-team/settings.local.json"   # 절대 링크
ln -s "$F/.claude/hooks" "$F/.claude-team/hooks"                              # 디렉터리 링크
ln -s loop-b "$F/.claude-team/loop-a"; ln -s loop-a "$F/.claude-team/loop-b"    # 순환 링크
runh(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$1" "$RANDOM$RANDOM" | HOME="$F" TMPDIR="$T" bash "$H"; }
o=$(runh "$F/.claude-team/settings.json");       has "$o" "전역 settings 편집" "좌석 settings.json 링크 → 전역 settings 판정"
o=$(runh "$F/.claude-team/settings.local.json"); has "$o" "전역 settings 편집" "좌석 settings.local.json 링크 → 전역 settings 판정"
o=$(runh "$F/.claude-team/hooks/new.sh");        has "$o" "전역 훅 편집" "좌석 hooks 디렉터리 링크 아래 신규 파일 → 전역 훅 판정"
o=$(runh "$F/.claude-team/loop-a");              has "[$o]" "[]" "순환 링크는 멈추고 무출력"
o=$(runh "$F/.claude/settings.json");            has "$o" "전역 settings 편집" "가짜 HOME 실경로 양성 대조"
# 레포 안 세팅 파일이 층 밖을 가리키는 링크 — 원래 자리(문자 경로)와 링크 대상(실경로)을 둘 다 안내한다.
R="$T/repo"; K="$T/kit"; mkdir -p "$R/.claude/hooks" "$K/hooks"; : > "$R/AGENTS.md"; : > "$K/hooks/g.sh"; : > "$F/.claude/hooks/gl.sh"
ln -s AGENTS.md "$R/CLAUDE.md"
ln -s "$K/hooks/g.sh" "$R/.claude/hooks/g.sh"
ln -s "$F/.claude/hooks/gl.sh" "$R/.claude/hooks/gl.sh"
o=$(runh "$R/CLAUDE.md");                       has "$o" "레포 규약 편집" "레포 CLAUDE.md -> AGENTS.md 링크 → 레포 규약 판정"
o=$(runh "$R/.claude/hooks/g.sh");              has "$o" "레포 훅 편집" "레포 훅 -> 킷 밖 파일 링크 → 레포 훅 판정"
o=$(runh "$R/.claude/hooks/gl.sh");             has "$o" "레포 훅 편집" "레포 훅 -> 전역 훅 링크 → 레포 훅 판정"; has "$o" "전역 훅 편집" "레포 훅 -> 전역 훅 링크 → 전역 훅 판정"
o=$(runh "$F/.claude-team/../.claude/settings.json"); has "$o" "전역 settings 편집" "'..' 경유 전역 settings → 전역 판정"; not "$o" "레포 settings" "'..' 경유 전역 settings 가 레포 settings 로 오분류되지 않음"
mkdir -p "$F/.claude/rules-rationale"; o=$(runh "$F/.claude/rules-rationale/x.md"); has "[$o]" "[]" "근거 문서 무출력"
runs(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"fixed%s"}' "$1" "$2" | HOME="$F" TMPDIR="$T" bash "$H"; }
s=$RANDOM$RANDOM; o=$(runs "$R/.claude/hooks/gl.sh" "$s"); o2=$(runs "$R/.claude/hooks/gl.sh" "$s")
has "$o" "전역 훅 편집" "같은 세션 첫 발화"; has "[$o2]" "[]" "같은 세션·같은 층 재편집은 무출력(마커)"
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
