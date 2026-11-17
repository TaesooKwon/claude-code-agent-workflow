#!/usr/bin/env bash
# PreToolUse(Write) 가드 — 전역 CLAUDE.md 「편집 안전」 "쓰기 전에 신규인지 확인하라(Write 는 통째로
# 갈아엎는다)" 조항의 강제화. 근거 처분 id = global:편집안전:4.
#
# 왜 필요한가: Write 는 대상 파일을 통째로 대체한다. 신규인 줄 알고 기존 파일에 Write 하면 원본이
# 조용히 사라지는데, 빌드·테스트·lint 어느 층도 "없어진 것"을 보지 못한다(테스트 파일이 대표적 —
# 줄어든 테스트는 실패하지 않는다). 도구 결과의 'File created' / 'has been updated' 를 사람이 읽고
# 알아채야 했던 그 대조를 요청 시점으로 앞당겨 기계화한 것이 이 훅이다.
#
# 판정: tool_input.file_path 가
#   ① 실재하고(디렉터리 제외)  그리고
#   ② 비어 있지 않거나(크기>0) git 이 추적 중이면            → deny
# 신규(부재) 파일과 '추적되지 않는 빈' 파일은 통과한다(잃을 내용이 없다).
# 상대경로는 stdin JSON 의 cwd(없으면 $PWD) 기준으로 해석한다.
#
# 우회: 환경변수 ALLOW_WRITE_OVERWRITE=1 (전면 재작성이 의도일 때).
#   ⚠️한계 — Bash 가드(ALLOW_TEST_COUNT_DROP 등)와 달리 Write 는 명령 문자열이 없어 '이번 한 번만'
#   접두 대입으로 켤 수 없다. 이 값은 Claude Code 프로세스의 환경(실행 시 export, 또는 settings.json
#   의 env)에서 상속되므로 한 번 켜면 세션 전체에서 열린다. 부분 편집이면 우회 대신 Edit 를 써라.
#   # ponytail: 요청 단위 우회 없음(세션 전역 스위치뿐) / 업그레이드 경로 = 필요해지면 프로젝트 루트의
#   #           1회용 sentinel 파일(예: .claude/.allow-write-overwrite)을 읽고 소비하는 방식으로 확장.
#
# 안전: jq 부재·JSON 파싱 실패·file_path 없음·Write 아님 → 조용히 exit 0(fail-open).
#       git 부재·비 git 트리에서는 추적 판정만 건너뛴다(크기 판정은 그대로 동작).
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

# matcher 가 Write 로 한정하지만, 오등록(Write|Edit 등)이 Edit 를 통째로 막지 않도록 한 겹 더 확인한다.
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$tool" ] || [ "$tool" = "Write" ] || exit 0

fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$fp" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

case "$fp" in
  /*) abs="$fp" ;;
  *)  abs="$cwd/$fp" ;;
esac

# 명시적 우회 — 전면 재작성이 의도일 때(세션 전역 스위치, 위 한계 주석 참조)
[ "${ALLOW_WRITE_OVERWRITE:-}" = "1" ] && exit 0

[ -e "$abs" ] || exit 0   # 신규 파일 — Write 의 정상 용법
[ -d "$abs" ] && exit 0   # 디렉터리는 Write 도구가 스스로 거부한다

if [ -s "$abs" ]; then
  why="내용이 있는 기존 파일"
elif command -v git >/dev/null 2>&1 \
  && git -C "$(dirname "$abs")" ls-files --error-unmatch -- "$abs" >/dev/null 2>&1; then
  why="git 이 추적 중인 파일(현재 비어 있음)"
else
  exit 0   # 추적되지 않는 빈 파일 — 잃을 내용이 없다
fi

reason="[Write 덮어쓰기 가드] ${why}입니다 — Write 는 이 파일을 통째로 대체합니다.

  ${abs}

부분 변경이면 Edit 를 쓰세요(Write 와 달리 사라지는 내용이 없습니다). 무엇이 있는 파일인지 모르겠으면
먼저 확인하세요:

  git show HEAD:<경로>        # 추적 중이라면 HEAD 판
  wc -l '<경로>' && head '<경로>'

특히 테스트 파일은 덮어써도 빌드·테스트가 전부 초록이라 커버리지 소실이 드러나지 않습니다 — 성격이 다른
검증을 추가하는 중이었다면 같은 파일을 재작성하지 말고 별도 클래스로 분리하세요.

정말 전면 재작성이 의도라면 사용자에게 알린 뒤 Claude Code 실행 환경에 ALLOW_WRITE_OVERWRITE=1 을 두고
진행하세요(세션 전역 스위치입니다)."

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
