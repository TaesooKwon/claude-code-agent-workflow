#!/usr/bin/env bash
# PostToolUse·PostToolUseFailure(Bash) 기록기 — CLAUDE.md 🧪검증 "harness 는 compile 까지, 커밋 전 mvn test 총계를 직접 확인"의 강제화 전반부.
# 근거 처분: project:검증:2 (+ project:검증:5 병합). 짝 = mvn-test-result-gate.sh(층 A 커밋 게이트).
#
# 왜 필요한가: 이 레포에서 red 커밋이 두 차례 났다. test-count-guard 는 테스트 '개수'만 보고 '결과'는 보지 않고,
# harness 는 compile 까지라 초록/빨강을 아무도 검문하지 않는 공백이 실재했다. 이 훅이 그 결과를 남기고,
# 짝 훅이 커밋 시점에 그 기록을 검문한다.
#
# 하는 일: 명령이 mvn + test 이면 .claude/.last-mvn-test 에
#   "<시작 epoch> <SUCCESS|FAILURE|UNKNOWN> <모듈 인자> <Tests run 총계> <full|partial>" 한 줄을 기록한다(원자적 교체).
#   모듈 인자 = 마지막 mvn 실행의 -pl/--projects 값(안전 문자만), 없으면 "-".
#   상태: 출력에 BUILD FAILURE 가 하나라도 있거나 Tests run 줄에 Failures·Errors 가 1 이상 = FAILURE /
#     BUILD SUCCESS 만 = SUCCESS / BUILD 줄이 없음·출력 판정 불가 = UNKNOWN(이전 SUCCESS 무효화 — 짝 훅은 SUCCESS 만 통과시킨다).
#   종료코드≠0 인 mvn test(PostToolUseFailure 이벤트)는 출력과 무관하게 "FAILURE … 0" 으로 기록한다.
#   시작 epoch = 훅 시각 − ceil(.duration_ms/1000) − START_MARGIN_S — 짝 훅은 이 시각 이후에 바뀐 소스를 미검증으로 본다
#     (종료 시각을 쓰면 테스트가 도는 동안 고친 편집이 검증된 것처럼 통과했다). .duration_ms 는 없을 수 있는 필드로
#     다룬다 — 없거나 숫자가 아니면 SUCCESS 는 기록하지 않는다(시작 시각을 모르는 초록 = 기록 무효).
#   범위(5번째 필드) = 허용 목록 형태의 명령만 full(아래 범위 판정). 부분 실행의 SUCCESS(총계>0)는 기록하지 않고
#     (이전 기록을 그대로 둔다 — 그 기록의 시작 시각 이후 변경은 짝 훅이 어차피 막는다), FAILURE·UNKNOWN·총계 0 은 판정한 범위 그대로 기록한다.
# 판정 재료는 stdin JSON 만 신뢰한다(.hook_event_name / .tool_input.command / .cwd / .duration_ms / .tool_response.stdout·stderr).
#   PostToolUse 에서 tool_response 가 객체가 아니면(형식 변화·누락) 판정 불가 → UNKNOWN 으로 기록한다(판정 불가 = 커밋 근거 아님).
#   기록을 쓰지 못하면 기존 기록을 지운다(낡은 SUCCESS 잔존 방지 — 기록 없음은 짝 훅이 막는다).
#
# 우회 환경변수: 없음(기록만 하고 아무것도 막지 않는다). 차단·우회는 짝 훅 mvn-test-result-gate.sh 의 ALLOW_UNTESTED_COMMIT=1.
#
# 한계(수용):
#   - 출력 문자열로 판정한다 — 명령에 mvn 과 test 낱말이 들어 있고 출력에 BUILD FAILURE 문구가 실린 다른 명령
#     (로그 파일 cat 등)도 FAILURE 로 기록될 수 있다(차단 쪽). 같은 명령의 BUILD SUCCESS 는 mvn 실행이 아니라 partial 이다.
#   - 이 세션이 이 레포 작업트리에서 친 명령만 본다. 레포 루트 pom 이 아닌 `-f` 대상·하위 디렉터리 실행은 partial 이다.
#   - 어느 테스트가 돌았는지는 기록하지 않는다(모듈 인자 문자열·총계·범위만). 짝 훅도 모듈 일치는 검사하지 않는다.
#
# Tests run 총계(2026-09-18 추가 — 전역 CLAUDE.md 「반증검사」 부칙 ⓓ: `Tests run: N>0` 을 단언한다.
#   미실행은 통과가 아니라 미반증이다): surefire 의 **모듈 요약 줄**(줄머리가 `[INFO]`·`[ERROR]`·`[WARNING]` 인 `Tests run: N, Failures: …` 중
#   `- in <클래스>` 가 붙지 않은 줄)만 골라 더한다 — 클래스별 줄까지 세면 이중계산이 된다.
#   요약 줄이 하나도 없으면 총계 0 으로 본다(= skipTests·테스트 없는 모듈).
#   BUILD SUCCESS 인데 총계가 0 이면 총계 0 으로 기록한다(이전 SUCCESS 무효화 — 짝 훅이 총계 0 을 막는다).
#   BUILD FAILURE 는 총계와 무관하게 기록한다(실패 사실 자체가 게이트의 근거다).
# ponytail: 총계 파싱은 surefire 출력 형식 가정이다(다른 테스트 플러그인·형식 변경 시 0 으로 읽힐 수 있다 →
#           보수적으로 총계 0 = 차단 쪽으로 틀린다) / 업그레이드 경로 = surefire XML 리포트 집계.
#   ⚠️범위 한계: 이 게이트는 `git rev-parse --show-toplevel` 이 CLAUDE_PROJECT_DIR 과 같을 때만 발화한다
#     (의도 — 세션 스코프 훅이 다른 레포 커밋까지 막던 사고를 끊는다). 그래서 **worktree 안에서 직접
#     커밋하면 조용히 통과한다**(worktree 의 toplevel 은 메인 레포 경로와 다르다). 규약의 병행 세션
#     절차는 리뷰만 worktree 에서 하고 커밋은 메인에서 하므로 그 경로에서는 게이트가 살아 있다.
#     worktree 커밋까지 덮으려면 비교축을 `git rev-parse --git-common-dir` 로 바꿔야 한다(미적용).
# 안전: jq/git 부재 · mvn test 아님 · 남의 레포 → 조용히 exit 0(fail-open). 다른 Bash 호출 방해 금지.
set -u

