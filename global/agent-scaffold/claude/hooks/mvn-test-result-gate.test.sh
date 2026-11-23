#!/usr/bin/env bash
# mvn-test-result-gate.sh + 짝 훅 mvn-test-record.sh 자체검사(근거 처분 project:검증:2).
# 실행: bash .claude/hooks/mvn-test-result-gate.test.sh
#
# 샌드박스 git 레포를 mktemp 로 만들어 실물 훅에 stdin JSON 을 먹인다. 이 레포의 .claude/.last-mvn-test 는
# 건드리지 않는다(CLAUDE_PROJECT_DIR 을 샌드박스로 덮어쓴다). 정리는 trap EXIT.
# ※ 커밋 명령 문자열은 이 파일 안에만 둔다 — Bash 도구 명령줄에 직접 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
set -u

# HOOKS_DIR_OVERRIDE = 사본 훅 디렉터리(스테이징 수리본 검증용). 기본값은 이 시험 파일이 있는 디렉터리.
HOOKS_DIR="${HOOKS_DIR_OVERRIDE:-$(cd "$(dirname "$0")" && pwd)}"
GATE="$HOOKS_DIR/mvn-test-result-gate.sh"
REC="$HOOKS_DIR/mvn-test-record.sh"

for f in "$GATE" "$REC" "$HOOKS_DIR/lib/git-cmd.sh"; do
  [ -f "$f" ] || { echo "선행조건 실패: $f 없음"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/mvn-test-gate-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

COMMIT_CMD='git commit -m "feat: 샌드박스 커밋 명령(실행되지 않음)"'
BYPASS_CMD="ALLOW_UNTESTED_COMMIT=1 $COMMIT_CMD"
MVN_PL='mvn test -pl {{MODULE_ADMIN}} -am -Dmaven.repo.local={{MAVEN_REPO}}'

run=0; pass=0

assert_eq() { # 설명 기대 실제
  run=$((run + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$1"
  else
    printf '  FAIL  %s\n        기대: [%s]\n        실제: [%s]\n' "$1" "$2" "$3"
  fi
}

mkrepo() { # 번호 → 레포 경로(초기 커밋까지)
  r="$SANDBOX/repo$1"
  mkdir -p "$r/{{MODULE_CORE}}/src/main/java" "$r/.claude"
  git -C "$r" init -q >/dev/null 2>&1
  git -C "$r" config user.email "t@example.com"
  git -C "$r" config user.name "t"
  : > "$r/.gitignore"
  git -C "$r" add .gitignore >/dev/null 2>&1
  git -C "$r" commit -q -m init >/dev/null 2>&1
  printf '%s' "$r"
}

stage_java() { # 레포 → A.java 스테이징
  printf 'class A {}\n' > "$1/{{MODULE_CORE}}/src/main/java/A.java"
  git -C "$1" add {{MODULE_CORE}}/src/main/java/A.java >/dev/null 2>&1
}

jmtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

numeric() { # 값이 0-9 로만 이뤄졌으면 num, 아니면 other
  case "${1:-}" in
    ''|*[!0-9]*) printf 'other' ;;
    *) printf 'num' ;;
  esac
}

# write_rec <repo> <epoch> <status> <모듈인자> [Tests run 총계 — 생략 시 12] [범위 — 생략 시 full]
# 5번째 인자에 빈 문자열을 주면 **구 형식(3필드)** 기록을 흉내 낸다(총계 미상).
# 6번째 인자에 빈 문자열을 주면 **구 형식(4필드 — 범위 없음·종료 시각 기록)** 을 흉내 낸다.
write_rec() {
  if [ "$#" -ge 5 ] && [ -z "$5" ]; then
    printf '%s %s %s\n' "$2" "$3" "$4" > "$1/.claude/.last-mvn-test"; return
  fi
  _t=12; [ "$#" -ge 5 ] && _t="$5"
  if [ "$#" -ge 6 ] && [ -z "$6" ]; then
    printf '%s %s %s %s\n' "$2" "$3" "$4" "$_t" > "$1/.claude/.last-mvn-test"
  else
    printf '%s %s %s %s %s\n' "$2" "$3" "$4" "$_t" "${6:-full}" > "$1/.claude/.last-mvn-test"
  fi
}

# age <파일> <초> — mtime 을 지금보다 <초> 전으로(테스트 시작 전에 고친 편집을 흉내 낸다).
age() { touch -t "$(date -r "$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - $2 ))" +%Y%m%d%H%M.%S)" "$1"; }

