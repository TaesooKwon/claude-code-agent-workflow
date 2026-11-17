#!/usr/bin/env bash
# git-push-guard.sh 계약 테스트 — 양성(차단)·음성(통과)·우회 형태를 stdin JSON 으로 태운다.
# 실행: bash ~/.claude/hooks/git-push-guard.test.sh
# ⚠️ 검사 대상 명령 문자열은 **이 파일 안에만** 둔다. Bash 도구 명령줄에 직접 적으면
#    레포의 커밋·푸시 계열 가드가 그 문자열을 보고 호출 자체를 막는다.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/git-push-guard.sh"
[ -f "$HOOK" ] || { echo "훅 파일 없음: $HOOK"; exit 2; }

run=0
passed=0

# 명령 문자열 → PreToolUse(Bash) stdin JSON (인용·이스케이프는 python3 json 에 맡긴다)
_payload() {
  python3 -c 'import json,sys
print(json.dumps({"session_id":"test","cwd":"/tmp","hook_event_name":"PreToolUse",
                  "tool_name":"Bash","tool_input":{"command":sys.argv[1]}}, ensure_ascii=False))' "$1"
}

# 훅 출력에서 permissionDecision 을 뽑는다(출력 없음 = 통과 = 빈 문자열)
_decision_of() {
  printf '%s' "$1" | python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("")
else:
    try:
        print(json.load(__import__("io").StringIO(raw)).get("hookSpecificOutput", {}).get("permissionDecision", "?"))
    except Exception:
        print("?parse-error")'
}

# $1=기대(deny|allow) $2=설명 $3=명령문자열
_check() {
  local want="$1" desc="$2" cmd="$3" out rc got
  run=$((run + 1))
  out=$(_payload "$cmd" | bash "$HOOK" 2>/dev/null)
  rc=$?
  got=$(_decision_of "$out")
  [ -n "$got" ] || got="allow"
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL  %-58s (exit=%s, 훅은 항상 0 이어야 한다)\n' "$desc" "$rc"
    return
  fi
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    printf 'ok    %-58s [%s]\n' "$desc" "$got"
  else
    printf 'FAIL  %-58s 기대=%s 실제=%s\n' "$desc" "$want" "$got"
  fi
}

# 원시 stdin 을 그대로 넣는 경우(깨진 JSON 등)
_check_raw() {
  local want="$1" desc="$2" raw="$3" out rc got
  run=$((run + 1))
  out=$(printf '%s' "$raw" | bash "$HOOK" 2>/dev/null)
  rc=$?
  got=$(_decision_of "$out")
  [ -n "$got" ] || got="allow"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then
    passed=$((passed + 1))
    printf 'ok    %-58s [%s]\n' "$desc" "$got"
  else
    printf 'FAIL  %-58s 기대=%s 실제=%s(exit=%s)\n' "$desc" "$want" "$got" "$rc"
  fi
}

