#!/usr/bin/env bash
# PreToolUse(Bash) 가드 — 층 A(git 훅: .claude/hooks/git/*)를 건너뛰거나 끄는 낱말을 막는다. 우회 변수 없음.
#   층 A 는 git 이 실행하는 훅이라 명령 형태와 무관하게 돌지만, 아래 형태는 훅 자체를 안 돌게 한다:
#     --no-verify(--no-veri… 축약 포함)·`git commit -n`(짧은 형태, 묶음 -nm 포함) · core.hooksPath(대소문자 무시) ·
#     `-c alias.…`(별칭으로 옵션 숨김) · `env -i`(CLAUDECODE 를 지운 환경) · `exec -c`(빈 환경) ·
#     CLAUDECODE 낱말(unset·재대입) · `.git/hooks`(스텁 삭제·교체).
#   명령에 git 낱말(.git 포함)이 있을 때만 본다. 히어독 본문은 lib 허용 목록 규칙(문서 싱크)으로 걷은 뒤 본다.
#   제외 = 모든 세그먼트가 쓰기·실행 수단이 없는 읽기 명령(아래 case 허용 목록)뿐이고
#   쓰기 리다이렉트(`>` — 낱개 토큰 `2>&1`·`>/dev/null` 류 제외)·명령치환(`$(`·백틱·`<(`)이 없는 경우.
#   허용 목록 밖 = 판정 대상: rg(`--pre` 로 임의 실행)·git log/show(`--output=` 으로 파일 쓰기)는 일부러 뺐다.
#   줄 이음(\+개행)은 펴고 본다(`git commit \⏎ -n` 의 -n 이 다음 줄로 갈리지 않게).
# 과탐 감수: 커밋 메시지·echo 안의 낱말도 막는다(정상 작업에 등장하지 않는 낱말만 골랐다). 정말 필요하면 사용자에게 요청한다
#   — 사용자는 자기 터미널(CLAUDECODE 미설정)에서 직접 실행한다.
# 안전: jq 부재 → exit 0(이 층은 조기 경보, 권위는 층 A).
# ponytail: 변수 조립·스크립트 파일에 써서 실행·다음 호출에서 실행은 못 본다(정적 판정의 천장) / 원격 보호 브랜치·층 A 재설치 점검.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])git([^[:alnum:]_-]|$)' || exit 0

scan="$cmd"
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ -f "$_lib" ] && . "$_lib" && command -v git_strip_heredoc >/dev/null 2>&1; then
  scan=$(git_strip_heredoc "$cmd")
fi
printf '%s' "$scan" | grep -qE '(^|[^[:alnum:]_-])git([^[:alnum:]_-]|$)' || exit 0
# 줄 잇기(\+LF) → 공백 1칸, 그 밖 바이트 불변 — 구현 원본 = 킷 스캐폴드 lib/git-cmd.sh 의 git_unfold_lines(동기화 = 그 함수와 diff).
#   종전 ${v//$'\\\n'/ } 는 bash 3.2 에서 비선형(timeout fail-open) → 줄 잇기가 있을 때만 sed 한 번(선형), sed 실패면 종전 치환.
case $scan in *$'\\\n'*)
  if _unf=$(printf '%sx' "$scan" | LC_ALL=C sed -n 'H;${x;s/\\\n/ /g;s/^\n//;p;}') && [ "${_unf%x}" != "$_unf" ]; then scan=${_unf%x}; else scan=${scan//$'\\\n'/ }; fi ;;
esac

# 읽기 명령뿐이면 제외 — 안전 리다이렉트를 걷은 뒤 세그먼트(; & | 줄바꿈) 머리가 전부 허용 목록이고, 남은 `>`·명령치환이 없을 때.
#   안전 리다이렉트 = 앞뒤가 공백·구분자인 낱개 토큰 `N>&M`(fd 복제)·`[&N]>[>]/dev/null` 만(`2>&1x`·`>/dev/null/..` 는 안 걷힘 → `>` 남음 → 판정).
#   같은 sed 를 두 번 = 붙은 리다이렉트(`>/dev/null 2>&1`)의 경계 공백을 앞 치환이 먹어도 둘째 패스가 마저 걷는다.
_safe_rd='(^|[[:space:]])([0-9]?>&[0-9]|[&0-9]?>>?[[:space:]]*/dev/null)([[:space:];&|]|$)'
_rd=$(printf '%s' "$scan" | sed -E -e "s#${_safe_rd}#\\1 \\3#g" -e "s#${_safe_rd}#\\1 \\3#g")
_all_read=1
printf '%s' "$_rd" | grep -qE '>|\$\(|`|<\(' && _all_read=0
_sed_line='^('"'"'[0-9]+(,[0-9]+)?p'"'"'|"[0-9]+(,[0-9]+)?p"|[0-9]+(,[0-9]+)?p)$'   # 'N[,M]p'·"N[,M]p"·N[,M]p
_plain_tok='^[[:alnum:]._/][[:alnum:]._/-]*$'   # 따옴표·$·{}·글롭·백슬래시·'-' 시작 = 불허
while [ "$_all_read" -eq 1 ] && IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  [ -n "$seg" ] || continue
  case "$seg" in
    # 쓰기·실행 옵션이 없는 명령만(인자 무제한) — 새로 넣을 땐 man 으로 파일 출력·외부 실행(--pre·e 류) 옵션 부재를 먼저 확인.
    # ponytail: Bash 셸이 zsh 면 인자 안의 글롭 한정자 (e:'…':)·=(…) 로 임의 실행된다(원본부터 있던 한계 · 위협모델 = 실수 방지라 미차단 — 이 때문에 stat·shasum 도 넣지 않는다, 목록을 늘리지 말 것) / 셸 의미 판정은 층 A(git 훅)가 권위.
    # ponytail: git config 읽기형 예외는 '<키> <값> --get' 같은 쓰기형도 통과시킨다(기존 동작) / 층 A 설치 점검(git-hooks-check)이 훅 경로 변경을 잡는다.
    ls|ls\ *|cat\ *|grep\ *|head|head\ *|tail|tail\ *|wc|wc\ *) ;;
    "sed -n "*)                                           # 줄 범위 출력만 — sed 의 w·e 명령·-i 가 들어올 자리를 형태로 막는다
      set -f; set -- $seg; set +f; shift 2
      if [ "$#" -ge 1 ] && [[ $1 =~ $_sed_line ]]; then
        shift
        for _t in "$@"; do [[ $_t =~ $_plain_tok ]] || { _all_read=0; break; }; done
      else
        _all_read=0
      fi ;;
    test\ -[a-z]\ *|"[ -"[a-z]\ *) ;;                      # 파일 검사(test -x .git/hooks/pre-commit)
    "git config "*)                                       # 읽기형만 — 값 쓰기(git config core.hooksPath x)는 판정 대상
      case " $seg " in
        *" --get"*|*" -l "*|*" --list "*|" git config get "*|" git config list "*) ;;
        *) _all_read=0 ;;
      esac ;;
    *) _all_read=0 ;;
  esac