pre_json() { jq -n --arg c "$1" --arg d "$2" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

# post_json <cmd> <repo> <출력> [duration_ms — 생략 시 1000, "none" 이면 필드 없음]
post_json() { jq -n --arg c "$1" --arg d "$2" --arg o "$3" --arg ms "${4:-1000}" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:"toolu_test",cwd:$d,tool_input:{command:$c},tool_response:{stdout:$o,stderr:""}}
   + (if $ms == "none" then {} else {duration_ms:($ms|tonumber)} end)'; }

gate() { # cmd repo → permissionDecision(없으면 none)
  o=$(pre_json "$1" "$2" | CLAUDE_PROJECT_DIR="$2" bash "$GATE" 2>/dev/null)
  if [ -z "$o" ]; then printf 'none'; else
    printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null || printf 'parse-error'
  fi
}

record() { # cmd repo 출력 [duration_ms] → 기록파일 내용(없으면 NONE)
  post_json "$1" "$2" "$3" "${4:-1000}" | CLAUDE_PROJECT_DIR="$2" bash "$REC" >/dev/null 2>&1
  if [ -f "$2/.claude/.last-mvn-test" ]; then cat "$2/.claude/.last-mvn-test"; else printf 'NONE'; fi
}

echo "── 게이트(PreToolUse) ────────────────────────────────"

# G1 양성: 기록 자체가 없다 → deny
r=$(mkrepo g1); stage_java "$r"
assert_eq "G1 양성: staged .java + mvn test 기록 없음 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# H1·H2 계약(2026-09-18 허용 목록 재설계): 히어독 본문은 데이터 싱크가 문서·데이터 확장자로 쓸 때만 판정에서 빠진다.
#   H1(문서로 쓰기만) = none(오탐 해소) · H2(스크립트로 쓰고 실행) = deny(미탐 방지). 3라운드 원문 판정 판에선 H1 이
#   deny 였고, 그 전 스트립 판(F5)에선 H2 가 none 이었다 — 둘의 엇갈림이 재설계의 반증이다. 다른 차단형 가드의
#   같은 계약 = blocking-heredoc-contract.test.sh.
r=$(mkrepo h1); stage_java "$r"
assert_eq "H1 계약: 히어독 본문(문서 쓰기)의 커밋 문구 → 통과(허용 목록)" "none" "$(gate "$(printf 'cat > note.md <<EOF\n%s\nEOF' "$COMMIT_CMD")" "$r")"
r=$(mkrepo h2); stage_java "$r"
assert_eq "H2 계약: 히어독으로 스크립트를 쓰고 실행 → deny" "deny" "$(gate "$(printf 'cat <<EOF > run.sh\n%s\nEOF\nbash run.sh' "$COMMIT_CMD")" "$r")"

# G2 양성: 기록이 FAILURE(시각은 최신) → deny
r=$(mkrepo g2); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/{{MODULE_CORE}}/src/main/java/A.java") + 100 ))" FAILURE {{MODULE_ADMIN}}
assert_eq "G2 양성: 마지막 결과가 FAILURE → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# G3 양성: SUCCESS 지만 소스보다 오래된 기록 → deny
r=$(mkrepo g3); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/{{MODULE_CORE}}/src/main/java/A.java") - 100 ))" SUCCESS {{MODULE_ADMIN}}
assert_eq "G3 양성: SUCCESS 기록이 staged .java mtime 보다 오래됨 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# G4 음성: SUCCESS 이고 소스보다 새 기록 → 통과
r=$(mkrepo g4); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/{{MODULE_CORE}}/src/main/java/A.java") + 100 ))" SUCCESS {{MODULE_ADMIN}}
assert_eq "G4 음성: 신선한 SUCCESS 기록 → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# G5 음성: staged 에 .java 가 없다(문서만) → 통과
r=$(mkrepo g5)
printf '# doc\n' > "$r/README.md"; git -C "$r" add README.md >/dev/null 2>&1
assert_eq "G5 음성: staged 에 .java 없음(md 만) → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# G6 음성: 커밋 명령이 아니다 → 통과
r=$(mkrepo g6); stage_java "$r"
assert_eq "G6 음성: 커밋이 아닌 git 명령(status) → 통과" "none" "$(gate 'git status --short' "$r")"

# G7 우회: ALLOW_UNTESTED_COMMIT=1
r=$(mkrepo g7); stage_java "$r"
assert_eq "G7 우회: ALLOW_UNTESTED_COMMIT=1 접두 → 통과" "none" "$(gate "$BYPASS_CMD" "$r")"

# G8 음성: 다른 레포({{MODULE_CORE}} 구조 없음)에서의 커밋 → 관여하지 않음
r2="$SANDBOX/foreign"; mkdir -p "$r2/.claude"
git -C "$r2" init -q >/dev/null 2>&1
git -C "$r2" config user.email "t@example.com"; git -C "$r2" config user.name "t"
mkdir -p "$r2/src"; printf 'class B {}\n' > "$r2/src/B.java"
git -C "$r2" add src/B.java >/dev/null 2>&1
o=$(pre_json "$COMMIT_CMD" "$r2" | CLAUDE_PROJECT_DIR="$r2" bash "$GATE" 2>/dev/null)
assert_eq "G8 음성: 이 레포 구조가 아닌 트리 → 관여 안 함" "" "$o"

# G9 양성: 하위 디렉터리 cwd 에서도 막혀야 한다
# 회귀 근거: staged 경로는 레포 루트 기준인데 cwd 로 조합해 [ -f ] 가 전부 실패 → newest=0 → 무검문 통과였다
# (2026-09-18 실측: cwd=<repo>/docs/... 에서 이 게이트가 조용히 allow).
r=$(mkrepo g9); stage_java "$r"
mkdir -p "$r/docs/deep/dir"
assert_eq "G9 전제: 루트 cwd 에서는 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
o=$(pre_json "$COMMIT_CMD" "$r/docs/deep/dir" | CLAUDE_PROJECT_DIR="$r" bash "$GATE" 2>/dev/null)
d=$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null)
assert_eq "G9 양성: 하위 디렉터리 cwd 에서도 deny(조용한 통과 금지)" "deny" "${d:-none}"

# G10 양성: SUCCESS 인데 Tests run 총계가 0 → deny(미실행 = 미반증)
r=$(mkrepo g10); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/{{MODULE_CORE}}/src/main/java/A.java") + 100 ))" SUCCESS {{MODULE_ADMIN}} 0
assert_eq "G10 양성: SUCCESS + Tests run 0 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# G11 양성: 구 형식(총계 필드 없음) 기록 → 미상이므로 deny
r=$(mkrepo g11); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/{{MODULE_CORE}}/src/main/java/A.java") + 100 ))" SUCCESS {{MODULE_ADMIN}} ""
assert_eq "G11 양성: 총계 필드 없는 구 형식 기록 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

echo "── 기록기(PostToolUse) ──────────────────────────────"

# R1 양성: mvn test + BUILD SUCCESS → SUCCESS·모듈 인자·Tests run 총계 기록
r=$(mkrepo r1)
line=$(record "$MVN_PL" "$r" $'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n')
assert_eq "R1 양성: BUILD SUCCESS → 상태·모듈 인자·총계 기록" "SUCCESS {{MODULE_ADMIN}} 12 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

# R1b: epoch 자리가 숫자인가
assert_eq "R1b: 첫 필드가 epoch(숫자)" "num" "$(numeric "$(printf '%s' "$line" | cut -d' ' -f1)")"

# R2 양성: BUILD FAILURE
r=$(mkrepo r2)
line=$(record "$MVN_PL" "$r" $'[ERROR] Tests run: 12, Failures: 1, Errors: 0, Skipped: 0\n[INFO] BUILD FAILURE\n')
assert_eq "R2 양성: BUILD FAILURE → FAILURE 기록" "FAILURE {{MODULE_ADMIN}} 12 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

# R3 음성: mvn test 명령이 아님
r=$(mkrepo r3)
assert_eq "R3 음성: mvn test 아닌 명령 → 기록 없음" "NONE" "$(record 'ls -la' "$r" '[INFO] BUILD SUCCESS')"

# R4 음성: tool_response 가 객체가 아님(형식 변화) → 침묵
r=$(mkrepo r4)
jq -n --arg c "$MVN_PL" --arg d "$r" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:"BUILD SUCCESS"}' \
  | CLAUDE_PROJECT_DIR="$r" bash "$REC" >/dev/null 2>&1
assert_eq "R4: tool_response 가 객체 아님 → UNKNOWN 기록(판정 불가 = 커밋 근거 아님)" "UNKNOWN {{MODULE_ADMIN}} 0 full" \
  "$([ -f "$r/.claude/.last-mvn-test" ] && cut -d' ' -f2- "$r/.claude/.last-mvn-test" || printf 'NONE')"

# R5: -pl 없는 전체 빌드 → 모듈 인자 "-"
r=$(mkrepo r5)
line=$(record 'mvn clean test -Dmaven.repo.local={{MAVEN_REPO}}' "$r" \
  $'[INFO] Tests run: 7, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n')
assert_eq "R5: -pl 없음 → 모듈 인자 '-'" "SUCCESS - 7 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

# R6: BUILD 결과 문구가 없음 → UNKNOWN(이전 SUCCESS 무효화 — 아래 N6)
r=$(mkrepo r6)
assert_eq "R6: 출력에 BUILD 결과 문구 없음 → UNKNOWN 기록" "UNKNOWN {{MODULE_ADMIN}} 3 full" "$(record "$MVN_PL" "$r" '[INFO] Tests run: 3, Failures: 0' | cut -d' ' -f2-)"

# R7: BUILD SUCCESS 인데 테스트가 한 건도 안 돌았다 → 총계 0 으로 기록(미실행 = 미반증 — 게이트 ③이 막는다)
r=$(mkrepo r7)
assert_eq "R7: SUCCESS + Tests run 줄 없음(skipTests) → 총계 0 기록" "SUCCESS {{MODULE_ADMIN}} 0 full" \
  "$(record "$MVN_PL" "$r" $'[INFO] Nothing to compile\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"

r=$(mkrepo r7b)
assert_eq "R7b: SUCCESS + Tests run: 0 → 총계 0 기록" "SUCCESS {{MODULE_ADMIN}} 0 full" \
  "$(record "$MVN_PL" "$r" $'[INFO] Tests run: 0, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"