echo "== 양성(차단되어야 한다) =="
_check deny  "맨 푸시"                        'git push'
_check deny  "옵션·원격·브랜치 인자"          'git push origin main --force-with-lease'
_check deny  "&& 체인(cd 뒤)"                 'cd /tmp/example-repo && git push'
_check deny  "; 체인(다른 git 명령 뒤)"       'git status --short; git push origin HEAD'
_check deny  "--git-dir/--work-tree 변형"     'git --git-dir=/tmp/x/.git --work-tree=/tmp/x push'
_check deny  "-C 경로 변형"                   'git -C /tmp/x push --tags'
_check deny  "절대경로 호출"                  '/usr/bin/git push'
_check deny  "셸 래핑(sh -c)"                 'sh -c "git push"'
_check deny  "파이프 뒤"                      'echo hi | xargs -I{} git push'
_check deny  "우회 문구 스푸핑(인용문 안)"    'git push origin main; echo "ALLOW_GIT_PUSH=1 아님"'
# 2026-11-06 lib 판정식 이식 — 공백 든 따옴표 옵션 값·줄 잇기·\git(별칭 회피)
_check deny  "\\git(별칭 회피)"                 '\git push origin main'
_check deny  "줄 잇기(git \\⏎ push)"            "$(printf 'git \\\n%s origin main' push)"
_check deny  "-c 공백 든 따옴표 값(스트립 후에도 deny 유지 — 회귀 고정)" 'git -c user.name="A B" push'
_check deny  "-C 공백 든 따옴표 경로(스트립 후에도 deny 유지 — 회귀 고정)" 'git -C "/a b" push'
# 리뷰 지적(2026-11-06) — 순서 상호작용 고정: 따옴표 값 안 줄 잇기 · heredoc 뒤 줄 잇기
_check deny  "-c 따옴표 값 안 줄 잇기"          "$(printf 'git -c x=\"a \\\nb\" push')"
# 인용 스트립을 피하는 꼴(따옴표 값이 줄 잇기로 두 줄에 걸침) — 인라인 _GIT_OPTVAL 이 직접 판정한다(종전 식이면 allow)
_check deny  "-C 따옴표 경로 안 줄 잇기(스트립 회피 — _GIT_OPTVAL 판정)" "$(printf 'git -C \"/a \\\nb\" push')"
_check deny  "heredoc 뒤 줄 잇기 push"         "$(printf 'cat > f.md <<EOF\nx\nEOF\ngit \\\npush')"

echo "== 음성(통과해야 한다) =="
_check allow "상태 조회"                      'git status --short'
_check allow "push 가 옵션 값으로만 등장"     'git log --grep=push --oneline -5'
_check allow "git 아닌 명령의 push 단어"      'npm run push-docs'
_check allow "무관한 빌드 명령"               'mvn test -pl CMS-Core -am'
# 2026-11-06 오탐 대조(lib 테스트와 같은 꼴) — 넓힌 판정이 이 꼴을 새로 막지 않는다
_check allow "-C 따옴표 경로 + 비푸시 && echo push" 'git -C "/a b" status && echo push'
_check allow "-c 따옴표 값 + log -- push"      'git -c x="a b" log -- push'
_check allow "echo 따옴표 push"                'echo "push"'
_check allow "git 아닌 명령의 줄 잇기"         "$(printf 'echo a \\\npush-docs')"
# 이 테스트를 Bash 도구로 돌리는 명령줄 자체가 막히면 안 된다(경로의 git-push 는 공백이 없어 비매칭)
_check allow "훅 자기 파일명이 든 실행 명령"  'bash __HOME__/.claude/hooks/git-push-guard.test.sh'
# 인용부 스트립(2026-09-18) — 읽기전용·안내문 명령이 막히던 오탐 3종. 처분 mechanizeSpec 의 git_strip_quoted 계약.
_check allow "인용문 검색(grep -rn)"          'grep -rn "git push" __HOME__/.claude/CLAUDE.md'
_check allow "안내문 출력(echo 작은따옴표)"   'echo '"'"'푸시는 사용자 전담 — git push 는 사용자가 칩니다'"'"''
# 커밋 명령 문자열은 조립해서 이 파일 안에 가둔다(파일 상단 ⚠️ 참조).
_GIT_BIN="git"
_check allow "커밋 메시지 안 문구"            "$_GIT_BIN commit -m \"가드 문서화: git push 는 사용자 전담\""

