#!/usr/bin/env bash
# setting-placement-reminder.sh — 좌석 사본(rules-lite) 상기가 전역 규약·킷 전역 규약 사본 편집에 붙고 settings·레포 규약엔 안 붙는지
#   + 층 판정(킷 규약 갈래 포함) + 킷 후보 큐 쓰기 안내
unset KIT_DIR CLAUDE_CONFIG_DIR   # 실행 환경의 킷·좌석 env 를 물려받지 않는다(KIT_DIR 미설정 단언이 실제로 미설정 경로를 보게)
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
# 킷 후보 큐 쓰기 안내 — 세팅 층 편집이면 갈래와 무관하게 끝에 한 번(세팅 밖 무출력은 위 "[]" 단언들이 본다).
QW="printf '%s\\n' '<한 줄>' >> ~/.claude/kit-candidates.md"
qn(){ printf '%s' "$1" | grep -oF -- "kit-candidates.md" | grep -c .; }   # 줄이 아니라 등장 횟수
# 큐 안내는 킷 운영 파일(KIT_DIR 의 scripts/live-edit.sh)이 있는 설치에서만 — KO = 그 파일을 둔 가짜 킷.
KO="$T/kitops"; mkdir -p "$KO/scripts"; : > "$KO/scripts/live-edit.sh"
runq(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$1" "$RANDOM$RANDOM" | HOME="$F" KIT_DIR="$KO" TMPDIR="$T" bash "$H"; }
for f in "$F/.claude/CLAUDE.md" "$F/.claude/settings.json" "$F/.claude/hooks/q.sh" "$F/.claude/skills/x/SKILL.md" "$F/.claude/agent-scaffold/claude/hooks/q.sh" "$F/.claude-team/rules-lite.md" "/x/repo/CLAUDE.md" "/x/repo/.claude/hooks/q.sh"; do
  o=$(runq "$f" | jq -r '.hookSpecificOutput.additionalContext // empty'); has "$o" "$QW" "큐 쓰기 명령 안내(디코드한 본문): $f"; [ "$(qn "$o")" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: 큐 안내 1회 아님($(qn "$o")): $f"; }
done
o=$(runq "$R/.claude/hooks/gl.sh"); has "$o" "레포 훅 편집" "두 갈래 걸림 확인"; [ "$(qn "$o")" = 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: 두 갈래여도 큐 안내 1회 아님($(qn "$o"))"; }
for f in "$F/.claude/CLAUDE.md" "/x/repo/.claude/hooks/q.sh"; do
  o=$(runh "$f" | jq -r '.hookSpecificOutput.additionalContext // empty'); has "$o" "편집" "(전제) 운영 파일 없는 설치도 배치 판정은 낸다: $f"; not "$o" "kit-candidates.md" "운영 파일 없는 설치 → 큐 안내 없음: $f"
done
# 킷 레포(원본·worktree)의 최상위 CLAUDE.md·global/CLAUDE.md → 킷 갈래. 킷의 다른 CLAUDE.md·킷 아닌 git 레포 → 레포 규약.
gitc(){ git -c user.name=t -c user.email=t@t "$@"; }
KR="$T/kitrepo"; mkdir -p "$KR/global" "$KR/sub" "$T/other/global"; : > "$KR/CLAUDE.md"; : > "$KR/global/CLAUDE.md"; : > "$KR/sub/CLAUDE.md"
git -C "$KR" init -q 2>/dev/null && git -C "$KR" add -A && gitc -C "$KR" commit -qm i && git -C "$KR" worktree add -q "$T/kitwt" 2>/dev/null || echo "FAIL: 킷 픽스처 생성"
git -C "$T/other" init -q 2>/dev/null; : > "$T/other/global/CLAUDE.md"
runk(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$1" "$RANDOM$RANDOM" | HOME="$F" KIT_DIR="$KR" TMPDIR="$T" bash "$H"; }
for f in "$KR/global/CLAUDE.md" "$KR/CLAUDE.md" "$T/kitwt/global/CLAUDE.md" "$T/kitwt/CLAUDE.md"; do
  o=$(runk "$f"); has "$o" "킷 규약 편집" "킷 갈래: $f"; not "$o" "레포 규약 편집" "레포 규약으로 오분류 안 됨: $f"
done
o=$(runk "$KR/sub/CLAUDE.md");          has "$o" "레포 규약 편집" "킷 하위 폴더 CLAUDE.md → 레포 규약"; not "$o" "킷 규약 편집" "킷 하위 폴더는 킷 갈래 아님"
o=$(runk "$T/other/global/CLAUDE.md");  has "$o" "레포 규약 편집" "킷 아닌 git 레포 global/CLAUDE.md → 레포 규약"
o=$(runh "$KR/global/CLAUDE.md");       has "$o" "레포 규약 편집" "KIT_DIR 미설정·기본 킷 경로 없음 → 레포 규약"
F2="$T/home2"; mkdir -p "$F2"; ln -s "$KR" "$F2/claude-agent-kit"
o=$(printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$T/kitwt/global/CLAUDE.md" "$RANDOM$RANDOM" | env -u KIT_DIR HOME="$F2" TMPDIR="$T" bash "$H")
has "$o" "킷 규약 편집" "KIT_DIR 미설정 → 기본 ~/claude-agent-kit(심링크) 의 worktree 도 킷 갈래"
# 킷 규약 갈래 본문 — global/CLAUDE.md = 전역 규약 킷 사본(라이브 짝·좌석 사본 대조) / 최상위 CLAUDE.md = 킷 레포 규약(라이브 짝 없음).
# 좌석 사본·live-edit 안내 = 그 파일이 킷에 있을 때만(양성 → 파일 제거 뒤 음성).
mkdir -p "$KR/scripts" "$KR/global/modules/team-seat"; : > "$KR/scripts/live-edit.sh"
o=$(runk "$KR/global/CLAUDE.md"); has "$o" "짝 = 라이브 ~/.claude/CLAUDE.md" "킷 전역 사본 본문 = 라이브 짝"
has "$o" "global/modules/team-seat/claude-team/rules-lite.md ↔ 라이브 ~/.claude-team/rules-lite.md" "킷 전역 사본 본문 = 좌석 사본 대조"; not "$o" "킷은 복사 원본이다" "킷 전역 사본에 템플릿 본문 없음"
has "$o" "scripts/live-edit.sh begin <파일>" "킷 운영 파일 있음 → live-edit 절차 안내"
rm -r "$KR/scripts" "$KR/global/modules"
o=$(runk "$KR/global/CLAUDE.md"); has "$o" "짝 = 라이브 ~/.claude/CLAUDE.md" "(전제) 운영 파일 없는 킷도 라이브 짝 안내"
not "$o" "team-seat" "좌석 모듈 없는 킷 → 좌석 사본 안내 없음"; not "$o" "live-edit" "live-edit 없는 킷 → 절차 안내 없음"
o=$(runk "$KR/CLAUDE.md"); has "$o" "킷 레포 규약이다(킷 고유 판정축 — 라이브 짝 없음)" "킷 루트 본문 = 킷 레포 규약"
not "$o" "rules-lite.md" "킷 루트 본문에 좌석 사본 대조 없음"; not "$o" "킷은 복사 원본이다" "킷 루트에 템플릿 본문 없음"
# 같은 세션에서 템플릿 ↔ 킷 규약(양 순서)·킷 전역 사본 ↔ 킷 루트 — 갈래가 달라 둘 다 발화한다.
runks(){ printf '{"tool_input":{"file_path":"%s"},"session_id":"ks%s"}' "$1" "$2" | HOME="$F" KIT_DIR="$KR" TMPDIR="$T" bash "$H"; }
TPL="$F/.claude/agent-scaffold/claude/hooks/q.sh"
s=$RANDOM$RANDOM; o=$(runks "$TPL" "$s"); o2=$(runks "$KR/global/CLAUDE.md" "$s"); o3=$(runks "$KR/CLAUDE.md" "$s")
has "$o" "킷 템플릿 편집" "같은 세션 ① 템플릿 발화"; has "$o2" "킷 규약 편집" "같은 세션 ② 템플릿 뒤 킷 전역 사본 발화"; has "$o3" "킷 레포 규약이다" "같은 세션 ③ 킷 전역 사본 뒤 킷 루트 발화"
s=$RANDOM$RANDOM; o=$(runks "$KR/CLAUDE.md" "$s"); o2=$(runks "$TPL" "$s")
has "$o" "킷 규약 편집" "같은 세션(역순) ① 킷 루트 발화"; has "$o2" "킷 템플릿 편집" "같은 세션(역순) ② 킷 루트 뒤 템플릿 발화"
# HOME 이 git(dotfiles)이고 기본 킷 경로가 git 아닌 사본 → HOME 최상위 CLAUDE.md·global/CLAUDE.md 는 킷이 아니다.
F3="$T/home3"; mkdir -p "$F3/claude-agent-kit/global" "$F3/global"; : > "$F3/CLAUDE.md"; : > "$F3/global/CLAUDE.md"; : > "$F3/claude-agent-kit/global/CLAUDE.md"
git -C "$F3" init -q 2>/dev/null || echo "FAIL: HOME git 픽스처 생성"
for f in "$F3/CLAUDE.md" "$F3/global/CLAUDE.md"; do
  o=$(printf '{"tool_input":{"file_path":"%s"},"session_id":"t%s"}' "$f" "$RANDOM$RANDOM" | HOME="$F3" TMPDIR="$T" bash "$H")
  has "$o" "레포 규약 편집" "HOME git + 킷 사본 git 아님 → 레포 규약: $f"; not "$o" "킷 규약 편집" "HOME git + 킷 사본 git 아님 → 킷 갈래 아님: $f"
done
# 큐 쓰기 안내는 다른 안내 줄처럼 한 칸 들여 쓴다(운영 파일을 둔 가짜 킷 KO 로 — 실제 HOME 의 킷 유무와 무관하게).
o=$(runq "/x/repo/CLAUDE.md" | jq -r '.hookSpecificOutput.additionalContext // empty')
case "$o" in *$'\n 킷 후보 큐: '*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL: 큐 안내 줄 들여쓰기 한 칸" ;; esac
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
