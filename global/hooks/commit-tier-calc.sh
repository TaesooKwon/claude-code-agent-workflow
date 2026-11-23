#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PreToolUse(Bash) 넛지 — 커밋 직전 staged diff 로 리뷰 티어(A/B)와 소형 A 후보를 계산해 보여준다.
# 근거 처분: global:비동기검증:10(검증 무게는 diff 성격에 비례) + project:검증:17(티어 판정축) — 훅승격 통합 1개.
#
# 왜 필요한가: 티어 판정이 산문으로만 있으면 "표현만 바뀐 것 같다"는 눈대중으로 A 를 B 로 조용히 강등하게 된다
#   (= 실행 의미가 바뀌는 변경을 워크플로 리뷰 없이 커밋). 판정축 자체는 이미 기계적으로 적혀 있으므로
#   사람이 매번 세는 대신 커밋 직전에 훅이 계산해 보여준다.
#
# 형: **warn(additionalContext)** — 차단하지 않는다. 차단은 리뷰 마커 게이트 몫이고, 이 훅은 계산·표시 전용이다.
#
# A 축(하나라도 걸리면 A):
#   ⓐ 서버 소스·스키마 SQL 파일
#   ⓑ 매퍼/쿼리 XML
#   ⓒ 템플릿 diff 의 <script> 블록 **안쪽** 추가 라인(추가 라인 번호 ∩ 사후 이미지의 script 범위)
#   ⓓ 템플릿 diff 의 바인딩 속성 추가 라인(th:if·th:each·onclick 등)
#   ⓔ 프로젝트 확장 축 — `<repo>/.claude/tier.conf` 의 extra_a_globs
#   축이 하나도 안 걸리면 B 후보.
#
# 부가 경고(티어와 무관, A/B 어느 보고문에도 덧붙인다 — 역시 warn 만):
#   ① 디버그 태그 잔존 — staged diff 의 **추가 라인**에 `[DEBUG-<hex 4자 이상>]` 가 있고 파일이 java/js/jsp/html/xml/properties
#      (diagnose-bug 스킬의 계측 태그. .md 는 스킬·문서가 태그 예시를 담으므로 제외, 삭제 라인은 정리이므로 제외)
#   ② one-way 후보 — staged 에 .sql 파일 추가/변경(삭제 제외): DDL·데이터 이관은 커밋 되돌림으로 원복되지 않는다.
#   둘 다 아래 pathspec·-a 판정 불가 분기에선 계산하지 않는다(그 분기는 인덱스를 보지 않는다 — 아래 「한계」의 pathspec·-a 항목과 같은 미탐).
#
# 프로젝트 확장 파일(선택) `<git toplevel>/.claude/tier.conf` — `키=값` 한 줄씩, 그 외 줄은 무시:
#   extra_a_globs=*/js/develop/*.js */mapper/*.xml      # 공백 구분 셸 글롭(case 매칭: * 는 / 도 먹는다)
#   auth_paths=comn/filter/ comn/interceptor/ SecurityConfig
# ※ 트러스트 경계: 이 파일은 **source 하지 않고** 키=값만 파싱한다(프로젝트 파일이 전역 훅에서 코드 실행을 얻으면 안 된다).
#
# 우회: 명령 앞에 `SKIP_TIER_CALC=1` 을 붙이거나 환경변수 SKIP_TIER_CALC=1 을 내보낸다.
#
# 한계(의도한 지름길):
#   - 커밋 명령 판정은 자체 정규식이다(전역 훅이라 레포의 lib/git-cmd.sh 에 의존할 수 없다). 셸 문법을 정규식으로
#     완전히 파싱할 수는 없으므로 변수 조립(`g=git; $g commit`) 류는 미탐이다 — 넛지형이라 미탐이 오탐보다 낫다.
#   - 소형 A 는 처분표가 기계화 대상으로 지정한 축(파일 수 상한 · 인증/인가·스키마 경로 무변경)만 판정한다.
#     상태전이·비동기 배선 무변경, 로직 단위테스트 커버 여부는 이 훅이 판정하지 않고 사람 몫으로 남긴다.
#   - pathspec·-a·-o·-i 커밋은 축을 세지 않고 "판정 불가 — A 로 간주"만 낸다(커밋 내용 ≠ 현재 인덱스).
#   - 경로명 기반 인증/인가 추정이라 이름에 auth/login/role 등이 없는 인가 코드는 놓친다 → tier.conf auth_paths 로 보강.
# ponytail: <script> 범위 판정은 사후 이미지를 줄 단위로 훑는 근사다(HTML 파서 아님 — 주석·문자열 안의 "<script" 를
#           구분하지 못한다) / 업그레이드 경로 = 오탐이 실제로 관측되면 파서 기반 판정으로 교체.
# 안전: jq/git/awk 부재·JSON 파싱 실패·commit 아님·staged 없음 → 조용히 exit 0(fail-open). 절대 deny/ask 하지 않는다.
set -u

