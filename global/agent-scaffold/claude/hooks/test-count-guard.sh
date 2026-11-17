#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=차단
# 커밋 내용 게이트(층 A) — 전역 CLAUDE.md "쓰기 전에 신규인지 확인하라"(Write 덮어쓰기) 조항의 강제화.
#   역할 = 층 A pre-commit 디스패처가 합성 PreToolUse 꼴 stdin 으로 부르는 게이트(호출부 조회 = `grep -n 'GATES=' .claude/hooks/git/pre-commit`).
# git commit 시점에 스테이징된 테스트 파일의 **테스트 메서드 수가 HEAD 대비 줄었는지** 검사해 차단한다.
#
# 왜 필요한가(2026-08-20 실측): 새 파일인 줄 알고 기존 테스트 파일에 Write 해 @Test 18건을 7건으로
# 날렸는데 **빌드도 테스트도 전부 초록이었다**(줄어든 테스트는 실패하지 않는다). 컴파일·단위테스트·
# 컨벤션 lint 어느 것도 커버리지 소실을 못 잡는다 — 사람이 git show HEAD: 로 대조해야만 보인다.
# 그 대조를 기계화한 것이 이 훅이다.
#
# 판정 대상: src/test/ 하위 .java 중 **수정(M)·이름 변경(R)** 된 것(R 은 옛 경로·새 경로 중 하나가 src/test/ 면 대상).
#   - R 은 HEAD 의 옛 경로 판과 인덱스의 새 경로 판을 비교한다(이름을 바꾸며 내용을 덮어쓴 사고도 잡는다).
#   - 신규(A)는 HEAD 판이 없어 비교 불가 → 대상 아님.
# ponytail: -M 짝짓기는 클래스 쪼개기(T → T1·T2)를 T→T1 rename 의 감소로 오판할 수 있다 — 같은 커밋의 A 상태
#   src/test 파일 @Test 합산은 하지 않고 안내문으로 사람이 합계를 확인하게 한다 / 업그레이드 = 감소분 ≤ 같은 커밋 A 파일
#   @Test 합이면 통과(쪼개기와 Write 사고를 함께 덮는 경우의 판정 규칙을 먼저 정한다).
#   - 삭제(D)는 git rm 을 명시적으로 쳐야 하는 의도적 행위라 이 실패모드(Write 사고)가 아니다 → 대상 아님.
# 세는 것: @Test / @ParameterizedTest / @RepeatedTest / @TestFactory (애노테이션 줄).
#   ParameterizedTest 등을 함께 세는 이유 = @Test 를 그것으로 전환한 정상 리팩터가 오탐이 되지 않도록.
#
# 의도적 감축이면: 명령 앞에 ALLOW_TEST_COUNT_DROP=1 을 붙여 다시 커밋한다(사용자에게 먼저 알릴 것).
# 무출력 exit 0(통과): 대상 없음·감축 없음·commit 아님·git 부재, 그리고 층 A 경로의 jq 부재 — 그 도구 부재를 막는 몫은 디스패처다.
#   PreToolUse 경로(settings 등록 레포)는 jq·판정기 부재와 허용 형태(단독 커밋 — lib git_commit_call_form) 밖 커밋 호출을 deny 한다.
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
    && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[테스트 수 감소 가드] jq 가 없어 커밋 호출 형태를 판정할 수 없어 막습니다(jq 설치 후 재시도)."}}\n'
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
      jq -n --arg r "[테스트 수 감소 가드] 허용 형태가 아닌 커밋 호출이라 막습니다. ${_guide} 사유: ${_why:-판정 불가}" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0 ;;
  esac
fi

# 명시적 우회 — 셸 변수 대입 형태로만 인정한다(커밋 메시지에 우연히 섞인 문자열로 뚫리지 않게).
if printf '%s' "$cmd" | grep -Eq '(^|[;&|][[:space:]]*)ALLOW_TEST_COUNT_DROP=1[[:space:]]'; then
  exit 0
fi

# 테스트 메서드 애노테이션 수. 인자 = git 오브젝트 경로(HEAD:x 또는 :x).
# cat-file blob = 원본 바이트(show 와 달리 textconv 설정의 영향이 없다).
_count_tests() {
  git -C "$cwd" cat-file blob "$1" 2>/dev/null \
    | grep -cE '^[[:space:]]*@(Test|ParameterizedTest|RepeatedTest|TestFactory)([[:space:]]|\(|$)' \
    || true
}

