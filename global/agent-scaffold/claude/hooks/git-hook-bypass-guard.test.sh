#!/usr/bin/env bash
# git-hook-bypass-guard.sh 회귀 — 실물 훅에 가짜 PreToolUse stdin 을 먹여 deny/allow 만 본다(부작용 없음).
# 케이스 추가 = `_c deny|allow "설명" '<명령>'` 한 줄.
# HOOKS_DIR_OVERRIDE = 사본 훅을 가리킬 때만(기본 = 이 테스트 옆의 실물 훅).
H="${HOOKS_DIR_OVERRIDE:-$(cd "$(dirname "$0")" && pwd)}/git-hook-bypass-guard.sh"
run=0; passed=0
_c() {
  local out d
  out=$(jq -n --arg c "$3" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}' | bash "$H" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"deny"'; then d=deny; else d=allow; fi
  run=$((run + 1))
  if [ "$d" = "$1" ]; then passed=$((passed + 1)); printf 'ok    %-44s [%s]\n' "$2" "$d"
  else printf 'FAIL  %-44s 기대=%s 실제=%s\n' "$2" "$1" "$d"; fi
}
echo "== 차단 =="
_c deny  "B1 --no-verify"                 'git commit -m x --no-verify'
_c deny  "B2 --no-veri 축약"              'git commit --no-veri -m x'
_c deny  "B3 commit -n"                   'git commit -n -m x'
_c deny  "B4 commit -nm 묶음"             'git commit -nm x'
_c deny  "B5 core.hooksPath"              'git -c core.hooksPath=/dev/null commit -m x'
_c deny  "B6 hookspath 대소문자"          'git -c CORE.HOOKSPATH=/x commit -m x'
_c deny  "B7 alias"                       'git -c alias.ci="commit --no-verify" ci -m x'
_c deny  "B8 env -i"                      'env -i PATH=/usr/bin git commit -m x'
_c deny  "B9 exec -c"                     'exec -c git commit -m x'
_c deny  "B10 CLAUDECODE 지움"            'CLAUDECODE= git commit -m x'
_c deny  "B11 unset CLAUDECODE"           'unset CLAUDECODE; git commit -m x'
_c deny  "B12 .git/hooks 삭제"            'rm .git/hooks/pre-commit'
_c deny  "B13 push --no-verify"           'git push --no-verify'
_c deny  "B14 sh -c 래핑"                 "sh -c 'git commit --no-verify -m x'"
_c deny  "B15 스크립트로 쓰고 실행"       $'cat > run.sh <<\'EOF\'\ngit commit --no-verify -m x\nEOF\nbash run.sh'
_c deny  "B16 env -u CLAUDECODE"          'env -u CLAUDECODE git commit -m x'
echo "== 통과 =="
_c allow "A1 평범한 커밋"                 'git commit -m "fix: 정리"'
_c allow "A2 메시지 안 n 글자"            'git commit -m "no newline"'
_c allow "A3 git 낱말 없음"               'echo --no-verify'
_c allow "A4 읽기: grep"                  'grep -rn hooksPath .claude/hooks'
_c allow "A5 읽기: git log"               'git log --grep=no-verify'
_c allow "A6 읽기: ls .git/hooks"         'ls .git/hooks'
_c allow "A7 문서 히어독 본문"            $'cat > note.md <<\'EOF\'\ngit commit --no-verify 금지\nEOF'
_c allow "A8 커밋 아닌 명령의 -n" 'git status && git diff -n 2>/dev/null; true'
_c allow "A9 설치 스크립트"               'bash .claude/scripts/install-git-hooks.sh'
_c allow "A10 commit --amend --no-edit"   'git commit --amend --no-edit'
echo "== 층 B 리뷰 회귀(2026-11-05 rvB) =="
_c deny  "R1 줄 이음으로 갈린 commit -n"  $'git commit \\\n  -n -m "wip"'
_c deny  "R2 읽기 명령 + > .git/hooks"    'cat /dev/null > .git/hooks/pre-commit'
_c deny  "R3 head + > .git/hooks"         'head -c0 /dev/null > .git/hooks/pre-push'
_c deny  "R4 읽기 명령 안 명령치환"       'grep x $(git commit --no-verify -m y)'
_c deny  "R5 config 쓰기형 hooksPath"     'git config core.hooksPath /dev/null'
_c deny  "R6 config 읽기 && 쓰기"         'git config --get core.hooksPath && git config core.hooksPath x'
_c allow "R7 읽기 + 2>/dev/null"          'grep -rn hookspath .claude/hooks/git 2>/dev/null'
_c allow "R8 config 읽기형(설치 안내)"    'git config --show-origin --get core.hooksPath'
_c allow "R9 test -x 설치 확인"           'test -x .git/hooks/pre-commit'
_c allow "R10 [ -f ] 설치 확인"           '[ -f .git/hooks/pre-push ]'
_c deny  "R11 겹따옴표 속 ' + 뒤 ' 사이 -n"     "git commit -m \"don't\" -n -m 'x'"
_c allow "R12 겹따옴표 속 ' + 뒤 '(오탐 대조)"  "git commit -m \"don't\" -m 'no-n here'"
echo "== 읽기 오탐 수리 · 허용목록 축소(2026-11-05) =="
_c allow "F1 ls 2>&1 | grep"                'ls -la .git/hooks 2>&1 | grep -v sample'
_c allow "F2 cat &>/dev/null"               'cat .git/hooks/pre-commit &>/dev/null'
_c deny  "F3 shasum 은 허용목록 밖(zsh 글롭 한정자 회귀 차단)" 'shasum .git/hooks/pre-commit .git/hooks/pre-push'
_c deny  "G44 shasum 글롭 한정자"            'shasum .git/hooks/pre-commit(e:'"'"'rm $REPLY'"'"':)'
_c deny  "G45 shasum =(…) 치환"             'shasum =(rm .git/hooks/pre-commit)'
_c deny  "F4 stat 은 허용목록 밖(zsh 글롭 한정자 회귀 차단)" 'stat -f %Lp .git/hooks/pre-commit'
_c deny  "G43 stat 글롭 한정자"              'stat -f %Lp .git/hooks/pre-commit(e:'"'"'chmod -x $REPLY'"'"':)'
_c allow "F5 sed -n '1,20p'"                "sed -n '1,20p' .git/hooks/pre-commit"
_c allow "F6 sed -n 1,20p(따옴표 없음)"     'sed -n 1,20p .git/hooks/pre-commit'
_c allow "F7 ls >/dev/null 2>&1"            'ls .git/hooks >/dev/null 2>&1'
_c allow "F8 cat 2>/dev/null | head(대조)"  'cat .git/hooks/pre-commit 2>/dev/null | head -5'
_c allow "F9 ls | grep(대조)"               'ls -la .git/hooks | grep -v sample'
_c allow "F10 git log 금지낱말 없음(대조)"  'git log --oneline -5'
_c deny  "G1 rg --pre 임의 실행"            'rg --pre rm x .git/hooks'
_c deny  "G2 rg 는 읽기 예외 밖(과탐 감수)" 'rg -n pre-commit .git/hooks'
_c deny  "G3 git log --output"              'git log -1 --output=.git/hooks/pre-commit'
_c deny  "G4 git show --outp 축약"          'git show HEAD --outp=.git/hooks/pre-push'
_c deny  "G5 git log 따옴표 속 --output"    'git log "--output=.git/hooks/pre-commit"'
_c deny  "G6 git log -\\-output"            'git log -\-output=.git/hooks/pre-commit'
_c deny  "G7 --o\${IFS:0:0}utput"           'git log -1 --o${IFS:0:0}utput=.git/hooks/pre-commit'
_c deny  "G8 --o\$@utput"                   'git show HEAD --o$@utput=.git/hooks/pre-push'
_c deny  "G9 ANSI-C \$'\\x2d-output'"       "git log -1 \$'\\x2d-output=.git/hooks/pre-commit'"
_c deny  "G10 중괄호 --o{utput,neline}"     'git log -1 --o{utput=.git/hooks/pre-commit,neline}'
_c deny  "G11 중괄호 범위 {t..v}"           'git log -1 --o{t..v}tput=.git/hooks/pre-commit'
_c deny  "G12 git log 는 읽기 예외 밖(과탐 감수)" 'git log --oneline -- .git/hooks'
_c deny  "G13 sed -n -i"                    "sed -n -i '1p' .git/hooks/pre-commit"
_c deny  "G14 sed w 명령"                   "sed -n 'w .git/hooks/pre-commit' x"
_c deny  "G15 sed s///w 플래그"             "sed -n '1s/a/b/w .git/hooks/pre-commit' x"
_c deny  "G16 sed e 명령"                   "sed -n '1e rm .git/hooks/pre-commit' x"
_c deny  "G17 sed 파일자리 '-i'"            "sed -n 1p .git/hooks/pre-commit '-i'"
_c deny  "G18 sed 파일자리 \"--in-place\""  'sed -n 1p .git/hooks/pre-commit "--in-place"'
_c deny  "G19 sed 파일자리 \\-i"            'sed -n 1p .git/hooks/pre-commit \-i'
_c deny  "G20 sed 짝 안 맞는 따옴표"        "sed -n '1p\" .git/hooks/pre-commit"
_c deny  "G21 sed 글롭 파일자리"            'sed -n 1p .git/hooks/pre-commit *'
_c deny  "G22 sed \$'' 파일자리"            "sed -n 1p .git/hooks/pre-commit \$'-i'"
_c deny  "G23 sed {,} 파일자리"             'sed -n 1p .git/hooks/pre-commit {-i,x}'
_c deny  "G24 sed \${IFS} 조립"             'sed -n 1p .git/hooks/pre-commit${IFS}-i'
_c deny  "G25 sed -n 1p 뒤 -i 맨토큰"       'sed -n 1p -i .git/hooks/pre-commit'
_c deny  "G42 sed 맨 w 명령(따옴표 없음)"   'sed -n 1w.git/hooks/pre-commit x'
_c deny  "G26 2>&1x 파일 리다이렉트"        'ls .git/hooks 2>&1x'
_c deny  "G27 >/dev/null/.. 꼬리"           'cat x >/dev/null/../../.git/hooks/pre-commit'
_c deny  "G28 2>&1 에 붙은 >"               'ls .git/hooks 2>&1>.git/hooks/x'
_c deny  "G29 1>&2 뒤 > 파일"               'cat x 1>&2 > .git/hooks/pre-commit'
_c deny  "G30 >& 파일"                      'cat x >& .git/hooks/pre-commit'
_c deny  "G31 >> 추가 쓰기"                 'cat x >> .git/hooks/pre-commit'
_c deny  "G32 cat | tee"                    'cat x | tee .git/hooks/pre-commit'
_c deny  "G33 stat 명령치환"                'stat $(rm .git/hooks/pre-commit)'
_c deny  "G34 cat 프로세스 치환 >("         'cat >(rm x) .git/hooks/pre-commit'
_c deny  "G35 >/dev/null ; rm"              'ls .git/hooks >/dev/null; rm .git/hooks/pre-commit'
_c deny  "G36 2>&1 && rm"                   'ls .git/hooks 2>&1 && rm .git/hooks/pre-push'
_c deny  "G37 &>/dev/null & rm"             'shasum .git/hooks/pre-commit &>/dev/null & rm .git/hooks/pre-push'
_c deny  "G38 ls || mv"                     'ls .git/hooks || mv .git/hooks/pre-commit /tmp/x'
_c deny  "G39 ls && chmod"                  'ls .git/hooks && chmod -x .git/hooks/pre-commit'
_c deny  "G40 ln -sf"                       'ln -sf /dev/null .git/hooks/pre-commit'
_c deny  "G41 &>/dev/null; --no-verify"     'cat .git/hooks/pre-commit &>/dev/null; git commit --no-verify -m x'
echo "== 선형 줄 잇기 펴기(2026-11-06) =="
_lsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-sed.XXXXXX") || exit 2
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log"\nexec /usr/bin/sed "$@"\n' "$_lsh" > "$_lsh/sed"; chmod +x "$_lsh/sed"; : > "$_lsh/log"
_unf_used() { grep -qF 'H;${x;s/' "$_lsh/log" && echo yes || echo no; }   # 선형 펴기 sed 스크립트가 불렸는가
PATH="$_lsh:$PATH" _c deny  "선형 펴기: 줄 잇기 뒤 --no-verify"  "$(printf 'git \\\ncommit --no-verify -m x')"
_v=$(_unf_used); run=$((run + 1)); if [ "$_v" = yes ]; then passed=$((passed + 1)); echo "ok    선형 펴기: 줄 잇기 있으면 sed 1회 경로"; else echo "FAIL  선형 펴기: 줄 잇기 있으면 sed 1회 경로"; fi
: > "$_lsh/log"; PATH="$_lsh:$PATH" _c deny  "선형 펴기 대조: 줄 잇기 없는 --no-verify"  'git commit --no-verify -m x'
_v=$(_unf_used); run=$((run + 1)); if [ "$_v" = no ]; then passed=$((passed + 1)); echo "ok    선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; else echo "FAIL  선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; fi
rm -rf "$_lsh"