input=$(cat 2>/dev/null || true)
command -v jq  >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
# 줄 이음(\+개행)을 펴고 본다 — 아래 판정은 줄 단위라 `git commit \⏎ -a` 의 -a 를 못 본다.
# 줄 잇기(\+LF) → 공백 1칸, 그 밖 바이트 불변 — 구현 원본 = 킷 스캐폴드 lib/git-cmd.sh 의 git_unfold_lines(동기화 = 그 함수와 diff).
#   종전 ${v//$'\\\n'/ } 는 bash 3.2 에서 비선형(timeout fail-open) → 줄 잇기가 있을 때만 sed 한 번(선형), sed 실패면 종전 치환.
case $cmd in *$'\\\n'*)
  if _unf=$(printf '%sx' "$cmd" | LC_ALL=C sed -n 'H;${x;s/\\\n/ /g;s/^\n//;p;}') && [ "${_unf%x}" != "$_unf" ]; then cmd=${_unf%x}; else cmd=${cmd//$'\\\n'/ }; fi ;;
esac
[ -n "$cwd" ] && [ -d "$cwd" ] || cwd="$PWD"

# ── 우회 ───────────────────────────────────────────────────────────────────────
[ "${SKIP_TIER_CALC:-}" = "1" ] && exit 0
# 셸 변수 대입 형태로만 인정한다(커밋 메시지에 우연히 섞인 문자열로 뚫리지 않게).
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)SKIP_TIER_CALC=1[[:space:]]'; then
  exit 0
fi

# ── 커밋 명령 판정(자체 정규식) ────────────────────────────────────────────────
# 넛지형이므로 따옴표 안 문자열은 지운 사본으로 본다(안내문에 인용된 커밋 문구로 발화하지 않게).
# 다만 셸 래퍼(sh -c "…")는 따옴표 안이 곧 실행될 명령이라 원문을 그대로 쓴다.
_strip_quoted() {
  if printf '%s' "$1" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?(sh|bash|zsh|env)[[:space:]]+(-[A-Za-z]*c|-c)"; then
    printf '%s' "$1"
    return 0
  fi
  # 한 패스 교대식 — 왼쪽에서 먼저 연 따옴표가 짝을 가진다(2패스는 "don't" 의 ' 를 뒤 'x' 와 짝지어 그 사이를 지웠다).
  printf '%s' "$1" | sed -E "s/'[^']*'|\"[^\"]*\"/\"\"/g"
}
_is_gitsub() { # $1=명령 $2=서브커맨드 정규식
  printf '%s' "$1" | grep -Eq "(^|[|;&({\`\"'[:space:]])([^[:space:]]*/)?git([[:space:]]+(-[cC][[:space:]]*[^[:space:]]+|--(git-dir|work-tree|namespace|super-prefix|exec-path)([[:space:]]+|=)[^[:space:]]+|--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]+)?|-[A-Za-z]))*[[:space:]]+($2)([^[:alnum:]_]|\$)"
}
_is_commit() { _is_gitsub "$1" commit; }
_is_commit "$(_strip_quoted "$cmd")" || exit 0

