#!/usr/bin/env bash
# 커밋 내용 게이트(층 A — 호출부 조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`) — CLAUDE.md 🧪검증 "harness 는 compile 까지, 커밋 전 mvn test 총계(SUCCESS/FAILURE)를
# 직접 확인"의 강제화 후반부. 근거 처분: project:검증:2 (+ project:검증:5 병합).
# 짝 = mvn-test-record.sh(PostToolUse·PostToolUseFailure 기록기)가 남기는 .claude/.last-mvn-test.
#
# 왜 필요한가: red 커밋이 두 차례 났다. test-count-guard 는 테스트 '개수'만, harness 는 compile 까지만 본다 —
# 테스트 '결과'를 검문하는 층이 없었다. 이 훅이 그 자리다.
#
# 판정: 커밋 명령이고 스테이징에 빌드 입력(아래 BUILD_INPUT_RE — .java · src/main|test/resources 의 xml·properties·yml ·
#   src/test 아래 전부 · pom.xml)이 있는데, 다음 중 하나면 deny.
#   ①.claude/.last-mvn-test 가 없거나 형식이 깨졌다(= 이 세션에서 mvn test 를 돌린 기록이 없다)
#   ②기록된 결과가 SUCCESS 가 아니다(FAILURE · UNKNOWN = 출력에서 BUILD 결과를 찾지 못한 실행)
#   ③기록된 Tests run 총계가 0 이거나 미상이다(미실행 = 미반증 — 전역 CLAUDE.md 반증검사 부칙 ⓓ)
#   ③-1 기록 범위(5번째 필드)가 full 이 아니다(부분 실행 · 범위 필드가 없는 구 형식 = 종료 시각 기록이라 불신)
#   ④기록 시각(= 테스트 **시작** 시각, 기록기가 duration_ms 로 역산)이 스테이징된 빌드 입력 중 가장 최근 것의
#     mtime 이상이 아니다(= 테스트가 시작된 뒤 — 도는 중 포함 — 코드가 바뀌었다. 같은 초도 미검증으로 본다).
#     삭제(D)된 빌드 입력은 작업트리에 남은 가장 가까운 상위 디렉터리의 mtime 을 쓴다(파일 삭제·이동이 그 디렉터리 mtime 을 올린다).
# 스테이징 목록·작업트리 경로는 **레포 루트 기준**으로 조합한다(하위 디렉터리 cwd 에서 조용히 통과하던 결함).
# 커밋 명령 판정은 공용 lib/git-cmd.sh 를 쓴다 — 층 A 경로는 git_has_subcommand(실검사형이라 따옴표 스트립 없이 원문으로 판정),
#   PreToolUse 경로(settings 등록 레포)는 허용 형태 판정(git_commit_call_form — 단독 커밋만 통과).
#
# 우회 환경변수: ALLOW_UNTESTED_COMMIT=1 (셸 변수 대입 형태로 명령 앞에 붙일 때만 인정 — 커밋 메시지에
#   우연히 섞인 문자열로 뚫리지 않게 한다. 사용자에게 먼저 알릴 것).
#
# 한계(수용):
#   - 스테이징된 내용이 아니라 작업트리 파일의 mtime 으로 신선도를 본다. 스테이징 후 같은 파일을 더 고치면
#     내용이 커밋 대상과 무관해도 mtime 이 올라가 차단된다(보수적 오탐 — 우회 있음).
#   - 모듈 일치는 검사하지 않는다. 다른 모듈만 테스트하고 커밋해도 기록만 신선하면 통과한다.
#   - git checkout/stash 로 복원된 파일은 mtime 이 현재 시각이 되어 차단될 수 있다.
# ponytail: 신선도 축이 mtime 이다 / 업그레이드 경로 = staged blob 해시 지문(mark-review.sh 방식)으로 교체.
# ponytail: 테스트는 작업트리로 돌고 커밋은 인덱스를 담는다 — 고친 파일을 다시 git add 하지 않은 부분 스테이징, add 하지 않은 의존 신규 파일은
#   테스트 초록·커밋 빨강인데 통과한다 / 업그레이드 경로 = 인덱스 스냅샷(git stash -k 류 또는 임시 worktree)에서 테스트하고 그 지문을 기록.
#   ⚠️범위 한계: 이 게이트는 `git rev-parse --show-toplevel` 이 CLAUDE_PROJECT_DIR 과 같을 때만 발화한다
#     (의도 — 세션 스코프 훅이 다른 레포 커밋까지 막던 사고를 끊는다). 그래서 **worktree 안에서 직접
#     커밋하면 조용히 통과한다**(worktree 의 toplevel 은 메인 레포 경로와 다르다). 규약의 병행 세션
#     절차는 리뷰만 worktree 에서 하고 커밋은 메인에서 하므로 그 경로에서는 게이트가 살아 있다.
#     worktree 커밋까지 덮으려면 비교축을 `git rev-parse --git-common-dir` 로 바꿔야 한다(미적용).
# 안전: git 부재 · 커밋 아님 · 남의 레포 · 스테이징된 빌드 입력 없음 → 조용히 exit 0(fail-open).
#   PreToolUse 경로의 jq·판정기 부재·허용 형태 밖 커밋 호출 = deny(fail-closed).
# ponytail: 템플릿·정적 자원(src/main/resources/templates·static)은 빌드 입력에서 뺐다 — UI 커밋마다 mvn test 를
#   요구하지 않으려는 선택(그것을 읽는 테스트의 회귀는 이 게이트가 못 본다) / 업그레이드 경로 = 테스트가 읽는 리소스 경로를
#   모아 모집단에 추가.
set -u

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
    && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[mvn test 결과 게이트] jq 가 없어 커밋 호출 형태를 판정할 수 없어 막습니다(jq 설치 후 재시도)."}}\n'
  exit 0