echo "== r2 리뷰: 채택·감지·드리프트 =="
# 2026-11-06 r2 리뷰 — sed 결과 '채택'(센티널 있음)·'감지'(센티널 없음 → 종전 치환)·호출 1회를 가짜 sed 로 고정
_fsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-fake.XXXXXX") || exit 2
cat > "$_fsh/sed" <<'SHIM'
#!/bin/bash
# 가짜 sed — 선형 펴기 스크립트(H;${x;s/…)만 가로챈다: mode=adopt → payload+센티널 x, nosent → payload(센티널 없음, rc 0). 그 밖은 진짜 sed.
d=$(dirname "$0"); printf '%s\n' "$*" >> "$d/log"
case "$*" in *'H;${x;s/'*)
m=$(cat "$d/mode" 2>/dev/null)
if [ "$m" = adopt ]; then cat >/dev/null; printf '%sx\n' "$(cat "$d/payload")"; exit 0; fi
if [ "$m" = nosent ]; then cat >/dev/null; printf '%s\n' "$(cat "$d/payload")"; exit 0; fi ;;
esac
exec /usr/bin/sed "$@"
SHIM
chmod +x "$_fsh/sed"
_fake() { printf '%s' "$1" > "$_fsh/mode"; printf '%s' "$2" > "$_fsh/payload"; : > "$_fsh/log"; }
_fake_n() { grep -cF 'H;${x;s/' "$_fsh/log"; }   # 선형 펴기 sed 호출 수
_unf_drift() { # $1=lib $2=인라인 사본 훅 → same|diff|nolib — sed 스크립트 리터럴과 센티널 비교 줄(변수명 정규화)을 대조
  [ -f "$1" ] || { echo nolib; return; }
  local lit cmp; lit=$(sed -n '/^git_unfold_lines() {/,/^}/p' "$1" | grep -oE "LC_ALL=C sed -n '[^']*'" | head -1)
  cmp=$(sed -n '/^git_unfold_lines() {/,/^}/p' "$1" | grep -oE '\[ "\$\{_GIT_UNFOLDED%x\}" != "\$_GIT_UNFOLDED" \]' | head -1 | sed 's/_GIT_UNFOLDED/_unf/g')
  [ -n "$lit" ] && [ -n "$cmp" ] && grep -qF "$lit" "$2" && grep -qF "$cmp" "$2" && echo same || echo diff
}
_fake adopt 'git commit --no-verify -m y'; PATH="$_fsh:$PATH" _c deny  "r2 펴기: 센티널 있는 sed 출력 채택(가짜 = --no-verify, 페이로드는 x 로 끝나지 않게)" "$(printf 'git status \\\n-s')"
run=$((run + 1)); if [ "$(_fake_n)" = 1 ]; then passed=$((passed + 1)); echo "ok    r2 펴기: sed 호출 1회(채택)"; else echo "FAIL  r2 펴기: sed 호출 1회(채택) (호출 $(_fake_n)회)"; fi
_fake nosent 'git commit --no-verify -m y'; PATH="$_fsh:$PATH" _c allow "r2 펴기: 센티널 없으면 종전 치환(감지)" "$(printf 'git status \\\n-s')"
run=$((run + 1)); if [ "$(_fake_n)" = 1 ]; then passed=$((passed + 1)); echo "ok    r2 펴기: sed 호출 1회(감지)"; else echo "FAIL  r2 펴기: sed 호출 1회(감지) (호출 $(_fake_n)회)"; fi
_d=$(_unf_drift "$(dirname "$H")/lib/git-cmd.sh" "$H"); run=$((run + 1)); if [ "$_d" = same ]; then passed=$((passed + 1)); echo "ok    r2 드리프트: 인라인 펴기 = lib git_unfold_lines"; else echo "FAIL  r2 드리프트: 인라인 펴기 ≠ lib ($_d)"; fi
rm -rf "$_fsh"

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -eq "$passed" ]