# ── 인덱스 밖 커밋 형태 = 판정 불가(A 로 간주) ─────────────────────────────────
# pathspec(`git commit -m m a.txt`)·-a/--all·-o/--only·-i/--include·--pathspec-from-file 은 커밋될 내용이 지금의
# 인덱스(아래 diff --cached)와 다르다 → 축 계산이 엉뚱한 파일을 보거나 0개를 본다. 계산하지 않고 A 로 간주한다고 알린다.
# 값을 받는 옵션(-m·-F·-C·-c·-t·--author 등)의 값 낱말은 pathspec 으로 세지 않는다. 메시지는 _strip_quoted 가 "" 로 지운 뒤다.
# 리다이렉트·히어독 낱말(`2>`·`>`·`<<''`·`>out.log` — `2>&1` 은 & 에서 갈린 뒤다)도 pathspec 이 아니다(떨어진 대상 낱말은 값으로 건너뛴다).
# 같은 명령에서 commit 앞에 git add·stage·rm·mv 세그먼트가 있으면 그것도 판정 불가다 — 훅 시점 인덱스엔 아직 반영 전이다.
# ponytail: 짧은 옵션 묶음에 a·o·i 글자가 있으면 A 로 본다(-uno 같은 드문 값 붙임은 과탐) / 넛지형이라 과탐 쪽이 안전.
# ponytail: 커밋 메시지 본문 줄의 git add·commit -a 문구도 판정 불가(A 간주)로 셀 수 있다(비차단·안전 방향)
#   / 업그레이드 = 따옴표 상태를 추적하는 다중행 스트립.
_nonindex_form() {
  local seg rest w expect_val=0 after_dd=0
  while IFS= read -r seg; do
    _is_gitsub "$seg" 'add|stage|rm|mv' && return 0
    _is_commit "$seg" || continue
    rest=$(printf '%s' "$seg" | sed -E 's/.*[[:space:]]commit([[:space:]]|$)//')
    set -f
    for w in $rest; do
      if [ "$after_dd" -eq 1 ]; then set +f; return 0; fi
      if [ "$expect_val" -eq 1 ]; then expect_val=0; continue; fi
      case "$w" in
        --) after_dd=1 ;;
        --all|--only|--include|--pathspec-from-file|--pathspec-from-file=*) set +f; return 0 ;;
        --message|--file|--author|--date|--template|--reuse-message|--reedit-message|--fixup|--squash|--trailer|--cleanup) expect_val=1 ;;
        --*) ;;
        '<'|'<<'|'<<-'|'>'|'>>') expect_val=1 ;;   # 떨어진 대상 낱말이 뒤따른다(`2>` 는 대개 `2>&1` 이 & 에서 갈린 것이라 아래 갈래)
        '<'*|'>'*|[0-9]'>'*|[0-9]'<'*) ;;                                      # 붙은 대상(`>out.log`·`<<''`·`2>`)
        -*)
          case "${w#-}" in *[aoi]*) set +f; return 0 ;; esac
          case "$w" in *[mFCct]) expect_val=1 ;; esac ;;
        *) set +f; return 0 ;;   # 옵션도 옵션 값도 아닌 낱말 = pathspec
      esac
    done
    set +f
  done < <(printf '%s\n' "$1" | tr ';&|' '\n\n\n')
  return 1
}
if _nonindex_form "$(_strip_quoted "$cmd")"; then
  jq -n --arg r "[커밋 티어 계산] 판정 불가 — **A 로 간주**. 이 커밋은 pathspec·-a·-o·-i 형태(또는 같은 명령 안에서 먼저 git add·rm·mv 를 친다)라 커밋될 내용이 지금의 인덱스와 다르다(이 훅은 인덱스로 축을 센다).