done < <(printf '%s\n' "$_rd" | tr ';&|' '\n\n\n')
[ "$_all_read" -eq 1 ] && exit 0

hit=""
if printf '%s' "$scan" | grep -qE -- '--no-veri[a-z]*'; then hit="--no-verify"
elif printf '%s' "$scan" | grep -qiE 'hookspath'; then hit="core.hooksPath"
elif printf '%s' "$scan" | grep -qE -- '-c[[:space:]]*alias\.'; then hit="-c alias.…"
elif printf '%s' "$scan" | grep -qE '(^|[^[:alnum:]_-])env[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-i([[:space:]]|$)|(^|[^[:alnum:]_-])env[[:space:]]+--ignore-environment'; then hit="env -i"
elif printf '%s' "$scan" | grep -qE '(^|[^[:alnum:]_-])exec[[:space:]]+-[a-zA-Z]*c'; then hit="exec -c"
elif printf '%s' "$scan" | grep -qE 'CLAUDECODE'; then hit="CLAUDECODE"
elif printf '%s' "$scan" | grep -qE '\.git/hooks'; then hit=".git/hooks"
else
  # `git commit -n`(= --no-verify) — commit 세그먼트의 짧은 옵션 묶음에 n. 따옴표 안(메시지)은 걷고 본다.
  #   걷기는 한 패스 교대식 — 왼쪽에서 먼저 연 따옴표가 짝을 가진다("don't" 의 ' 가 뒤 'x' 와 짝지어지지 않게).
  while IFS= read -r seg; do
    if command -v git_has_subcommand >/dev/null 2>&1 && git_has_subcommand "$seg" commit; then
      rest=$(printf '%s' "$seg" | sed -E -e "s/'[^']*'|\"[^\"]*\"//g" -e 's/.*[[:space:]]commit([[:space:]]|$)//')
      if printf ' %s ' "$rest" | grep -qE '[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then hit="git commit -n"; break; fi
    fi
  done < <(printf '%s\n' "$scan" | tr ';&|' '\n\n\n')
fi
[ -n "$hit" ] || exit 0

reason="[git 훅 우회 가드] 이 명령에 git 훅(층 A — 커밋 내용 게이트·푸시 차단)을 건너뛰거나 끄는 형태(${hit})가 있습니다.
에이전트는 git 훅을 우회하지 않습니다(우회 변수 없음). 막힌 원인은 훅이 낸 안내문을 따라 해소하세요.
정말 훅 없이 실행해야 하는 사정이면 그 이유와 명령을 사용자에게 알리고, 사용자가 자기 터미널에서 직접 실행하게 하세요.
(오탐 — 커밋 메시지·문서 문구에 이 낱말이 든 경우 — 이면 그 낱말을 빼고 다시 실행하세요.)"
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
