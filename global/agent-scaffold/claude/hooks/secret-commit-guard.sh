#!/usr/bin/env bash
# 커밋 내용 게이트(층 A — 호출부 조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`) — "민감정보 비노출" 규칙의 커밋 시점 강제화. (agent-scaffold 범용판)
# git commit 시 스테이징 diff의 '추가된 줄(+)'에서 시크릿 패턴(토큰·개인키·URL내 계정·비밀번호 대입)을
# 스캔해 발견 시 커밋을 deny 로 차단한다.
#   - 예외 경로: 팀이 tracked 로 관리하며 원래 접속정보를 담는 파일(아래 EXCLUDE_PATH_REGEX).
#     ※ 부트스트랩 시 프로젝트 고유 예외(정본 DB 덤프 디렉터리 등)를 정규식에 추가할 것.
#   - 층 A: git pre-commit 디스패처(.claude/hooks/git/pre-commit)가 합성 입력으로 이 스크립트를 부른다 — 그때
#     `git diff --cached` 는 git 이 넘긴 GIT_INDEX_FILE 로 실제 커밋될 내용(pathspec·-a·-o·-i 포함)을 본다.
#   - 오탐 필터: 플레이스홀더(${}·#{}), env 참조, 마스킹(***), <치환자>, 코드참조 값은 제외.
#   - settings 의 PreToolUse(Bash)에 등록한 레포에서는 명령 문자열이 허용 형태(단독 커밋 — lib git_commit_call_form)일 때만
#     통과시킨 뒤 스테이징을 본다.
# 안전: git 부재·commit 아님·매치 없음 → 조용히 exit 0. PreToolUse 경로의 jq·판정기 부재·허용 형태 밖 커밋 호출 = deny(fail-closed).
set -u

# 프로젝트별 예외 경로(정규식) — 팀 tracked 설정/정본 덤프 등 "원래 접속정보를 담는" 파일만 등록.
EXCLUDE_PATH_REGEX=''   # 기본 = 제외 없음(전 파일 스캔). 팀이 tracked 로 관리하는 접속정보 파일만 설치 시 추가 — 예: '(^|/)application[^/]*\.properties$'

input=$(cat 2>/dev/null || true)
# 층 A(git pre-commit 디스패처)가 부른 호출인가 — GATE_LAYER=git 은 git 이 훅에 넘기는 GIT_INDEX_FILE 이 함께 있을 때만 믿는다
#   (PreToolUse 경로에서 환경변수 하나로 아래 허용 형태 판정을 건너뛰지 못하게).
# ponytail: GATE_LAYER·GIT_INDEX_FILE 은 환경 입력이다 — 둘 다 settings env 로 넣으면 형태 판정을 건너뛴다 /
#   업그레이드 = 층 A 설치(권위 = 실제 커밋 내용을 보는 git 훅)
_layer_a=0; [ "${GATE_LAYER:-}" = git ] && [ -n "${GIT_INDEX_FILE:-}" ] && _layer_a=1
if ! command -v jq >/dev/null 2>&1; then
  [ "$_layer_a" -eq 1 ] && exit 0   # 층 A — 종전 동작 그대로(도구 부재 판정은 층 A 디스패처 몫)
  # PreToolUse — 명령을 꺼낼 수 없다. 이스케이프를 공백으로 편 stdin 에 git·commit 낱말이 함께 보이면 차단(fail-closed).
  _flat=$(printf '%s' "$input" | sed -E 's/\\(u[0-9A-Fa-f]{4}|[\\"\/bfnrt])/ /g')
  printf '%s' "$_flat" | grep -qE '(^|[^[:alnum:]_.-])git([^[:alnum:]_-]|$)' \
    && printf '%s' "$_flat" | grep -qE '(^|[^[:alnum:]_-])commit([^[:alnum:]_-]|$)' \
    && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[시크릿 커밋 가드] jq 가 없어 커밋 호출 형태를 판정할 수 없어 막습니다(jq 설치 후 재시도)."}}\n'
  exit 0
