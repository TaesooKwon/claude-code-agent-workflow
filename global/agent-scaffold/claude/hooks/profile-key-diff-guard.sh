#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# 프로파일 키 정합 가드 — CLAUDE.md ⚙️프로젝트설정 "프로파일 파일은 항목 동일·값만 다름 — 미확정 키도
# `#키=` + TODO 로 자리 유지" 조항의 기계화.
#
# 왜 필요한가: 산문으로만 두면 프로파일 파일 하나에만 키를 추가하는 실수를 아무 층도 검사하지
# 않는다(띄우지 않은 프로파일은 기동 검증에도 안 걸린다) — 키 누락은 그 프로파일로 띄울 때까지 조용하다.
#
# 하나의 스크립트가 두 이벤트에서 동작한다(stdin JSON `hook_event_name` 으로 분기):
#   - PreToolUse  matcher=Bash : git commit 시도이고 스테이징 파일에 대상 프로파일 파일이 있으면
#     모듈({{MODULE_ADMIN}}/{{MODULE_FRONT}})별로 -dev/-prod(PROD_PROFILE_FILE 값 — 아래 대입 줄)/(있으면)-local 키 집합을 비교 → 경고(기본).
#     PROFILE_KEY_DIFF_MODE=deny 면 차단. base(application.properties)는 공통 기본값을 홀로 갖는 파일이라
#     기본 제외(PROFILE_KEY_DIFF_INCLUDE_BASE=1 로 포함) — 규약 "항목 동일·값만 다름" 의 비교 집합 = local/dev/prod.
#   - PostToolUse matcher=Edit|Write : 편집된 파일이 대상 프로파일 파일이면 그 모듈만 비교 → warn
#     (additionalContext, 비차단).
#
# 비교 대상(모듈당 최대 4개, 없는 파일은 건너뛴다 — fail-open):
#   application.properties / application-dev.properties / <PROD_PROFILE_FILE — 아래 대입 줄 값, 잘못된 값이면 .sample 로 폴백> /
#   application-local.properties(미추적이라 없을 수 있음)
# 키 추출: 각 줄 `^#?키=` 에서 키만(값은 보지 않는다) — 주석 처리된 `#키=` 도 "자리 있음"으로 인정.
#   ⚠️ `:` 구분자·대괄호 인덱스 키·값 뒤 줄바꿈 연속(`\`)·멀티라인 값은 이 정규식이 못 본다 — 설치 레포의
#   프로파일 파일이 `=` 구분자만 쓰는지 설치 때 재본다(`grep -nE '^[^#=]*:' <파일>`).
#   # ponytail: 연속행(\) 미지원 / 업그레이드 경로 = 필요해지면 awk 로 논리 줄 병합 후 추출.
#
# 우회: 커밋 명령 앞에 셸 변수 대입 `ALLOW_PROFILE_KEY_DIFF=1` (의도적 비대칭이면 사용자에게 먼저 알릴 것).
#
# ⚠️base 를 포함(PROFILE_KEY_DIFF_INCLUDE_BASE=1)하면 차집합이 크게 나온다 — base 는 공통 Spring 기본값
#   (spring.* 공통 설정 등)을 홀로 갖고 프로파일 파일엔 의도적으로 없을 수 있다. 포함 모드로 올리기 전 재측정:
#     for m in {{MODULE_ADMIN}} {{MODULE_FRONT}}; do for f in $m/src/main/resources/application*.properties*; do
#       printf '%s %s\n' "$f" "$(grep -cE '^#?[A-Za-z_][A-Za-z0-9._-]*=' "$f")"; done; done
#   기본값(MODE=warn · INCLUDE_BASE=0)에서 실제로 걸리는 자리는 커밋 때 훅 출력이 직접 알려 준다.
#
# 안전: jq/git 부재·대상 이벤트 아님·대상 파일 무관·비교 가능 파일 2개 미만 → 조용히 exit 0(fail-open).
set -u
# 모드: warn(기본 — 실물 키 차집합이 남은 레포에서 차단하면 커밋이 회귀한다. 키를 맞춘 뒤
#       settings 등록 명령에 PROFILE_KEY_DIFF_MODE=deny 를 붙여 차단형으로 올린다) / deny
MODE="${PROFILE_KEY_DIFF_MODE:-warn}"
INCLUDE_BASE="${PROFILE_KEY_DIFF_INCLUDE_BASE:-0}"
# prod 프로파일 파일 이름(모듈 resources 아래 basename) — 레포마다 이 줄의 값만 바꾼다(.sample 을 안 쓰는 레포 =
# 'application-prod.properties'). 비교 대상과 PostToolUse 발화 대상을 둘 다 이 값으로 정한다(case 리터럴 비교 — 패턴 해석 없음).
# 비어 있거나 경로(/)·글롭 문자가 섞이면 기본값으로 되돌린다.
PROD_PROFILE_FILE='application-prod.properties.sample'
case "$PROD_PROFILE_FILE" in ''|*/*|*[*?[]*) PROD_PROFILE_FILE='application-prod.properties.sample' ;; esac

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ -n "$event" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# 모듈 경로는 **레포 루트 기준**이다 — cwd 로 조합하면 하위 디렉터리에서 커밋할 때 비교 대상 파일이
# 0~1개로 잡혀 조용히 통과한다(2026-09-18 실측: cwd=<repo>/docs/... 에서 무출력 allow).
# git 이 없거나 저장소 밖이면 CLAUDE_PROJECT_DIR → cwd 순으로 폴백한다(fail-open 유지).
repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$repo" ] || repo="${CLAUDE_PROJECT_DIR:-$cwd}"

MODULES="{{MODULE_ADMIN}} {{MODULE_FRONT}}"

# 키 추출: 파일 1개 → 정렬된 유일 키 목록(stdout)
# ponytail: 대괄호 인덱스 키(a.b[0]=) 미지원 — POSIX 브래킷식은 `\[`/`\]` 를 이스케이프로 안 받아
# 클래스가 조기 종료되는 실측 함정이 있어(2026-09-17 반증에서 발견) 뺐다. 이 레포 8파일 실측 0건
# (2026-09-17). 업그레이드 경로 = 필요해지면 `[^=[:space:]]+`(등호 전까지 전부)로 교체.
_extract_keys() {
  grep -E '^#?[A-Za-z0-9_.-]+=' "$1" 2>/dev/null | sed -E 's/^#//; s/=.*//' | sort -u
}