# R8: 클래스별 줄(`- in <FQCN>`)은 모듈 요약과 이중계산하지 않는다 — 리액터 2모듈 합계 = 12 + 5
r=$(mkrepo r8)
line=$(record "$MVN_PL" "$r" $'[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.1 s - in com.example.AT\n[INFO] Tests run: 9, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 0.2 s - in com.example.BT\n[INFO] Results:\n[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n')
assert_eq "R8: 모듈 요약만 합산(클래스별 줄 제외) → 17" "SUCCESS {{MODULE_ADMIN}} 17 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

# R9 양성: FAILURE 는 총계가 0 이어도 기록한다(실패 사실이 게이트의 근거다)
r=$(mkrepo r9)
line=$(record "$MVN_PL" "$r" $'[ERROR] 컴파일 실패\n[INFO] BUILD FAILURE\n')
assert_eq "R9: FAILURE 는 총계 0 이어도 기록" "FAILURE {{MODULE_ADMIN}} 0 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

echo "── 통합(기록 → 게이트) ──────────────────────────────"

# I1: 기록기가 SUCCESS 를 남기면 같은 레포의 게이트가 풀린다
r=$(mkrepo i1); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60
record "$MVN_PL" "$r" $'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "I1: 기록기 SUCCESS(총계 12) 직후 커밋 → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# I3: 초록이어도 한 건도 안 돌았으면 기록이 없어 여전히 막힌다
r=$(mkrepo i3); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60
record "$MVN_PL" "$r" $'[INFO] Tests run: 0, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "I3: SUCCESS 지만 Tests run 0 → 커밋은 여전히 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# I2: 그 뒤 소스를 더 고치면 다시 막힌다
sleep 1
printf 'class A { int x; }\n' > "$r/{{MODULE_CORE}}/src/main/java/A.java"
git -C "$r" add {{MODULE_CORE}}/src/main/java/A.java >/dev/null 2>&1
assert_eq "I2: 기록 이후 소스 변경 → 다시 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

echo "── 실패 이벤트(PostToolUseFailure) ──────────────────"
# 계약(공식 hooks 문서): Bash 종료코드≠0 이면 PostToolUse 가 아니라 PostToolUseFailure 가 불리고,
#   입력은 tool_response 없이 .error("Exit code N" + 출력, 중간 절단 가능) 를 싣는다.
fail_json() { jq -n --arg c "$1" --arg d "$2" --arg e "$3" \
  '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",cwd:$d,tool_input:{command:$c},error:$e}'; }
record_fail() { # cmd repo error → 기록파일 내용(없으면 NONE)
  fail_json "$1" "$2" "$3" | CLAUDE_PROJECT_DIR="$2" bash "$REC" >/dev/null 2>&1
  if [ -f "$2/.claude/.last-mvn-test" ]; then cat "$2/.claude/.last-mvn-test"; else printf 'NONE'; fi
}

# F1: 실패 이벤트는 FAILURE 로 기록된다(.error 에 BUILD 문구가 절단돼 없어도)
r=$(mkrepo f1)
line=$(record_fail "$MVN_PL" "$r" $'Exit code 1\n[INFO] Tests run: 12, Failures: 1\n... [9000 characters truncated] ...\n[ERROR] Failed to execute goal')
assert_eq "F1: PostToolUseFailure(mvn test) → FAILURE 기록" "FAILURE {{MODULE_ADMIN}} 0 full" "$(printf '%s' "$line" | cut -d' ' -f2-)"

# F2 핵심 회귀: 신선한 SUCCESS 뒤 같은 소스로 mvn test 가 실패(exit≠0)하면 게이트가 다시 막혀야 한다
r=$(mkrepo f2); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60
record "$MVN_PL" "$r" $'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "F2 전제: SUCCESS 직후 → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"
record_fail "$MVN_PL" "$r" $'Exit code 1\n[ERROR] Tests run: 12, Failures: 1, Errors: 0, Skipped: 0\n[INFO] BUILD FAILURE\n' >/dev/null
assert_eq "F2: SUCCESS 뒤 실패 이벤트 → deny(낡은 SUCCESS 불신)" "deny" "$(gate "$COMMIT_CMD" "$r")"

# F3 음성: mvn test 가 아닌 명령의 실패는 기존 SUCCESS 를 건드리지 않는다
r=$(mkrepo f3); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60
record "$MVN_PL" "$r" $'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
record_fail 'ls /nonexistent' "$r" $'Exit code 1\nls: /nonexistent: No such file' >/dev/null
assert_eq "F3 음성: 비-mvn 실패 → SUCCESS 유지(통과)" "none" "$(gate "$COMMIT_CMD" "$r")"

# F4 음성: 다른 레포 구조에서의 실패는 기록하지 않는다
r2="$SANDBOX/foreign-f4"; mkdir -p "$r2/.claude"; git -C "$r2" init -q >/dev/null 2>&1
fail_json "$MVN_PL" "$r2" 'Exit code 1' | CLAUDE_PROJECT_DIR="$r2" bash "$REC" >/dev/null 2>&1
assert_eq "F4 음성: 남의 레포 실패 → 기록 없음" "NONE" "$([ -f "$r2/.claude/.last-mvn-test" ] && cat "$r2/.claude/.last-mvn-test" || printf 'NONE')"

# F5: 기록을 쓰지도 지우지도 못하면(.claude 읽기 전용) 낡은 SUCCESS 가 남는다 → exit 2 로 크게 알린다
r=$(mkrepo f5); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60
record "$MVN_PL" "$r" $'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
chmod 555 "$r/.claude"
fail_json "$MVN_PL" "$r" 'Exit code 1' | CLAUDE_PROJECT_DIR="$r" bash "$REC" >/dev/null 2>&1; rc=$?
chmod 755 "$r/.claude"
assert_eq "F5: 실패 기록·기존 기록 삭제 모두 불가 → exit 2(크게 알림)" "2" "$rc"

echo "── 결함 ⑤ (a) 신선도 축 = 테스트 시작 시각 ─────────"
OK12=$'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n'
A={{MODULE_CORE}}/src/main/java/A.java

# A1: 60초 걸린 mvn test 의 30초째에 고친 편집 → 그 편집은 검증되지 않았다
r=$(mkrepo a1); stage_java "$r"; age "$r/$A" 30
record "$MVN_PL" "$r" "$OK12" 60000 >/dev/null
assert_eq "A1 양성: 테스트 도중 편집(시작 이후 mtime) → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# A2 음성: 편집이 시작 전(120초 전)이면 통과
r=$(mkrepo a2); stage_java "$r"; age "$r/$A" 120
record "$MVN_PL" "$r" "$OK12" 60000 >/dev/null
assert_eq "A2 음성: 시작 전 편집 + 60초 실행 SUCCESS → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

# A3: 기록 epoch 는 시작 시각(훅 시각 − 실행 시간) 이하다
r=$(mkrepo a3); before=$(date +%s)
line=$(record "$MVN_PL" "$r" "$OK12" 60000)
ep=$(printf '%s' "$line" | cut -d' ' -f1)
assert_eq "A3: 기록 epoch ≤ 기록 직전 시각 − 60초" "yes" "$([ "$(numeric "$ep")" = num ] && [ "$ep" -le $(( before - 60 + 1 )) ] && echo yes || echo no)"

# A4: duration_ms 가 없으면(공식 문서상 선택 필드) SUCCESS 는 기록하지 않는다
r=$(mkrepo a4)
assert_eq "A4 양성: duration_ms 없음 + SUCCESS → 기록 없음" "NONE" "$(record "$MVN_PL" "$r" "$OK12" none)"

