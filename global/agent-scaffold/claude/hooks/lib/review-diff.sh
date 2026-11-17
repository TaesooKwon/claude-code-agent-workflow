#!/usr/bin/env bash
# 공용 라이브러리 — "커밋 전 코드리뷰" 게이트가 대조할 **리뷰 대상 diff 지문**.
# 검문(code-review-marker-reminder.sh)과 기록(mark-review.sh)이 반드시 같은 값을 쓰도록 단일 정본으로 둔다
# (두 곳에 복붙하면 한쪽만 고쳐졌을 때 게이트가 조용히 항상-deny 또는 항상-pass 가 된다).
#
# 왜 날짜가 아니라 지문인가: 날짜 마커는 "오늘 아무 diff나 리뷰했으면 통과"라서, 다른 세션이 아침에
# 마커를 소진하면 그날 나머지 커밋이 전부 무검문 통과한다(2026-08-05 실측 사고 — 07:54 소진, 11시 커밋 통과).
#
# 사용: review_diff_hash <repo> [commit 명령문]  → 표준출력에 sha256
#   rc 0 = 지문 산출  /  rc 1 = git 저장소 아님·해시도구 부재(fail-open 대상)  /  rc 2 = 검토할 변경 없음

review_diff_hash() {
  repo="$1"
  cmd="${2:-}"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
  command -v shasum >/dev/null 2>&1 || return 1

  # diff 표시 설정(color·외부 diff 도구·textconv)이 지문을 흔들지 않게 끈다 — 기록과 검문이 같은 값을 내야 한다.
  local _rd_flags='--no-color --no-ext-diff --no-textconv'
  # cmd 에 `-a`/`--all` 이 보이면 워킹트리 변경까지 지문에 넣는다 — 명령 문자열만 보는 PreToolUse 넛지
  # (roundtrip-verify-reminder)용 분기다. 층 A(git pre-commit 디스패처)는 합성 명령에 -a 를 싣지 않는다: 그 시점엔
  # -a 의 내용이 이미 인덱스(GIT_INDEX_FILE)에 들어 있다. mark-review.sh --all 은 임시 인덱스에 `git add -u` 를 한 뒤
  # -a 없이 이 함수를 불러 층 A 와 같은 지문을 낸다.
  if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(-[A-Za-z]*a[A-Za-z]*|--all)([[:space:]]|$)'; then
    diff=$( { git -C "$repo" diff $_rd_flags HEAD 2>/dev/null; git -C "$repo" diff $_rd_flags --cached 2>/dev/null; } )
  else
    diff=$(git -C "$repo" diff $_rd_flags --cached 2>/dev/null)
  fi

  [ -n "$diff" ] || return 2
  printf '%s' "$diff" | shasum -a 256 2>/dev/null | awk '{print $1}'
}