# 히어독 스트립(2026-09-18) — 문서·스크립트를 히어독으로 쓰는 명령이 본문 문구 때문에 막히던 오탐.
# 한 세션에서 3회 재현해 근본 수리했다(git_strip_heredoc). 본문의 실제 명령은 판정에서 빠지는 트레이드오프.
_check allow "문서 히어독 본문의 문구"        "$(printf 'cat > f.md <<EOF\n안내: %s 는 사용자 몫\nEOF' "$_GIT_BIN push")"
# ↓ python 은 싱크가 아니라 히어독 본문은 남는다. allow 인 이유는 뒤 단계의 따옴표 스트립(s='…' 안) — 기존 트레이드오프.
_check allow "파이썬 히어독 본문의 문구"      "$(printf "python3 - <<'PY'\ns='… %s …'\nPY" "$_GIT_BIN push")"
_check allow "들여쓴 히어독(<<-)"             "$(printf 'cat <<-EOF\n\t%s 금지\n\tEOF' "$_GIT_BIN push")"
_check allow "히어독 종료 뒤 무관 명령"       "$(printf 'cat > a.txt <<EOF\n%s\nEOF\necho done' "$_GIT_BIN push")"
_check deny  "인터프리터 히어독(본문=실행)"   "$(printf 'bash <<EOF\n%s\nEOF' "$_GIT_BIN push")"
_check deny  "히어독 밖의 실제 호출"          "$(printf 'cat > f.md <<EOF\n설명\nEOF\n%s origin main' "$_GIT_BIN push")"
# 2026-09-18 회귀 고정: here-string·따옴표 안 << 를 히어독 시작으로 오인해 다음 줄의 실제 호출을 삼키던 결함.
_check deny  "here-string 다음 줄의 호출"     "$(printf 'tr a-z A-Z <<<hi\n%s origin main' "$_GIT_BIN push")"
_check deny  "따옴표 안 << 다음 줄의 호출"    "$(printf 'grep -n "a << b" x.cpp\n%s origin main' "$_GIT_BIN push")"
_check deny  "인용된 <<TOKEN 다음 줄의 호출"  "$(printf 'echo "see <<NOTE"\n%s origin main' "$_GIT_BIN push")"
# 2026-09-18 허용 목록 재설계(G1): 본문을 실행하는 형태는 걷어내지 않는다 — 종전 금지 목록 판은 아래 3건을 allow 로 흘렸다.
_check deny  "cat <<EOF | bash 본문의 호출"   "$(printf 'cat <<EOF | bash\n%s origin main\nEOF' "$_GIT_BIN push")"
_check deny  "스크립트로 쓰고 실행"           "$(printf "cat <<'EOF' > p.sh\n%s origin main\nEOF\nbash p.sh" "$_GIT_BIN push")"
_check deny  "ssh host <<EOF 본문의 호출"     "$(printf 'ssh host <<EOF\n%s origin main\nEOF' "$_GIT_BIN push")"

echo "== 사본 드리프트(인라인 git_strip_heredoc = 킷 lib) =="
# 전역 훅은 레포 lib 를 source 할 수 없어 함수를 인라인 사본으로 둔다 — 사본이 갈라지면 층마다 계약이 달라진다.
# 대조 lib = 이 테스트 위치 기준 스캐폴드 lib(킷 global/hooks → 킷 global/agent-scaffold, 라이브 ~/.claude/hooks → ~/.claude/agent-scaffold), 없으면 $HOME 설치본
_kitlib="$(cd "$(dirname "$0")" && pwd)/../agent-scaffold/claude/hooks/lib/git-cmd.sh"; [ -f "$_kitlib" ] || _kitlib="$HOME/.claude/agent-scaffold/claude/hooks/lib/git-cmd.sh"
if [ -f "$_kitlib" ]; then
  _a=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$(dirname "$0")/git-push-guard.sh")
  _b=$(sed -n '/^git_strip_heredoc() {/,/^}/p' "$_kitlib")
  run=$((run + 1))
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then passed=$((passed + 1)); echo "  ok    인라인 사본 = 킷 lib"
  else echo "  FAIL  인라인 사본이 킷 lib 와 다르다(또는 추출 실패) — 한쪽만 고쳤다"; fi
else
  echo "  (건너뜀 — 킷 lib 없음: $_kitlib)"
fi