input=$(cat 2>/dev/null || true)
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# 이 레포에서만 기록한다 — 다른 레포의 초록을 이 레포 기록으로 남기면 그 자체가 거짓 초록이 된다.
[ -d "$proj/{{MODULE_CORE}}/src/main" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$top" ] || exit 0
[ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$proj" 2>/dev/null && pwd -P)" ] || exit 0

# 트리거: mvn 호출 + test 가 독립 토큰(경로 접두 /usr/local/bin/mvn·셸 래핑 허용, test-compile 류는 비매칭)
# 또는 harness 스킬 래퍼(`bash ~/.claude/skills/harness/harness.sh test <모듈>` — 안에서 레포 루트의 mvn test -pl <모듈> -am 을 돈다, 11-15).
if ! printf '%s' "$cmd" | grep -Eq "/\.claude/skills/harness/harness\.sh[\"']?[[:space:]]+test([[:space:]]|\$)"; then
  printf '%s' "$cmd" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?mvn([[:space:]]|\$)" || exit 0
  printf '%s' "$cmd" | grep -Eq "(^|[[:space:]])test([[:space:]]|\$)" || exit 0
fi

# 범위 판정 — 허용 목록. full = 아래 허용 형태만으로 이뤄진 실행. 그 밖은 전부 partial(커밋 근거가 못 된다).
#   명령을 제어 연산자(&& || ; | & 줄바꿈)로 끊은 조각마다, 명령 자리(환경 대입·time/nice/timeout 류·if/then/do 류·`bash -c` 를
#   건넌 첫 낱말)를 본다.
#   - 명령 자리가 cd/pushd → 실행 디렉터리를 갱신한다(조각 순서대로).
#   - 명령 자리가 mvn(또는 MVN_EXEC_HEADS 뒤의 mvn — xargs mvn · find -exec mvn) = mvn 실행. 그 뒤 인자가 _scope_mvn 허용 목록에 모두 들어야 하고, 리액터 루트(-f 대상 pom 의 디렉터리, 없으면 실행 디렉터리)가
#     레포 루트여야 한다(하위 모듈 디렉터리 실행·하위 pom 지정 = 의존 Core 가 로컬 저장소의 옛 jar 로 해석된다 — -am 누락과 같은 상황).
#     -pl 이 있으면: 제외 지정(`!`·`-` 접두)·셸 전개 = partial, {{MODULE_CORE}} 밖 모듈이 있는데 -am 도 {{MODULE_CORE}} 동반도 없으면 partial.
#   - 그 밖의 명령 인자 속 mvn 낱말(echo 안내 문구 · mark-review.sh --skip-reason "… mvn test …" 등)은 실행이 아니라 데이터로 본다.
#   - mvn 실행을 하나도 찾지 못한 명령(로그 cat·grep 등)은 partial — 그 출력의 BUILD SUCCESS 는 커밋 근거가 아니다.
#   문자열 전체 판정(조각 판정과 별개로 하나라도 걸리면 partial): MAVEN_* 환경 대입 · 목록 밖 -D 키 · `-D key`·--define · -rf/--resume-from.
#   한 Bash 호출에 mvn 이 여럿이면 어느 하나만 부분이어도 partial(차단 쪽).
# ponytail: 앞선 Bash 호출에서 export 한 MAVEN_OPTS·MAVEN_ARGS, ~/.mavenrc, 셸 함수·별칭으로 감싼 mvn 은 문자열에 보이지 않아 full 로 읽힌다
#   (설치 레포에서 확인: `ls .mvn/` — 있으면 다시 판정) / 업그레이드 경로 = surefire XML 리포트(target/surefire-reports)의 실행 클래스 수를 모듈 테스트 클래스 수와 대조.
FULL_D_KEYS='maven\.repo\.local|spring\.profiles\.active|file\.encoding|style\.color|surefire\.printSummary'   # grep -Ex 정규식(점 이스케이프)
# ponytail: -Plocal 을 허용한다 — 설치 레포 pom 에 <profile> 이 없을 때만 효과가 없다(설치 때 확인: grep -c '<profile>' pom.xml */pom.xml — 있으면 허용 목록에서 뺀다) /
#   업그레이드 경로 = 프로필이 생기면 그 프로필이 테스트 범위를 바꾸는지 보고 허용 목록에서 다시 판정.
MVN_EXEC_HEADS='xargs|find|parallel|watch'
_canon() { (cd "$1" 2>/dev/null && pwd -P); }
proj_c=$(_canon "$proj")
mods='-'
scope=full
invoked=0   # mvn 실행을 하나라도 찾았는가

_scope_global() {
  local c
  c=$(printf '%s' "$cmd" | tr -d "\"'")   # -D"test=x" → -Dtest=x
  printf '%s' "$c" | grep -Eq -- '(^|[^A-Za-z0-9_])MAVEN_[A-Za-z_]*=' && return 0
  printf '%s' "$c" | grep -Eq -- '(^|[[:space:]=])(-D[[:space:]]|-D$|--define([[:space:]]|=|$))' && return 0
  printf '%s' "$c" | grep -Eo -- '(^|[[:space:]=])-D[^[:space:]=]+' | sed -E 's/^[[:space:]=]*-D//' \
    | grep -Evx -- "$FULL_D_KEYS" | grep -q . && return 0
  printf '%s' "$c" | grep -Eq -- '(^|[[:space:]=])(-rf|--resume-from)([[:space:]]|=|$)' && return 0
  return 1
}

# _scope_mvn <디렉터리|""> <mvn 뒤 인자…> — 한 번의 mvn 실행을 판정한다. partial 이면 rc 1. -pl 값은 전역 mods 에 남긴다.
_scope_mvn() {
  local dir="$1"; shift
  local a seg_mods="" am=0 root="$dir" f k
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      clean|validate|compile|test-compile|process-resources|process-test-resources|process-classes|process-test-classes|test|package|verify|install) ;;
      -q|--quiet|-o|--offline|-B|--batch-mode|-e|--errors|-X|--debug|-U|--update-snapshots|-ntp|--no-transfer-progress|-V|--show-version|-ff|--fail-fast|-Plocal) ;;
      -am|--also-make) am=1 ;;
      -pl|--projects) seg_mods="${1:-}"; mods="$seg_mods"; [ "$#" -gt 0 ] && shift ;;
      --projects=*) seg_mods="${a#*=}"; mods="$seg_mods" ;;
      -T|--threads) case "${1:-x}" in *[!0-9C.]*) return 1 ;; esac; shift ;;
      -f|--file|--file=*)
        case "$a" in --file=*) f="${a#--file=}" ;; *) f="${1:-}"; [ "$#" -gt 0 ] && shift ;; esac
        case "$f" in ''|*'$'*|*'`'*|'~'*) return 1 ;; esac
        [ -n "$dir" ] || return 1
        case "$f" in /*) ;; *) f="$dir/$f" ;; esac
        [ -d "$f" ] && f="$f/pom.xml"
        [ "${f##*/}" = pom.xml ] || return 1
        root=$(_canon "${f%/*}") ;;
      -D?*)
        k="${a#-D}"; k="${k%%=*}"
        printf '%s' "$k" | grep -Eqx -- "$FULL_D_KEYS" || return 1 ;;
      '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>'|'&>') [ "$#" -gt 0 ] && shift ;;   # 리디렉션 + 파일명
      '>'?*|'>>'?*|'<'?*|[0-9]'>'?*) ;;
      *) return 1 ;;   # 모르는 인자(-fn·-fae·-rf·-P<기타>·-amd·셸 전개 등) = partial
    esac
  done
  [ -n "$root" ] && [ "$root" = "$proj_c" ] || return 1
  if [ -n "$seg_mods" ]; then
    case "$seg_mods" in *'$'*|*'`'*|*'*'*|*'?'*) return 1 ;; esac
    case ",$seg_mods" in *',!'*|*',-'*) return 1 ;; esac
    if printf '%s' "$seg_mods" | tr ',' '\n' | sed -E 's#^:##' | grep -Evx '{{MODULE_CORE}}' | grep -q . \
       && ! printf '%s' "$seg_mods" | tr ',' '\n' | sed -E 's#^:##' | grep -Eqx '{{MODULE_CORE}}' \
       && [ "$am" -eq 0 ]; then
      return 1
    fi
  fi
  return 0
}