fi
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git commit 계열만 관여. 탐지 정규식은 공용 라이브러리로 일원화(붙임형 -C/path·공백-값형 --git-dir /x 포함).
_lib="$(dirname "$0")/lib/git-cmd.sh"
if [ "$_layer_a" -eq 1 ]; then   # 층 A — 현행 판정 그대로(합성 명령 `[<우회 변수>=1 ; ]git commit` 은 허용 형태 판정이면 막힐 꼴이다)
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_heredoc "$cmd")" commit || exit 0   # 히어독 판정 = lib 허용 목록 규칙
else                             # PreToolUse — 허용 형태만(판정기 = lib/cmdform.py · 부재 시 lib 의 대체 판정)
  if [ -f "$_lib" ] && . "$_lib" && command -v git_commit_call_form >/dev/null 2>&1; then
    _form=$(git_commit_call_form "$cmd" "$cwd")
  else
    # ponytail: lib(또는 새 함수) 부재 창은 commit 낱말만 본다 — 커밋도, 낱말이 든 비커밋 호출도 막힌다 /
    #   업그레이드 = lib 선배치 배포 순서 준수(lib → 게이트)
    _form=NONE
    printf '%s' "$cmd" | tr -d '\042\047\134' | grep -Eq '(^|[^A-Za-z0-9_.-])commit(-tree)?([^A-Za-z0-9_.-]|$)' \
      && _form="DENY	판정기 부재(lib/git-cmd.sh — 복구 후 재시도)"
  fi
  case "$_form" in
    NONE) exit 0 ;;
    ALLOW) ;;
    *)
      _why=${_form#DENY}; _why=${_why#$'\t'}
      _guide=$(git_commit_form_guide 2>/dev/null) || _guide=""
      jq -n --arg r "[시크릿 커밋 가드] 허용 형태가 아닌 커밋 호출이라 막습니다. ${_guide} 사유: ${_why:-판정 불가}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0 ;;
  esac
fi

# 1차 = 고신뢰 토큰 포맷(대소문자 구분) — GitHub/Slack/AWS/OpenAI계열/Figma/JWT/개인키/URL내 계정.
#   배열로 한 번만 정의해 검출·발췌에 동일 패턴을 재사용한다.
P_STRONG=(
  -e 'ghp_[A-Za-z0-9]{30,}'
  -e 'github_pat_[A-Za-z0-9_]{20,}'
  -e 'xox[abprs]-[A-Za-z0-9-]{10,}'
  -e 'AKIA[0-9A-Z]{16}'
  -e 'sk-[A-Za-z0-9_-]{24,}'
  -e 'figd_[A-Za-z0-9_-]{16,}'
  -e 'eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{10,}'
  -e '\-\-\-\-\-BEGIN [A-Z ]*PRIVATE KEY\-\-\-\-\-'
  -e '[a-z][a-z0-9+.-]*://[^/@:[:space:]]+:[^@[:space:]]{3,}@'
)
# 2차 = 자격증명 키에 리터럴 값 대입(대소문자 무시). 구분자 [:=] 양쪽 모두, 따옴표는 선택,
#   키 앞 임의 접두 허용(YAML `password: v` · 주석 `-- password=v` 형태가 통과하던 구멍을 막음).
P_WEAK=(
  -e '(password|passwd|pswd|secret|api[_.-]?key|access[_.-]?key|client[_.-]?secret|auth[_.-]?token)["'\'']?[[:space:]]*[:=][[:space:]]*["'\''][^"'\'']{6,}["'\'']'
  -e '(password|passwd|pswd|secret|apikey|api[._-]key)[[:space:]]*[:=][[:space:]]*["'\'']?[^[:space:]();{}<>"'\'']{6,}'
)
# 플레이스홀더·env 참조 — 1·2차 공통 제외(진짜 값이 아님).
F_PLACEHOLDER='\$\{|#\{|process\.env|getenv|getProperty'
# 더미 표기·객체 참조 — **2차에만** 적용한다(-i 로 대소문자 무시).
#   1차 고신뢰 히트에까지 걸면 `키=eyJ…`(JWT) 같은 '절대 놓치면 안 되는' 값이 필터에서 삭제된다(2026-08-05 감사 실측).
F_SOFT='\*{3,}|MASK|CHANGE_?ME|EXAMPLE|SAMPLE|dummy|<[^>]{1,40}>'
# ponytail: 값이 '소문자.식별자' 꼴이면 코드 참조로 간주해 제외 — `password=my.secret.value` 같은
#   점 포함 실값도 함께 놓친다(1차 고신뢰 패턴이 커버하는 형태가 아니면 미탐).
#   업그레이드 경로 = 확장자별 언어 인식(.java/.js 만 코드 참조 필터 적용)으로 좁히기.
F_OBJREF='=[[:space:]]*[a-z_][A-Za-z0-9_]*\.[A-Za-z_]'

_DIFF_FLAGS=(--no-color --no-ext-diff --no-textconv)   # 표시 설정(color·외부 diff·textconv)이 판정을 흔들지 않게
findings=""
# -z name-status = 상태\0경로\0 (R·C 는 상태\0옛\0새\0) — 예외 판정은 새 경로, diff 는 옛·새 경로를 함께 본다.
while IFS= read -r -d '' st; do
  case "$st" in
    R*|C*) IFS= read -r -d '' old || break; IFS= read -r -d '' f || break ;;
    *)  IFS= read -r -d '' f || break; old="$f" ;;
  esac
  [ -n "$f" ] || continue
  # 빈 값이면 grep -E '' 가 모든 줄에 매치돼 전 파일이 제외된다(가드 무기능) — 비었을 땐 제외하지 않는다.
  [ -n "$EXCLUDE_PATH_REGEX" ] && printf '%s' "$f" | grep -Eq "$EXCLUDE_PATH_REGEX" && continue

  # R/C 는 옛·새 경로를 함께 넘겨 -M 으로 짝짓는다 — 새 경로만 pathspec 이면 짝을 못 찾아 기존 내용 전체가 '+' 로 보인다.
  _paths=("$f"); [ "$old" != "$f" ] && _paths=("$old" "$f")
  added=$(git -C "$cwd" -c core.quotepath=false diff --cached "${_DIFF_FLAGS[@]}" -M -U0 -- "${_paths[@]}" 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+' || true)
  [ -n "$added" ] || continue

  hits1=$(printf '%s\n' "$added" | grep -E "${P_STRONG[@]}" 2>/dev/null \
    | grep -Ev "$F_PLACEHOLDER" || true)
  hits2=$(printf '%s\n' "$added" | grep -iE "${P_WEAK[@]}" 2>/dev/null \
    | grep -Ev "$F_PLACEHOLDER" | grep -ivE "$F_SOFT" | grep -Ev "$F_OBJREF" || true)

  hits=$(printf '%s\n%s' "$hits1" "$hits2" | grep -Ev '^[[:space:]]*$' || true)
  [ -n "$hits" ] || continue

  # 표시는 화이트리스트 방식 — 라인 원문을 절대 내보내지 않고, **매치된 구간만** 발췌해 앞 4자 + **** 로 축약.
  #   기존 블랙리스트식 sed 치환은 대입 기호가 없는 라인(토큰 단독·CSV·헤더)에서 원문이 그대로 새어 나갔다.
  masked=$(printf '%s\n' "$hits" | grep -ioE "${P_STRONG[@]}" "${P_WEAK[@]}" 2>/dev/null \
    | sed -E -e 's#(://[^/@:[:space:]]+:).*#\1****@#' \
             -e 's/([:=][[:space:]]*["'\'']?).*/\1****/' \
             -e 's/^(.{4}).*/\1****/' \
    | sed 's/^/    /' | sort -u | head -10)
  [ -n "$masked" ] || masked="    (패턴 매치 — 값 발췌 불가, 해당 파일 직접 확인)"
  findings="${findings}
  ${f}:
${masked}"
done < <(git -C "$cwd" -c core.quotepath=false diff --cached "${_DIFF_FLAGS[@]}" -M --name-status -z --diff-filter=ACMR 2>/dev/null)

[ -n "$findings" ] || exit 0

reason="[시크릿 커밋 가드] 스테이징된 변경에 시크릿(비밀번호·토큰·키) 패턴이 감지되어 커밋을 차단했습니다(팀 규칙: 민감정보 비노출). 감지 위치(값은 마스킹):
${findings}

조치: 해당 값을 제거/마스킹/환경변수 참조로 바꾸거나, 파일을 언스테이징(git restore --staged <파일>) 후 다시 커밋하세요. 오탐(테스트 더미 등)이라 판단되면 사용자 확인 후 진행하세요."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