# A5: duration_ms 가 숫자가 아니면(신뢰 밖 입력) 기록 무효
r=$(mkrepo a5)
jq -n --arg c "$MVN_PL" --arg d "$r" --arg o "$OK12" \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c},tool_response:{stdout:$o,stderr:""},duration_ms:"1000"}' \
  | CLAUDE_PROJECT_DIR="$r" bash "$REC" >/dev/null 2>&1
assert_eq "A5 양성: duration_ms 문자열 → 기록 없음" "NONE" "$([ -f "$r/.claude/.last-mvn-test" ] && cat "$r/.claude/.last-mvn-test" || printf 'NONE')"

# A6 경계: 기록 시각과 최신 mtime 이 같은 초 → 미검증으로 본다
r=$(mkrepo a6); stage_java "$r"
write_rec "$r" "$(jmtime "$r/$A")" SUCCESS {{MODULE_ADMIN}}
assert_eq "A6 경계: 기록 epoch == staged mtime → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

echo "── 결함 ⑤ (b) 매퍼 XML·리소스 모집단 ──────────────"
X={{MODULE_CORE}}/src/main/resources/egovframework/mapper/x/X_sql.xml
# B1: 매퍼 XML 만 스테이징, 기록 없음 → deny
r=$(mkrepo b1); mkdir -p "$r/${X%/*}"; printf '<mapper/>\n' > "$r/$X"; git -C "$r" add "$X" >/dev/null 2>&1
assert_eq "B1 양성: 매퍼 XML 만 staged + 기록 없음 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
# B2: 매퍼 XML 을 기록 이후 고쳤다 → deny
r=$(mkrepo b2); mkdir -p "$r/${X%/*}"; printf '<mapper/>\n' > "$r/$X"; git -C "$r" add "$X" >/dev/null 2>&1
write_rec "$r" "$(( $(jmtime "$r/$X") - 100 ))" SUCCESS {{MODULE_ADMIN}}
assert_eq "B2 양성: 기록 이후 매퍼 XML 변경 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
# B3 음성: 매퍼 XML + 신선한 기록 → 통과
r=$(mkrepo b3); mkdir -p "$r/${X%/*}"; printf '<mapper/>\n' > "$r/$X"; git -C "$r" add "$X" >/dev/null 2>&1
write_rec "$r" "$(( $(jmtime "$r/$X") + 100 ))" SUCCESS {{MODULE_ADMIN}}
assert_eq "B3 음성: 매퍼 XML + 신선한 full SUCCESS → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"
# B4: src/test 아래 리소스(테스트 픽스처) → deny
r=$(mkrepo b4); T={{MODULE_FRONT}}/src/test/resources/templates/t.html; mkdir -p "$r/${T%/*}"; printf 'x\n' > "$r/$T"; git -C "$r" add "$T" >/dev/null 2>&1
assert_eq "B4 양성: src/test 리소스만 staged + 기록 없음 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
# B5 음성: 템플릿·정적 자원만(src/main/resources/templates·static) → 관여 안 함
r=$(mkrepo b5); T={{MODULE_ADMIN}}/src/main/resources/templates/a.html; J={{MODULE_ADMIN}}/src/main/resources/static/js/a.js
mkdir -p "$r/${T%/*}" "$r/${J%/*}"; printf 'x\n' > "$r/$T"; printf 'x\n' > "$r/$J"; git -C "$r" add "$T" "$J" >/dev/null 2>&1
assert_eq "B5 음성: 템플릿·정적 JS 만 staged → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"
# B6: pom.xml → deny
r=$(mkrepo b6); printf '<project/>\n' > "$r/pom.xml"; git -C "$r" add pom.xml >/dev/null 2>&1
assert_eq "B6 양성: pom.xml 만 staged + 기록 없음 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

echo "── 결함 ⑤ (c) 부분 실행·-am 누락 ───────────────────"
MVN_DT='mvn test -pl {{MODULE_ADMIN}} -am -Dtest=FooTest -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.repo.local={{MAVEN_REPO}}'
OK1=$'[INFO] Tests run: 1, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n'
# C1: -Dtest= 단건 SUCCESS → 기록 없음 → 커밋 deny
r=$(mkrepo c1); stage_java "$r"; age "$r/$A" 60
assert_eq "C1 양성: -Dtest= 단건 SUCCESS → 기록 없음" "NONE" "$(record "$MVN_DT" "$r" "$OK1")"
assert_eq "C1b 양성: -Dtest= 단건 SUCCESS 뿐 → 커밋 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
# C2: -pl {{MODULE_ADMIN}} 에 -am 없음 → 기록 없음
r=$(mkrepo c2)
assert_eq "C2 양성: -am 없는 -pl {{MODULE_ADMIN}} SUCCESS → 기록 없음" "NONE" "$(record 'mvn test -pl {{MODULE_ADMIN}} -Dmaven.repo.local=/x' "$r" "$OK12")"
# C3 음성: 리프 {{MODULE_CORE}} 만이면 -am 없이도 full
r=$(mkrepo c3c)
assert_eq "C3c 음성: -pl {{MODULE_CORE}},{{MODULE_ADMIN}}(Core 동반) -am 없음 → full 기록" "SUCCESS {{MODULE_CORE}},{{MODULE_ADMIN}} 12 full" "$(record 'mvn test -pl {{MODULE_CORE}},{{MODULE_ADMIN}} -Dmaven.repo.local=/x' "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo c3)
assert_eq "C3 음성: -pl {{MODULE_CORE}}(리프) -am 없음 → full 기록" "SUCCESS {{MODULE_CORE}} 12 full" "$(record 'mvn test -pl {{MODULE_CORE}} -Dmaven.repo.local=/x' "$r" "$OK12" | cut -d' ' -f2-)"
# C4: 공백 분리 -D test=X · --define → partial
r=$(mkrepo c4)
assert_eq "C4 양성: '-D test=X'(공백 분리) → 기록 없음" "NONE" "$(record 'mvn test -pl {{MODULE_ADMIN}} -am -D test=FooTest' "$r" "$OK1")"
r=$(mkrepo c4b)
assert_eq "C4b 양성: --define test=X → 기록 없음" "NONE" "$(record 'mvn test -pl {{MODULE_ADMIN}} -am --define test=FooTest' "$r" "$OK1")"
# C5: -Dit.test= · -rf → partial
r=$(mkrepo c5)
assert_eq "C5 양성: -Dit.test= → 기록 없음" "NONE" "$(record 'mvn test -pl {{MODULE_ADMIN}} -am -Dit.test=FooIT' "$r" "$OK12")"
r=$(mkrepo c5b)
assert_eq "C5b 양성: -rf :{{MODULE_ADMIN}} → 기록 없음" "NONE" "$(record 'mvn test -rf :{{MODULE_ADMIN}}' "$r" "$OK12")"
# C11: -pl 제외 지정(!모듈) → partial(-am 이 있어도)
r=$(mkrepo c11)
assert_eq "C11 양성: -pl '!{{MODULE_FRONT}}' -am → 기록 없음" "NONE" "$(record "mvn test -pl !{{MODULE_FRONT}} -am -Dmaven.repo.local=/x" "$r" "$OK12")"
# C7: 부분 실행의 SUCCESS 는 앞선 full SUCCESS 를 덮지 않는다(그 기록의 시작 시각 이후 변경은 어차피 막힌다)
r=$(mkrepo c7); stage_java "$r"; age "$r/$A" 120
record "$MVN_PL" "$r" "$OK12" 1000 >/dev/null
record "$MVN_DT" "$r" "$OK1" >/dev/null
assert_eq "C7 음성: full SUCCESS 뒤 부분 SUCCESS → full 기록 유지(통과)" "none" "$(gate "$COMMIT_CMD" "$r")"
# C8: 부분 실행의 실패는 partial FAILURE 로 덮는다
r=$(mkrepo c8)
fail_json "$MVN_DT" "$r" 'Exit code 1' | CLAUDE_PROJECT_DIR="$r" bash "$REC" >/dev/null 2>&1
assert_eq "C8: 부분 실행 실패 → FAILURE … partial 기록" "FAILURE {{MODULE_ADMIN}} 0 partial" "$(cut -d' ' -f2- "$r/.claude/.last-mvn-test" 2>/dev/null)"
# C9: 게이트 — 범위 partial 기록(SUCCESS 라도) · 구 형식(4필드) 기록 → deny
r=$(mkrepo c9); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/$A") + 100 ))" SUCCESS {{MODULE_ADMIN}} 12 partial
assert_eq "C9 양성: SUCCESS 지만 범위 partial → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo c9b); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/$A") + 100 ))" SUCCESS {{MODULE_ADMIN}} 12 ""
assert_eq "C9b 양성: 범위 필드 없는 구 형식(4필드) → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo c9c); stage_java "$r"
printf '%s SUCCESS {{MODULE_ADMIN}} 12 full junk\n' "$(( $(jmtime "$r/$A") + 100 ))" > "$r/.claude/.last-mvn-test"
assert_eq "C9c 양성: 필드 6개(형식 불량) → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
# C10: 우회 의미 유지 — partial 기록이어도 ALLOW_UNTESTED_COMMIT=1 접두면 통과
r=$(mkrepo c10); stage_java "$r"
write_rec "$r" "$(( $(jmtime "$r/$A") + 100 ))" SUCCESS {{MODULE_ADMIN}} 12 partial
assert_eq "C10 우회: partial 기록 + ALLOW_UNTESTED_COMMIT=1 → 통과" "none" "$(gate "$BYPASS_CMD" "$r")"

