#!/usr/bin/env bash
# destructive-cmd-ask.sh — 잡아야 할 것(ask)·통과할 것(무출력) 표
H="${1:-$(dirname "$0")/destructive-cmd-ask.sh}"; pass=0; fail=0
TD=$(mktemp -d); : > "$TD/cases"   # Bash 로 돈 (cwd, 명령) NUL 구분 — run 은 $(…) 서브셸에서 돌아 배열로는 못 모은다. 아래 HEAD 차등 비교가 다시 돌린다
run(){ [ "$1" = Bash ] && printf '%s\0%s\0' "${3:-/repo}" "$2" >> "$TD/cases"; jq -n --arg t "$1" --arg c "$2" --arg w "${3:-/repo}" '{tool_name:$t,tool_input:{command:$c},cwd:$w}' | bash "$H"; }
one(){ [ "$(printf '%s' "$1" | jq -s length 2>/dev/null)" = 1 ]; }   # 출력 = JSON 1개
okw(){ o=$(run Bash "$1" "$2"); if [ -z "$o" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(통과 기대, cwd=$2): $1"; fi; }
ask(){ o=$(run Bash "$1"); if printf '%s' "$o" | grep -q '"permissionDecision": *"ask"' && one "$o"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(ask 기대): $1"; fi; }
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
ask $'cat > a.md <<"E"OF\nx\nEOF\nrm -rf src'; ask $'cat > a.md <<E"OF"\nx\nEOF\nrm -rf src'   # 섞인 인용 구분자 — bash 는 EOF 에서 끝내고 뒤 줄을 실행한다
ok $'# rm -rf src 는 하지 않는다\nls'; ok 'ls  # 정리 뒤; rm -rf src 는 금지'; ok $'git commit -F - <<\'EOF\'\nfix: don\'t break\nEOF'
# 드리프트: 인라인 git_strip_heredoc = 킷 lib(전역 훅은 레포 lib 를 source 할 수 없다 — 사본이 갈라지면 층마다 계약이 달라진다)
_kl="$HOME/.claude/agent-scaffold/claude/hooks/lib/git-cmd.sh"
if [ -f "$_kl" ]; then
  _a=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$H"); _b=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$_kl")
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: 인라인 git_strip_heredoc 이 킷 lib 와 다르다"; fi
else echo "(드리프트 건너뜀 — 킷 lib 없음: $_kl)"; fi
# 2026-11-17 git branch 강제 삭제(순서·묶음·전역옵션·래퍼·따옴표 무관) / -d 단독·이동·목록·-- 뒤 이름은 통과
ask 'git branch -D feat'; ask 'git branch -Df feat'; ask 'git branch -fD feat'; ask 'git branch -df feat'
ask 'git branch --delete --force feat'; ask 'git branch --force --delete feat'; ask 'git branch -d -f feat'
ask 'git branch -d --force feat'; ask 'git branch feat -D'; ask 'git -C /repo branch -D feat'
ask 'git -c core.x=y branch -D feat'; ask 'sudo git branch -D feat'; ask 'git branch "-D" feat'; ask 'ls; git branch -D feat'
ok 'git branch -d feat'; ok 'git branch --delete feat'; ok 'git branch -f feat HEAD~1'; ok 'git branch'
ask 'git branch --del --forc feat'; ask 'git branch -d --forc feat'; ask 'git branch --dele -f feat'; ask 'git branch --d -f feat'; ask 'git branch -f --d feat'   # 긴 옵션 축약(git 이 받아들임)
# git clean 강제·find 삭제(2026-11-17)
ask 'git clean -f'; ask 'git clean -fdx'; ask 'git clean -df'; ask 'git clean --force'; ask 'git clean --forc -d'; ask 'git -C /repo clean -f'; ask 'sudo git clean -f'; ask 'cd a && git clean -fd'
ok 'git clean -n'; ok 'git clean -nfd'; ok 'git clean -f -n'; ok 'git clean --dry-run -f'; ok 'git clean -d'; ok 'git clean -i'
ask 'find . -name "*.java" -delete'; ask 'find ~/proj -delete'; ask 'find src -exec rm {} +'; ask 'find src -execdir /bin/rm -f {} \;'; ask 'find src -ok rm {} \;'; ask 'find -delete'; ask 'find /tmp/x ~/p -delete'
ok 'find /tmp/x -delete'; ok 'find /private/tmp/a -name "*.o" -exec rm {} +'; ok 'find . -name "*.java"'; ok 'find src -exec grep -l x {} +'; ok 'find . -print -exec cat {} \;'
# 델타 리뷰 B1·B2·R3(2026-11-17) — 괄호·\; 가 find 세그먼트를 끊지 않게, 앞머리 -H/-L/-P, clean -e 값
ask 'find . \( -name a -o -name b \) -delete'; ask "find . '(' -name a ')' -delete"; ask 'find src -name x -exec ls {} \; -delete'; ask 'find src -exec echo {} \; -exec rm {} \;'; ask 'find . -name a -o \( -name b -delete \)'
ask 'find -L /etc -delete'; ask 'find -H ~ -delete'; ask 'find -P /Users/me/proj -exec rm {} +'; ask 'find /tmp/w -files0-from list -delete'; ask 'find -L /tmp/w -delete'; ask 'git clean -f -enx'
ok 'find /tmp/w \( -name a \) -delete'; ok 'find -P /tmp/w -delete'; ok 'git clean -f -e x -n'; ok 'find . -name "*.java" -exec grep -l x {} \;'; ok 'find . \( -name a \) -print'
# 재리뷰 D1·A1·A2(2026-11-17) — 인용·이스케이프 상태를 따른 괄호 보호, BSD 앞머리 옵션, --exclude 값
ask 'echo \\; rm -rf ~'; ask 'echo \\; git reset --hard'; ask 'echo "x";"rm" -rf ~'; ask "echo 'a';'git' reset --hard"; ask 'echo "a";"git" reset --hard'
ok 'echo x \; rm -rf ~'; ask "ls ';' && rm -rf ~"
T=/tmp/w; tk(){ o=$(run Bash "$1" "$T"); if printf '%s' "$o" | grep -q '"permissionDecision": *"ask"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(ask 기대, cwd=$T): $1"; fi; }
to(){ o=$(run Bash "$1" "$T"); if [ -z "$o" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(통과 기대, cwd=$T): $1"; fi; }
tk 'find -- ~/proj -delete'; tk 'find -x ~/proj -delete'; tk 'find -E ~/proj -name x -delete'; tk 'find -f ~/proj -delete'; tk 'find -s ~/proj -delete'; tk 'find -HL /tmp/w -delete'; tk 'find -delete'
to 'find -x /tmp/w -delete'; to 'find -f /tmp/w -delete'
ask 'git clean -f --exclude -n'; ask 'git clean -f --excl -n'; ok 'git clean -f --exclude=x -n'
# 재리뷰3 B1·A-2·A-3 — 주석 속 따옴표가 인용 상태를 뒤집지 않게, clean 값 --dry-run, 식 위치 -follow
ask $'ls # don\'t\necho \'a\';\'git\' reset --hard'; ask $'ls # don\'t\necho \'a\';\'rm\' -rf ~'; ask $'ls # say "hi\necho "x";"rm" -rf ~'; ask $'ls # "\necho "(";"git" reset --hard'; ask $'ls # it\'s\nfind ~/p \\( -name a \\) -delete'
ask 'git clean -f -e --dry-run'; ask 'git clean -f --exclude --dry-run'; ask 'git clean -fe --dry-run'
tk 'find /tmp/w -follow -delete'; tk 'find /tmp/w -follow -exec rm {} +'
ok 'git branch -a'; ok 'git branch -- -D'; ok 'git branch -dr origin/feat'; ok 'echo "git branch -D feat"'
# 추가 관문 G-D1~G-D4(2026-11-20) — HEAD 판정이 통과시킨 형태 중 새로 ask 되는 것
ask 'for d in build out; do rm -rf $d; done'; ask 'if [ -d build ]; then rm -rf build; fi'; ask '{ rm -rf build; }'
ask 'while false; do git reset --hard; done'; ask '! rm -rf build'; ask 'if false; then :; else rm -rf build; fi'
ask 'for r in a b; do git -C $r clean -fdx; done'                                                  # G-D1 예약어 뒤
ask 'find . -type d -name build | xargs rm -rf'; ask 'find src -print0 | xargs -0 rm -rf'; ask 'echo . | xargs git clean -fdx'
ask 'git diff --name-only | xargs git restore --staged --worktree'
ask 'timeout 60 rm -rf src'; ask 'nice rm -rf src'; ask 'sudo -u root rm -rf src'; ask 'find . -name x -exec sudo rm -rf {} +'   # G-D1 래퍼·xargs 경유
ask "find . -name build -exec sh -c 'rm -rf \"\$1\"' _ {} \\;"; ask 'bash -c "rm -rf src"'; ask "sh -c 'git reset --hard HEAD~1'"
ask "bash -o pipefail -c 'rm -rf src'"; ask "bash -c \"bash -c 'bash -c \\\"rm -rf src\\\"'\""                # G-D2 셸 -c 본문(중첩 한도 넘으면 판정 불가)
ask 'git -c clean.requireForce=false clean -dx'                                                     # G-D3
ask 'git checkout HEAD src/main/App.java'; ask 'git checkout main -p src/a'; ask 'git stash -m wip'; ask 'git stash save wip'; ask 'git stash --keep-index'   # G-D4
# 정상 형태 고정 — 관문을 더해도 통과
ok 'git rm -r src/old'; ok 'git rm -r --cached build'; ok 'git -C /repo rm -rq x'; ok 'G=git; $G rm -rqf --cached .'
ok 'git stash pop'; ok 'git stash apply stash@{1}'; ok 'git stash show -p'; ok 'git stash branch tmp'
ok 'git checkout -b x'; ok 'git checkout -b x origin/x'; ok 'git checkout main'; ok 'git checkout --track origin/feat'; ok 'git checkout --detach HEAD~1'
ok "printf '%s\n' rm -rf x"; ok 'for f in a.md b.md; do cat $f; done'; ok 'bash -c "ls -la"'; ok 'bash -c "rm -r /tmp/x"'
ok 'xargs rm -f < list.txt'; ok 'timeout 60 rm -rf /tmp/x'; ok 'git -c clean.requireForce=false clean -n'; ok 'git -c core.x=y clean -d'
ok 'git worktree remove --force ../wt'   # 한계 고정(헤더 ponytail) — 이 형태를 잡게 바꾸면 이 줄도 바꾼다
# A리뷰 수리(2026-11-20) — G-D4 위치 인자에서 리다이렉트 낱말·대상 제외 · find -exec 바로 뒤 rm 은 find 분기(임시 폴더 면제)에 맡김 · -exec 뒤 래퍼 벗기기
ok 'git checkout main 2>&1 | tail -2'; ok 'git checkout main > /dev/null'; ok 'git checkout feat 2>/dev/null'; ok 'git checkout -q main 2>&1'
ask 'git checkout HEAD src/a.java 2>/dev/null'; ask 'git stash 2>/dev/null'
ok 'find /tmp/w -exec rm -rf {} +'; ok 'find /tmp/w -execdir rm -r {} \;'; ok 'find /tmp/w -exec rm -rf {} \;'
ask 'find /tmp/w -exec rm -rf src \;'; ask 'find /tmp/w -exec rm -rf {} src +'; ask 'find /tmp/w -exec rm -rf'   # rm 에 {} 밖 대상·종결자 없음 = G-D1 재판정
ask 'find /tmp/w -exec sudo rm -rf {} +'
ask 'find . -exec sudo rm {} +'; ask 'find src -exec env X=1 rm {} \;'; ok 'find /tmp/w -exec sudo rm {} +'
# 관문 실패 주입 — 관문 예외 = 판정 불가 ask, 판정기 비정상 종료 = ask, HEAD 판정의 hit 는 관문 예외로 지워지지 않는다
sed 's/^def gate_seg(a, depth):$/&\n    raise RuntimeError("inj")/' "$H" > "$TD/g.sh"
sed 's/^import os, re, shlex$/&\nraise SystemExit(3)/' "$H" > "$TD/x.sh"
inj(){ jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/repo"}' | bash "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'; }
if cmp -s "$H" "$TD/g.sh" || cmp -s "$H" "$TD/x.sh"; then fail=$((fail+1)); echo "FAIL: 주입 지점(gate_seg 정의 줄·python import 줄)이 없다"
else
  case "$(inj "$TD/g.sh" 'ls git')" in *"판정 불가(추가 관문 오류)"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: 관문 예외 → 판정 불가 ask 기대";; esac
  case "$(inj "$TD/g.sh" 'rm -rf src')" in *"rm -r src"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: 관문 예외가 HEAD hit 를 지웠다";; esac
  case "$(inj "$TD/x.sh" 'ls git')" in *"판정기 비정상 종료"*) pass=$((pass+1));; *) fail=$((fail+1)); echo "FAIL: 판정기 rc≠0 → ask 기대";; esac
fi
# HEAD 판과 차등 비교 — HEAD 가 ask 한 Bash 입력은 이 판도 ask(약화 0). 위에서 돈 입력 전부를 같은 cwd 로 다시 돌린다.
_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$_root" ] && git -C "$_root" show "${BASE_REF:-HEAD}:global/hooks/destructive-cmd-ask.sh" > "$TD/head.sh" 2>/dev/null; then
  weak=0; n=0
  while IFS= read -r -d '' w && IFS= read -r -d '' c; do
    n=$((n+1)); jj=$(jq -n --arg c "$c" --arg w "$w" '{tool_name:"Bash",tool_input:{command:$c},cwd:$w}')
    if printf '%s' "$jj" | bash "$TD/head.sh" | grep -q '"ask"' && ! printf '%s' "$jj" | bash "$H" | grep -q '"ask"'; then weak=$((weak+1)); echo "  약화: $c"; fi
  done < "$TD/cases"
  if [ $n -gt 0 ] && [ $weak -eq 0 ]; then pass=$((pass+1)); echo "ok HEAD ask ⊆ 이 판 ask (${n}건 대조)"; else fail=$((fail+1)); echo "FAIL: HEAD ask ⊆ 이 판 ask — 약화 ${weak} / 대조 ${n}건"; fi
else echo "(차등 비교 건너뜀 — 킷 git 작업 트리 밖이거나 ${BASE_REF:-HEAD} 에 파일 없음)"; fi
rm -rf "$TD"
# MCP 운영 DB 규칙 — 소문자화 후 개발 DB 접미사(-dev-db__·-devserver-db__)를 지우고도 mcp__*-db__* 면 ask. 픽스처는 example-* 만(실명 반출 금지).
mcp(){ jq -n --arg t "$1" '{tool_name:$t,tool_input:{sql:"select 1"}}' | bash "$H"; }
mask(){ o=$(mcp "$1"); if printf '%s' "$o" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(mcp ask 기대) $2: $1"; fi; }
mok(){ o=$(mcp "$1"); if [ -z "$o" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL(mcp 통과 기대) $2: $1"; fi; }
mask 'mcp__example-real-db__mysql_query' db-real-ask; mask 'mcp__example-prd-db__q' db-prd-ask; mask 'mcp__example-prod-db__q' db-prod-ask
mask 'mcp__Example-Real-DB__q' db-upper-ask; mask 'mcp__plugin_x_y-prod-db__q' db-plugin-ask; mask 'mcp__a__b-prod-db__q' db-dunder-ask
mask 'mcp__example-prod-db__x-dev-db__y' db-devtail-ask; mask 'MCP__example-real-db__q' db-upper-prefix-ask
mok 'mcp__example-dev-db__mysql_query' dev-db-pass; mok 'mcp__Example-DEV-DB__q' dev-upper-pass; mok 'mcp__paseo__list_agents' non-db-mcp-pass
mok 'mcp__example-devserver-db__q' devserver-pass; mok 'mcp__Example-DevServer-DB__q' devserver-upper-pass
mok 'mcp__mydb__q' db-nohyphen-pass; mok 'Read' read-pass
# jq 부재 — MCP 운영 DB 는 여전히 ask(고정 JSON), Bash 는 기존대로 통과.
NB=$(mktemp -d); for b in bash cat grep sed tr; do ln -s "$(command -v $b)" "$NB/$b"; done
nj(){ printf '%s' "$1" | /usr/bin/env PATH="$NB" "$NB/bash" "$H"; }
o=$(nj '{"tool_name":"mcp__example-real-db__q","tool_input":{}}'); printf '%s' "$o" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nojq-db-ask"; }
o=$(nj '{"tool_input":{"sql":"x"}, "tool_name" : "MCP__Example-Prod-DB__q"}'); printf '%s' "$o" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nojq-db-order-ask"; }
o=$(nj '{"tool_name":"mcp__example-dev-db__q","tool_input":{}}'); [ -z "$o" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nojq-dev-pass"; }
o=$(nj '{"tool_name":"Bash","tool_input":{"command":"rm -r app-core"}}'); [ -z "$o" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL nojq-bash-pass"; }
rm -rf "$NB"
echo "Tests run: $((pass+fail)), pass=$pass fail=$fail"; [ $fail -eq 0 ]
