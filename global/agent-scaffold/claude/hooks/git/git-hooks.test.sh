#!/usr/bin/env bash
# 층 A(git 훅) 통합 테스트 — 임시 레포에 이 .claude(훅·lib·설치 스크립트)를 미러링하고 install-git-hooks.sh 로 스텁을
# 깐 뒤 **실제 git commit/push/merge** 를 쳐서 rc·stderr 를 본다. 실레포·실 .git 은 건드리지 않는다(전부 mktemp 아래).
# 실행: bash .claude/hooks/git/git-hooks.test.sh      케이스 추가 = 아래 _expect 한 줄(기대 rc 0|1, 설명, 명령).
# 전제: git·jq·shasum·python3. CLAUDECODE 는 케이스마다 명시한다(이 셸에 있든 없든 결과가 같게).
set -u
SRC_CLAUDE="$(cd "$(dirname "$0")/../.." && pwd)"   # = <레포>/.claude
for t in git jq shasum python3; do command -v "$t" >/dev/null 2>&1 || { echo "전제 도구 없음($t) — 실행하지 않았다"; exit 2; }; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE ALLOW_TEST_COUNT_DROP ALLOW_UNTESTED_COMMIT ALLOW_GIT_PUSH CLAUDE_PROJECT_DIR

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-hooks-test.XXXXXX") || exit 2
trap 'case "$WORK" in /tmp/*|/private/tmp/*|/var/folders/*) rm -rf "$WORK" ;; esac' EXIT
# HOME·XDG 격리 — GIT_CONFIG_GLOBAL=/dev/null 이어도 git 은 XDG 기본 ignore·attributes 를 읽는다.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config"; mkdir -p "$HOME"
run=0; passed=0
GIT=git
TOKEN="ghp_$(printf 'A%.0s' $(seq 1 36))"     # 시크릿 게이트 1차 패턴(가짜 값)

# 미러 원본 = 이 .claude 의 hooks(하위 전부)·scripts(최상위 파일). GIT_HOOKS_TEST_BASE(다른 .claude 경로)를 주면
# 그 hooks·scripts 를 먼저 깔고 이 .claude 를 덮는다 — 일부 파일만 담은 스테이징 사본을 실레포 의존 파일과 함께 돌릴 때.
MIRROR="$WORK/.claude-mirror"; mkdir -p "$MIRROR/hooks" "$MIRROR/scripts"
_fill_mirror() { # $1=.claude 경로 — 백업 사본(*.bak*)은 싣지 않는다
  [ -d "$1/hooks" ] && (cd "$1/hooks" && find . -type f ! -name '*.bak*' -print0 | while IFS= read -r -d '' f; do
    mkdir -p "$MIRROR/hooks/$(dirname "$f")" && cp -p "$f" "$MIRROR/hooks/$f"; done)
  [ -d "$1/scripts" ] && find "$1/scripts" -maxdepth 1 -type f ! -name '*.bak*' -exec cp -p {} "$MIRROR/scripts/" \;
  return 0
}
if [ -n "${GIT_HOOKS_TEST_BASE:-}" ]; then
  [ -d "$GIT_HOOKS_TEST_BASE/hooks" ] || { echo "GIT_HOOKS_TEST_BASE 에 hooks 없음: $GIT_HOOKS_TEST_BASE — 실행하지 않았다"; exit 2; }
  _fill_mirror "$GIT_HOOKS_TEST_BASE"
fi
_fill_mirror "$SRC_CLAUDE"
[ -f "$MIRROR/scripts/install-git-hooks.sh" ] && [ -f "$MIRROR/hooks/git/pre-commit" ] \
  || { echo "미러에 설치 스크립트·디스패처 없음 — 실행하지 않았다"; exit 2; }

