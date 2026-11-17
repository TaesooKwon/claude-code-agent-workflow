#!/usr/bin/env bash
# destructive-cmd-ask.sh — 잡아야 할 것(ask)·통과할 것(무출력) 표
H="${1:-$(dirname "$0")/destructive-cmd-ask.sh}"; pass=0; fail=0
run(){ jq -n --arg t "$1" --arg c "$2" --arg w "${3:-/repo}" '{tool_name:$t,tool_input:{command:$c},cwd:$w}' | bash "$H"; }
okw(){ o=$(run Bash "$1" "$2"); if [ -z "$o" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(통과 기대, cwd=$2): $1"; fi; }
ask(){ o=$(run Bash "$1"); if printf '%s' "$o" | grep -q '"permissionDecision": *"ask"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(ask 기대): $1"; fi; }
ok(){ o=$(run Bash "$1"); if [ -z "$o" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(통과 기대): $1"; fi; }
ask 'git checkout -- src/A.java'; ask 'git checkout .'; ask 'git checkout -f main'
ask 'git restore .'; ask 'git restore --worktree a'; ask 'git restore --source=HEAD~1 a'; ask 'git restore :/'
ask 'git switch -f dev'; ask 'git switch --discard-changes dev'
ask 'git stash'; ask 'git stash push -m x'; ask 'git stash drop'; ask 'git stash clear'; ask 'git stash -u'
ask 'cd /repo && git stash drop'; ask 'echo hi; git checkout -- .'; ask 'FOO=1 git restore .'
ask 'rm -r src/old'; ask 'rm -R build'; ask 'rm --recursive x'
ok 'git status'; ok 'git checkout main'; ok 'git checkout -b feat'; ok 'git restore --staged a'
ok 'git stash list'; ok 'git stash show'; ok 'git switch dev'; ok 'git log --oneline'
ok 'rm a.txt'; ok 'rm -r /tmp/x'; ok 'rm -r /private/tmp/claude-501/s/x'; ok 'echo "git checkout -- ."'
ok 'grep -n rm file'; ok 'ls'
okw 'rm -r x' /tmp; okw 'rm -r ../s/x' /private/tmp/claude-501/a
# 2026-11-05 사냥 probe 회귀 + 수리 범위(줄바꿈 분할·ValueError ask·rm basename·글롭 대상·restore·reset·전역옵션·래퍼)
ask $'echo "don\'t"\nrm -r app-core'; ask $'cd /tmp\ngit checkout -- .'; ask '/bin/rm -r app-core'; ask '\rm -r app-core'
ask 'git restore app-core/src/'; ask 'git restore -W a'; ask 'git restore --staged --worktree a'
ask 'git reset HEAD~1 --hard'; ask 'git reset --hard'; ask 'git reset --merge'; ask 'git reset --keep HEAD~1'
ask 'echo "x; rm -r a'; ask 'rm -r /tmp/*'; ask 'rm -r "/tmp/$X"'; ask 'rm -r /tmp/{a,b}'
ask 'git -C /repo checkout -- .'; ask 'git -c core.x=y restore .'; ask 'sudo rm -r build'; ask 'command rm -r build'
ask $'python3 - <<\'PY\'\nimport os\nPY\nrm -r build'
ok $'git commit -m "don\'t break the build"'; ok $'git commit -m "it\'s fine to rm -r later"'
ok $'cat > note.md <<\'EOF\'\nrm -r build 금지\nEOF'; ok 'git restore -S a'; ok 'git reset --soft HEAD~1'; ok 'git reset HEAD a'
ok 'npm run format'; ok $'echo hi\nls'
# 2026-11-05 층 B 리뷰(rvB attack#1·fp#1) — 주석 뒤 줄 소실 · 낱말 중간 # · 걷지 않은 히어독 본문의 아포스트로피
ask $'# 빌드 산출물 정리\nrm -rf src'; ask $'cd x  # 이동\ngit reset --hard HEAD'; ask 'echo a#b; rm -rf src'
ask $'git commit -F - <<\'EOF\'\nfix: don\'t break\nEOF\nrm -rf src'
ok $'# rm -rf src 는 하지 않는다\nls'; ok 'ls  # 정리 뒤; rm -rf src 는 금지'; ok $'git commit -F - <<\'EOF\'\nfix: don\'t break\nEOF'
# 드리프트: 인라인 git_strip_heredoc = 킷 lib(전역 훅은 레포 lib 를 source 할 수 없다 — 사본이 갈라지면 층마다 계약이 달라진다)
_kl="$HOME/.claude/agent-scaffold/claude/hooks/lib/git-cmd.sh"
if [ -f "$_kl" ]; then
  _a=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$H"); _b=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$_kl")
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: 인라인 git_strip_heredoc 이 킷 lib 와 다르다"; fi
else echo "(드리프트 건너뜀 — 킷 lib 없음: $_kl)"; fi
o=$(jq -n '{tool_name:"mcp____PROJECT__-real-db__mysql_query",tool_input:{sql:"select 1"}}' | bash "$H"); printf '%s' "$o" | grep -q '"ask"' && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: real-db mcp ask"; }
o=$(jq -n '{tool_name:"mcp____PROJECT__-dev-db__mysql_query",tool_input:{sql:"select 1"}}' | bash "$H"); [ -z "$o" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: dev-db mcp 통과"; }
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