# 대상 쌍 "옛경로<TAB>새경로"(M 은 둘이 같다). -z name-status = 상태\0경로\0 (R 은 상태\0옛\0새\0).
# core.quotepath=false + -z : 비ASCII 경로가 8진 이스케이프로 나와 앵커가 막히는 함정 방어.
# diff 표시 설정(color·외부 diff·textconv)은 끈다 — 목록이 사용자 설정에 흔들리지 않게.
_TEST_RE='(^|/)src/test/.*\.java$'
pairs=""
while IFS= read -r -d '' st; do
  case "$st" in
    M*) IFS= read -r -d '' p || break; o="$p"; n="$p" ;;
    R*) IFS= read -r -d '' o || break; IFS= read -r -d '' n || break ;;
    *)  IFS= read -r -d '' _skip || break; continue ;;
  esac
  printf '%s\n%s\n' "$o" "$n" | grep -qE "$_TEST_RE" || continue
  pairs="${pairs}${o}	${n}
"
done < <(git -C "$cwd" -c core.quotepath=false diff --cached --no-color --no-ext-diff --no-textconv \
           -M --name-status -z --diff-filter=MR 2>/dev/null)
[ -n "$pairs" ] || exit 0

drops=""
while IFS='	' read -r o f; do
  [ -n "$f" ] || continue
  before=$(_count_tests "HEAD:$o")
  after=$(_count_tests ":$f")
  # 숫자로 해석되지 않으면(오브젝트 부재 등) 건너뛴다 = fail-open
  case "$before$after" in *[!0-9]*) continue ;; esac
  [ "$before" -gt 0 ] 2>/dev/null || continue
  if [ "$after" -lt "$before" ]; then
    if [ "$o" = "$f" ]; then _lbl="$f"; else _lbl="$o → $f"; fi
    drops="${drops}  ${_lbl}: ${before} → ${after}건 (-$((before - after)))
"
  fi
done <<EOF
$pairs
EOF

[ -n "$drops" ] || exit 0

reason="[테스트 수 감소 가드] 스테이징된 테스트 파일에서 테스트 메서드가 줄었습니다:

${drops}
빌드·단위테스트는 이 소실을 잡지 못합니다(줄어든 테스트는 실패하지 않습니다). 커밋 전에 확인하세요:

  git show HEAD:<파일> | grep -E '^[[:space:]]*@(Test|ParameterizedTest|RepeatedTest|TestFactory)' -A1

의도치 않은 덮어쓰기라면(새 파일인 줄 알고 Write 한 경우가 대표적) 원본을 되살리세요 — 살릴 편집이
섞여 있으면 먼저 사본을 뜬 뒤 'git checkout HEAD -- <파일>'. 성격이 다른 검증을 추가하는 중이었다면
같은 파일을 재작성하지 말고 별도 테스트 클래스로 분리하세요.
테스트 클래스를 둘 이상으로 쪼갠 경우라면 이름 변경 짝짓기(-M) 오판일 수 있습니다 — 쪼갠 파일들의 테스트 수 합계가
원본 이상인지 확인한 뒤 아래 우회로 진행하세요.

정말 의도한 감축이면 그 사실을 사용자에게 먼저 알린 뒤 'ALLOW_TEST_COUNT_DROP=1 git commit ...' 으로 진행하세요."

# 층 A(git pre-commit, GATE_LAYER=git)는 우회를 실제 환경변수로만 받는다 → 그 형태 제약을 안내한다.
# 히어독 절은 PreToolUse(명령 문자열 판정)에서만 맞는 안내다 — 층 A 는 실제 커밋에서만 돌아 히어독 오판이 없다.
if [ "$_layer_a" -eq 1 ]; then
reason="${reason}
우회 변수는 git 훅에 닿는 형태만 인정합니다 — 같은 명령의 대입 접두(ALLOW_TEST_COUNT_DROP=1 git commit …) 또는 export. 'ALLOW_TEST_COUNT_DROP=1 && git commit' 은 export 되지 않은 셸 변수라 통하지 않습니다."
else
reason="${reason}

※ 커밋하려던 게 아니라 히어독 본문(<<EOF … EOF)의 문구 때문에 막힌 것이라면: 히어독 본문은 **데이터 싱크(cat·tee 등)가 문서·데이터 확장자 파일(.md·.txt·.json 등)로 쓸 때만** 판정에서 빠집니다 — 스크립트 파일로 쓰거나 파이프·인터프리터·ssh 로 넘기는 본문은 실행될 수 있어 그대로 판정합니다. 문서 확장자로 쓰거나 Write 도구로 파일을 쓰세요."
fi
jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