echo "── 2라운드: 실패 무시 옵션·허용 목록·하위 모듈·체인·삭제·판정 불가 ──"
FAIL3_OK=$'[ERROR] Tests run: 12, Failures: 3, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n'
ERR1_OK=$'[ERROR] Tests run: 12, Failures: 0, Errors: 1, Skipped: 0\n[INFO] BUILD SUCCESS\n'
P={{MAVEN_REPO}}
# N2: -fn/--fail-never·-Dmaven.test.failure.ignore 류 — BUILD SUCCESS 라도 요약 줄 Failures·Errors>0 이면 FAILURE
r=$(mkrepo n2a)
assert_eq "N2a 양성: -fn + Failures 3 + BUILD SUCCESS → FAILURE(partial)" "FAILURE {{MODULE_ADMIN}} 12 partial" "$(record "$MVN_PL -fn" "$r" "$FAIL3_OK" | cut -d' ' -f2-)"
r=$(mkrepo n2b)
assert_eq "N2b 양성: -Dmaven.test.failure.ignore=true + Errors 1 → FAILURE" "FAILURE {{MODULE_ADMIN}} 12 partial" "$(record "$MVN_PL -Dmaven.test.failure.ignore=true" "$r" "$ERR1_OK" | cut -d' ' -f2-)"
r=$(mkrepo n2c)
assert_eq "N2c 양성: 옵션 없이도 요약 줄 Failures>0 + BUILD SUCCESS → FAILURE" "FAILURE {{MODULE_ADMIN}} 12 full" "$(record "$MVN_PL" "$r" "$FAIL3_OK" | cut -d' ' -f2-)"
r=$(mkrepo n2d)
assert_eq "N2d 양성: --fail-never(실패 0건) → partial = 기록 없음" "NONE" "$(record "$MVN_PL --fail-never" "$r" "$OK12")"
r=$(mkrepo n2e)
assert_eq "N2e 양성: -fae → partial = 기록 없음" "NONE" "$(record "$MVN_PL -fae" "$r" "$OK12")"
r=$(mkrepo n2f)
assert_eq "N2f 양성: 모르는 옵션(-amd) → partial = 기록 없음" "NONE" "$(record "$MVN_PL -amd" "$r" "$OK12")"
r=$(mkrepo n2g)
assert_eq "N2g 양성: 목록 밖 프로필(-Pfast) → partial = 기록 없음" "NONE" "$(record "$MVN_PL -Pfast" "$r" "$OK12")"
r=$(mkrepo n2h)
assert_eq "N2h 음성: 허용 옵션(-q -o -Plocal -B clean)·리디렉션·파이프 → full" "SUCCESS {{MODULE_ADMIN}} 12 full" \
  "$(record "mvn -q -o -B clean test -Plocal -pl {{MODULE_ADMIN}} -am -Dmaven.repo.local=$P > /tmp/x.log 2>&1 | tail -40" "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo n2i)
assert_eq "N2i 음성: 앞 조각의 echo 안내 문구 속 mvn → 데이터로 보고 full" "SUCCESS {{MODULE_ADMIN}} 12 full" \
  "$(record "echo \"== mvn test 전체 · 변이 확인 ==\"; $MVN_PL" "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo n2j)
assert_eq "N2j 양성: bash -c 안의 -Dtest= → partial = 기록 없음" "NONE" "$(record "bash -c \"mvn test -pl {{MODULE_ADMIN}} -am -Dtest=Foo\"" "$r" "$OK1")"
r=$(mkrepo n2k)
assert_eq "N2k 양성: xargs 뒤 mvn 의 -fn → partial = 기록 없음" "NONE" "$(record "echo x | xargs mvn test -pl {{MODULE_ADMIN}} -am -fn" "$r" "$OK12")"
r=$(mkrepo n2l)
assert_eq "N2l 양성: 줄 잇기 뒤의 -pl(‑am 없음) → partial = 기록 없음" "NONE" "$(record $'mvn test \\\n  -pl {{MODULE_ADMIN}} -Dmaven.repo.local=/x' "$r" "$OK12")"
r=$(mkrepo n2m)
assert_eq "N2m 양성: -pl 셸 변수 전개 → partial = 기록 없음" "NONE" "$(record 'for P in {{MODULE_ADMIN}}; do mvn test -pl $P -am ; done' "$r" "$OK12")"