_mkrepo() { # $1=이름 → 경로. .claude 미러 + 초기 커밋 + 층 A 설치.
  local r="$WORK/$1"
  mkdir -p "$r"; $GIT -C "$r" init -q
  $GIT -C "$r" config user.name t; $GIT -C "$r" config user.email t@example.invalid; $GIT -C "$r" config commit.gpgsign false
  cp -R "$MIRROR" "$r/.claude"
  printf '.claude/\n' > "$r/.git/info/exclude"
  printf 'x\n' > "$r/README"; $GIT -C "$r" add README; env -u CLAUDECODE $GIT -C "$r" commit -qm init
  (cd "$r" && bash .claude/scripts/install-git-hooks.sh >/dev/null) || { echo "설치 실패: $r"; return 1; }
  printf '%s' "$r"
}
_mark() { # $1=레포 [$2=--all] — 리뷰 마커(생략 경로)로 code-review 게이트를 통과시킨다
  (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash .claude/hooks/mark-review.sh --skip-reason "test" ${2:-} >/dev/null 2>&1)
}
LAST_ERR=""
_expect() { # $1=기대 rc(0|1) $2=설명 $3=레포 $4=명령(bash -c 로 실행, cwd=레포) [$5=stderr 에 있어야 할 문구]
  local rc err
  err=$(cd "$3" && bash -c "$4" 2>&1 >/dev/null); rc=$?
  [ "$rc" -ne 0 ] && rc=1
  LAST_ERR="$err"
  run=$((run + 1))
  if [ "$rc" = "$1" ] && { [ -z "${5:-}" ] || printf '%s' "$err" | grep -qF -- "$5"; }; then
    passed=$((passed + 1)); printf 'ok    %-56s [rc=%s]\n' "$2" "$rc"
  else
    printf 'FAIL  %-56s 기대 rc=%s%s 실제 rc=%s\n' "$2" "$1" "${5:+ + '$5'}" "$rc"
    printf '%s\n' "$err" | head -5 | sed 's/^/        /'
  fi
}
_assert() { # $1=설명 $2=조건(평가 문자열)
  run=$((run + 1))
  if eval "$2"; then passed=$((passed + 1)); printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fi
}
CC='CLAUDECODE=1'