_scope_global && scope=partial
# 조각 나누기: 줄 잇기(\+줄바꿈) 제거 → fd 복제(2>&1) 제거 → 제어 연산자를 줄바꿈으로 → 따옴표 제거·낱말 앞뒤 괄호/백틱 제거.
_c=$cmd
# 줄 잇기(\+LF) → 공백 1칸, 그 밖 바이트 불변 — 구현 원본 = 킷 스캐폴드 lib/git-cmd.sh 의 git_unfold_lines(동기화 = 그 함수와 diff).
#   종전 ${v//$'\\\n'/ } 는 bash 3.2 에서 비선형(timeout fail-open) → 줄 잇기가 있을 때만 sed 한 번(선형), sed 실패면 종전 치환.
case $_c in *$'\\\n'*)
  if _unf=$(printf '%sx' "$_c" | LC_ALL=C sed -n 'H;${x;s/\\\n/ /g;s/^\n//;p;}') && [ "${_unf%x}" != "$_unf" ]; then _c=${_unf%x}; else _c=${_c//$'\\\n'/ }; fi ;;
esac
_c=$(printf '%s' "$_c" | sed -E 's/[0-9]*>&[0-9-]+/ /g')
# 제어 연산자 → 개행(순서 &&→||→;→|→&, 종전 5치환과 같은 결과). bash 3.2 의 ${v//pat/rep} 는 구분자 수·길이에 비선형이라
#   (실측 5만 자·; 100 = 10.4s, 10만 자·400 = 120s 초과) 구분자가 있을 때만 sed 한 번(H 로 모아 치환 — 선형). 센티널 x·폴백 = git_unfold_lines 와 같은 계약.
case $_c in *'&'*|*'|'*|*';'*)
  if _sep=$(printf '%sx' "$_c" | LC_ALL=C sed 'H;$!d;x;s/^\n//;s/&&/\
/g;s/||/\
/g;s/;/\
/g;s/|/\
/g;s/&/\
/g') && [ "${_sep%x}" != "$_sep" ]; then _c=${_sep%x}
  else _c=${_c//'&&'/$'\n'}; _c=${_c//'||'/$'\n'}; _c=${_c//;/$'\n'}; _c=${_c//|/$'\n'}; _c=${_c//&/$'\n'}; fi ;;
esac
_c=$(printf '%s\n' "$_c" | sed -E "s/[\"']//g; s/(^|[[:space:]])(\\\$\\(|[({\`])+/\\1/g; s/[)}\`]+([[:space:]]|\$)/\\1/g")
dir=$(_canon "$cwd")
set -f
while IFS= read -r _line; do
  read -ra _t <<<"$_line"
  _n=${#_t[@]}; _i=0
  while [ "$_i" -lt "$_n" ]; do
    case "${_t[$_i]}" in
      time|nice|nohup|env|command|exec|builtin|eval|caffeinate|sudo|if|then|do|else|elif|while|until|'!') ;;
      timeout|gtimeout) _i=$((_i + 1)) ;;
      bash|sh|zsh) case "${_t[$((_i + 1))]:-}" in -c|-lc|-ic|-ec) _i=$((_i + 1)) ;; esac ;;
      [A-Za-z_]*=*) ;;   # 환경 대입(MAVEN_* 는 문자열 전체 판정이 partial 로 잡는다)
      *) break ;;
    esac
    _i=$((_i + 1))
  done
  [ "$_i" -lt "$_n" ] || continue
  _h=${_t[$_i]}
  case "$_h" in
    cd|pushd)
      _d=${_t[$((_i + 1))]:-}
      case "$_d" in
        ''|-|'~'*|*'$'*) dir="" ;;
        /*) dir=$(_canon "$_d") ;;
        *) [ -n "$dir" ] && dir=$(_canon "$dir/$_d") ;;
      esac
      continue ;;
    mvn|*/mvn)
      invoked=1
      _scope_mvn "$dir" "${_t[@]:$((_i + 1))}" || scope=partial
      continue ;;
    "$HOME/.claude/skills/harness/harness.sh"|'~/.claude/skills/harness/harness.sh'|'$HOME/.claude/skills/harness/harness.sh'|'${HOME}/.claude/skills/harness/harness.sh')
      # harness 래퍼 = 실행 디렉터리의 git 루트에서 `mvn test -pl <모듈> -am -Dmaven.repo.local=<핀>` 을 그대로 돈다(래퍼가 모듈을
      #   루트 pom <module> 허용 목록으로 거른다). 정확히 `harness.sh test <모듈>` 형태만 그 mvn 실행으로 판정하고, 여분 인자·
      #   실행 디렉터리 미상은 partial. 같은 경로 밖의 harness.sh(복사본)는 실행으로 보지 않는다.
      # ponytail: 따옴표를 지운 뒤 비교라 따옴표 안의 ~·$HOME 리터럴(실제로는 ./~/… 실행)과 앞선 HOME= 재대입을 구별하지 못한다
      #   (실행기 위조는 */mvn 분기와 같은 신뢰 수준) / 업그레이드 = 따옴표 제거 전 원문에서 ~·$HOME 이 따옴표 밖인지·HOME= 대입이 있는지 판정.
      [ "${_t[$((_i + 1))]:-}" = test ] || continue
      invoked=1
      _wr=""
      [ -n "$dir" ] && _wr=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) && _wr=$(_canon "$_wr")
      if [ -n "$_wr" ] && [ "$((_n - _i))" -eq 3 ]; then
        _scope_mvn "$_wr" test -pl "${_t[$((_i + 2))]}" -am || scope=partial
      else
        scope=partial
      fi
      continue ;;
  esac
  printf '%s' "$_h" | grep -Eqx -- "$MVN_EXEC_HEADS" || continue
  # 인자를 명령으로 실행하는 명령(xargs mvn … · find -exec mvn …) — 그 뒤 mvn 을 실행으로 보고 같은 허용 목록으로 판정한다.
  _j=$((_i + 1))
  while [ "$_j" -lt "$_n" ]; do
    case "${_t[$_j]}" in
      mvn|*/mvn) invoked=1; _scope_mvn "$dir" "${_t[@]:$((_j + 1))}" || scope=partial; break ;;
    esac
    _j=$((_j + 1))
  done