# 모듈 1개의 프로파일 파일(기본 3개, INCLUDE_BASE=1 이면 base 포함) 키 정합 리포트. 차집합 없으면 빈 문자열.
_diff_report() {
  local mod="$1"
  local base="$repo/$mod/src/main/resources/application.properties"
  local dev="$repo/$mod/src/main/resources/application-dev.properties"
  local prod="$repo/$mod/src/main/resources/$PROD_PROFILE_FILE"
  local lcl="$repo/$mod/src/main/resources/application-local.properties"

  local -a paths=() cand=("$dev" "$prod" "$lcl")
  [ "$INCLUDE_BASE" = "1" ] && cand=("$base" "${cand[@]}")
  local f
  for f in "${cand[@]}"; do
    [ -f "$f" ] && paths+=("$f")
  done
  [ "${#paths[@]}" -ge 2 ] || return 0

  local -a keysets=()
  local union="" i
  for i in "${!paths[@]}"; do
    keysets[$i]=$(_extract_keys "${paths[$i]}")
    union="${union}
${keysets[$i]}"
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' | sort -u)

  local report="" missing cnt
  for i in "${!paths[@]}"; do
    missing=$(comm -23 <(printf '%s\n' "$union") <(printf '%s\n' "${keysets[$i]}"))
    [ -n "$missing" ] || continue
    cnt=$(printf '%s\n' "$missing" | grep -c .)
    report="${report}  [${mod}/$(basename "${paths[$i]}")] 누락 ${cnt}건:
$(printf '%s\n' "$missing" | sed 's/^/    - /')
"
  done
  printf '%s' "$report"
}

if [ "$event" = "PreToolUse" ]; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || exit 0

  _lib="$(dirname "$0")/lib/git-cmd.sh"
  [ -f "$_lib" ] && . "$_lib" || exit 0
  git_has_subcommand "$(git_strip_heredoc "$cmd")" commit || exit 0   # 히어독 판정 = lib 허용 목록 규칙

  # 명시적 우회 — 셸 변수 대입 형태로만 인정(커밋 메시지 문자열로 우연히 뚫리지 않게)
  if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_PROFILE_KEY_DIFF=1[[:space:]]'; then
    exit 0
  fi

  command -v git >/dev/null 2>&1 || exit 0
  staged=$(git -C "$repo" -c core.quotepath=false diff --cached --name-only -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E '(^|/)({{MODULE_ADMIN}}|{{MODULE_FRONT}})/src/main/resources/application(-[A-Za-z]+)?\.properties(\.sample)?$')
  [ -n "$staged" ] || exit 0

  full=""
  for mod in $MODULES; do
    printf '%s\n' "$staged" | grep -Eq "(^|/)${mod}/" || continue
    r=$(_diff_report "$mod")
    [ -n "$r" ] && full="${full}${r}
"
  done
  [ -n "$full" ] || exit 0

  reason="[프로파일 키 정합 가드] 스테이징된 application*.properties 계열 파일에서 모듈 내 프로파일 파일 간 키 차집합이 발견됐습니다(CLAUDE.md ⚙️프로젝트설정 — 프로파일 파일은 항목 동일·값만 다름, 미확정 키도 '#키=' + TODO 로 자리 유지):

${full}
값이 아직 미확정이면 빈 값 대신 '#키=' 주석 + TODO 로 자리만 유지하세요. 의도적으로 한 프로파일에만 있는 키라면(레거시 정리 등) 그 사실을 사용자에게 먼저 알린 뒤 'ALLOW_PROFILE_KEY_DIFF=1 git commit ...' 으로 진행하세요."

  if [ "$MODE" = "deny" ]; then
    jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
  fi
  exit 0
fi

if [ "$event" = "PostToolUse" ]; then
  fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -n "$fp" ] || exit 0
  case "$fp" in /*) ;; *) fp="$cwd/$fp" ;; esac

  mod=""
  case "$fp" in
    */{{MODULE_ADMIN}}/src/main/resources/application*) mod="{{MODULE_ADMIN}}" ;;
    */{{MODULE_FRONT}}/src/main/resources/application*) mod="{{MODULE_FRONT}}" ;;
    *) exit 0 ;;
  esac

  # 허용 목록으로만 발동(금지 목록 아님) — 대상 4개 파일명 정확 일치만
  bn=$(basename "$fp")
  case "$bn" in
    application.properties|application-dev.properties|"$PROD_PROFILE_FILE"|application-local.properties) ;;
    *) exit 0 ;;
  esac

  r=$(_diff_report "$mod")
  [ -n "$r" ] || exit 0

  ctx="[프로파일 키 정합 리마인더] 방금 편집한 ${bn}(모듈 ${mod})이 같은 모듈의 다른 프로파일 파일과 키 집합이 다릅니다(비차단 — 커밋 시점에 다시 검사됩니다):

${r}
미확정 키는 삭제 대신 '#키=' + TODO 로 자리를 유지하세요."

  jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  exit 0
fi

exit 0