echo "== 사본 드리프트(인라인 _GIT_OPTVAL·git_unfold_lines·git_has_subcommand = 킷 lib) =="
if [ -f "$_kitlib" ]; then
  _a=$( { grep '^_GIT_OPTVAL=' "$(dirname "$0")/git-push-guard.sh"; sed -n '/^git_unfold_lines() {/,/^}/p;/^git_has_subcommand() {/,/^}/p' "$(dirname "$0")/git-push-guard.sh"; } )
  _b=$( { grep '^_GIT_OPTVAL=' "$_kitlib"; sed -n '/^git_unfold_lines() {/,/^}/p;/^git_has_subcommand() {/,/^}/p' "$_kitlib"; } )
  run=$((run + 1))
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then passed=$((passed + 1)); echo "  ok    인라인 판정 본문 = 킷 lib"
  else echo "  FAIL  인라인 판정 본문이 킷 lib 와 다르다(또는 추출 실패) — 한쪽만 고쳤다"; fi
else
  echo "  (건너뜀 — 킷 lib 없음: $_kitlib)"
fi

echo "== 선형 줄 잇기 펴기(2026-11-06) =="
_lsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-sed.XXXXXX") || exit 2
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log"\nexec /usr/bin/sed "$@"\n' "$_lsh" > "$_lsh/sed"; chmod +x "$_lsh/sed"; : > "$_lsh/log"
_unf_used() { grep -qF 'H;${x;s/' "$_lsh/log" && echo yes || echo no; }   # 선형 펴기 sed 스크립트가 불렸는가
PATH="$_lsh:$PATH" _check deny "선형 펴기: 줄 잇기 push"  "$(printf 'git \\\npush origin main')"
run=$((run + 1)); if [ "$(_unf_used)" = yes ]; then passed=$((passed + 1)); echo "ok    선형 펴기: 줄 잇기 있으면 sed 1회 경로"; else echo "FAIL  선형 펴기: 줄 잇기 있으면 sed 1회 경로"; fi
: > "$_lsh/log"; PATH="$_lsh:$PATH" _check deny "선형 펴기 대조: 줄 잇기 없는 push"  'git push origin main'
run=$((run + 1)); if [ "$(_unf_used)" = no ]; then passed=$((passed + 1)); echo "ok    선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; else echo "FAIL  선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; fi
rm -rf "$_lsh"

echo "== r2 리뷰: 채택·감지 =="
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
_fake adopt 'git push origin main'; PATH="$_fsh:$PATH" _check deny "r2 펴기: 센티널 있는 sed 출력 채택(가짜 = push)" "$(printf 'git status \\\n-s')"
run=$((run + 1)); if [ "$(_fake_n)" = 1 ]; then passed=$((passed + 1)); echo "ok    r2 펴기: sed 호출 1회(채택)"; else echo "FAIL  r2 펴기: sed 호출 1회(채택) (호출 $(_fake_n)회)"; fi
_fake nosent 'git push origin main'; PATH="$_fsh:$PATH" _check allow "r2 펴기: 센티널 없으면 종전 치환(감지)" "$(printf 'git status \\\n-s')"
run=$((run + 1)); if [ "$(_fake_n)" = 1 ]; then passed=$((passed + 1)); echo "ok    r2 펴기: sed 호출 1회(감지)"; else echo "FAIL  r2 펴기: sed 호출 1회(감지) (호출 $(_fake_n)회)"; fi
rm -rf "$_fsh"

echo "== 우회(ALLOW_GIT_PUSH=1) =="
_check allow "줄머리 변수 대입"               'ALLOW_GIT_PUSH=1 git push origin main'
_check allow "&& 뒤 변수 대입"                'cd /tmp && ALLOW_GIT_PUSH=1 git push'

echo "== 입력 방어 =="
_check_raw allow "깨진 JSON"                  'not a json at all'
_check_raw allow "빈 stdin"                   ''
_check      allow "빈 명령"                   ''

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -eq "$passed" ] || exit 1