done <<EOF
$_c
EOF
set +f
[ "$invoked" -eq 1 ] || scope=partial
# 기록 필드는 공백으로 나뉜다 — 모듈 인자는 안전 문자만 남긴다(소비자도 같은 문자 집합만 옮긴다).
mods=$(printf '%s' "$mods" | tr -cd 'A-Za-z0-9._,:/!-')
[ -n "$mods" ] || mods='-'

# 시작 epoch — .duration_ms(음 아닌 정수 ms)로 역산한다. 없거나 형식이 어긋나면 빈 값(= SUCCESS 기록 무효).
# ponytail: START_MARGIN_S 는 도구 종료 → 이 훅 실행 사이 지연의 추정 상한이다(실측 아님 — 지연이 이보다 길면 그 틈의
#   편집이 통과한다) / 업그레이드 경로 = PreToolUse 에서 tool_use_id 별 시작 시각을 남겨 짝짓기.
START_MARGIN_S=2
dur_ms=$(printf '%s' "$input" | jq -r 'if (.duration_ms | type) == "number" and .duration_ms >= 0 and .duration_ms < 86400000
  then (.duration_ms | floor | tostring) else empty end' 2>/dev/null)
start=""
case "${dur_ms:-x}" in
  *[!0-9]*) ;;
  *) start=$(( $(date +%s) - (dur_ms + 999) / 1000 - START_MARGIN_S )) ;;
