#!/usr/bin/env bash
# test-hooks.sh — 훅 "동작" 회귀 테스트. doctor.sh(설치·등록 검진)의 보완 — 판정 로직 자체를 검사.
# 대상 = test-fixtures/hooks (env 구동 런타임 파생형 훅. 토큰 치환 없이 그대로 실행 가능 —
#   전역 배포본 global/hooks 는 __HOME__·__PROJECTS_DIR__ 등 토큰이 박혀 직접 실행 불가라 픽스처로 부적합).
#   [1~3] 가드 3종: 차단/통과 케이스 (픽스처 git 레포)
#   [4] SessionStart 2종: 주입/침묵 (가짜 HOME·원격 behind 픽스처)
#   [5] Stop 4종 등: 빈 입력 fail-open 스모크 (실알림 차단용 no-op curl/osascript 심)
#   [6] Stop 실판정: Hermes 폐쇄루프 block/pass(OR·AND·loop-guard) + 컨벤션 게이트 위반검출 (트랜스크립트 JSONL 픽스처)
#   [7] commit-regress-reminder: 당일 1회 차단 후 통과
#   [17] rules-size-check: 상한 초과 block · 당일 1회 · 오탐 금지 · 비프로젝트/홈 제외(스코프 무관 확인)
#   [19] git-add-all-guard: 일괄 스테이징 deny · 명시 경로 allow · 래핑/전역옵션 · 예외 접두
#   [18] history-rotate-check: 백업 상태 보고의 진위(fresh/stale) — 문구의 참·거짓까지 판정
#   [20] lsp-first-reminder: Java 전용 스코프 + 심볼 모양 패턴일 때만 발화(혼합 스코프·텍스트 검색은 침묵) — 2026-09-03 축소
#   [21] prod-db-guard heredoc: 문서 append 본문의 DB 문구는 통과, 인터프리터가 받는 heredoc 은 여전히 차단
#   [22] zsh-glob-quote-guard: 미인용 글롭 옵션값 경고 · 인용/이스케이프/heredoc/주석은 침묵
#   [23] mvn-am-guard: -pl 단독 경고 · -am/--also-make · 리프 모듈 · 따옴표 안 · 비 mvn 은 침묵
#   [24] git-hooks-installed-guard: 층 A 미설치·스크립트 부재·.git 없는 프로젝트의 커밋 deny(대상 레포 무관) · 설치 프로젝트·비커밋은 통과
# 커버리지 한계(정직 고지): notify-done(알림 본문 조립)의 실판정은 스모크만.
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"
H="$KIT/test-fixtures/hooks"
PASS=0; FAIL=0
TMP=$(mktemp -d) || { echo '임시 디렉터리 생성 실패 — 실행하지 않았다'; exit 2; }; TMP=$(cd "$TMP" && pwd -P) || exit 2   # macOS /var→/private/var 심링크 정규화(체커 경로 대조용)
trap 'case "$TMP" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) rm -rf "$TMP" ;; esac' EXIT

command -v jq >/dev/null 2>&1 || { echo "✗ jq 필요"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "✗ git 필요"; exit 1; }

# Stop 스모크 중 실제 알림 발송 차단용 no-op 심
mkdir -p "$TMP/bin"
for c in curl osascript; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"; done

decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null; }
json_cmd() { jq -n --arg c "$1" --arg d "$2" '{tool_input:{command:$c},cwd:$d}'; }

t() { # $1=이름 $2=기대(deny|allow) $3=훅파일명 $4=stdin JSON
  local got; got=$(printf '%s' "$4" | bash "$H/$3" 2>/dev/null | decision)
  [ -n "$got" ] || got=allow
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s (기대 %s, 실제 %s)\n' "$1" "$2" "$got"; fi
}

ok() { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
ng() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

repo() { local r="$TMP/$1"; git init -q "$r"; git -C "$r" config user.email t@t.t; git -C "$r" config user.name t; printf '%s' "$r"; }

echo "=== [1] sql-staging-guard (신규 .sql 커밋 차단) ==="
R=$(repo r1)
echo x > "$R/a.sql"; git -C "$R" add a.sql
t "신규 .sql 스테이징 + git commit → 차단" deny sql-staging-guard.sh "$(json_cmd 'git commit -m x' "$R")"
t "비커밋 명령(git status) → 통과" allow sql-staging-guard.sh "$(json_cmd 'git status' "$R")"
git -C "$R" reset -q 2>/dev/null || git -C "$R" rm --cached -q a.sql
echo x > "$R/b.txt"; git -C "$R" add b.txt
t "신규 .sql 없음(.txt만) → 통과" allow sql-staging-guard.sh "$(json_cmd 'git commit -m x' "$R")"
git -C "$R" add a.sql; git -C "$R" commit -qm seed
echo y >> "$R/a.sql"; git -C "$R" add a.sql
t "tracked .sql 수정(M) → 통과" allow sql-staging-guard.sh "$(json_cmd 'git commit -m x' "$R")"

echo "=== [1b] test-count-guard (테스트 수 감소 커밋 차단) ==="
R=$(repo r1b)
mkdir -p "$R/src/test/java"
T="$R/src/test/java/FooTest.java"
printf '    @Test\n    void a() {}\n    @Test\n    void b() {}\n    @Test\n    void c() {}\n' > "$T"
git -C "$R" add src; git -C "$R" commit -qm seed
# 3건 → 1건으로 감축(덮어쓰기 사고 재현)
printf '    @Test\n    void a() {}\n' > "$T"; git -C "$R" add src
t "테스트 수 감소(M) + git commit → 차단" deny test-count-guard.sh "$(json_cmd 'git commit -m x' "$R")"
t "우회 플래그(ALLOW_TEST_COUNT_DROP=1) → 통과" allow test-count-guard.sh "$(json_cmd 'ALLOW_TEST_COUNT_DROP=1 git commit -m x' "$R")"
t "비커밋 명령(git status) → 통과" allow test-count-guard.sh "$(json_cmd 'git status' "$R")"
# 증가는 통과해야 한다(오탐 금지)
printf '    @Test\n    void a() {}\n    @Test\n    void b() {}\n    @Test\n    void c() {}\n    @Test\n    void d() {}\n' > "$T"; git -C "$R" add src
t "테스트 수 증가 → 통과(오탐 금지)" allow test-count-guard.sh "$(json_cmd 'git commit -m x' "$R")"
# @Test → @ParameterizedTest 전환은 합계 불변이라 통과해야 한다
printf '    @ParameterizedTest\n    void a() {}\n    @Test\n    void b() {}\n    @Test\n    void c() {}\n' > "$T"; git -C "$R" add src
t "@Test→@ParameterizedTest 전환(합계 불변) → 통과" allow test-count-guard.sh "$(json_cmd 'git commit -m x' "$R")"
# 테스트가 아닌 파일의 감소는 무관
printf 'x\n' > "$R/src/test/java/notes.txt"; git -C "$R" add src
t "비 .java 변경 → 통과" allow test-count-guard.sh "$(json_cmd 'git commit -m x' "$R")"

echo "=== [2] secret-commit-guard (스테이징 diff 시크릿 차단) ==="
R=$(repo r2)
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$R/key.pem"; git -C "$R" add key.pem
t "개인키 헤더 → 차단" deny secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"
git -C "$R" rm --cached -q key.pem
printf 'password = "${DB_PASS}"\n' > "$R/conf.yml"; git -C "$R" add conf.yml
t "플레이스홀더 \${} → 통과" allow secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"
git -C "$R" rm --cached -q conf.yml
printf 'api_key = "supersecretvalue123"\n' > "$R/app.yml"; git -C "$R" add app.yml
t "자격증명 키 리터럴 대입 → 차단" deny secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"
git -C "$R" rm --cached -q app.yml
printf 'db.password=realpass123\n' > "$R/application.properties"; git -C "$R" add application.properties
# 픽스처 = 킷 기본(EXCLUDE_PATH_REGEX 빈 값 = 전 파일 스캔) → 차단. 예외 값을 넣은 사본(같은 lib 옆)은 통과해야 한다.
t "예외 경로 미설정(킷 기본) → application.properties 도 스캔·차단" deny secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"
mkdir -p "$TMP/hx/lib"; cp "$H/lib/git-cmd.sh" "$H/lib/cmdform.py" "$TMP/hx/lib/"   # PreToolUse 경로의 커밋 형태 판정기도 lib 몫
sed "s/^EXCLUDE_PATH_REGEX=.*/EXCLUDE_PATH_REGEX='(^|\\/)application[^\\/]*\\.properties\$'/" "$H/secret-commit-guard.sh" > "$TMP/hx/secret-commit-guard.sh"
grep -q "^EXCLUDE_PATH_REGEX='(^|/)application" "$TMP/hx/secret-commit-guard.sh" && ok "secret: 예외 값 사본 준비(전제)" || ng "secret: 예외 값 사본 준비 실패(전제)"
got=$(printf '%s' "$(json_cmd 'git commit -m x' "$R")" | bash "$TMP/hx/secret-commit-guard.sh" 2>/dev/null | decision); [ -n "$got" ] || got=allow
[ "$got" = allow ] && ok "예외 경로(application*.properties) 설정 사본 → 통과" || ng "예외 경로 설정 사본 → 통과 실패($got)"

echo "=== [3] prod-db-guard (미확인 호스트 직접 접속 차단) ==="
t "인라인 pymysql 미확인 호스트 → 차단" deny prod-db-guard.sh "$(json_cmd "python3 -c \"import pymysql; pymysql.connect(host='db.prod.internal')\"" "$TMP")"
t "인라인 pymysql localhost → 차단(킷 가드 v2: 인라인 python DB = 호스트 무관)" deny prod-db-guard.sh "$(json_cmd "python3 -c \"import pymysql; pymysql.connect(host='localhost')\"" "$TMP")"
t "코드 검색(grep pymysql) → 통과" allow prod-db-guard.sh "$(json_cmd 'grep -r pymysql src/' "$TMP")"
t "mycli URI 미확인 호스트 → 차단" deny prod-db-guard.sh "$(json_cmd 'mycli mysql://root@10.0.0.5/db' "$TMP")"
# 따옴표 안 산문 라벨 오탐 회귀 — CLI 이름이 echo 문자열에 있을 뿐인데 차단되던 건(정본 DB 스크립트 호출까지 막혔음).
t "echo 라벨 속 CLI 이름 → 통과(오탐 회귀)" allow prod-db-guard.sh "$(json_cmd 'echo "=== mariadb 키 확인 ==="; python3 .claude/skills/db/scripts/apply_ddl.py --check' "$TMP")"
t "따옴표 밖 실제 CLI 호출은 여전히 차단" deny prod-db-guard.sh "$(json_cmd 'mariadb -h db.prod.internal -e "select 1"' "$TMP")"
t "sudo 경유 CLI 호출도 차단" deny prod-db-guard.sh "$(json_cmd 'sudo mariadb -h db.prod.internal' "$TMP")"