echo "== 설치 스크립트 =="
r=$(_mkrepo inst)
_assert "스텁 3종 설치됨" "[ -f '$r/.git/hooks/pre-commit' ] && [ -f '$r/.git/hooks/pre-push' ] && [ -f '$r/.git/hooks/pre-merge-commit' ]"
_expect 0 "재실행 멱등" "$r" "bash .claude/scripts/install-git-hooks.sh"
_expect 0 "--check 통과" "$r" "bash .claude/scripts/install-git-hooks.sh --check"
r2=$(_mkrepo foreign); printf '#!/bin/sh\necho mine\n' > "$r2/.git/hooks/pre-push"
rm -f "$r2/.git/hooks/pre-commit"
_expect 1 "남의 훅이 있으면 중단" "$r2" "bash .claude/scripts/install-git-hooks.sh" "덮어쓰지 않고 중단"
_assert "중단 시 아무것도 쓰지 않음(pre-commit 미생성)" "[ ! -e '$r2/.git/hooks/pre-commit' ]"
r3=$(_mkrepo hp); $GIT -C "$r3" config core.hooksPath /dev/null
_expect 1 "core.hooksPath 설정 시 중단" "$r3" "bash .claude/scripts/install-git-hooks.sh" "core.hooksPath"
r4=$(_mkrepo noexec); chmod -x "$r4/.git/hooks/pre-commit"
_expect 1 "우리 스텁 실행 비트 없음 → --check 실패" "$r4" "bash .claude/scripts/install-git-hooks.sh --check" "실행 비트 없음 1건"
_expect 0 "재설치가 실행 비트 복구" "$r4" "bash .claude/scripts/install-git-hooks.sh"
_assert "복구 뒤 실행 가능" "[ -x '$r4/.git/hooks/pre-commit' ]"
_expect 0 "복구 뒤 --check 통과" "$r4" "bash .claude/scripts/install-git-hooks.sh --check"
r5=$(_mkrepo brokenlink); rm -f "$r5/.git/hooks/pre-push"; ln -s "$WORK/no-such-hook" "$r5/.git/hooks/pre-push"
_expect 1 "깨진 심볼릭 링크 → 설치 중단" "$r5" "bash .claude/scripts/install-git-hooks.sh" "깨진 심볼릭 링크"
_assert "중단 시 링크 보존(덮어쓰지 않음)" "[ -L '$r5/.git/hooks/pre-push' ] && [ \"\$(readlink '$r5/.git/hooks/pre-push')\" = '$WORK/no-such-hook' ]"
_expect 1 "깨진 심볼릭 링크 → --check 실패" "$r5" "bash .claude/scripts/install-git-hooks.sh --check" "깨진 심볼릭 링크"
# 2026-11-06 결함 사냥 G6 — 빈·잘린·문법 오류 본문과 잘린 스텁은 '설치됨'이 아니다
r7=$(_mkrepo emptybody); : > "$r7/.claude/hooks/git/pre-commit"
_expect 1 "G6 본문 0바이트 → --check 실패" "$r7" "bash .claude/scripts/install-git-hooks.sh --check" "본문 무효"
_expect 1 "G6 본문 0바이트 → 설치도 중단" "$r7" "bash .claude/scripts/install-git-hooks.sh" "본문 무효"
r8=$(_mkrepo cutpush); head -n 7 "$r8/.claude/hooks/git/pre-push" > "$r8/cut" && cat "$r8/cut" > "$r8/.claude/hooks/git/pre-push"
_expect 1 "G6 pre-push 본문 잘림(우회 줄 뒤) → --check 실패" "$r8" "bash .claude/scripts/install-git-hooks.sh --check" "본문 무효"
r9=$(_mkrepo synbody); { printf 'if true; then\n'; cat "$r9/.claude/hooks/git/pre-merge-commit"; } > "$r9/b" && cat "$r9/b" > "$r9/.claude/hooks/git/pre-merge-commit"
_expect 1 "G6 본문 문법 오류(끝 표지는 있음) → --check 실패" "$r9" "bash .claude/scripts/install-git-hooks.sh --check" "본문 무효"
r10=$(_mkrepo cutstub); head -n 2 "$r10/.git/hooks/pre-commit" > "$r10/s" && cat "$r10/s" > "$r10/.git/hooks/pre-commit"
_expect 1 "G6 우리 스텁 잘림(표지 줄만 남음) → --check 실패" "$r10" "bash .claude/scripts/install-git-hooks.sh --check" "스텁 손상 1건"
_expect 0 "잘린 스텁은 재설치가 다시 쓴다" "$r10" "bash .claude/scripts/install-git-hooks.sh"
_expect 0 "재설치 뒤 --check 통과" "$r10" "bash .claude/scripts/install-git-hooks.sh --check"
# 2026-11-06 r2 — 표지 뒤 빈 줄 허용·CR 무효·손상 스텁 백업·NUL 손상·중단 문구
_expect 1 "r2 본문 무효 문구 = 표지만 덧붙이지 말 것" "$r7" "bash .claude/scripts/install-git-hooks.sh --check" "표지 줄만 덧붙이지 말고"
r11=$(_mkrepo trailblank); printf '\n  \n\t\n' >> "$r11/.claude/hooks/git/pre-commit"
_expect 0 "r2 표지 뒤 빈 줄·공백뿐인 줄 → 정상(--check 통과)" "$r11" "bash .claude/scripts/install-git-hooks.sh --check"
r12=$(_mkrepo crlfbody); sed 's/$/\r/' "$r12/.claude/hooks/git/pre-push" > "$r12/b" && cat "$r12/b" > "$r12/.claude/hooks/git/pre-push"
_expect 1 "r2 CRLF 본문 → 본문 무효" "$r12" "bash .claude/scripts/install-git-hooks.sh --check" "본문 무효"
r12b=$(_mkrepo crtail); printf '\r\n' >> "$r12b/.claude/hooks/git/pre-merge-commit"
_expect 1 "r2 표지 뒤 CR 만 있는 줄 → 본문 무효(CR 은 빈 줄로 안 침)" "$r12b" "bash .claude/scripts/install-git-hooks.sh --check" "본문 무효"
r13=$(_mkrepo userstub); printf 'echo user-extra\n' >> "$r13/.git/hooks/pre-commit"; cp "$r13/.git/hooks/pre-commit" "$r13/damaged.copy"
R13_OUT=$(cd "$r13" && bash .claude/scripts/install-git-hooks.sh 2>&1); R13_RC=$?
R13_BAK=$(ls "$r13/.git/hooks/" | grep '^pre-commit\.bak-' | head -1)
_assert "r2 손상 스텁 재설치 → rc 0·'덮어씀(… 백업 = …)' 출력" "[ $R13_RC -eq 0 ] && printf '%s' \"\$R13_OUT\" | grep -qE '^덮어씀\(손상된 우리 스텁 — 백업 = /.*/userstub/\.git/hooks/$R13_BAK\): '"   # 접두는 /private 정규화될 수 있어 꼬리로 본다
_assert "r2 백업 = 손상본 그대로(사용자 추가 줄 보존)" "[ -n '$R13_BAK' ] && cmp -s '$r13/damaged.copy' '$r13/.git/hooks/$R13_BAK'"
_expect 0 "r2 백업 뒤 --check 통과(백업 파일은 훅으로 안 침)" "$r13" "bash .claude/scripts/install-git-hooks.sh --check"
r14=$(_mkrepo nulstub); printf '\000' >> "$r14/.git/hooks/pre-push"   # 끝에 NUL 1바이트 — 명령치환 비교는 이걸 버린다
_expect 1 "r2 NUL 낀 스텁 → 스텁 손상(cmp 바이트 비교)" "$r14" "bash .claude/scripts/install-git-hooks.sh --check" "스텁 손상 1건"