esac

mark="$proj/.claude/.last-mvn-test"

# _write <status> <총계> — 원자적 교체(임시파일+mv). 실패하면 기존 기록을 지운다(기록 없음 = 짝 훅 deny) —
# 새 결과를 못 쓴 채 낡은 SUCCESS 가 남는 것이 이 게이트의 최악 결함이다. 지우기도 실패하면 exit 2 로 크게 알린다.
# 시작 시각을 모르면 훅 시각을 쓴다 — SUCCESS 가 아니거나 총계 0 인 기록은 시각과 무관하게 짝 훅이 막는다.
_write() {
  mkdir -p "$(dirname "$mark")" 2>/dev/null || true
  tmp="$mark.tmp.$$"
  # 형식: "<시작 epoch> <SUCCESS|FAILURE|UNKNOWN> <모듈 인자> <Tests run 총계> <full|partial>" — 필드 5개(짝 훅이 5개로 읽는다).
  if printf '%s %s %s %s %s\n' "${start:-$(date +%s)}" "$1" "$mods" "$2" "$scope" > "$tmp" 2>/dev/null && mv -f "$tmp" "$mark" 2>/dev/null; then
    exit 0
  fi
  rm -f "$tmp" "$mark" 2>/dev/null
  if [ -e "$mark" ]; then
    echo "[mvn test 기록] 결과($1)를 기록하지 못했고 이전 기록($mark)도 지우지 못했습니다 — 낡은 기록으로 커밋 게이트가 오판할 수 있습니다. 그 파일을 직접 지우세요." >&2
    exit 2
  fi
  exit 0
}