# N3: 하위 모듈 디렉터리 실행 = 의존 Core 가 옛 jar → partial
r=$(mkrepo n3a); mkdir -p "$r/{{MODULE_ADMIN}}"
assert_eq "N3a 양성: cd {{MODULE_ADMIN}} && mvn test → 기록 없음" "NONE" "$(record "cd {{MODULE_ADMIN}} && mvn test -Dmaven.repo.local=$P" "$r" "$OK12")"
r=$(mkrepo n3b); mkdir -p "$r/{{MODULE_ADMIN}}"
post_json "mvn test -Dmaven.repo.local=$P" "$r/{{MODULE_ADMIN}}" "$OK12" | CLAUDE_PROJECT_DIR="$r" bash "$REC" >/dev/null 2>&1
assert_eq "N3b 양성: cwd={{MODULE_ADMIN}} 에서 mvn test → 기록 없음" "NONE" "$([ -f "$r/.claude/.last-mvn-test" ] && cat "$r/.claude/.last-mvn-test" || printf 'NONE')"
r=$(mkrepo n3c); mkdir -p "$r/{{MODULE_ADMIN}}"; : > "$r/{{MODULE_ADMIN}}/pom.xml"
assert_eq "N3c 양성: -f {{MODULE_ADMIN}}/pom.xml → 기록 없음" "NONE" "$(record "mvn -f {{MODULE_ADMIN}}/pom.xml test -Dmaven.repo.local=$P" "$r" "$OK12")"
r=$(mkrepo n3d); mkdir -p "$r/{{MODULE_ADMIN}}"
assert_eq "N3d 양성: (cd {{MODULE_ADMIN}} && mvn test) → 기록 없음" "NONE" "$(record "(cd {{MODULE_ADMIN}} && mvn test -Dmaven.repo.local=$P)" "$r" "$OK12")"
r=$(mkrepo n3e); : > "$r/pom.xml"
assert_eq "N3e 음성: -f pom.xml(레포 루트) → full" "SUCCESS - 12 full" "$(record "mvn -f pom.xml test -Dmaven.repo.local=$P" "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo n3f); mkdir -p "$r/{{MODULE_ADMIN}}"
assert_eq "N3f 음성: cd {{MODULE_ADMIN}} && cd .. && mvn test → 루트로 돌아와 full" "SUCCESS - 12 full" "$(record "cd {{MODULE_ADMIN}} && cd .. && mvn test -Dmaven.repo.local=$P" "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo n3g)
assert_eq "N3g 음성: cd <레포 절대경로> && mvn test → full" "SUCCESS - 12 full" "$(record "cd $r && mvn test -Dmaven.repo.local=$P" "$r" "$OK12" | cut -d' ' -f2-)"

# N4: 한 호출에 mvn test 여럿 — 하나라도 BUILD FAILURE 면 FAILURE
r=$(mkrepo n4)
assert_eq "N4 양성: ';' 체인 FAILURE 다음 SUCCESS → FAILURE" "FAILURE {{MODULE_FRONT}} 19 full" \
  "$(record "mvn test -pl {{MODULE_ADMIN}} -am -Dmaven.repo.local=$P ; mvn test -pl {{MODULE_FRONT}} -am -Dmaven.repo.local=$P" "$r" $'[ERROR] Tests run: 7, Failures: 1, Errors: 0, Skipped: 0\n[INFO] BUILD FAILURE\n[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo n4c)
assert_eq "N4c 양성: ';' 체인 컴파일 FAILURE(요약 줄 없음) 다음 SUCCESS → FAILURE" "FAILURE {{MODULE_FRONT}} 12 full" \
  "$(record "mvn test -pl {{MODULE_ADMIN}} -am -Dmaven.repo.local=$P ; mvn test -pl {{MODULE_FRONT}} -am -Dmaven.repo.local=$P" "$r" $'[ERROR] COMPILATION ERROR\n[INFO] BUILD FAILURE\n[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo n4b); stage_java "$r"; age "$r/$A" 60
record "$MVN_PL" "$r" "$OK12" >/dev/null
record "$MVN_PL && $MVN_PL" "$r" $'[INFO] BUILD FAILURE\n[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "N4b 양성: 신선 SUCCESS 뒤 '&&' 체인의 FAILURE 포함 → 커밋 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# N5: 삭제만 스테이징한 커밋도 검문한다. keep_dir = git rm 이 빈 상위 디렉터리를 지워 샌드박스의 {{MODULE_CORE}}/src/main
#   (이 레포 판별 조건)까지 사라지지 않게 미추적 파일 하나를 둔다 — 실레포에선 그 디렉터리가 비지 않는다.
keep_dir() { : > "$1/{{MODULE_CORE}}/src/main/.keep"; }
r=$(mkrepo n5a); keep_dir "$r"; stage_java "$r"; git -C "$r" commit -qm a >/dev/null 2>&1
git -C "$r" rm -q "$A" >/dev/null 2>&1
assert_eq "N5a 양성: .java 삭제만 staged + 기록 없음 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n5b); keep_dir "$r"; stage_java "$r"; git -C "$r" commit -qm a >/dev/null 2>&1
git -C "$r" rm -q "$A" >/dev/null 2>&1; age "$r/{{MODULE_CORE}}/src/main" 120   # git rm 이 빈 java/ 를 지워 남은 상위 = src/main
record "$MVN_PL" "$r" "$OK12" >/dev/null
assert_eq "N5b 음성: 삭제가 테스트 시작 전 + full SUCCESS → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n5c); keep_dir "$r"; stage_java "$r"; git -C "$r" commit -qm a >/dev/null 2>&1
write_rec "$r" "$(( $(date +%s) - 100 ))" SUCCESS {{MODULE_ADMIN}}
git -C "$r" rm -q "$A" >/dev/null 2>&1
assert_eq "N5c 양성: 테스트 시작 뒤 삭제(상위 디렉터리 mtime) → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n5d); X2={{MODULE_CORE}}/src/main/resources/egovframework/mapper/x/Y_sql.xml
mkdir -p "$r/${X2%/*}"; printf '<mapper/>\n' > "$r/$X2"; git -C "$r" add "$X2" >/dev/null 2>&1; git -C "$r" commit -qm a >/dev/null 2>&1
write_rec "$r" "$(( $(date +%s) - 100 ))" SUCCESS {{MODULE_ADMIN}}
git -C "$r" rm -q "$X2" >/dev/null 2>&1
assert_eq "N5d 양성: 매퍼 XML 삭제(디렉터리째 사라짐) → 남은 상위 디렉터리 mtime → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n5e); stage_java "$r"; git -C "$r" commit -qm a >/dev/null 2>&1; age "$r/$A" 300
write_rec "$r" "$(( $(date +%s) - 100 ))" SUCCESS {{MODULE_ADMIN}}
git -C "$r" mv "$A" {{MODULE_CORE}}/src/main/java/B.java >/dev/null 2>&1
assert_eq "N5e 양성: 시작 뒤 git mv(파일 mtime 보존) → 옛 경로 삭제로 deny" "deny" "$(gate "$COMMIT_CMD" "$r")"