echo "== SessionStart 층 A 점검(git-hooks-check.sh) =="
r6=$(_mkrepo sscheck)
_hc() { (cd "$1" && CLAUDE_PROJECT_DIR="$1" bash .claude/hooks/git-hooks-check.sh </dev/null 2>/dev/null); }
_assert "설치됨 → 무출력" "[ -z \"\$(_hc '$r6')\" ]"
rm -f "$r6/.git/hooks/pre-merge-commit"
HC_OUT=$(_hc "$r6"); HC_RC=$?
_assert "미설치 → rc 0(차단 아님)" "[ $HC_RC -eq 0 ]"
_assert "미설치 → additionalContext 에 설치 명령" "printf '%s' \"\$HC_OUT\" | jq -e '.hookSpecificOutput.hookEventName==\"SessionStart\" and (.hookSpecificOutput.additionalContext | contains(\"bash .claude/scripts/install-git-hooks.sh\"))' >/dev/null"
mkdir -p "$WORK/notrepo/.claude/scripts"; cp "$MIRROR/scripts/install-git-hooks.sh" "$WORK/notrepo/.claude/scripts/"; cp -R "$MIRROR/hooks" "$WORK/notrepo/.claude/"
_assert "git 레포 아님(점검 불가) → 무출력" "[ -z \"\$(_hc '$WORK/notrepo')\" ]"

echo "== 인덱스 밖 커밋 형태 → 실제 커밋 내용으로 판정(secret) =="
r=$(_mkrepo idx)
printf 'token=%s\n' "$TOKEN" > "$r/a.txt"; $GIT -C "$r" add a.txt; env -u CLAUDECODE $GIT -C "$r" commit -qm a --no-verify
printf 'plain\n' > "$r/b.txt"
printf 'token2=%s\n' "$TOKEN" >> "$r/a.txt"
_expect 1 "pathspec 커밋(인덱스 비움)" "$r" "$CC $GIT commit -qm m a.txt" "[시크릿 커밋 가드]"
_assert "pathspec 거부 뒤 인덱스 그대로(비어 있음)" "[ -z \"\$($GIT -C '$r' diff --cached --name-only)\" ]"
_expect 1 "add && commit 한 호출" "$r" "$GIT add a.txt && $CC $GIT commit -qm m" "[시크릿 커밋 가드]"
$GIT -C "$r" reset -q
_expect 1 "commit -a" "$r" "$CC $GIT commit -qam m" "[시크릿 커밋 가드]"
_expect 1 "commit -o" "$r" "$CC $GIT commit -q -o -m m a.txt" "[시크릿 커밋 가드]"
$GIT -C "$r" add b.txt
_expect 1 "commit -i" "$r" "$CC $GIT commit -q -i -m m a.txt" "[시크릿 커밋 가드]"
$GIT -C "$r" reset -q
# 별도 인덱스 파일로 스테이징한 뒤 그 인덱스로 커밋
_expect 1 "GIT_INDEX_FILE 대입" "$r" "cp .git/index .git/alt-index && GIT_INDEX_FILE=.git/alt-index $GIT add a.txt && GIT_INDEX_FILE=.git/alt-index $CC $GIT commit -qm m" "[시크릿 커밋 가드]"