# PostToolUseFailure(Bash 종료코드≠0) — PostToolUse 는 성공한 도구에만 불린다(공식 hooks 문서: 실패는
# PostToolUseFailure, 입력 = .error 문자열이고 tool_response 가 없다). 실패한 mvn test 는 PostToolUse 로 들어오지 않는다.
# 종료코드≠0 은 출력 문구와 무관하게 FAILURE 다(.error 는 중간 절단·형식 비보장이라 판정 재료로 쓰지 않는다 → 총계 0).
# ponytail: 명령 문자열에 mvn·test 토큰이나 harness.sh test 경로 문자열이 든 비-mvn 실패 명령(예: grep "mvn test" 0건)도 FAILURE 로 덮어 커밋을 막는다
#   (차단 쪽 오탐 — mvn test 재실행으로 풀린다) / 업그레이드 경로 = 실제 실행 프로그램이 mvn 인지 셸 파서로 판정.
if [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = "PostToolUseFailure" ]; then
  _write FAILURE 0
fi

# 판정 불가(tool_response 가 객체가 아님 · 출력이 비었음 · BUILD SUCCESS/FAILURE 줄이 없음 — `| tail -5`·`| grep 'Tests run'` 처럼
# 출력을 잘라 종료코드 0 으로 끝난 실행)는 UNKNOWN 으로 기록해 이전 SUCCESS 를 무효로 만든다 — 잘린 출력 뒤에 실패가 숨어 있을 수 있다.
# mvn 실행을 찾지 못한 명령(문구 속 mvn 낱말뿐)은 무효화하지 않는다 — 판정 재료가 없을 뿐 실행이 없었다.
[ "$(printf '%s' "$input" | jq -r '.tool_response | type' 2>/dev/null)" = "object" ] || { [ "$invoked" -eq 1 ] && _write UNKNOWN 0; exit 0; }
out=$(printf '%s' "$input" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")' 2>/dev/null)
printf '%s' "$out" | grep -q '[^[:space:]]' || { [ "$invoked" -eq 1 ] && _write UNKNOWN 0; exit 0; }

# BUILD 결과 — 한 호출에 mvn 실행이 여럿일 수 있으므로 **하나라도** BUILD FAILURE 면 FAILURE(마지막 줄만 보지 않는다).
if printf '%s\n' "$out" | grep -Eq 'BUILD FAILURE'; then
  status="FAILURE"
elif printf '%s\n' "$out" | grep -Eq 'BUILD SUCCESS'; then
  status="SUCCESS"
else
  status="UNKNOWN"
fi

# Surefire 요약 줄 — 줄머리가 Maven 로그 접두([INFO]·[ERROR]·[WARNING])인 `Tests run:` 줄만 본다. 같은 명령에 섞인
# 다른 러너의 요약 줄(jsharness 의 접두 없는 `Tests run: N, Failures: F, Specs: S` 등)은 총계·실패 판정에 넣지 않는다.
# ANSI 색 코드(-Dstyle.color=always)는 먼저 걷는다.
_esc=$(printf '\033')
sf_lines=$(printf '%s\n' "$out" | sed -E "s/${_esc}\\[[0-9;]*m//g" \
  | grep -E '^\[(INFO|ERROR|WARNING)\][[:space:]]+Tests run:[[:space:]]*[0-9]+,')

# Tests run 총계 — 모듈 요약 줄만 합산(클래스별 줄 `… - in <FQCN>` 은 제외해 이중계산 방지).
tests=$(printf '%s\n' "$sf_lines" \
  | grep -v -- '- in ' \
  | sed -E 's/.*Tests run:[[:space:]]*([0-9]+),.*/\1/' \
  | awk '{ s += $1 } END { printf "%d", s + 0 }')
case "${tests:-}" in ''|*[!0-9]*) tests=0 ;; esac