정확한 티어가 필요하면 커밋할 파일을 \`git add <경로>\` 로 먼저 스테이징한 뒤 경로 없는 \`git commit\` 으로 다시 치면 계산된다. (차단하지 않는다.)" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
  exit 0
fi

# ── 기준 디렉터리 = 레포 루트 ──────────────────────────────────────────────────
# `diff --cached --name-only` 이 내는 경로는 **레포 루트 기준**이다. 하위 디렉터리에서 커밋을 치면
# cwd 를 기준으로 그 경로를 다시 pathspec 으로 넘기는 순간 아무 파일도 매칭되지 않아 템플릿 축(ⓒⓓ)이
# 통째로 사라지고 A 가 B 로 뒤집힌다(2026-09-18 실측: cwd=<repo>/sub/dir 에서 ⓓ 소멸).
toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
repo="${toplevel:-$cwd}"

# ── staged 파일 ────────────────────────────────────────────────────────────────
# core.quotepath=false + -z : 비ASCII 경로가 8진 이스케이프로 나와 앵커가 막히는 함정 방어.
staged=$(git -C "$repo" -c core.quotepath=false diff --cached --name-only -z 2>/dev/null | tr '\0' '\n' | grep -v '^$')
[ -n "$staged" ] || exit 0
nfiles=$(printf '%s\n' "$staged" | grep -c . || true)

# ── 프로젝트 확장(tier.conf) ───────────────────────────────────────────────────
extra_a_globs=""
auth_paths=""
conf=""
if [ -n "$toplevel" ] && [ -f "$toplevel/.claude/tier.conf" ]; then
  conf="$toplevel/.claude/tier.conf"
  _conf_get() {
    # source 하지 않는다 — `키=값` 첫 줄만 뽑아 앞뒤 따옴표/공백을 벗긴다.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" 2>/dev/null \
      | head -1 | sed -e 's/[[:space:]]*$//' -e "s/^['\"]//" -e "s/['\"]$//"
  }
  extra_a_globs=$(_conf_get extra_a_globs)
  auth_paths=$(_conf_get auth_paths)
fi

# ── 축 계산 ────────────────────────────────────────────────────────────────────
axis_a=""; axis_b=""; axis_c=""; axis_d=""; axis_e=""
auth_hit=""; schema_hit=""

# 템플릿 추가 라인 중 <script> 블록 안쪽이 있으면 파일명을, 없으면 빈 문자열을 낸다.
_script_inside_added() {
  local f="$1" nums nums1 post
  nums=$(git -C "$repo" diff --cached -U0 -- "$f" 2>/dev/null | awk '
    /^@@/ {
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
        spec = substr($0, RSTART + 1, RLENGTH - 1)
        n = split(spec, p, ",")
        cur = p[1] + 0
        rem = (n > 1 ? p[2] + 0 : 1)
      }
      next
    }
    /^\+\+\+/ { next }
    /^\+/ { if (rem > 0) { print cur; cur++; rem-- } }
  ')
  [ -n "$nums" ] || return 0
  post=$(git -C "$repo" show ":$f" 2>/dev/null || true)
  [ -n "$post" ] || return 0
  # ⚠️ awk -v 대입값에 개행이 들어가면 BSD(macOS) awk 는 "newline in string" 으로 **죽는다** —
  # 추가 라인이 2줄 이상이면 ⓒ 축이 상시 미작동이었다(2026-09-18 실측). 한 줄로 접어 넘긴다.
  nums1=$(printf '%s' "$nums" | tr '\n' ' ')
  printf '%s\n' "$post" | awk -v nums="$nums1" '
    BEGIN { n = split(nums, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i] + 0] = 1 }
    {
      low = tolower($0); isin = ins
      if (index(low, "<script") > 0)  { isin = 1; ins = 1 }
      if (index(low, "</script") > 0) { isin = 1; ins = 0 }
      if (isin && (NR in want)) { print "hit"; exit }
    }'
}

# 템플릿 추가 라인에 바인딩 속성이 새로 생겼는가.
_binding_added() {
  # '+' 는 문자클래스로 적는다 — BSD grep 은 '\+' 를 피연산자 없는 반복 연산자로 보고 거부한다(macOS 실측).
  git -C "$repo" diff --cached -U0 -- "$1" 2>/dev/null \
    | grep -E '^[+]' | grep -vE '^[+][+][+]' \
    | grep -Eq '(th:if|th:unless|th:each|th:switch|th:case|th:onclick|th:attr|on(click|change|submit|input|keyup|keydown|blur|focus|load)[[:space:]]*=)'
}

_match_extra() {
  local f="$1" g
  [ -n "$extra_a_globs" ] || return 1
  # set -f: 값을 낱말로만 나누고 파일명으로 펼치지 않는다(펼치면 훅 cwd 의 실제 파일명이 패턴을 대신한다). 반환 경로마다 set +f.
  set -f
  for g in $extra_a_globs; do
    # shellcheck disable=SC2254  # 글롭 패턴이므로 의도적 비인용
    case "$f" in $g) set +f; return 0 ;; esac
  done
  set +f
  return 1
}

while IFS= read -r f; do
  [ -n "$f" ] || continue

  if _match_extra "$f"; then
    axis_e="${axis_e}    - ${f}
"
  fi

  case "$f" in
    *_sql.xml|*/mapper/*.xml|*/mappers/*.xml)
      axis_b="${axis_b}    - ${f}
" ;;
    *.java|*.kt|*.groovy|*.scala|*.sql)
      axis_a="${axis_a}    - ${f}
" ;;
    *.html|*.htm|*.jsp|*.vm|*.ftl|*.ftlh|*.thtml)
      if [ -n "$(_script_inside_added "$f")" ]; then
        axis_c="${axis_c}    - ${f}
"
      fi
      if _binding_added "$f"; then
        axis_d="${axis_d}    - ${f}
"
      fi ;;
  esac

  # 소형 A 실격 축 — 인증/인가 경로, 스키마(SQL)
  if printf '%s' "$f" | grep -Eq '([Aa]uth|AUTH|[Ss]ecurity|[Ll]ogin|[Ss]so|SSO|[Pp]ermission|[Rr]ole|[Ss]ession|Filter|Interceptor)'; then
    auth_hit="${auth_hit}    - ${f}
"
  elif [ -n "$auth_paths" ]; then
    set -f   # 낱말 나누기만(파일명 확장 없음 — _match_extra 와 같은 이유)
    for p in $auth_paths; do
      case "$f" in *"$p"*) auth_hit="${auth_hit}    - ${f}
"; break ;; esac
    done
    set +f
  fi
  case "$f" in
    *.sql) schema_hit="${schema_hit}    - ${f}
" ;;
  esac
done <<EOF
$staged
EOF

# ── 보고문 ─────────────────────────────────────────────────────────────────────
evidence=""
[ -n "$axis_a" ] && evidence="${evidence}  ⓐ 서버 소스·스키마 SQL:
${axis_a}"
[ -n "$axis_b" ] && evidence="${evidence}  ⓑ 매퍼/쿼리 XML:
${axis_b}"
[ -n "$axis_c" ] && evidence="${evidence}  ⓒ 템플릿 <script> 블록 안쪽 추가 라인:
${axis_c}"
[ -n "$axis_d" ] && evidence="${evidence}  ⓓ 템플릿 바인딩 속성 추가 라인(th:if·th:each·onclick 등):
${axis_d}"
[ -n "$axis_e" ] && evidence="${evidence}  ⓔ 프로젝트 확장 축(tier.conf extra_a_globs):
${axis_e}"

confline="확장 설정: ${conf:-없음(전역 기본 축만 적용)}"

if [ -n "$evidence" ]; then
  small=""
  if [ "$nfiles" -le 5 ] && [ -z "$auth_hit" ] && [ -z "$schema_hit" ]; then
    small="소형 A 후보: **예**(staged ${nfiles}개 ≤ 5 · 인증/인가·스키마 경로 히트 없음).
  → 남은 조건은 훅이 판정하지 않는다: 상태전이·비동기 배선 무변경 / 로직 단위테스트 커버. 셋 다 충족이면
    단일 에이전트 델타형 리뷰, 하나라도 미충족이면 풀 A(엔진 = 레포 규약의 A티어 리뷰)."
  else
    small="소형 A 후보: **아니오** → 풀 A(레포 규약의 A티어 리뷰). 사유:"
    [ "$nfiles" -gt 5 ] && small="${small}
  - staged ${nfiles}개 > 5"
    [ -n "$auth_hit" ] && small="${small}
  - 인증/인가 추정 경로 포함:
${auth_hit}"
    [ -n "$schema_hit" ] && small="${small}
  - 스키마(SQL) 변경 포함:
${schema_hit}"
  fi

  reason="[커밋 티어 계산] staged ${nfiles}개 → **A티어**(실행 의미가 바뀌는 변경 → 레포 규약의 A티어 리뷰 — 엔진은 그 레포 CLAUDE.md).
걸린 축:
${evidence}
${small}

${confline}
(이 훅은 차단하지 않는다. 축 판정이 틀렸다고 보면 사람이 재판정하되, 애매하면 A 다.)"
else
  reason="[커밋 티어 계산] staged ${nfiles}개 → **B티어 후보**(이 훅이 검사한 축에 걸린 파일 없음).
⚠️ 이것은 \"마크업·문구·스타일만\"이라는 판정이 **아니다** — 훅이 보지 않는 축이 아래에 있고, 그 축에 걸리면 A 다.
B 로 가려면 **B 판정을 사용자에게 말해야 한다**(침묵 강등 금지). 빌드·렌더 검증은 B 에서도 그대로다.
애매하면 A 다 — 특히 아래는 이 훅이 못 보는 축이다:
  - 템플릿 밖(외부 .js 등)에서 바뀐 동작 → 프로젝트 tier.conf 의 extra_a_globs 로 축을 추가하라.
    (예: 이 레포의 js/develop/** 는 화면 로직이라 A 다 — tier.conf 가 없으면 이 훅은 그것을 못 본다.)
  - 설정 파일(.properties·.yml)만 바뀐 커밋 — 기본 축에 없다(실행 의미를 바꾸면 A 다. tier.conf 로 추가 가능).
  - 기존 <script> 블록 안 **수정/삭제**만 있고 추가 라인이 없는 경우.
  - 문구 상수 변경이 서버 분기·회귀 스위트에 물려 있는 경우.

${confline}"
fi

# ── 부가 경고(헤더 「부가 경고」) ───────────────────────────────────────────────
debug_hit=""
# diff 1회(파일마다 부르면 큰 커밋에서 훅 timeout → 티어 안내까지 소실). --no-color: color.diff=always 면 행 머리에 ESC 가 붙어 미탐.
# '+' 는 문자클래스로(BSD). '+++ b/' 머리로 현재 파일을 따라가며 추가 라인만 본다. rename 은 -M 으로 내용 동일분이 추가로 안 보이게.
debug_hit=$(git -C "$repo" -c core.quotepath=false diff --cached -M -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ -- \
    '*.java' '*.js' '*.jsp' '*.html' '*.xml' '*.properties' 2>/dev/null \
  | awk '/^[+][+][+] b\// { f = substr($0, 7); next }
         /^[+]/ && !/^[+][+][+]/ && /\[DEBUG-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/ && !(f in seen) { seen[f] = 1; print "    - " f }' || true)
[ -n "$debug_hit" ] && debug_hit="${debug_hit}
"
# ponytail: .sql 순수 rename 도 one-way 후보로 경고(파일명=버전인 도구 대비) · 디버그 태그 검사는 확장자 대소문자 구분(A.JS 미탐) / 필요 시 R 제외·icase pathspec
sql_am=$(git -C "$repo" -c core.quotepath=false diff --cached --name-only -z --diff-filter=AMR 2>/dev/null \
  | tr '\0' '\n' | grep -iE '\.sql$' || true)
[ -n "$debug_hit" ] && reason="${reason}

⚠️ 디버그 태그 잔존: 추가 라인에 [DEBUG-…] 가 있다 — 계측 로그를 지우고 커밋하라(diagnose-bug 정리 단계).
${debug_hit}"
[ -n "$sql_am" ] && reason="${reason}

⚠️ one-way 후보: DDL·데이터 이관 — 되돌림 경로를 커밋 보고에 적어라(.sql 추가/변경: $(printf '%s' "$sql_am" | tr '\n' ' '))."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