# N6: 판정 불가·0건 실행이 이전 SUCCESS 를 무효화한다
r=$(mkrepo n6a); stage_java "$r"; age "$r/$A" 60
record "$MVN_PL" "$r" "$OK12" >/dev/null
assert_eq "N6 전제: full SUCCESS → 통과" "none" "$(gate "$COMMIT_CMD" "$r")"
record "$MVN_PL 2>&1 | tail -5" "$r" $'[ERROR] Failed to execute goal\n[ERROR] -> [Help 1]\n' >/dev/null
assert_eq "N6a 양성: | tail 로 BUILD 줄이 잘린 실행 → UNKNOWN → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n6b); stage_java "$r"; age "$r/$A" 60
record "$MVN_PL" "$r" "$OK12" >/dev/null
record "$MVN_PL 2>&1 | grep 'Tests run'" "$r" '' >/dev/null
assert_eq "N6b 양성: | grep 으로 출력이 비어 끝난 실행 → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n6c); stage_java "$r"; age "$r/$A" 60
record "$MVN_PL" "$r" "$OK12" >/dev/null
record "mvn test -pl {{MODULE_ADMIN}} -am -Dtest=NoSuch -Dsurefire.failIfNoSpecifiedTests=false" "$r" $'[INFO] Tests run: 0, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "N6c 양성: full SUCCESS 뒤 0건 SUCCESS → deny" "deny" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n6e); stage_java "$r"; age "$r/$A" 60
record "$MVN_PL" "$r" "$OK12" >/dev/null
record 'bash .claude/hooks/mark-review.sh --skip-reason "소형 A — mvn test -pl {{MODULE_ADMIN}} -am SUCCESS"' "$r" '리뷰 마커 기록' >/dev/null
assert_eq "N6e 음성: 인자 문구 속 mvn test(실행 아님)·BUILD 줄 없음 → 이전 SUCCESS 유지(통과)" "none" "$(gate "$COMMIT_CMD" "$r")"
r=$(mkrepo n6f)
assert_eq "N6f 양성: mvn 실행 없는 로그 열람의 BUILD SUCCESS → partial = 기록 없음" "NONE" "$(record 'cat /tmp/mvn.log  # mvn test 결과' "$r" "$OK12")"
r=$(mkrepo n6g)
assert_eq "N6g: mvn 실행 없는 로그 열람의 BUILD FAILURE → FAILURE(차단 쪽)" "FAILURE - 0 partial" "$(record 'grep BUILD /tmp/mvn.log  # mvn test' "$r" $'[INFO] BUILD FAILURE\n' | cut -d' ' -f2-)"
r=$(mkrepo n6d); stage_java "$r"; write_rec "$r" "$(( $(jmtime "$r/$A") + 100 ))" UNKNOWN {{MODULE_ADMIN}}
assert_eq "N6d 우회: UNKNOWN 기록 + ALLOW_UNTESTED_COMMIT=1 → 통과" "none" "$(gate "$BYPASS_CMD" "$r")"

# L: 인라인 대입·따옴표 속 -D·따옴표 친 -pl 제외 지정
r=$(mkrepo l1)
assert_eq "L1 양성: MAVEN_OPTS=-Dtest=Foo mvn test → 기록 없음" "NONE" "$(record "MAVEN_OPTS=-Dtest=Foo $MVN_PL" "$r" "$OK1")"
r=$(mkrepo l2)
assert_eq "L2 양성: MAVEN_ARGS=-Dtest=Foo mvn test → 기록 없음" "NONE" "$(record "MAVEN_ARGS=-Dtest=Foo $MVN_PL" "$r" "$OK1")"
r=$(mkrepo l3)
assert_eq "L3 양성: -D\"test=Foo\" → 기록 없음" "NONE" "$(record "$MVN_PL -D\"test=Foo\"" "$r" "$OK1")"
r=$(mkrepo l4)
assert_eq "L4 양성: -pl '!{{MODULE_FRONT}}' -am(따옴표) → 기록 없음" "NONE" "$(record "mvn test -pl '!{{MODULE_FRONT}}' -am -Dmaven.repo.local=$P" "$r" "$OK12")"
r=$(mkrepo l5)
assert_eq "L5 음성: 허용 환경 대입(JAVA_HOME=…) → full" "SUCCESS {{MODULE_ADMIN}} 12 full" "$(record "JAVA_HOME=/x $MVN_PL" "$r" "$OK12" | cut -d' ' -f2-)"
r=$(mkrepo l6)
assert_eq "L6 양성: MAVEN_ARGS=-fn 인라인 대입(-D 아님) → 기록 없음" "NONE" "$(record "MAVEN_ARGS=-fn $MVN_PL" "$r" "$OK12")"

# J: 한 명령에 jsharness 와 mvn test — 총계·실패 판정은 Surefire 접두([INFO]/[ERROR]/[WARNING]) 줄만 본다
JS_RED='Tests run: 12, Failures: 2, Specs: 3'
JS_GREEN='Tests run: 12, Failures: 0, Specs: 3'
r=$(mkrepo j1)
assert_eq "J1 양성: jsharness 12건 + Surefire 5건 → 총계 5" "SUCCESS {{MODULE_ADMIN}} 5 full" \
  "$(record "node .claude/jsharness/run.js; $MVN_PL" "$r" "$JS_GREEN"$'\n[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo j2)
assert_eq "J2 양성: jsharness 12건 + mvn 0건 → 총계 0" "SUCCESS {{MODULE_ADMIN}} 0 full" \
  "$(record "node .claude/jsharness/run.js; $MVN_PL" "$r" "$JS_GREEN"$'\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo j3)
assert_eq "J3 양성: jsharness 빨간불(Failures 2)은 mvn 판정을 바꾸지 않는다 → SUCCESS" "SUCCESS {{MODULE_ADMIN}} 5 full" \
  "$(record "node .claude/jsharness/run.js; $MVN_PL" "$r" "$JS_RED"$'\n[INFO] Tests run: 5, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo j4); E=$'\033'