[ "$status" = UNKNOWN ] && { [ "$invoked" -eq 1 ] && _write UNKNOWN "$tests"; exit 0; }

# BUILD SUCCESS 인데 Tests run 줄에 Failures·Errors 가 1 이상이면 FAILURE — -fn/--fail-never·-Dmaven.test.failure.ignore 류는
# 테스트가 실패해도 BUILD SUCCESS 를 찍는다(그 옵션들은 범위 판정에서도 partial 이다).
if [ "$status" = SUCCESS ] && printf '%s\n' "$sf_lines" | grep -Eq '(Failures|Errors):[[:space:]]*0*[1-9]'; then
  status="FAILURE"
fi

# 미실행은 초록이 아니다 — mvn 실행이 SUCCESS 인데 한 건도 안 돌았으면 총계 0 으로 기록해 이전 SUCCESS 를 무효로 만든다(짝 훅이 ③으로 막는다).
if [ "$status" = "SUCCESS" ] && [ "$tests" -eq 0 ]; then
  [ "$invoked" -eq 1 ] && _write SUCCESS 0
  exit 0
fi

# 부분 실행의 초록·시작 시각을 모르는 초록은 커밋 근거로 남기지 않는다(이전 기록 유지 — 그 기록의 시작 시각 이후 변경은
# 짝 훅이 어차피 막는다). 에이전트에게는 PostToolUse additionalContext 로 왜 기록되지 않았는지 알린다(차단 아님).
if [ "$status" = "SUCCESS" ] && { [ "$scope" != full ] || [ -z "$start" ]; }; then
  if [ "$scope" != full ]; then
    _why="부분 실행·판정 불가 형태(-Dtest= 류 -D 속성·허용 목록 밖 옵션·-rf·-pl 제외·-am 없는 -pl·하위 모듈 디렉터리나 하위 pom 실행·MAVEN_* 대입·셸 변수 전개 중 하나)이라 커밋 근거로 기록하지 않았습니다"
  else
    _why="도구 실행 시간(duration_ms)이 입력에 없어 테스트 시작 시각을 알 수 없으므로 기록하지 않았습니다"
  fi
  jq -n --arg r "[mvn test 기록] BUILD SUCCESS 였지만 ${_why}. 커밋 게이트를 풀려면 레포 루트에서 mvn test -pl <모듈> -am -Dmaven.repo.local=<핀>(또는 bash ~/.claude/skills/harness/harness.sh test <모듈>) 을 그대로 다시 돌리세요." \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$r}}' 2>/dev/null
  exit 0
fi

_write "$status" "$tests"