fi
command -v git >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# git commit 계열만 관여(탐지 정규식은 공용 라이브러리로 일원화)
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
      jq -n --arg r "[mvn test 결과 게이트] 허용 형태가 아닌 커밋 호출이라 막습니다. ${_guide} 사유: ${_why:-판정 불가}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0 ;;
  esac
fi

# 명시적 우회 — 셸 변수 대입 형태로만 인정한다.
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_UNTESTED_COMMIT=1[[:space:]]'; then
  exit 0
fi

proj="${CLAUDE_PROJECT_DIR:-$cwd}"
# 이 레포의 커밋만 검문한다 — 다른 레포 커밋을 이 레포 기록으로 판정하면 오탐이다.
[ -d "$proj/{{MODULE_CORE}}/src/main" ] || exit 0
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$top" ] || exit 0
[ "$(cd "$top" 2>/dev/null && pwd -P)" = "$(cd "$proj" 2>/dev/null && pwd -P)" ] || exit 0

# 스테이징된 빌드 입력(추가·수정·삭제 — 삭제만 스테이징한 커밋도 참조하던 코드를 깨뜨릴 수 있다).
# --no-renames: 이동을 삭제+추가로 받아 옛 경로의 삭제도 신선도 축에 넣는다.
# 허용 목록: 테스트 결과를 바꿀 수 있는 파일. 매퍼 XML 은 SQL 렌더 테스트(XMLMapperBuilder)의 입력이다.
BUILD_INPUT_RE='(\.java$)|(^|/)src/(main|test)/resources/.*\.(xml|properties|ya?ml)$|(^|/)src/test/|(^|/)pom\.xml$'
# core.quotepath=false + -z : 비ASCII 경로가 8진 이스케이프로 나와 앵커가 막히는 함정 방어.
# ponytail: diff 의 rc 를 보지 않는다 — git 오류면 목록이 비어 통과(판정 불가가 통과로 수렴, 층 A 디스패처도 이것을
#   통과와 구분하지 못한다) / 업그레이드 = GATE_LAYER=git 일 때 rc≠0 이면 비정상 종료(exit 3)로 디스패처의 판정 불가 차단에 넘긴다.
staged=$(git -C "$cwd" -c core.quotepath=false diff --cached --no-color --no-ext-diff --no-textconv --name-only -z --no-renames --diff-filter=ACMRD 2>/dev/null \
  | tr '\0' '\n' | grep -E "$BUILD_INPUT_RE")
[ -n "$staged" ] || exit 0

_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