assert_eq "J4 음성: 색 코드(-Dstyle.color=always) 붙은 Surefire 줄도 집계 → 총계 7" "SUCCESS {{MODULE_ADMIN}} 7 full" \
  "$(record "$MVN_PL -Dstyle.color=always" "$r" "[${E}[1;34mINFO${E}[m] ${E}[1;32mTests run: 7, Failures: 0, Errors: 0, Skipped: 0${E}[m"$'\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"
r=$(mkrepo j5)
assert_eq "J5 음성: [WARNING] 요약 줄(Skipped>0)도 집계 → 총계 9" "SUCCESS {{MODULE_ADMIN}} 9 full" \
  "$(record "$MVN_PL" "$r" $'[WARNING] Tests run: 9, Failures: 0, Errors: 0, Skipped: 1\n[INFO] BUILD SUCCESS\n' | cut -d' ' -f2-)"

echo "── 선형 줄 잇기 펴기(2026-11-06, 기록기) ──"
_lsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-sed.XXXXXX") || exit 2
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log"\nexec /usr/bin/sed "$@"\n' "$_lsh" > "$_lsh/sed"; chmod +x "$_lsh/sed"; : > "$_lsh/log"
_unf_used() { grep -qF 'H;${x;s/' "$_lsh/log" && echo yes || echo no; }   # 선형 펴기 sed 스크립트가 불렸는가
r=$(mkrepo lin1)
_o=$(PATH="$_lsh:$PATH" record "$(printf 'mvn \\\n%s' "${MVN_PL#mvn }")" "$r" $'[INFO] Tests run: 3, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n')
assert_eq "선형 펴기: 줄 잇기 mvn test 기록됨" "SUCCESS" "$(printf '%s' "$_o" | cut -d' ' -f2)"
assert_eq "선형 펴기: 줄 잇기 있으면 sed 1회 경로" "yes" "$(_unf_used)"
: > "$_lsh/log"; r=$(mkrepo lin2); PATH="$_lsh:$PATH" record "$MVN_PL" "$r" $'[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음" "no" "$(_unf_used)"
rm -rf "$_lsh"

echo "── r2 리뷰: 채택·감지·드리프트·구분자 sed ──"
# 2026-11-06 r2 리뷰 — sed 결과 '채택'(센티널 있음)·'감지'(센티널 없음 → 종전 치환)·호출 1회를 가짜 sed 로 고정
_fsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-fake.XXXXXX") || exit 2
cat > "$_fsh/sed" <<'SHIM'
#!/bin/bash
# 가짜 sed — 선형 펴기 스크립트(H;${x;s/…)만 가로챈다: mode=adopt → payload+센티널 x, nosent → payload(센티널 없음, rc 0). 그 밖은 진짜 sed.
d=$(dirname "$0"); printf '%s\n' "$*" >> "$d/log"
case "$*" in *'H;${x;s/'*)
m=$(cat "$d/mode" 2>/dev/null)
if [ "$m" = adopt ]; then cat >/dev/null; printf '%sx\n' "$(cat "$d/payload")"; exit 0; fi
if [ "$m" = nosent ]; then cat >/dev/null; printf '%s\n' "$(cat "$d/payload")"; exit 0; fi ;;
esac
exec /usr/bin/sed "$@"
SHIM
chmod +x "$_fsh/sed"
_fake() { printf '%s' "$1" > "$_fsh/mode"; printf '%s' "$2" > "$_fsh/payload"; : > "$_fsh/log"; }
_fake_n() { grep -cF 'H;${x;s/' "$_fsh/log"; }   # 선형 펴기 sed 호출 수
_unf_drift() { # $1=lib $2=인라인 사본 훅 → same|diff|nolib — sed 스크립트 리터럴과 센티널 비교 줄(변수명 정규화)을 대조
  [ -f "$1" ] || { echo nolib; return; }
  local lit cmp; lit=$(sed -n '/^git_unfold_lines() {/,/^}/p' "$1" | grep -oE "LC_ALL=C sed -n '[^']*'" | head -1)
  cmp=$(sed -n '/^git_unfold_lines() {/,/^}/p' "$1" | grep -oE '\[ "\$\{_GIT_UNFOLDED%x\}" != "\$_GIT_UNFOLDED" \]' | head -1 | sed 's/_GIT_UNFOLDED/_unf/g')
  [ -n "$lit" ] && [ -n "$cmp" ] && grep -qF "$lit" "$2" && grep -qF "$cmp" "$2" && echo same || echo diff
}
_mc="$(printf 'mvn \\\n%s' "${MVN_PL#mvn }")"
r=$(mkrepo lin3); _fake adopt 'echo nope'
_o=$(PATH="$_fsh:$PATH" record "$_mc" "$r" $'[INFO] BUILD SUCCESS\n')
assert_eq "r2 펴기: 센티널 있는 sed 출력 채택(가짜 = 비 mvn → 기록 없음)" "NONE" "$(printf '%s' "$_o" | awk '{print $NF}')"
assert_eq "r2 펴기: sed 호출 1회(채택)" "1" "$(_fake_n)"
r=$(mkrepo lin4); _fake nosent 'echo nope'
_o=$(PATH="$_fsh:$PATH" record "$_mc" "$r" $'[INFO] BUILD SUCCESS\n')
assert_eq "r2 펴기: 센티널 없으면 종전 치환(감지 → full)" "full" "$(printf '%s' "$_o" | awk '{print $NF}')"
assert_eq "r2 펴기: sed 호출 1회(감지)" "1" "$(_fake_n)"
assert_eq "r2 드리프트: 인라인 펴기 = lib git_unfold_lines" "same" "$(_unf_drift "$HOOKS_DIR/lib/git-cmd.sh" "$REC")"
_fake off ''; r=$(mkrepo lin5); PATH="$_fsh:$PATH" record "$MVN_PL; echo done" "$r" $'[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "r2 구분자: ; 있으면 sed 1회 경로" "1" "$(grep -cF 'H;$!d;x;s/^\n//;s/&&/' "$_fsh/log")"
: > "$_fsh/log"; r=$(mkrepo lin6); PATH="$_fsh:$PATH" record "$MVN_PL" "$r" $'[INFO] BUILD SUCCESS\n' >/dev/null
assert_eq "r2 구분자: 구분자 없으면 sed 를 부르지 않음" "0" "$(grep -cF 'H;$!d;x;s/^\n//;s/&&/' "$_fsh/log")"
rm -rf "$_fsh"

echo "── harness 래퍼(harness.sh test <모듈>, 11-15) ─────────"
W_OUT=$'[INFO] Tests run: 12, Failures: 0, Errors: 0, Skipped: 0\n[INFO] BUILD SUCCESS\n[harness] ── 요약 ──\n[harness] {{MODULE_ADMIN}}: Tests run 12, Failures 0, Errors 0, Skipped 0\n[harness] 결과: BUILD SUCCESS (mvn 종료코드 0)\n'
r=$(mkrepo w1)
assert_eq "W1 양성: ~ 경로 래퍼 → SUCCESS·모듈·총계(요약 줄 이중계산 없음)·full" "SUCCESS {{MODULE_ADMIN}} 12 full" \
  "$(record 'bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}' "$r" "$W_OUT" | cut -d' ' -f2-)"
r=$(mkrepo w2)
assert_eq "W2: \"\$HOME\" 리터럴 경로 래퍼 → full" "SUCCESS {{MODULE_CORE}} 12 full" \
  "$(record 'bash "$HOME/.claude/skills/harness/harness.sh" test {{MODULE_CORE}}' "$r" "$W_OUT" | cut -d' ' -f2-)"
r=$(mkrepo w3)
assert_eq "W3: 절대 경로 래퍼(하위 디렉터리에서 실행) → full" "SUCCESS {{MODULE_ADMIN}} 12 full" \
  "$(record "cd {{MODULE_CORE}} && bash $HOME/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}" "$r" "$W_OUT" | cut -d' ' -f2-)"
r=$(mkrepo w4)
assert_eq "W4 음성: 래퍼 뒤 여분 인자 → 부분 실행 초록은 기록 안 함" "NONE" \
  "$(record 'bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}} -Dtest=Foo' "$r" "$W_OUT")"
r=$(mkrepo w4b)
assert_eq "W4b 음성: 래퍼 뒤 -D 없는 여분 인자 → 기록 안 함(토큰 수 검사)" "NONE" \
  "$(record 'bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}} extra' "$r" "$W_OUT")"
r=$(mkrepo w5)
assert_eq "W5 음성: 정해진 경로 밖 harness.sh 복사본 → 기록 안 함" "NONE" \
  "$(record 'bash /tmp/x/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}' "$r" "$W_OUT")"
r=$(mkrepo w6)
assert_eq "W6 음성: MAVEN_REPO_LOCAL 대입(핀 변경) → 기록 안 함" "NONE" \
  "$(record 'MAVEN_REPO_LOCAL=/tmp/r bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}' "$r" "$W_OUT")"
r=$(mkrepo w7)
assert_eq "W7 양성: 래퍼 실패(종료코드≠0) → FAILURE 기록" "FAILURE {{MODULE_ADMIN}} 0 full" \
  "$(record_fail 'bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}' "$r" 'exit 1' | cut -d' ' -f2-)"
r=$(mkrepo w8)
assert_eq "W8 음성: 래퍼 install 모드(test 아님) → 기록 안 함" "NONE" \
  "$(record 'bash ~/.claude/skills/harness/harness.sh install {{MODULE_ADMIN}}' "$r" "$W_OUT")"
r=$(mkrepo w9); stage_java "$r"; age "$r/{{MODULE_CORE}}/src/main/java/A.java" 60   # 소스는 테스트 시작 전에 고쳐졌다
record 'bash ~/.claude/skills/harness/harness.sh test {{MODULE_ADMIN}}' "$r" "$W_OUT" 1000 >/dev/null
assert_eq "W9 양성: 래퍼 SUCCESS 기록 뒤 커밋 게이트 통과" "none" "$(gate "$COMMIT_CMD" "$r")"

echo
printf 'Tests run: %d, Passed: %d\n' "$run" "$pass"
[ "$run" -gt 0 ] || exit 1
[ "$run" -eq "$pass" ]