echo "=== [3b] lsp-first-reminder (Java 심볼 grep → LSP 리마인더) ==="
out=$(json_cmd 'grep -rE "MbrInfo|mbrInfo" --include="*.java" .' "$TMP" | bash "$KIT/global/hooks/lsp-first-reminder.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "lsp: Java 심볼 grep(--include=*.java) → 리마인더 주입" || ng "lsp: Java 심볼 grep 주입 실패"
out=$(json_cmd 'grep -rn insertMbr CMS-Core/src/main/java/' "$TMP" | bash "$KIT/global/hooks/lsp-first-reminder.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "lsp: 경로형(src/main/java) 심볼 grep → 리마인더 주입" || ng "lsp: 경로형 심볼 grep 주입 실패"
out=$(json_cmd 'grep -n tn_mbr_info LoginMapper_sql.xml' "$TMP" | bash "$KIT/global/hooks/lsp-first-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "lsp: DB식별자(밑줄) XML grep → 침묵" || ng "lsp: DB식별자 grep 침묵 실패"
out=$(json_cmd 'grep -rn 회원정보 --include=*.java .' "$TMP" | bash "$KIT/global/hooks/lsp-first-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "lsp: 한글주석 grep(.java, 험프없음) → 침묵" || ng "lsp: 한글주석 침묵 실패"

echo "=== [4] SessionStart 2종 (주입/침묵) ==="
FP="$TMP/proj"; mkdir -p "$FP/.claude"
FH="$TMP/home"; slug=$(printf '%s' "$FP" | sed 's#/#-#g')
mkdir -p "$FH/.claude/projects/$slug/memory"; : > "$FH/.claude/projects/$slug/memory/MEMORY.md"
out=$(echo '{}' | HOME="$FH" CLAUDE_PROJECT_DIR="$FP" bash "$H/monthly-memory-hygiene.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "monthly: 그달 첫 발동 → 리마인더 주입" || ng "monthly: 첫 발동 주입 실패"
out=$(echo '{}' | HOME="$FH" CLAUDE_PROJECT_DIR="$FP" bash "$H/monthly-memory-hygiene.sh" 2>/dev/null)
[ -z "$out" ] && ok "monthly: 같은 달 재발동 → 침묵" || ng "monthly: 같은 달 침묵 실패"
out=$(echo '{}' | HOME="$FH" CLAUDE_PROJECT_DIR="$TMP/no-mem-proj" bash "$H/monthly-memory-hygiene.sh" 2>/dev/null)
[ -z "$out" ] && ok "monthly: memory 없는 프로젝트 → 침묵" || ng "monthly: memory 없음 침묵 실패"

SRC=$(repo r4); echo 1 > "$SRC/f"; git -C "$SRC" add f; git -C "$SRC" commit -qm c1
git clone -q --bare "$SRC" "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/clone"
br=$(git -C "$SRC" symbolic-ref --short HEAD)
echo 2 >> "$SRC/f"; git -C "$SRC" commit -qam c2; git -C "$SRC" push -q "$TMP/origin.git" "HEAD:$br"
mkdir -p "$TMP/clone/.claude"
out=$(echo '{}' | CLAUDE_PROJECT_DIR="$TMP/clone" bash "$H/daily-first-session-fetch.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "daily-fetch: 원격 behind → 리마인더 주입" || ng "daily-fetch: behind 주입 실패"
out=$(echo '{}' | CLAUDE_PROJECT_DIR="$TMP/clone" bash "$H/daily-first-session-fetch.sh" 2>/dev/null)
[ -z "$out" ] && ok "daily-fetch: 같은 날 재발동 → 침묵" || ng "daily-fetch: 같은 날 침묵 실패"
out=$(echo '{}' | CLAUDE_PROJECT_DIR="$FP" bash "$H/daily-first-session-fetch.sh" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "daily-fetch: 비git 프로젝트 → fail-open 침묵" || ng "daily-fetch: 비git fail-open 실패"

echo "=== [5] Stop 4종 빈 입력 fail-open 스모크 (알림 심 적용) ==="
for h in closed-loop-history convention-gate history-rotate-check notify-done mirror-history pull-smoke-reminder; do
  echo '{}' | PATH="$TMP/bin:$PATH" HOME="$FH" CLAUDE_PROJECT_DIR="$FP" CLAUDE_PLUGIN_ROOT="$KIT/global" bash "$H/$h.sh" >/dev/null 2>&1
  rc=$?
  [ "$rc" = 0 ] && ok "$h: 빈 입력 → exit 0(fail-open)" || ng "$h: 빈 입력에 exit $rc"
done

echo "=== [6] Stop 실판정 — Hermes 폐쇄루프 + 컨벤션 게이트 ==="
# 픽스처: base=$TMP(=dirname CLAUDE_PROJECT_DIR), 프로젝트 hermesproj, 트랜스크립트 JSONL 수제.
HP="$TMP/hermesproj"; mkdir -p "$HP/docs"; : > "$HP/docs/agent_history.md"
mkdir -p "$FH/.claude/hooks"   # 훅 로그 경로(HOME=$FH)
# 훅이 레코드 순서를 라인 인덱스가 아니라 **timestamp** 로 판정하므로(파일 여러 개를 합치면
# 인덱스로 선후를 못 가림) 픽스처도 호출 순서대로 증가하는 timestamp 를 넣어야 한다.
TJSEQ=0
tj() { TJSEQ=$((TJSEQ+1)); jq -nc --arg f "$1" --arg ts "$(printf '2026-01-01T00:00:%02dZ' "$TJSEQ")" \
       '{timestamp:$ts,message:{content:[{type:"tool_use",name:"Edit",input:{file_path:$f}}]}}'; }
stopin() { jq -n --arg c "$HP" --arg t "$1" --argjson a "${2:-false}" '{cwd:$c,transcript_path:$t,stop_hook_active:$a}'; }
hermes() { HOME="$FH" CLAUDE_PROJECT_DIR="$TMP/x" CLAUDE_STRICT_PROJECT="${2:-}" bash "$H/closed-loop-history.sh" <<<"$1" 2>/dev/null; }

TR="$TMP/tr-src-only.jsonl"; tj "$HP/src/A.java" > "$TR"
got=$(hermes "$(stopin "$TR")" | jq -r '.decision // "pass"')
[ "$got" = "block" ] && ok "Hermes: 소스만 수정 → block" || ng "Hermes: 소스만 수정에 $got"

TR="$TMP/tr-src-hist.jsonl"; { tj "$HP/src/A.java"; tj "$HP/docs/agent_history.md"; } > "$TR"
out=$(hermes "$(stopin "$TR")")
[ -z "$out" ] && ok "Hermes: 소스+history 기록 → pass" || ng "Hermes: history 기록에도 출력"

MEMF="$FH/.claude/projects/-tmp-hermesproj/memory/x.md"
TR="$TMP/tr-src-mem.jsonl"; { tj "$HP/src/A.java"; tj "$MEMF"; } > "$TR"
out=$(hermes "$(stopin "$TR")")
[ -z "$out" ] && ok "Hermes: 소스+memory 기록 → pass(OR)" || ng "Hermes: memory 기록에도 출력"

got=$(hermes "$(stopin "$TR")" hermesproj | jq -r '.decision // "pass"')
[ "$got" = "block" ] && ok "Hermes: STRICT(AND)에서 memory만 → block" || ng "Hermes: STRICT AND에 $got"

out=$(hermes "$(stopin "$TMP/tr-src-only.jsonl" true)")
[ -z "$out" ] && ok "Hermes: stop_hook_active → loop-guard 침묵" || ng "Hermes: loop-guard 실패"

# ── 2026-08-05 감사 회귀: 감지 범위 확장(서브에이전트) + Bash 쓰기 휴리스틱 오탐 ──────────
# (a) 소스 수정을 전부 서브에이전트/Workflow 에 위임한 세션은 부모 transcript 에 편집이 없어
#     2채널 게이트를 통째로 우회했다. (b) Bash 쓰기 감지는 텍스트 스캔이라 '쓰기'와 '언급'을
#     구분 못 해, 레포에 실재하는 파일을 명령문에서 언급만 해도 차단됐다(실사고).
tbash() { jq -nc --arg ts "$1" --arg c "$2" '{timestamp:$ts,message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}'; }
TSNOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$HP/src"
printf 'class Fresh{}\n' > "$HP/src/Fresh.java"                       # 방금 쓴 파일
printf 'class Old{}\n'   > "$HP/src/Old.java"; touch -t 202601010900 "$HP/src/Old.java"   # 오래된 파일

# (a) 서브에이전트 jsonl 에만 편집이 있어도 잡아야 한다.
TR="$TMP/tr-sub.jsonl"; : > "$TR"
mkdir -p "$TMP/tr-sub/subagents"; tj "$HP/src/A.java" > "$TMP/tr-sub/subagents/agent-1.jsonl"
got=$(hermes "$(stopin "$TR")" | jq -r '.decision // "pass"')
[ "$got" = "block" ] && ok "Hermes: 서브에이전트 편집만 → block(위임 우회 차단)" || ng "Hermes: 서브에이전트 편집 미감지($got)"

# (b) 진성 — 실재하고 mtime 이 명령 시각 이후인 파일에 Bash 로 쓰면 잡아야 한다.
TR="$TMP/tr-bash-write.jsonl"; tbash "$TSNOW" "printf 'x' >> $HP/src/Fresh.java" > "$TR"
got=$(hermes "$(stopin "$TR")" | jq -r '.decision // "pass"')
[ "$got" = "block" ] && ok "Hermes: Bash 쓰기(실재·최신 mtime) → block" || ng "Hermes: Bash 쓰기 미감지($got)"

# (b) 오탐 금지 — 실재하지만 안 바뀐 파일을 '언급'만 한 경우(리다이렉션이 붙어도) 침묵.
TR="$TMP/tr-bash-mention.jsonl"; tbash "$TSNOW" "grep -n foo $HP/src/Old.java > /tmp/out.txt" > "$TR"
out=$(hermes "$(stopin "$TR")")
[ -z "$out" ] && ok "Hermes: 안 바뀐 파일 '언급' → 침묵(오탐 회귀)" || ng "Hermes: 언급만으로 차단(오탐)"

# (b) 오탐 금지 — 레포에 없는 경로(다른 레포의 상대토큰·미전개 셸 변수)는 침묵.
TR="$TMP/tr-bash-ghost.jsonl"; tbash "$TSNOW" 'printf "class B{}" > src/B.java' > "$TR"
out=$(hermes "$(stopin "$TR")")
[ -z "$out" ] && ok "Hermes: 미존재 경로 쓰기 토큰 → 침묵(오탐 회귀)" || ng "Hermes: 미존재 경로로 차단(오탐)"

CP="$TMP/convproj"; git init -q "$CP"; git -C "$CP" config user.email t@t.t; git -C "$CP" config user.name t
mkdir -p "$CP/.claude" "$CP/src"; echo "# 컨벤션 게이트 테스트 마커" > "$CP/.claude/conventions.enabled"
echo r > "$CP/README.md"; git -C "$CP" add README.md; git -C "$CP" commit -qm init
printf 'public class Foo {\n  void m() {\n    var x = java.util.List.of(1);\n  }\n}\n' > "$CP/src/Foo.java"
convin=$(jq -n --arg c "$CP" '{cwd:$c,stop_hook_active:false}')
got=$(HOME="$FH" CLAUDE_PROJECT_DIR="$TMP/x" CLAUDE_PLUGIN_ROOT="$KIT/global" bash "$H/convention-gate.sh" <<<"$convin" 2>/dev/null | jq -r '.decision // "pass"')
[ "$got" = "block" ] && ok "conv-gate: 룰 H 위반(.java var·List.of) → block" || ng "conv-gate: 위반 검출 실패($got)"
rm "$CP/src/Foo.java"
out=$(HOME="$FH" CLAUDE_PROJECT_DIR="$TMP/x" CLAUDE_PLUGIN_ROOT="$KIT/global" bash "$H/convention-gate.sh" <<<"$convin" 2>/dev/null)
[ -z "$out" ] && ok "conv-gate: 위반 제거 후 → pass" || ng "conv-gate: 클린에 출력"

echo "=== [7] commit-regress-reminder (당일 1회 차단 후 통과) ==="
RP="$TMP/regproj"; mkdir -p "$RP/.claude"
rj=$(json_cmd 'git commit -m x' "$RP")
got=$(printf '%s' "$rj" | CLAUDE_PROJECT_DIR="$RP" bash "$H/commit-regress-reminder.sh" 2>/dev/null | decision)
[ "$got" = "deny" ] && ok "reminder: 회귀 마커 없음 1차 커밋 → 차단" || ng "reminder: 1차 차단 실패($got)"
out=$(printf '%s' "$rj" | CLAUDE_PROJECT_DIR="$RP" bash "$H/commit-regress-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "reminder: 같은 날 재시도 → 통과" || ng "reminder: 재시도 통과 실패"
rm -f "$RP/.claude/.regress-reminded"; date +%F > "$RP/.claude/.last-regress"
out=$(printf '%s' "$rj" | CLAUDE_PROJECT_DIR="$RP" bash "$H/commit-regress-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "reminder: 오늘 회귀 완료 마커 → 통과" || ng "reminder: 마커 통과 실패"
out=$(json_cmd 'git status' "$RP" | CLAUDE_PROJECT_DIR="$RP" bash "$H/commit-regress-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "reminder: 비커밋 명령 → 무개입" || ng "reminder: 비커밋 개입"

echo "=== [8] mvn-clean-on-delete-reminder (전역, 삭제된 .java/.xml + non-clean mvn 빌드 리마인더) ==="
R=$(repo r8); echo 'class A{}' > "$R/A.java"; git -C "$R" add A.java; git -C "$R" commit -qm seed
rm "$R/A.java"
out=$(json_cmd 'mvn compile' "$R" | bash "$KIT/global/hooks/mvn-clean-on-delete-reminder.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "mvn-clean: 삭제된 .java + mvn compile(비-clean) → 리마인더 주입" || ng "mvn-clean: 주입 실패"
out=$(json_cmd 'mvn clean compile' "$R" | bash "$KIT/global/hooks/mvn-clean-on-delete-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "mvn-clean: mvn clean compile → 침묵" || ng "mvn-clean: clean 있는데도 주입"

echo "=== [9] code-review-marker-reminder (diff 지문 대조 게이트 — 마커 지문 = 커밋될 diff 일 때만 통과) ==="
RVP=$(repo revproj); mkdir -p "$RVP/.claude"; printf '.claude/\n' >> "$RVP/.git/info/exclude"
echo a > "$RVP/a.txt"; git -C "$RVP" add a.txt; git -C "$RVP" commit -qm seed
echo b >> "$RVP/a.txt"; git -C "$RVP" add a.txt
rj2=$(json_cmd 'git commit -m x' "$RVP")
crm() { printf '%s' "$1" | CLAUDE_PROJECT_DIR="$RVP" bash "$H/code-review-marker-reminder.sh" 2>/dev/null; }
got=$(crm "$rj2" | decision); [ -n "$got" ] || got=allow
[ "$got" = deny ] && ok "code-review: 마커 없음 → 차단" || ng "code-review: 마커 없음 차단 실패($got)"
got=$(crm "$rj2" | decision); [ -n "$got" ] || got=allow
[ "$got" = deny ] && ok "code-review: 재시도도 차단(당일 1회 통과 없음)" || ng "code-review: 재시도 통과 — 옛 넛지 계약"
cur=$(. "$H/lib/review-diff.sh" && review_diff_hash "$RVP" 'git commit -m x')
[ -n "$cur" ] && ok "code-review: 지문 산출(전제)" || ng "code-review: 지문 산출 실패(전제)"
printf '%s %s\n' "$(date +%F)" "$cur" > "$RVP/.claude/.last-review"
out=$(crm "$rj2"); [ -z "$out" ] && ok "code-review: 마커 지문 = 커밋될 diff → 통과" || ng "code-review: 일치 마커인데 개입"
echo c >> "$RVP/a.txt"; git -C "$RVP" add a.txt
got=$(crm "$rj2" | decision); [ -n "$got" ] || got=allow
[ "$got" = deny ] && ok "code-review: 리뷰 뒤 diff 변경 → 차단(반증)" || ng "code-review: 낡은 마커로 통과($got)"
out=$(crm "$(json_cmd 'git status' "$RVP")"); [ -z "$out" ] && ok "code-review: 비커밋 명령 → 무개입" || ng "code-review: 비커밋 개입"
RVO=$(repo revother); echo z > "$RVO/z.txt"; git -C "$RVO" add z.txt
# 킷 가드 v2 — PreToolUse 경로는 허용 형태(단독 커밋)만 통과: 다른 레포 `git -C` 커밋은 대상 추정 없이 deny("그 레포를 연 세션에서").
got=$(crm "$(json_cmd "git -C $RVO commit -m x" "$RVP")" | decision); [ -n "$got" ] || got=allow
[ "$got" = deny ] && ok "code-review: 다른 레포 git -C 커밋 → 허용 형태 밖 deny" || ng "code-review: 다른 레포 git -C 커밋 통과($got)"

echo "=== [10] module-isolation-reminder (Write|Edit, 멀티모듈 격리 위반 리마인더) ==="
fp1="$TMP/CMS-Admin/src/main/java/com/example/app/core/mbr/mapper/Foo.java"
in1=$(jq -n --arg f "$fp1" '{tool_input:{file_path:$f}}')
out=$(printf '%s' "$in1" | bash "$H/module-isolation-reminder.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "module-iso: CMS-Admin의 mapper 경로 → 리마인더 주입" || ng "module-iso: mapper 경로 주입 실패"
fp2="$TMP/CMS-Core/src/main/java/com/example/app/core/mbr/mapper/Foo.java"
in2=$(jq -n --arg f "$fp2" '{tool_input:{file_path:$f}}')
out=$(printf '%s' "$in2" | bash "$H/module-isolation-reminder.sh" 2>/dev/null)
[ -z "$out" ] && ok "module-iso: CMS-Core의 mapper 경로 → 침묵" || ng "module-iso: CMS-Core 침묵 실패"
fp3="$TMP/CMS-Admin/src/main/java/com/example/app/core/mbr/web/FooController.java"
in3=$(jq -n --arg f "$fp3" --arg c 'import com.example.app.core.mbr.mapper.FooMapper;
public class FooController {}' '{tool_input:{file_path:$f, content:$c}}')
out=$(printf '%s' "$in3" | bash "$H/module-isolation-reminder.sh" 2>/dev/null)
printf '%s' "$out" | grep -q additionalContext && ok "module-iso: 컨트롤러의 Mapper 직접 import → 리마인더 주입" || ng "module-iso: 컨트롤러 Mapper import 주입 실패"

echo "=== [11] mirror-history 민감 memory 제외(MIRROR_MEMORY_EXCLUDE) ==="
# 백업 미러는 MIRROR_PUSH=1 이면 오프사이트로 나가므로 자격증명 memory 는 미러에서 빠져야 한다.
menc=$(printf '%s' "$FP" | sed 's/[^a-zA-Z0-9]/-/g')
mmem="$FH/.claude/projects/$menc/memory"; mkdir -p "$mmem"
printf 'index\n' > "$mmem/MEMORY.md"; printf 'id/pw\n' > "$mmem/verify-login.md"
mdest="$FH/.claude/history-backups/$(basename "$FP")/memory"
mrun(){ printf '%s' "{\"tool_input\":{\"file_path\":\"$mmem/MEMORY.md\"}}" | \
  HOME="$FH" CLAUDE_PROJECT_DIR="$FP" MIRROR_MEMORY_EXCLUDE="$1" bash "$H/mirror-history.sh" >/dev/null 2>&1; }

rm -rf "$mdest"; mrun "verify-login.md"
[ -f "$mdest/MEMORY.md" ] && ok "mirror-exclude: 일반 memory 는 미러됨" || ng "mirror-exclude: 미러 자체 실패"
[ ! -f "$mdest/verify-login.md" ] && ok "mirror-exclude: 등재 파일 제외됨" || ng "mirror-exclude: 자격증명 파일이 백업에 유입"
# 반증 — 미등재면 실제로 들어와야 한다(안 그러면 위 검사는 항상 통과하는 가짜 검사)
rm -rf "$mdest"; mrun ""
[ -f "$mdest/verify-login.md" ] && ok "mirror-exclude: 미등재 시 유입됨(제외가 실동작 증명)" || ng "mirror-exclude: 반증 실패 — 위 검사 무의미"

# ─────────────────────────────────────────────────────────────────────────────
# [12]~[15] 2026-08-05 전수 감사에서 드러난 **실제 우회 경로**의 회귀 고정.
#   이 케이스들이 없어서 게이트가 몇 달간 죽은 줄도 모르고 있었다(정본 교훈 = memory
#   gate-teeth-verification). 여기 등록된 건 전부 "고치기 전에는 실제로 뚫렸던" 입력이다.
# ─────────────────────────────────────────────────────────────────────────────

echo "=== [12] 커밋 게이트 래핑 우회 (lib/git-cmd.sh — 세 가드 공용) ==="
# 공용 lib 의 선행문맥 문자클래스에 (·따옴표·경로접두가 빠져 있어, 한 줄 래핑으로
# sql-staging·secret-commit·commit-regress 세 게이트가 **동시에** 무력화됐다.
R=$(repo r12); echo x > "$R/a.sql"; git -C "$R" add a.sql
t "sh -c 래핑 커밋 → 차단" deny sql-staging-guard.sh "$(json_cmd 'sh -c "git commit -m x"' "$R")"
t "bash -lc 래핑 커밋 → 차단" deny sql-staging-guard.sh "$(json_cmd 'bash -lc "git commit -m x"' "$R")"
t "서브셸 (git commit) → 차단" deny sql-staging-guard.sh "$(json_cmd '(git commit -m x)' "$R")"
t "절대경로 /usr/bin/git commit → 차단" deny sql-staging-guard.sh "$(json_cmd '/usr/bin/git commit -m x' "$R")"
# 반증 — 넓힌 정규식이 커밋 아닌 명령까지 삼키면 안 된다(오탐 회귀).
t "git log --grep=commit → 통과(오탐 금지)" allow sql-staging-guard.sh "$(json_cmd 'git log --grep=commit' "$R")"
t "git config commit.template → 통과(오탐 금지)" allow sql-staging-guard.sh "$(json_cmd 'git config commit.template x' "$R")"

echo "=== [13] 비ASCII(한글) 파일명 우회 (core.quotepath) ==="
# git 은 기본(quotepath=true)에서 비ASCII 경로를 "따옴표+8진 이스케이프"로 출력한다.
# 그 탓에 '\.sql$' 앵커가 닫는 따옴표에 막혀 0건이 되고, 가드가 조용히 통과시켰다.
R=$(repo r13); echo x > "$R/한글초안_20260805.sql"; git -C "$R" add "한글초안_20260805.sql"
t "한글명 .sql 스테이징 + 커밋 → 차단" deny sql-staging-guard.sh "$(json_cmd 'git commit -m x' "$R")"
git -C "$R" rm --cached -q "한글초안_20260805.sql"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$R/한글설정.txt"; git -C "$R" add "한글설정.txt"
t "한글명 파일의 개인키 → 차단" deny secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"

echo "=== [14] secret-guard 정밀도(1차 고신뢰 히트 보호 · 마스킹) ==="
R=$(repo r14)
# 객체참조 오탐필터가 1차 고신뢰 히트까지 지워, '절대 놓치면 안 되는' JWT 가 통과했다.
printf 'jwtKey=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0\n' > "$R/c.txt"; git -C "$R" add c.txt
t "JWT(점 포함 무따옴표 대입) → 차단" deny secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"
# 마스킹이 값 위치를 못 찾으면 라인 원문이 그대로 사유에 실려 나갔다 → 화이트리스트 발췌로 역전.
sec_out=$(printf '%s' "$(json_cmd 'git commit -m x' "$R")" | bash "$H/secret-commit-guard.sh" 2>/dev/null)
printf '%s' "$sec_out" | grep -q 'eyJhbGciOiJIUzI1' \
  && ng "secret-mask: 시크릿 원문이 사유에 노출됨" || ok "secret-mask: 원문 미노출(발췌+**** 만)"
# 반증 — 위 검사가 '아무것도 안 나와서' 통과한 게 아님을 보인다.
printf '%s' "$sec_out" | grep -q '\*\*\*\*' && ok "secret-mask: 마스킹 발췌가 실제 출력됨(반증)" \
  || ng "secret-mask: 반증 실패 — 출력 자체가 없어 위 검사가 무의미"
git -C "$R" rm --cached -q c.txt
printf 'secret = config.getSecret()\n' > "$R/d.java"; git -C "$R" add d.java
t "객체 참조(코드) → 통과(오탐 금지)" allow secret-commit-guard.sh "$(json_cmd 'git commit -m x' "$R")"

echo "=== [15] prod-db-guard: AND 판정 · 터널 포트 · 하이픈 접미형 CLI ==="
# ①허용 호스트가 '하나라도' 있으면 통과하던 OR 판정 → 지시자가 가리키는 호스트가 '전부' 허용일 때만.
#   ⚠️ 허용 호스트가 **접속 지시자 위치**(-h/host=)에 있어야 이 수정을 증명한다.
#   따옴표 라벨 속 localhost 로는 구버전도 차단하므로(허용 판정에 애초에 안 쓰임) 검사가 무의미해진다
#   — 실측으로 확인하고 교체한 케이스다(2026-08-05).
t "허용호스트 + 운영호스트 혼재 → 차단(AND 판정)" deny prod-db-guard.sh \
  "$(json_cmd 'mycli -h localhost -e "select 1" && python3 -c "import pymysql; pymysql.connect(host=\"db.prod.internal\")"' "$TMP")"
# ②MariaDB 실제 클라이언트 이름(하이픈 접미형)이 탐지 목록에서 통째로 빠져 있었다.
t "mariadb-dump 운영 호스트 → 차단" deny prod-db-guard.sh "$(json_cmd 'mariadb-dump -h db.prod.internal db > d.sql' "$TMP")"
t "mariadb-admin 운영 호스트 → 차단" deny prod-db-guard.sh "$(json_cmd 'mariadb-admin -h db.prod.internal shutdown' "$TMP")"
# ③SSH 로컬 포워딩 종단은 '로컬처럼' 보이지만 실제로는 원격 DB다.
t "127.0.0.1 비표준(터널) 포트 → 차단" deny prod-db-guard.sh \
  "$(json_cmd 'python3 -c "import pymysql; pymysql.connect(host=\"127.0.0.1\", port=33306)"' "$TMP")"
t "인라인 python localhost 표준 포트 → 차단(킷 가드 v2: 인라인 python DB = 호스트 무관)" deny prod-db-guard.sh \
  "$(json_cmd 'python3 -c "import pymysql; pymysql.connect(host=\"127.0.0.1\", port=3306)"' "$TMP")"

echo "=== [16] 넛지형 훅 오탐 — 인용문이 그날 1회를 소진하면 안 됨 ==="
# 안내문에 'git commit' 을 인용한 턴이 넛지를 태워버리면, 정작 진짜 커밋 때 침묵한다.
NP="$TMP/nudge"; mkdir -p "$NP/.claude"
# 무출력(=통과)일 때 decision 이 빈 문자열이 되므로 t() 와 동일한 allow 폴백을 둔다.
nrun(){ local g; g=$(printf '%s' "$(json_cmd "$2" "$NP")" | CLAUDE_PROJECT_DIR="$NP" bash "$H/$1" 2>/dev/null | decision); [ -n "$g" ] || g=allow; printf '%s' "$g"; }
[ "$(nrun commit-regress-reminder.sh 'echo "먼저 git commit 하지 마세요"')" = allow ] \
  && ok "commit-regress: 인용문에 침묵" || ng "commit-regress: 인용문에 발동(넛지 소진)"
[ "$(nrun commit-regress-reminder.sh 'git commit -m x')" = deny ] \
  && ok "commit-regress: 진짜 커밋에 발동(반증)" || ng "commit-regress: 진짜 커밋에도 침묵 — 위 검사 무의미"
[ "$(nrun commit-regress-reminder.sh 'git commit -m x')" = allow ] \
  && ok "commit-regress: 같은 날 재시도는 통과" || ng "commit-regress: 당일 1회 계약 위반"

echo "=== [17] rules-size-check: 상시 로드 컨텍스트 상한(스코프 무관·당일 1회) ==="
# 이 훅만 프로젝트 디렉터리로 스코프하지 않는다(검사 대상이 스택·위치 무관) — 임의 경로의 git 레포도 잡혀야 한다.
RSH="$TMP/home-rs"; mkdir -p "$RSH/.claude/hooks"; printf 'x' > "$RSH/.claude/CLAUDE.md"
rsin() { jq -n --arg c "$1" '{cwd:$c,stop_hook_active:false}'; }
# 무출력(=통과)이면 jq 가 아무것도 안 내므로 빈 문자열 → pass 폴백을 둔다(nrun 과 같은 축).
rsrun() { local g; g=$(printf '%s' "$(rsin "$1")" | HOME="$RSH" bash "$H/rules-size-check.sh" 2>/dev/null | jq -r '.decision // "pass"'); [ -n "$g" ] || g=pass; printf '%s' "$g"; }

RSOVER="$TMP/rs-over"; git init -q "$RSOVER"
head -c 40000 /dev/zero | tr '\0' 'x' > "$RSOVER/CLAUDE.md"
[ "$(rsrun "$RSOVER")" = block ] \
  && ok "규약 39KB(상한 30KB) 초과 → block" || ng "초과인데 침묵 — 게이트 이빨 없음"
[ "$(rsrun "$RSOVER")" = pass ] \
  && ok "같은 날 재실행 → 침묵(당일 1회)" || ng "당일 1회 계약 위반"

RSOK="$TMP/rs-ok"; git init -q "$RSOK"; printf 'x' > "$RSOK/CLAUDE.md"
[ "$(rsrun "$RSOK")" = pass ] \
  && ok "상한 이하 → 침묵(오탐 금지)" || ng "상한 이하인데 발동"

RSNP="$TMP/rs-nonproj"; mkdir -p "$RSNP"
[ "$(rsrun "$RSNP")" = pass ] \
  && ok "git 도 CLAUDE.md 도 없는 경로 → 대상 아님" || ng "비프로젝트 경로에서 발동(잡음)"
[ "$(rsrun "$RSH")" = pass ] \
  && ok "홈 디렉터리 자체 → 대상 아님" || ng "홈에서 발동(잡음)"

echo "=== [18] history-rotate-check: 백업 상태 보고의 진위(fresh/stale) ==="
# 왜 필요한가: 이 훅은 백업이 이미 있으면 복사하지 않는데, 과거엔 reason 문자열이 분기 밖에서
#   조립돼 **무조건 "자동 생성했습니다"** 라고 말했다. 에이전트가 그 말을 믿고 트림하면 스냅샷
#   이후 작성분이 영구 소실된다(2026-08-31 실사고 직전까지 감). 발화 여부만 보는 스모크로는
#   문구의 참·거짓이 안 잡혀 이 케이스를 별도로 둔다.
HRP="$TMP/hrproj"; mkdir -p "$HRP/docs/archive/history"
hrrun() { jq -n --arg c "$HRP" '{cwd:$c,stop_hook_active:false}' \
          | HOME="$FH" CLAUDE_PROJECT_DIR="$TMP/x" bash "$H/history-rotate-check.sh" 2>/dev/null | jq -r '.reason // ""'; }

: > "$HRP/docs/agent_history.md"                       # 임계 이하
[ -z "$(hrrun)" ] && ok "rotate: 40KB 이하 → 침묵(오탐 금지)" || ng "rotate: 임계 이하인데 발동"

head -c 45000 /dev/zero | tr '\0' 'a' > "$HRP/docs/agent_history.md"   # 임계 초과
out=$(hrrun)
# 양성 대조 — 위 침묵이 "훅이 안 돈 것"이 아니라 진짜 통과였음을 여기서 증명한다.
[ -n "$out" ] && ok "rotate: 40KB 초과 → block(양성 대조)" || ng "rotate: 초과인데 침묵"
printf '%s' "$out" | grep -q '새로 생성' \
  && ok "rotate: 백업 없음 → '새로 생성' 사실 보고" || ng "rotate: fresh 문구 없음"

out=$(hrrun)   # 두 번째 호출 = 백업이 이미 있음(멱등이라 재생성 안 함)
printf '%s' "$out" | grep -q '재생성하지 않았습니다' \
  && ok "rotate: 백업 기존 → '재생성 안 함' 경고" || ng "rotate: stale 인데 생성했다고 말함(거짓 보고)"
printf '%s' "$out" | grep -q 'append' \
  && ok "rotate: stale 시 append 후 트림 지시 포함" || ng "rotate: stale 대처 지시 누락"

echo "=== [19] git-add-all-guard (병행 세션 — 일괄 스테이징 차단, 명시 경로 통과) ==="
# 2026-09-02 신설. 첫 판 결함 2건의 회귀 고정: ⓐ 단일 명령(마지막 세그먼트 개행 없음) 통과 ⓑ sh -c 래핑 종결자.
R=$(repo r19)
t "git add -A → 차단" deny git-add-all-guard.sh "$(json_cmd 'git add -A' "$R")"
t "git add . → 차단" deny git-add-all-guard.sh "$(json_cmd 'git add .' "$R")"
t "git add -u → 차단" deny git-add-all-guard.sh "$(json_cmd 'git add -u' "$R")"
t "git commit -am → 차단" deny git-add-all-guard.sh "$(json_cmd 'git commit -am "x"' "$R")"
t "cd && git add -A && commit(복합) → 차단" deny git-add-all-guard.sh "$(json_cmd 'cd /x && git add -A && git commit -m x' "$R")"
t "git -C /repo add . (전역옵션) → 차단" deny git-add-all-guard.sh "$(json_cmd 'git -C /repo add .' "$R")"
t "sh -c 래핑 git add -A → 차단" deny git-add-all-guard.sh "$(json_cmd 'sh -c "git add -A"' "$R")"
t "git add -- . → 차단" deny git-add-all-guard.sh "$(json_cmd 'git add -- .' "$R")"
t "git add <명시 경로> → 통과" allow git-add-all-guard.sh "$(json_cmd 'git add src/a.java docs' "$R")"
t "git add -p <경로> → 통과" allow git-add-all-guard.sh "$(json_cmd 'git add -p src/a.java' "$R")"
t "git commit -m → 통과" allow git-add-all-guard.sh "$(json_cmd 'git commit -m "x"' "$R")"
t "git commit --amend → 통과(-a 오탐 금지)" allow git-add-all-guard.sh "$(json_cmd 'git commit --amend --no-edit' "$R")"
t "git log --grep=add → 통과(오탐 금지)" allow git-add-all-guard.sh "$(json_cmd 'git log --grep=add' "$R")"
t "ALLOW_GIT_ADD_ALL=1 예외 → 통과" allow git-add-all-guard.sh "$(json_cmd 'ALLOW_GIT_ADD_ALL=1 git add -A' "$R")"
t "비 git 명령(ls -A .) → 통과" allow git-add-all-guard.sh "$(json_cmd 'ls -A .' "$R")"

# 소프트 훅(additionalContext) 판정 헬퍼: warn(주입) / silent(침묵)
ctx() { jq -r 'if (.hookSpecificOutput.additionalContext // "") != "" then "warn" else "silent" end' 2>/dev/null; }
w() { # $1=이름 $2=기대(warn|silent) $3=훅파일명 $4=명령 문자열
  local got; got=$(json_cmd "$4" "$TMP" | bash "$H/$3" 2>/dev/null | ctx)
  [ -n "$got" ] || got=silent
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s (기대 %s, 실제 %s)\n' "$1" "$2" "$got"; fi
}

echo "[20] lsp-first-reminder — Java 전용 스코프 + 심볼 모양일 때만 발화(2026-09-03 축소)"
w "--include='*.java' + camelCase 심볼 → 발화" warn lsp-first-reminder.sh 'grep -rn "readLsn" --include="*.java" CMS-Core/src'
w "src/main/java 경로 + PascalCase → 발화" warn lsp-first-reminder.sh 'grep -rn "LsnService" CMS-Core/src/main/java'
w "class 정의 검색 → 발화" warn lsp-first-reminder.sh 'grep -rn "class RoomServiceImpl" CMS-Core/src/main/java'
w "메서드 호출형 createRoom( → 발화" warn lsp-first-reminder.sh 'grep -rn "createRoom(" CMS-Core/src/main/java'
w "rg -tjava + 심볼 → 발화" warn lsp-first-reminder.sh 'rg -tjava "RoomMapper" CMS-Core'
w "--include *.java + *.xml 혼합 → 침묵" silent lsp-first-reminder.sh 'grep -rn "readLsn" --include="*.java" --include="*.xml" CMS-Core/src'
w "java 경로 + resources 경로 혼합 → 침묵" silent lsp-first-reminder.sh 'grep -rn "readLsn" CMS-Core/src/main/java CMS-Core/src/main/resources'
w "모듈 루트(src) 만 → 침묵(혼합 트리)" silent lsp-first-reminder.sh 'grep -rn "readLsn" CMS-Core/src'
w "매퍼 XML 디렉터리 → 침묵" silent lsp-first-reminder.sh 'grep -rn "cnvrsRoom" CMS-Core/src/main/resources/egovframework/mapper/'
w "JS 디렉터리 → 침묵" silent lsp-first-reminder.sh 'grep -rn "App.confirm" CMS-Front/src/main/resources/static/resources/js/develop'
w "한글 검색어 → 침묵" silent lsp-first-reminder.sh 'grep -rn "소통방" CMS-Core/src/main/java'
w "밑줄 DB 식별자 → 침묵" silent lsp-first-reminder.sh 'grep -rn "tn_sample_room" --include="*.java" CMS-Core'
w "대안(|) 갈래 전부 심볼 → 발화" warn lsp-first-reminder.sh 'grep -rnE "readLsn|readRoom" --include="*.java" CMS-Core'
w "대안(|) 에 텍스트 갈래 섞임 → 침묵" silent lsp-first-reminder.sh 'grep -rnE "readLsn|room id" --include="*.java" CMS-Core'
w "공백 든 문장 패턴 → 침묵" silent lsp-first-reminder.sh 'grep -rn "roomId = " CMS-Core/src/main/java'
w "테스트 계수(@Test) → 침묵" silent lsp-first-reminder.sh 'grep -c "@Test" CMS-Core/src/test/java/kr/x/RoomServiceTest.java'
w "docs 경로 → 침묵" silent lsp-first-reminder.sh 'grep -rn "readLsn" docs/'

echo "[21] prod-db-guard — heredoc 본문 제외(실행 토큰만 판정)"
t "cat >> 문서 heredoc 본문의 MariaDB·host= 문구 → 통과(오탐 회귀)" allow prod-db-guard.sh \
  "$(json_cmd $'cat >> docs/설계.md <<\'EOF\'\n## DB\n- MariaDB 10.11 (mariadb -h prod.db 로 접속 금지)\n- host=db.prod.internal\nEOF' "$TMP")"
t "tee heredoc 의 pymysql 문구 + 같은 호출의 python 실행 → 차단(쓰고 실행 — 문서 확장자 면제는 같은 호출에 실행이 없을 때만)" deny prod-db-guard.sh \
  "$(json_cmd $'python3 add_term.py lookup x; tee -a note.md <<\'EOF\'\npymysql 은 쓰지 마라\nEOF' "$TMP")"
t "python3 - <<PY 로 받는 pymysql 운영 접속 → 차단(우회 금지)" deny prod-db-guard.sh \
  "$(json_cmd $'python3 - <<\'PY\'\nimport pymysql\npymysql.connect(host="db.prod.internal")\nPY' "$TMP")"
t "bash <<EOF 로 받는 mariadb 운영 접속 → 차단" deny prod-db-guard.sh \
  "$(json_cmd $'bash <<EOF\nmariadb -h db.prod.internal -e "select 1"\nEOF' "$TMP")"
t "heredoc 뒤 이어지는 실제 접속 → 차단" deny prod-db-guard.sh \
  "$(json_cmd $'cat > x.md <<\'EOF\'\nmemo\nEOF\nmariadb -h db.prod.internal -e "select 1"' "$TMP")"

echo "[22] zsh-glob-quote-guard — 미인용 글롭 옵션값 경고(비차단)"
w "--include=*.java 미인용 → 경고" warn zsh-glob-quote-guard.sh 'grep -rn foo --include=*.java src'
w "--exclude-dir=*-old 미인용 → 경고" warn zsh-glob-quote-guard.sh 'grep -rn foo --exclude-dir=*-old src'
w "rg -g *.xml 미인용 → 경고" warn zsh-glob-quote-guard.sh 'rg -g *.xml foo'
w "find -name *.sql 미인용 → 경고" warn zsh-glob-quote-guard.sh 'find . -name *.sql'
w "--include=\"*.java\" 인용 → 침묵" silent zsh-glob-quote-guard.sh 'grep -rn foo --include="*.java" src'
w "--include='*.java' --exclude-dir=target(글롭 없음) → 침묵" silent zsh-glob-quote-guard.sh "grep -rn foo --include='*.java' --exclude-dir=target src"
w "-name \\*.sql 이스케이프 → 침묵" silent zsh-glob-quote-guard.sh 'find . -name \*.sql'
w "heredoc 본문 안의 --include=*.java → 침묵" silent zsh-glob-quote-guard.sh $'cat <<EOF\n--include=*.java\nEOF'
w "주석 속 --include=*.java → 침묵" silent zsh-glob-quote-guard.sh 'grep -rn foo src # --include=*.java'
w "ls -g(옵션 동명·값 없음) → 침묵" silent zsh-glob-quote-guard.sh 'ls -g src'

echo "[23] mvn-am-guard — -pl 단독 빌드 경고(비차단)"
w "mvn -pl 웹모듈 without -am → 경고" warn mvn-am-guard.sh 'mvn -q -pl CMS-Admin test -Dmaven.repo.local=/x'
w "-pl 목록에 비리프 포함 → 경고" warn mvn-am-guard.sh 'mvn -pl CMS-Core,CMS-Front compile'
w "./mvnw -pl → 경고" warn mvn-am-guard.sh 'cd /x && ./mvnw -pl web-app package'
w "-pl + -am → 침묵" silent mvn-am-guard.sh 'mvn -q -pl CMS-Admin -am test'
w "--projects= + --also-make → 침묵" silent mvn-am-guard.sh 'mvn --projects=CMS-Front --also-make compile'
w "리프 모듈(Core) 단독 → 침묵" silent mvn-am-guard.sh 'mvn -q -pl CMS-Core test'
w "-pl 없는 전체 빌드 → 침묵" silent mvn-am-guard.sh 'mvn clean install'
w "따옴표 안 문구 → 침묵" silent mvn-am-guard.sh 'echo "mvn -pl CMS-Admin test"'
w "grep 인자 속 -pl → 침묵(비 mvn)" silent mvn-am-guard.sh 'grep -n "-pl CMS-Admin" docs/harness.md'


echo "=== [24] git-hooks-installed-guard (층 A 미설치 레포의 커밋 fail-closed) ==="
# --check 가 보는 것 = .claude/scripts/install-git-hooks.sh 와 .claude/hooks/git/<본문>·common dir 의 스텁. 설치 스크립트는 킷 스캐폴드 원본(자리표시 없음).
IGS="$KIT/global/agent-scaffold/claude/scripts/install-git-hooks.sh"
gmk() { # $1 이름 $2 = install|noinstall|noscript
  local r; r=$(repo "$1"); mkdir -p "$r/.claude/hooks/git" "$r/.claude/scripts"
  for n in pre-commit pre-push pre-merge-commit; do printf '#!/usr/bin/env bash\nexit 0\n# claude-layer-a-body-end v1\n' > "$r/.claude/hooks/git/$n"; done
  [ "$2" = noscript ] || cp "$IGS" "$r/.claude/scripts/"
  [ "$2" = install ] && (cd "$r" && bash .claude/scripts/install-git-hooks.sh >/dev/null 2>&1)
  printf '%s' "$r"
}
gt() { # $1 이름 $2 기대 $3 레포 $4 명령
  local got; got=$(printf '%s' "$(json_cmd "$4" "$3")" | (cd "$3" && CLAUDE_PROJECT_DIR="$3" bash "$H/git-hooks-installed-guard.sh") 2>/dev/null | decision)
  [ -n "$got" ] || got=allow
  [ "$got" = "$2" ] && ok "$1" || ng "$1 (기대 $2, 실제 $got)"
}
GU=$(gmk g-uninst noinstall); GI=$(gmk g-inst install); GN=$(gmk g-noscript noscript)
gt "미설치 레포 커밋 → 차단" deny "$GU" 'git commit -m x'
gt "설치 레포 커밋 → 통과" allow "$GI" 'git commit -m x'
gt "설치 스크립트 없음 → 차단" deny "$GN" 'git commit -m x'
gt "미설치 레포 비커밋 → 통과" allow "$GU" 'git status'
gt "미설치 프로젝트: 다른 레포 대상 커밋도 차단(대상 추정 없음)" deny "$GU" "git -C $GI commit -m x"
gt "미설치 프로젝트: 복합 명령(git -C 다른 레포 && git commit) → 차단" deny "$GU" "git -C $GI log -1 && git commit -m x"
gt "미설치 프로젝트: cd 다른 레포; cd 이 프로젝트; git commit → 차단" deny "$GU" "cd $GI; cd $GU; git commit -m x"
gt "설치 프로젝트: 미설치 레포 대상 커밋 → 통과(가드 무개입)" allow "$GI" "git -C $GU commit -m x"
GNG="$TMP/g-notgit"; mkdir -p "$GNG"   # 아직 git 저장소가 아닌 프로젝트(= 층 A 설치 전)
gt ".git 없는 프로젝트: 커밋 → 차단" deny "$GNG" 'git commit -m x'
gt ".git 없는 프로젝트: git init && git add && git commit(한 명령) → 차단" deny "$GNG" 'git init -q && git add README && git commit -qm init'
gt ".git 없는 프로젝트: git init 단독 → 통과" allow "$GNG" 'git init -q'
GNI="$GI/nested-proj"; mkdir -p "$GNI"   # 층 A 설치 상위 레포 안의 .git 없는 하위 프로젝트(rev-parse 는 상위를 잡는다)
gt "층 A 설치 상위 레포 안의 .git 없는 하위 프로젝트: git init && git add && git commit(한 명령) → 차단" deny "$GNI" 'git init -q && git add README && git commit -qm init'

echo "=== [25] mirror-history 자체검사(킷 원본 global/agent-scaffold — flock 잠금 경합·신호·python3 부재) ==="
_mt="$(cd "$(dirname "$0")" && pwd)/global/agent-scaffold/claude/hooks/mirror-history.test.sh"
# 그 자체검사는 python3·jq 가 없으면 선행조건에서 끝난다 — 이 단계는 건너뜀으로 알리고 실패로 세지 않는다.
if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "  - 건너뜀: python3 또는 jq 없음(mirror-history.test.sh 선행조건)"
else
  _mo="$(bash "$_mt" 2>&1)"; _mr=$?
  [ "$_mr" = 0 ] && ok "mirror-history.test.sh: $(printf '%s\n' "$_mo" | grep -E '^Tests run' | tail -1)" || ng "mirror-history.test.sh rc=$_mr: $(printf '%s\n' "$_mo" | grep -E '^[[:space:]]*FAIL|선행조건' | head -4 | tr '\n' ' ')$(printf '%s\n' "$_mo" | grep -E '^Tests run' | tail -1)"
fi

echo
if [ "$FAIL" = 0 ]; then echo "== 전체 PASS (${PASS}건) =="; exit 0
else echo "== 실패 ${FAIL}건 / 통과 ${PASS}건 — 위 ✗ 확인 =="; exit 1; fi