newest=0
newest_f=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # `diff --cached --name-only` 의 경로는 **레포 루트 기준**이다(cwd 기준이 아니다).
  # cwd 로 조합하면 하위 디렉터리에서 커밋할 때 전부 [ -f ] 실패 → newest=0 → 무검문 통과가 된다
  # (2026-09-18 실측: cwd=<repo>/docs/... 에서 이 게이트가 조용히 allow).
  p="$top/$f"
  # 작업트리에 없으면(삭제) 남아 있는 가장 가까운 상위 디렉터리로 올라간다 — 레포 루트에서 멈춘다.
  while [ ! -e "$p" ] && [ "$p" != "$top" ]; do p=${p%/*}; [ -n "$p" ] || p="$top"; done
  m=$(_mtime "$p")
  case "${m:-x}" in *[!0-9]*) continue ;; esac
  if [ "$m" -gt "$newest" ]; then newest="$m"; newest_f="$f"; fi
done <<EOF
$staged
EOF

# mtime 을 하나도 읽지 못했으면(stat 실패) newest=0 — 신선도를 알 수 없으니 ④에서 막는다(판정 불가 = 커밋 근거 아님).
# ponytail: 삭제의 시각을 상위 디렉터리 mtime 으로 갈음한다 — 같은 디렉터리의 다른 파일 생성·삭제도 그 mtime 을 올려
#   차단 쪽으로 틀린다 / 업그레이드 경로 = staged blob 해시 지문(위 mtime ponytail 과 같은 경로).

# 기록 형식: "<시작 epoch> <SUCCESS|FAILURE|UNKNOWN> <모듈 인자> <Tests run 총계> <full|partial>"(mvn-test-record.sh 가 쓴다).
# 구 형식(4필드 — 종료 시각 기록)은 범위 미상으로 읽혀 ③-1 에서 막힌다(mvn test 재실행 1회로 풀린다).
mark="$proj/.claude/.last-mvn-test"
rec_epoch=""; rec_status=""; rec_mods=""; rec_tests=""; rec_scope=""; rec_extra=""
if [ -f "$mark" ]; then
  IFS=' ' read -r rec_epoch rec_status rec_mods rec_tests rec_scope rec_extra < "$mark" 2>/dev/null || true
fi
[ -z "$rec_extra" ] || rec_scope=""   # 필드가 남으면 형식 불량 → 범위 미상
case "${rec_epoch:-x}" in *[!0-9]*) rec_epoch="" ;; esac
case "${rec_status:-}" in SUCCESS|FAILURE|UNKNOWN) : ;; *) rec_status="" ;; esac
# 총계 필드가 없거나 숫자가 아니면 **미상**으로 둔다(구 형식 기록) — 미상·0 은 초록으로 치지 않는다.
case "${rec_tests:-x}" in *[!0-9]*) rec_tests="" ;; esac
case "${rec_scope:-}" in full|partial) : ;; *) rec_scope="" ;; esac

_fmt() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'epoch %s' "$1"; }

why=""
if [ -z "$rec_epoch" ] || [ -z "$rec_status" ]; then
  why="이 레포에서 mvn test 를 돌린 기록이 없습니다(.claude/.last-mvn-test 부재 또는 형식 불량)."
elif [ "$rec_status" = "UNKNOWN" ]; then
  why="마지막 mvn test 실행의 출력에서 BUILD SUCCESS/FAILURE 를 찾지 못했습니다($(_fmt "$rec_epoch"), 모듈 인자: ${rec_mods:--}) — 출력을 '| tail'·'| grep' 으로 잘랐거나 백그라운드(run_in_background)로 돌려 결과가 도구 응답에 없으면 판정 불가라 커밋 근거가 아닙니다. 전경에서 출력을 자르지 말고 다시 돌리세요."
elif [ "$rec_status" != "SUCCESS" ]; then
  why="마지막 mvn test 결과가 FAILURE 입니다($(_fmt "$rec_epoch"), 모듈 인자: ${rec_mods:--})."
elif [ -z "$rec_tests" ] || [ "$rec_tests" -eq 0 ]; then
  # 미실행은 통과가 아니라 미반증이다(전역 CLAUDE.md 반증검사 부칙 ⓓ).
  why="마지막 mvn test 는 BUILD SUCCESS 였지만 실행된 테스트가 ${rec_tests:-미상}건입니다($(_fmt "$rec_epoch"), 모듈 인자: ${rec_mods:--}) — 미실행은 초록이 아닙니다."
elif [ "$rec_scope" != full ]; then
  why="마지막 mvn test 기록이 전체 실행 근거가 아닙니다(범위: ${rec_scope:-미상 — 구 형식 기록}, 모듈 인자: ${rec_mods:--}) — -Dtest= 같은 부분 실행·-am 없는 -pl·하위 모듈 디렉터리 실행·허용 목록 밖 옵션은 커밋 근거가 되지 않습니다."
elif [ "$newest" -gt 0 ] && [ "$rec_epoch" -gt "$newest" ]; then
  : # 신선 — 테스트 시작 시각이 가장 최근 변경보다 뒤다
else
  why="마지막 mvn test SUCCESS 의 시작 시각($(_fmt "$rec_epoch"), 모듈 인자: ${rec_mods:--}) 이후(실행 중 포함)에 스테이징된 소스가 바뀌었습니다 — 가장 최근 변경: ${newest_f:-mtime 확인 불가} ($(_fmt "$newest"))."
fi

[ -n "$why" ] || exit 0

reason="[mvn test 결과 게이트] 스테이징에 빌드 입력(.java·매퍼 XML 등)이 있는데 초록을 확인한 기록이 없습니다.

  ${why}

harness 는 compile 까지입니다 — 테스트 결과(SUCCESS/FAILURE)를 검문하는 자리가 이 훅이고, 이 게이트가 없던
동안 red 커밋이 실제로 났습니다. 커밋 전에 총계를 직접 확인하세요:

  mvn test -pl <모듈> -am -Dmaven.repo.local={{MAVEN_REPO}}
  (같은 실행 = bash ~/.claude/skills/harness/harness.sh test <모듈> — 끝에 모듈별 총계 요약)

(-am 을 빼면 stale Core jar 로 오진합니다. bare mvn 은 의존성 없는 스텁 저장소를 타 실패합니다.)
결과가 SUCCESS 이고 **Tests run 총계가 1건 이상**이면 기록이 자동으로 갱신되고(mvn-test-record.sh) 이 차단은
풀립니다. 초록이어도 한 건도 실행되지 않았거나(-DskipTests·대상 없음) 부분 실행(-Dtest=·-am 없는 -pl 등)이면
커밋 근거가 되지 않습니다 — 레포 루트에서, 출력을 자르지 말고 돌리세요. 테스트가 도는 동안 고친 파일은 다음 실행에서 검증됩니다.

테스트를 돌릴 수 없는 사정이거나 그 변경이 테스트와 무관하다고 판단했다면, 그 사실을 사용자에게 먼저
알린 뒤 명령 앞에 ALLOW_UNTESTED_COMMIT=1 을 붙여 진행하세요."

# 층 A(git pre-commit, GATE_LAYER=git)는 우회를 실제 환경변수로만 받는다 → 그 형태 제약을 안내한다.
# 히어독 절은 PreToolUse(명령 문자열 판정)에서만 맞는 안내다 — 층 A 는 실제 커밋에서만 돌아 히어독 오판이 없다.
if [ "$_layer_a" -eq 1 ]; then
reason="${reason}
우회 변수는 git 훅에 닿는 형태만 인정합니다 — 같은 명령의 대입 접두(ALLOW_UNTESTED_COMMIT=1 git commit …) 또는 export. 'ALLOW_UNTESTED_COMMIT=1 && git commit' 은 export 되지 않은 셸 변수라 통하지 않습니다."
else
reason="${reason}

※ 커밋하려던 게 아니라 히어독 본문(<<EOF … EOF)의 문구 때문에 막힌 것이라면: 히어독 본문은 **데이터 싱크(cat·tee 등)가 문서·데이터 확장자 파일(.md·.txt·.json 등)로 쓸 때만** 판정에서 빠집니다 — 스크립트 파일로 쓰거나 파이프·인터프리터·ssh 로 넘기는 본문은 실행될 수 있어 그대로 판정합니다. 문서 확장자로 쓰거나 Write 도구로 파일을 쓰세요."
fi
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
