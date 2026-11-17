#!/usr/bin/env bash
# harness.sh 반증검사 — 가짜 mvn(PATH 앞)과 임시 git 레포로 인자 허용 목록·실행 명령·요약·종료코드를 단언한다(실제 Maven 미실행).
# 마지막 줄 "Tests run: N, Passed: M".
set -u
H="$(cd "$(dirname "$0")" && pwd)/harness.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/harness-test.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/pin" "$W/tmp" "$W/repo/CMS-Core/src" "$W/norepo"
cat > "$W/repo/pom.xml" <<'EOF'
<project><modules>
        <module>CMS-Core</module>
        <module>CMS-Admin</module>
</modules></project>
EOF
git -C "$W/repo" init -q
# 가짜 mvn — 인자·실행 디렉터리를 남기고 FAKE_MVN(ok|fail|nobuild)에 따라 Maven 모양 출력.
cat > "$W/bin/mvn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_W/argv"; pwd -P > "$FAKE_W/cwd"
cat <<'OUT'
[INFO] ----------------------< kr.example:CMS-Core >-----------------------
[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.1 s - in kr.example.A
[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 1, Time elapsed: 0.1 s - in kr.example.B
[INFO] Tests run: 8, Failures: 0, Errors: 0, Skipped: 1
[INFO] ----------------------< kr.example:CMS-Admin >----------------------
OUT
case "$FAKE_MVN" in
  ok) printf '%s\n' '[INFO] Tests run: 4, Failures: 0, Errors: 0, Skipped: 0' '[INFO] BUILD SUCCESS'; exit 0 ;;
  fail) printf '%s\n' '[ERROR] Tests run: 4, Failures: 2, Errors: 1, Skipped: 0' '[INFO] BUILD FAILURE'; exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$W/bin/mvn"

run=0 pass=0
check() { run=$((run+1)); if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"; else echo "FAIL: $1 — 기대 [$2] 실제 [$3]"; fi; }
# h <dir> <FAKE_MVN> [인자…] → OUT·RC
h() { local d="$1" f="$2"; shift 2; rm -f "$W/argv"
  OUT="$(cd "$d" && PATH="$W/bin:$PATH" TMPDIR="$W/tmp" FAKE_W="$W" FAKE_MVN="$f" MAVEN_REPO_LOCAL="${PIN:-$W/pin}" bash "$H" "$@" 2>&1)"; RC=$?; }
has() { case "$OUT" in *"$1"*) echo yes ;; *) echo no ;; esac; }
ran() { [ -f "$W/argv" ] && echo yes || echo no; }

h "$W/repo" ok;                         check "인자 없음 → 2·미실행" "2 no" "$RC $(ran)"
h "$W/repo" ok install;                 check "install 거부 → 2·미실행" "2 no" "$RC $(ran)"
check "install 거부 사유 문구" yes "$(has '허용되지 않은 모드: install')"
h "$W/repo" ok clean CMS-Core;          check "clean 거부 → 2" "2 no" "$RC $(ran)"
h "$W/repo" ok test;                    check "모듈 없음 → 2" "2 no" "$RC $(ran)"
h "$W/repo" ok test CMS-Front;          check "허용 목록 밖 모듈 → 2" "2 no" "$RC $(ran)"
h "$W/repo" ok test 'CMS-Core;rm';      check "셸 문자 섞인 모듈 → 2" "2 no" "$RC $(ran)"
h "$W/repo" ok test 'CMS-Core,';        check "끝 쉼표 → 2" "2 no" "$RC $(ran)"
h "$W/repo" ok test CMS-Core extra;     check "여분 인자 → 2" "2 no" "$RC $(ran)"
h "$W/norepo" ok test CMS-Core;         check "git 레포 밖 → 2" "2 no" "$RC $(ran)"
PIN="$W/nope" h "$W/repo" ok test CMS-Core; check "핀 디렉터리 없음 → 2" "2 no" "$RC $(ran)"

h "$W/repo/CMS-Core/src" ok test CMS-Admin
check "성공 — 종료코드 0" 0 "$RC"
check "성공 — 실행 명령 고정" "test -pl CMS-Admin -am -B -ntp -Dmaven.repo.local=$W/pin" "$(cat "$W/argv")"
check "성공 — 하위 디렉터리에서 불러도 레포 루트에서 실행" "$(cd "$W/repo" && pwd -P)" "$(cat "$W/cwd")"
check "성공 — Core 요약(클래스별 줄 이중계산 없음)" yes "$(has '[harness] CMS-Core: Tests run 8, Failures 0, Errors 0, Skipped 1')"
check "성공 — Admin 요약" yes "$(has '[harness] CMS-Admin: Tests run 4, Failures 0, Errors 0, Skipped 0')"
check "성공 — 결과 줄" yes "$(has '[harness] 결과: BUILD SUCCESS (mvn 종료코드 0)')"
check "요약 줄은 [INFO] 접두가 아니다(기록기 이중계산 방지)" 0 "$(printf '%s\n' "$OUT" | grep -c '^\[INFO\].*\[harness\]')"

h "$W/repo" fail test CMS-Core,CMS-Admin
check "실패 — 종료코드 = mvn 종료코드 1" 1 "$RC"
check "실패 — 여러 모듈 인자 전달" "test -pl CMS-Core,CMS-Admin -am -B -ntp -Dmaven.repo.local=$W/pin" "$(cat "$W/argv")"
check "실패 — Admin 실패 수 요약" yes "$(has '[harness] CMS-Admin: Tests run 4, Failures 2, Errors 1, Skipped 0')"
check "실패 — 결과 줄" yes "$(has '[harness] 결과: BUILD FAILURE (mvn 종료코드 1)')"

h "$W/repo" nobuild test CMS-Core
check "BUILD 줄 없음 — 판정 불가 표기" yes "$(has '[harness] 결과: 판정 불가')"
check "BUILD 줄 없음 — 테스트 요약 없는 모듈 0 표기" yes "$(has '[harness] CMS-Admin: Tests run 0 (테스트 요약 줄 없음)')"
check "임시 로그 잔여 없음(전 실행)" 0 "$(ls "$W/tmp" | wc -l | tr -d ' ')"

echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ]