echo "== CLAUDECODE·fail-closed =="
_expect 0 "CLAUDECODE 미설정 → 층 A 무발화(사용자 터미널)" "$r" "env -u CLAUDECODE $GIT commit -qm user a.txt"
r=$(_mkrepo nolib); printf 'ok\n' > "$r/c.txt"; $GIT -C "$r" add c.txt; _mark "$r"
mv "$r/.claude/hooks/lib/review-diff.sh" "$r/.claude/hooks/lib/review-diff.sh.off"
_expect 1 "lib 부재 → exit 1(판정 불가)" "$r" "$CC $GIT commit -qm m" "lib 부재"
mv "$r/.claude/hooks/lib/review-diff.sh.off" "$r/.claude/hooks/lib/review-diff.sh"
mv "$r/.claude/hooks/sql-staging-guard.sh" "$r/.claude/hooks/sql-staging-guard.sh.off"
_expect 1 "게이트 부재 → exit 1" "$r" "$CC $GIT commit -qm m" "게이트 부재"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "not json {"\n' > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "게이트 출력 JSON 파싱 실패 → exit 1" "$r" "$CC $GIT commit -qm m" "파싱 실패"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n' > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "게이트 비정상 종료 → exit 1" "$r" "$CC $GIT commit -qm m" "비정상 종료"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %%s %s\n' "'{ \"hookSpecificOutput\" : { \"permissionDecision\" :  \"deny\" , \"permissionDecisionReason\" : \"FAKE-DENY\" } }'" > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "공백 섞인 JSON 의 deny 감지" "$r" "$CC $GIT commit -qm m" "FAKE-DENY"
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "  \\n"\n' > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 0 "공백뿐인 출력 = 통과" "$r" "$CC $GIT commit -qm m"
printf 'ok2\n' > "$r/c2.txt"; $GIT -C "$r" add c2.txt; _mark "$r"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho %s\necho %s\n' "'{\"systemMessage\":\"note\"}'" "'{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"MULTI-DENY\"}}'" > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "JSON 여러 개 중 뒤의 deny 감지" "$r" "$CC $GIT commit -qm m" "MULTI-DENY"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho %s\n' "'{\"hookSpecificOutput\":{\"permissionDecision\":\"maybe\"}}'" > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "낯선 permissionDecision → 판정 불가" "$r" "$CC $GIT commit -qm m" "형식 판정 불가"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho %s\n' "'\"deny\"'" > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "JSON 객체가 아닌 출력 → 판정 불가" "$r" "$CC $GIT commit -qm m" "형식 판정 불가"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho BOOM-DIAG-LINE >&2\nexit 3\n' > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "비정상 종료 시 게이트 stderr 끝줄 첨부" "$r" "$CC $GIT commit -qm m" "BOOM-DIAG-LINE"
printf 'ok4\n' > "$r/c4.txt"; $GIT -C "$r" add c4.txt; _mark "$r"   # 앞 케이스가 잘못 통과해도 이 케이스는 따로 판정되게
# 한 게이트 파일이 ALLOW 낱말을 둘 이상 가질 때 — 정렬상 뒤 변수도 우회 정규식(줄 머리·;&| 뒤)에 걸려야 한다.
printf '%s\n' '#!/usr/bin/env bash' 'in=$(cat)' '# 다른 변수 언급: ALLOW_AAA_OTHER' \
  'c=$(printf "%s" "$in" | jq -r .tool_input.command)' \
  'printf "%s" "$c" | grep -Eq "(^|[;&|][[:space:]]*)ALLOW_ZZZ_MINE=1[[:space:]]" && exit 0' \
  'jq -n "{hookSpecificOutput:{permissionDecision:\"deny\",permissionDecisionReason:\"ALLOW-NOT-SEEN\"}}"' > "$r/.claude/hooks/sql-staging-guard.sh"
_expect 1 "(대조) 자기 ALLOW 없음 → deny" "$r" "ALLOW_AAA_OTHER=1 $CC $GIT commit -qm m" "ALLOW-NOT-SEEN"
_expect 0 "한 게이트의 ALLOW 둘 다 대입 → 뒤 변수도 인정" "$r" "ALLOW_AAA_OTHER=1 ALLOW_ZZZ_MINE=1 $CC $GIT commit -qm m"
printf 'ok3\n' > "$r/c3.txt"; $GIT -C "$r" add c3.txt; _mark "$r"
mv "$r/.claude/hooks/secret-commit-guard.sh" "$r/.claude/hooks/secret-commit-guard.sh.off"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho SECRET-VALUE-LEAK >&2\nexit 3\n' > "$r/.claude/hooks/secret-commit-guard.sh"
_expect 1 "시크릿 게이트 비정상 종료 → 막음" "$r" "$CC $GIT commit -qm m" "secret-commit-guard rc=3"
_assert "시크릿 게이트 stderr 는 싣지 않음" "! printf '%s' \"\$LAST_ERR\" | grep -qF SECRET-VALUE-LEAK"
mv "$r/.claude/hooks/secret-commit-guard.sh.off" "$r/.claude/hooks/secret-commit-guard.sh"
mv "$r/.claude/hooks/sql-staging-guard.sh.off" "$r/.claude/hooks/sql-staging-guard.sh"

echo "== ALLOW = 실제 환경변수 =="
r=$(_mkrepo allow); mkdir -p "$r/src/test/java"   # {{MODULE_CORE}} 는 mvn 게이트 단계에서 만든다(.java 스테이징이면 mvn 게이트도 깨어난다)
printf 'class T {\n  @Test void a() {}\n  @Test void b() {}\n}\n' > "$r/src/test/java/T.java"
$GIT -C "$r" add src; env -u CLAUDECODE $GIT -C "$r" commit -qm t
printf 'class T {\n  @Test void a() {}\n}\n' > "$r/src/test/java/T.java"; $GIT -C "$r" add src; _mark "$r"
_expect 1 "테스트 감소 → deny" "$r" "$CC $GIT commit -qm m" "[테스트 수 감소 가드]"
_assert "층 A 안내문엔 히어독 절 없음(GATE_LAYER=git)" "! printf '%s' \"\$LAST_ERR\" | grep -q '히어독 본문'"
_expect 1 "메시지 안 ALLOW 위조 → deny" "$r" "$CC $GIT commit -q -m 'x
ALLOW_TEST_COUNT_DROP=1 y'" "[테스트 수 감소 가드]"
_expect 1 "따옴표 안 ; ALLOW 위조 → deny" "$r" "$CC $GIT commit -q -m 'x; ALLOW_TEST_COUNT_DROP=1 y'" "[테스트 수 감소 가드]"
_expect 1 "ALLOW 셸 변수 대입 뒤 && commit(env 아님) → deny" "$r" "ALLOW_TEST_COUNT_DROP=1 && $CC $GIT commit -qm m" "[테스트 수 감소 가드]"
_expect 1 "다른 게이트의 ALLOW 만 → deny" "$r" "ALLOW_UNTESTED_COMMIT=1 $CC $GIT commit -qm m" "[테스트 수 감소 가드]"
_expect 0 "진짜 ALLOW 대입 → 통과" "$r" "ALLOW_TEST_COUNT_DROP=1 $CC $GIT commit -qm m"
mkdir -p "$r/{{MODULE_CORE}}/src/main"; printf 'class A {}\n' > "$r/{{MODULE_CORE}}/src/main/A.java"
printf 'class T {\n}\n' > "$r/src/test/java/T.java"; $GIT -C "$r" add {{MODULE_CORE}} src; _mark "$r"
_expect 1 "java+감소: ALLOW 하나만 → 다른 게이트가 막음" "$r" "ALLOW_TEST_COUNT_DROP=1 $CC $GIT commit -qm m" "[mvn test 결과 게이트]"
_assert "java+감소 거부 사유엔 히어독 절 없음(GATE_LAYER=git)" "! printf '%s' \"\$LAST_ERR\" | grep -q '히어독 본문'"
_expect 0 "ALLOW 다중 대입 → 두 게이트 통과" "$r" "ALLOW_TEST_COUNT_DROP=1 ALLOW_UNTESTED_COMMIT=1 $CC $GIT commit -qm m"
# rename(R): 내용 유사도가 50% 를 넘게 공통 줄을 깔고, 이름을 바꾸며 @Test 하나를 지운다.
FILL=$(for i in $(seq 1 30); do printf '  // filler line %s\\n' "$i"; done)
_expect 0 "(전제) rename 대상 기준 커밋" "$r" "printf 'class T {\n${FILL}  @Test void a() {}\n  @Test void b() {}\n}\n' > src/test/java/T.java && $GIT add src && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null && ALLOW_UNTESTED_COMMIT=1 $CC $GIT commit -qm base"
_expect 1 "rename 으로 테스트 감소(R) → deny" "$r" "$GIT mv src/test/java/T.java src/test/java/U.java && printf 'class T {\n${FILL}  @Test void a() {}\n}\n' > src/test/java/U.java && $GIT add src && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null && $CC $GIT commit -qm mv" "[테스트 수 감소 가드]"
_assert "(전제) 인덱스가 R 로 본다" "$GIT -C '$r' diff --cached -M --name-status | grep -q '^R'"

echo "== code-review 마커 지문 =="
r=$(_mkrepo mark)
printf 'v1\n' > "$r/m.txt"; $GIT -C "$r" add m.txt; env -u CLAUDECODE $GIT -C "$r" commit -qm m
printf 'v2\n' > "$r/m.txt"; $GIT -C "$r" add m.txt
_expect 1 "마커 없음 → deny" "$r" "$CC $GIT commit -qm m" "[커밋 전 코드리뷰 게이트]"
_mark "$r"
_expect 0 "마커 일치 → 통과" "$r" "$CC $GIT commit -qm m"
printf 'v3\n' > "$r/m.txt"
_mark "$r" --all
_assert "mark-review --all 은 실제 인덱스를 건드리지 않음" "[ -z \"\$($GIT -C '$r' diff --cached --name-only)\" ]"
_expect 0 "mark-review --all 지문 = commit -a 지문" "$r" "$CC $GIT commit -qam m"
printf 'v4\n' > "$r/m.txt"; _mark "$r"   # 인덱스가 비어 마커를 못 찍는다(rc=1) — 이전 마커 유지
_expect 1 "--all 없이 찍은(못 찍은) 마커로 commit -a → deny" "$r" "$CC $GIT commit -qam m" "[커밋 전 코드리뷰 게이트]"
r=$(_mkrepo markcfg)   # diff 표시 설정이 걸린 레포 — 외부 diff(false = 실행되면 diff 가 죽는다)·색 강제
$GIT -C "$r" config diff.external false; $GIT -C "$r" config color.diff always
printf 'v2\n' > "$r/README"; $GIT -C "$r" add README; _mark "$r"; MK_RC=$?
_assert "diff.external·color.diff=always 레포에서도 마커가 찍힌다(지문 산출 성공)" "[ $MK_RC -eq 0 ]"
_assert "(전제) 이 레포에선 플래그 없는 diff --cached 가 실패한다" "! $GIT -C '$r' diff --cached >/dev/null 2>&1"
_expect 0 "diff.external·color.diff=always 레포에서 마커 일치 → 통과" "$r" "$CC $GIT commit -qm m"

echo "== SQL 초안 게이트 =="
r=$(_mkrepo sql); printf 'select 1;\n' > "$r/draft.sql"
_expect 1 "신규 .sql pathspec 커밋 → deny" "$r" "$GIT add -N draft.sql && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null; $CC $GIT commit -qm m draft.sql" "[SQL 커밋 가드]"
_assert "SQL 거부 사유엔 다른 게이트 표지 없음" "! printf '%s' \"\$LAST_ERR\" | grep -qF '[시크릿 커밋 가드]'"
r=$(_mkrepo sqlmv); printf 'select 2;\n' > "$r/x.sql"; $GIT -C "$r" add x.sql; env -u CLAUDECODE $GIT -C "$r" commit -qm x
$GIT -C "$r" mv x.sql y.sql; _mark "$r"
_assert "(전제) 인덱스가 x.sql→y.sql 을 R 로 본다" "$GIT -C '$r' diff --cached -M --name-status | grep -q '^R'"
_expect 1 "추적 .sql 을 git mv(R) → deny" "$r" "$CC $GIT commit -qm m" "[SQL 커밋 가드]"

echo "== 시크릿 예외 경로(EXCLUDE_PATH_REGEX) — 프로파일 설정 =="
# 기대는 설치된 게이트의 EXCLUDE_PATH_REGEX 값이 정한다: 프로파일 경로가 예외면 통과, 아니면(킷 기본 = 빈 값) 차단.
# 값 줄을 못 읽으면 기대를 정할 수 없다 → 전제 단언 실패로 센다(조용히 건너뛰지 않는다).
_SG="$MIRROR/hooks/secret-commit-guard.sh"
_exp_for() { # $1=경로 → 0(예외 = 통과) | 1(스캔 = 차단) | 2(판정 불가)
  local x
  grep -q "^EXCLUDE_PATH_REGEX='" "$_SG" || return 2
  x=$(sed -n "s/^EXCLUDE_PATH_REGEX='\([^']*\)'.*/\1/p" "$_SG" | head -n 1)
  [ -n "$x" ] && printf '%s\n' "$1" | grep -qE -- "$x" && return 0
  return 1
}
r=$(_mkrepo prod); P={{MODULE_FRONT}}/src/main/resources/application-prod.properties; mkdir -p "$r/${P%/*}"
printf 'server.port=8080\nGlobals.db.password=<운영 DB 비밀번호>\n' > "$r/$P"
$GIT -C "$r" add "$P"; env -u CLAUDECODE $GIT -C "$r" commit -qm prod
REAL='Zq7Real0Pw'   # 가짜 실값 — 줄 정규식(2차)에 걸리는 형태라 제외가 없으면 막힌다
printf 'server.port=8080\nGlobals.db.password=%s\n' "$REAL" > "$r/$P"
_exp_for "$P"; _pe=$?
_assert "(전제) 시크릿 게이트의 EXCLUDE_PATH_REGEX 줄을 읽었다" "[ $_pe -ne 2 ]"
[ "$_pe" -eq 2 ] && _pe=1
_expect "$_pe" "운영 프로파일 실값 추가(예외면 통과·아니면 차단)" "$r" "$GIT add '$P' && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null && $CC $GIT commit -qm m"
_assert "운영 프로파일 판정 사유에 실값 비노출" "! printf '%s' \"\$LAST_ERR\" | grep -qF '$REAL'"
$GIT -C "$r" reset -q   # 차단됐으면 스테이징을 비워 다음 케이스와 섞이지 않게(통과했으면 무동작)
D={{MODULE_FRONT}}/src/main/resources/application-dev.properties
printf 'Globals.db.password=%s\n' "$REAL" > "$r/$D"
_exp_for "$D"; _de=$?; [ "$_de" -eq 2 ] && _de=1
_expect "$_de" "개발 프로파일 실값 추가(예외면 통과·아니면 차단)" "$r" "$GIT add '$D' && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null && $CC $GIT commit -qm m"
$GIT -C "$r" reset -q
printf 'Globals.db.password=%s\n' "$REAL" > "$r/other.conf"
_expect 1 "(대조) 같은 줄을 프로파일 밖 파일에 → deny" "$r" "$GIT add other.conf && CLAUDE_PROJECT_DIR=\"\$PWD\" bash .claude/hooks/mark-review.sh --skip-reason t >/dev/null && $CC $GIT commit -qm m" "[시크릿 커밋 가드]"
_assert "대조 거부 사유에 실값 비노출" "! printf '%s' \"\$LAST_ERR\" | grep -qF '$REAL'"

echo "== worktree =="
r=$(_mkrepo wt)
$GIT -C "$r" worktree add -q "$WORK/wt-tree" -b wtb >/dev/null 2>&1
printf 'token=%s\n' "$TOKEN" > "$WORK/wt-tree/s.txt"; $GIT -C "$WORK/wt-tree" add s.txt
_expect 1 "worktree 커밋 → 메인 트리 게이트 작동(secret)" "$WORK/wt-tree" "$CC $GIT commit -qm m" "[시크릿 커밋 가드]"

echo "== pre-merge-commit =="
r=$(_mkrepo mg)
$GIT -C "$r" checkout -qb side; printf 'token=%s\n' "$TOKEN" > "$r/s.txt"; $GIT -C "$r" add s.txt
env -u CLAUDECODE $GIT -C "$r" commit -qm side; $GIT -C "$r" checkout -q -
printf 'main\n' > "$r/mm.txt"; $GIT -C "$r" add mm.txt; env -u CLAUDECODE $GIT -C "$r" commit -qm mainside
_expect 1 "병합 커밋도 내용 게이트(secret)" "$r" "$CC $GIT merge -q --no-ff --no-edit side" "[시크릿 커밋 가드]"
_assert "병합 거부 안내에 merge --abort 복구 경로" "printf '%s' \"\$LAST_ERR\" | grep -qF 'git merge --abort'"
$GIT -C "$r" merge --abort >/dev/null 2>&1 || true
# 들어오는 쪽에 .java·테스트 감소가 있어도 병합 커밋은 mvn·code-review·test-count 로 막히지 않는다(병합 모드 = 내용 게이트만).
r=$(_mkrepo mgj); mkdir -p "$r/{{MODULE_CORE}}/src/main" "$r/src/test/java"
printf 'class T {\n  @Test void a() {}\n  @Test void b() {}\n}\n' > "$r/src/test/java/T.java"
$GIT -C "$r" add src; env -u CLAUDECODE $GIT -C "$r" commit -qm t
$GIT -C "$r" checkout -qb side
printf 'class A {}\n' > "$r/{{MODULE_CORE}}/src/main/A.java"; printf 'class T {\n  @Test void a() {}\n}\n' > "$r/src/test/java/T.java"
$GIT -C "$r" add {{MODULE_CORE}} src; env -u CLAUDECODE $GIT -C "$r" commit -qm side; $GIT -C "$r" checkout -q -
printf 'main\n' > "$r/mm.txt"; $GIT -C "$r" add mm.txt; env -u CLAUDECODE $GIT -C "$r" commit -qm mainside
mkdir -p "$r/{{MODULE_CORE}}/src/main"; printf 'class B {}\n' > "$r/{{MODULE_CORE}}/src/main/B.java"; $GIT -C "$r" add {{MODULE_CORE}}
_expect 1 "(대조) 같은 레포 일반 커밋의 .java → mvn 게이트 작동" "$r" "$CC $GIT commit -qm m" "[mvn test 결과 게이트]"
$GIT -C "$r" rm -q --cached {{MODULE_CORE}}/src/main/B.java; rm -f "$r/{{MODULE_CORE}}/src/main/B.java"
_assert "(전제) 병합 전 인덱스 = HEAD" "[ -z \"\$($GIT -C '$r' diff --cached --name-only)\" ]"
_expect 0 "upstream .java·테스트 감소 병합 → 통과(마커 없음)" "$r" "$CC $GIT merge -q --no-ff --no-edit side"
_assert "병합 커밋 생성됨(부모 2)" "[ \"\$($GIT -C '$r' rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')\" = 3 ]"

echo "== pre-push =="
r=$(_mkrepo pp); $GIT init -q --bare "$WORK/remote.git"; $GIT -C "$r" remote add origin "$WORK/remote.git"
_expect 1 "에이전트 push → 차단" "$r" "$CC $GIT pu""sh -q origin HEAD:main" "푸시는 사용자 전담"
_assert "차단 뒤 원격에 ref 없음" "! $GIT -C '$WORK/remote.git' rev-parse -q --verify refs/heads/main >/dev/null"
_expect 1 "메시지 위조 아님 — 명령 문자열 ALLOW 는 env 가 아님" "$r" "$CC $GIT -c core.x='ALLOW_GIT_PUSH=1' pu""sh -q origin HEAD:main" "푸시는 사용자 전담"
_expect 0 "ALLOW_GIT_PUSH=1 → 통과" "$r" "ALLOW_GIT_PUSH=1 $CC $GIT pu""sh -q origin HEAD:main"
_expect 0 "CLAUDECODE 미설정 → 통과" "$r" "env -u CLAUDECODE $GIT pu""sh -q origin HEAD:main2"

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -gt 0 ] || { echo "실행된 단언 0 — 미실행은 통과가 아니다"; exit 2; }
[ "$run" -eq "$passed" ]
