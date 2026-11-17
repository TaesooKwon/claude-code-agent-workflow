#!/usr/bin/env bash
# 차단형 가드 히어독 계약 테스트 — 명령 문자열로 판정하는 차단형 가드가 lib 의 히어독 허용 목록 규칙을 같게 쓰는지.
#   H0 실제 명령 → deny(양성 대조) · H1 히어독으로 문서를 쓰는 본문의 명령 문구 → allow(오탐 해소) ·
#   H2 히어독으로 스크립트를 쓰고 같은 호출에서 실행 → deny(미탐 방지).
# 대상 = PreToolUse 에 남는 차단형 가드(아래 _triple 호출부가 모집단). 커밋 내용 게이트 5종(secret·sql-staging·
#   test-count·mvn-test-result-gate·code-review-marker)은 2026-11-05 층 A(git pre-commit)로 옮겨 명령 문자열을 보지
#   않으므로 여기서 뺐다 — 그 게이트들의 판정은 .claude/hooks/git/git-hooks.test.sh 가 실제 커밋으로 검사한다.
# 실행: bash .claude/hooks/blocking-heredoc-contract.test.sh
# 의존 훅 = 아래 _triple 이 부르는 가드들. 레포가 그중 하나를 의도적으로 설치하지 않았으면(킷 MISSING 지문)
#   그 가드의 3건만 SKIP 으로 세고 합계(Tests run)에서 뺀다 — 실패를 숨기는 게 아니라 '부재'만 건너뛴다.
# ⚠️ 검사 대상 명령 문자열은 이 파일 안에서만 조립한다(Bash 도구 명령줄에 직접 적으면 가드가 호출 자체를 막는다).
# 반증 예고: 히어독 판정을 원문 판정으로 되돌린 판이면 H1 이 대상 가드 수만큼 deny 로 빨강,
#   허용 목록 이전 스트립 판(F5)이면 H2 가 대상 가드 수만큼 allow 로 빨강이어야 한다.
set -u
HOOKS="$(cd "$(dirname "$0")" && pwd)"
for t in git jq; do command -v "$t" >/dev/null 2>&1 || { echo "전제 도구 없음($t) — 테스트를 실행하지 않았다"; exit 2; }; done

run=0; passed=0; skipped=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bhc-test.XXXXXX") || exit 2
trap 'case "$WORK" in /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$WORK" ;; esac' EXIT

GC="git co""mmit -m x"
GA="git a""dd -A"
_mkrepo() { # $1=이름 → 경로(초기 커밋까지)
  local r="$WORK/$1"; mkdir -p "$r/.claude"; git -C "$r" init -q
  git -C "$r" config user.name t; git -C "$r" config user.email t@example.invalid
  git -C "$r" config commit.gpgsign false; git -C "$r" config core.hooksPath /dev/null
  printf 'x\n' > "$r/README"; git -C "$r" add README; git -C "$r" commit -qm init
  printf '%s' "$r"
}
_dec() { # $1=훅 $2=레포 $3=명령 [$4=추가 환경] → deny|allow
  local out
  out=$(jq -n --arg c "$3" --arg d "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
        | env CLAUDE_PROJECT_DIR="$2" ${4:-} bash "$HOOKS/$1.sh" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"deny"'; then printf deny; else printf allow; fi
}
_chk() { # $1=기대 $2=설명 $3=실제
  run=$((run + 1))
  if [ "$1" = "$3" ]; then passed=$((passed + 1)); printf 'ok    %-50s [%s]\n' "$2" "$3"
  else printf 'FAIL  %-50s 기대=%s 실제=%s\n' "$2" "$1" "$3"; fi
}
_triple() { # $1=훅 $2=레포 $3=실제명령 [$4=추가 환경]
  [ -f "$HOOKS/$1.sh" ] || { skipped=$((skipped + 3)); printf 'SKIP  %-50s [훅 부재 — 3건]\n' "$1"; return; }
  _chk deny  "$1 H0 실제 명령"            "$(_dec "$1" "$2" "$3" "${4:-}")"
  _chk allow "$1 H1 문서 쓰기 히어독 본문" "$(_dec "$1" "$2" "$(printf 'cat > note.md <<EOF\n%s\nEOF' "$3")" "${4:-}")"
  _chk deny  "$1 H2 스크립트로 쓰고 실행"  "$(_dec "$1" "$2" "$(printf "cat <<'EOF' > run.sh\n%s\nEOF\nbash run.sh" "$3")" "${4:-}")"
}

# profile-key-diff-guard(deny 모드) — 모듈 프로파일 키 차집합. 운영 파일명 = 훅의 PROD_PROFILE_FILE 값
#   (훅의 대입 줄과 폴백 case 줄을 그대로 평가해 읽는다 — 훅 값이 바뀌어도 픽스처가 따라간다).
#   훅이 있는데 줄 머리 '^PROD_PROFILE_FILE=' 대입 줄이 정확히 하나가 아니거나(형태가 바뀌면 폴백 case 만 평가돼
#   폴백 이름이 나오므로) 평가 값이 비었거나 경로·글롭 문자가 섞이면 판정 불가로 중단한다(exit 2).
r=$(_mkrepo pk); P="$r/{{MODULE_ADMIN}}/src/main/resources"; mkdir -p "$P"
PROD_FILE=application-prod.properties
if [ -f "$HOOKS/profile-key-diff-guard.sh" ]; then
  n_assign=$(grep -c '^PROD_PROFILE_FILE=' "$HOOKS/profile-key-diff-guard.sh")
  [ "$n_assign" = 1 ] || { echo "훅의 PROD_PROFILE_FILE 대입 줄이 하나가 아니다(${n_assign}줄) — 테스트를 실행하지 않았다"; exit 2; }
  PROD_FILE=$(sed -n '/^PROD_PROFILE_FILE=/p; /^case "\$PROD_PROFILE_FILE"/p' "$HOOKS/profile-key-diff-guard.sh" \
              | { cat; printf '\nprintf %%s "${PROD_PROFILE_FILE:-}"\n'; } | bash 2>/dev/null)
  case "$PROD_FILE" in ''|*/*|*[*?[]*) echo "훅의 PROD_PROFILE_FILE 을 읽지 못했다('$PROD_FILE') — 테스트를 실행하지 않았다"; exit 2 ;; esac
fi
printf 'a=1\nb=2\n' > "$P/application-dev.properties"; printf 'a=1\n' > "$P/$PROD_FILE"
git -C "$r" add .
_triple profile-key-diff-guard "$r" "$GC" "PROFILE_KEY_DIFF_MODE=deny"

# git-add-all-guard — 일괄 스테이징 명령 자체
r=$(_mkrepo aa)
_triple git-add-all-guard "$r" "$GA"

# git-hook-bypass-guard — 층 A(git 훅)를 건너뛰는 낱말
r=$(_mkrepo hb)
_triple git-hook-bypass-guard "$r" "git co""mmit --no-ver""ify -m x"

echo
if [ "$skipped" -gt 0 ]; then echo "Tests run: $run, Passed: $passed, Skipped: $skipped(의존 훅 부재)"
else echo "Tests run: $run, Passed: $passed"; fi
[ "$run" -gt 0 ] || { echo "실행된 단언 0 — 대상 훅이 모두 부재(통과가 아니다)"; exit 2; }
[ "$run" -eq "$passed" ] || exit 1
