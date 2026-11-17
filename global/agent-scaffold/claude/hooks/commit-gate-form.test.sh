#!/usr/bin/env bash
# 커밋 게이트 5종(sql-staging·secret-commit·test-count·mvn-test-result·code-review-marker)의 층 A / PreToolUse 분기 계약 테스트
# + 운영 DB 가드의 판정기 실패 계약(부재·시간 초과·rc≠0·형식 밖 출력·jq 부재). 킷 가드 v2(2026-11-11).
# 실행: bash .claude/hooks/commit-gate-form.test.sh   (jq·git·python3 필요 — 없으면 실행하지 않고 rc 2)
# 격리: mktemp 아래 임시 레포와 훅 사본(설치된 게이트 + prod-db-guard + lib/)만 쓴다. 실레포·실 설정은 건드리지 않는다.
# 게이트 부재: 이 디렉터리에 없는 게이트는 그 게이트의 행을 실행하지 않고 `skip <게이트>: 미설치` 를 낸다(Passed 에 세지 않는다).
#   게이트가 하나도 없으면 rc 2 — 미실행은 통과가 아니다. lib·판정기·jq 부재 단언은 설치된 게이트로 그대로 본다.
#   시간 초과 단언은 판정기 자리에 잠드는 python3 심을 놓고 `timeout 5` 가 끊는지 본다(단언마다 약 5초).
# 반증 예고(깨질 이름을 먼저 적는다):
#   - 게이트의 `_layer_a` 판정에서 GIT_INDEX_FILE 조건을 빼면 F1(위조) 5건이 allow 로 샌다.
#   - 게이트의 층 A 분기를 없애고 모든 호출을 허용 형태로 판정하면 L1(층 A 합성 명령) 5건이 deny 로 막힌다.
#   - PreToolUse 분기를 없애고 종전 git_has_subcommand 로 되돌리면 P1(add && commit) 중 인덱스에 걸릴 것이 없는 게이트가 allow 로 샌다.
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
for _t in jq git python3; do
  command -v "$_t" >/dev/null 2>&1 || { echo "전제 도구 없음($_t) — 테스트를 실행하지 않았다"; exit 2; }
done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GATE_LAYER CLAUDECODE ALLOW_TEST_COUNT_DROP ALLOW_UNTESTED_COMMIT

TMP=$(mktemp -d "${TMPDIR:-/tmp}/commit-gate-form.XXXXXX") || { echo "mktemp 실패"; exit 2; }
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
ALL_GATES="sql-staging-guard secret-commit-guard test-count-guard mvn-test-result-gate code-review-marker-reminder"
GATES=""
for g in $ALL_GATES; do
  if [ -f "$SRC/$g.sh" ]; then GATES="$GATES $g"; else echo "skip $g: 미설치"; fi
done
[ -n "$GATES" ] || { echo "게이트가 하나도 설치돼 있지 않다 — 실행된 단언 0, 미실행은 통과가 아니다"; exit 2; }
_has() { case " $GATES " in *" $1 "*) return 0;; esac; return 1; }

_mkhooks() { # $1 = 대상 디렉터리, $2 = full|nolib|nocmdform
  mkdir -p "$1/lib"
  for g in $GATES prod-db-guard; do cp "$SRC/$g.sh" "$1/"; done
  [ "$2" = nolib ] && return 0
  cp "$SRC/lib/git-cmd.sh" "$SRC/lib/review-diff.sh" "$1/lib/"
  [ "$2" = nocmdform ] || cp "$SRC/lib/cmdform.py" "$1/lib/"
}
HK="$TMP/hooks"; _mkhooks "$HK" full
HN="$TMP/hooks-nolib"; _mkhooks "$HN" nolib
HC="$TMP/hooks-nocmdform"; _mkhooks "$HC" nocmdform

_g() { git -C "$R" "$@" >/dev/null 2>&1; }
_repo() { # 새 레포(기준 커밋 하나) → R
  R="$TMP/r$1"; mkdir -p "$R"; _g init -q; _g config user.name t; _g config user.email t@example.invalid; _g config commit.gpgsign false
  printf 'base\n' > "$R/base.txt"; _g add base.txt; _g commit -qm base
}
run=0; passed=0; skipped=0; OUT=""
_skip() { skipped=$((skipped + $1)); } # $1 = 실행하지 않은 단언 수(게이트 미설치)
for g in $ALL_GATES; do _has "$g" || _skip 10; done   # 아래 게이트 루프의 게이트당 단언 수
_ok() { run=$((run + 1)); if [ "$1" = 0 ]; then passed=$((passed + 1)); printf 'ok    %s\n' "$2"; else printf 'FAIL  %s %s\n' "$2" "${3:-}"; fi; }
_call() { # $1 = 훅 파일, $2 = 명령, 나머지 = env 대입 → OUT 에 출력
  local h=$1 c=$2; shift 2
  OUT=$(jq -cn --arg c "$c" --arg d "$R" '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' \
    | env CLAUDE_PROJECT_DIR="$R" "$@" bash "$h" 2>/dev/null)
}
_dec() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null | head -1; }
_is_deny() { [ "$(_dec)" = deny ]; }
_is_pass() { [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ] || [ "$(_dec)" = allow ]; }

echo "== 게이트 5종 — 층 A / PreToolUse 분기 =="
_repo 1; printf 'x\n' > "$R/x.txt"   # 인덱스는 비어 있다(게이트 실검사에 걸릴 것이 없다 — 판정은 형태만으로 갈린다)
for g in $GATES; do
  H="$HK/$g.sh"
  _call "$H" 'git add x.txt && git commit -m y'
  _is_deny && printf '%s' "$OUT" | grep -q '허용 형태가 아닌 커밋 호출'; _ok $? "P1 $g: PreToolUse add && commit → deny(허용 형태 밖)"
  _call "$H" 'git commit -m y'
  _is_pass; _ok $? "P2 $g: PreToolUse 단독 커밋(검사할 스테이징 없음) → 통과"
  _call "$H" 'ALLOW_TEST_COUNT_DROP=1 ; git commit'
  _is_deny; _ok $? "P3 $g: PreToolUse 층 A 합성 꼴(대입 ; 커밋) → deny"
  _call "$H" 'git add x.txt && git commit -m y' GATE_LAYER=git
  _is_deny; _ok $? "F1 $g: GATE_LAYER=git 위조(GIT_INDEX_FILE 없음) → PreToolUse 판정(deny)"
  _call "$H" 'ALLOW_TEST_COUNT_DROP=1 ; git commit' GATE_LAYER=git GIT_INDEX_FILE="$R/.git/index"
  _is_pass; _ok $? "L1 $g: 층 A(GATE_LAYER=git + GIT_INDEX_FILE) 합성 명령 → 현행 판정(통과)"
  _call "$H" 'ls -la && git status'
  _is_pass; _ok $? "P4 $g: 비커밋 → 통과"
  _call "$HN/$g.sh" 'git commit -m y'
  _is_deny; _ok $? "B1 $g: lib 부재 + 커밋 → deny(fail-closed)"
  _call "$HN/$g.sh" 'ls -la'
  _is_pass; _ok $? "B2 $g: lib 부재 + 비커밋 → 통과"
  _call "$HC/$g.sh" 'git commit -m y'
  _is_deny && printf '%s' "$OUT" | grep -q '판정기 부재'; _ok $? "B3 $g: 판정기(cmdform.py) 부재 + 커밋 → deny(대체 판정)"
  _call "$HC/$g.sh" 'git log --grep=commit'
  _is_pass; _ok $? "B4 $g: 판정기 부재 + 단일 읽기 명령(git log --grep=commit) → 통과(대체 판정 2단계)"
done

echo "== jq 부재(PreToolUse = fail-closed, 층 A = 현행 통과) =="
NJ="$TMP/nojq-bin"; mkdir -p "$NJ"
for t in cat sed grep tr head dirname git python3 timeout; do p=$(command -v "$t") && ln -s "$p" "$NJ/$t"; done
BASH_BIN=$(command -v bash)
for g in sql-staging-guard code-review-marker-reminder; do
  _has "$g" || { _skip 3; continue; }
  OUT=$(jq -cn --arg c 'git commit -m y' --arg d "$R" '{tool_input:{command:$c},cwd:$d}' | env PATH="$NJ" "$BASH_BIN" "$HK/$g.sh" 2>/dev/null)
  _is_deny; _ok $? "J1 $g: jq 부재 + 커밋 → deny"
  OUT=$(jq -cn --arg c 'ls -la' --arg d "$R" '{tool_input:{command:$c},cwd:$d}' | env PATH="$NJ" "$BASH_BIN" "$HK/$g.sh" 2>/dev/null)
  _is_pass; _ok $? "J2 $g: jq 부재 + 비커밋 → 통과"
  OUT=$(jq -cn --arg c 'git commit' --arg d "$R" '{tool_input:{command:$c},cwd:$d}' | env PATH="$NJ" GATE_LAYER=git GIT_INDEX_FILE="$R/.git/index" "$BASH_BIN" "$HK/$g.sh" 2>/dev/null)
  _is_pass; _ok $? "J3 $g: jq 부재 + 층 A → 통과(종전 동작 — 도구 부재 판정은 디스패처 몫)"
done
OUT=$(jq -cn --arg c 'mysql -h prod-db.example.invalid' '{tool_input:{command:$c}}' | env PATH="$NJ" "$BASH_BIN" "$HK/prod-db-guard.sh" 2>/dev/null)
_is_deny; _ok $? "J4 prod-db-guard: jq 부재 + DB 낱말 → deny"
OUT=$(jq -cn --arg c 'ls -la' '{tool_input:{command:$c}}' | env PATH="$NJ" "$BASH_BIN" "$HK/prod-db-guard.sh" 2>/dev/null)
_is_pass; _ok $? "J5 prod-db-guard: jq 부재 + 무관 명령 → 통과"

echo "== 판정기 시간 초과·rc≠0·형식 밖 출력 → deny =="
SL="$TMP/slow-bin"; mkdir -p "$SL"; printf '#!/bin/sh\nsleep 30\n' > "$SL/python3"; chmod +x "$SL/python3"
BD="$TMP/bad-bin"; mkdir -p "$BD"; printf '#!/bin/sh\nexit 1\n' > "$BD/python3"; chmod +x "$BD/python3"
GB="$TMP/garbage-bin"; mkdir -p "$GB"; printf '#!/bin/sh\necho ALLOWED\n' > "$GB/python3"; chmod +x "$GB/python3"
if command -v timeout >/dev/null 2>&1; then
  if _has sql-staging-guard; then
    _t0=$(date +%s); _call "$HK/sql-staging-guard.sh" 'git commit -m y' PATH="$SL:$PATH"; _t1=$(date +%s)
    _is_deny && [ $((_t1 - _t0)) -lt 15 ]; _ok $? "T1 sql-staging-guard: 판정기 시간 초과 → deny($((_t1 - _t0))s)"
  else _skip 1; fi
  _t0=$(date +%s); _call "$HK/prod-db-guard.sh" 'mysql -h localhost -e "select 1"' PATH="$SL:$PATH"; _t1=$(date +%s)
  _is_deny && [ $((_t1 - _t0)) -lt 15 ]; _ok $? "T2 prod-db-guard: 판정기 시간 초과 → deny($((_t1 - _t0))s)"
else
  echo "skip  T1·T2 timeout 명령 없음 — 판정기 내부 상한(LIMIT_SEC)은 lib/cmdform.test.sh E1 이 본다"
fi
if _has sql-staging-guard; then
  _call "$HK/sql-staging-guard.sh" 'git commit -m y' PATH="$BD:$PATH"
  _is_deny; _ok $? "T3 sql-staging-guard: 판정기 rc≠0 → deny"
  _call "$HK/sql-staging-guard.sh" 'git commit -m y' PATH="$GB:$PATH"
  _is_deny; _ok $? "T4 sql-staging-guard: 판정기 형식 밖 출력 → deny"
else _skip 2; fi
_call "$HK/prod-db-guard.sh" 'mysql -h localhost -e "select 1"' PATH="$BD:$PATH"
_is_deny; _ok $? "T5 prod-db-guard: 판정기 rc≠0 → deny"
_call "$HK/prod-db-guard.sh" 'mysql -h localhost -e "select 1"' PATH="$GB:$PATH"
_is_deny; _ok $? "T6 prod-db-guard: 판정기 형식 밖 출력 → deny"
_call "$HC/prod-db-guard.sh" 'mysql -h localhost -e "select 1"'
_is_deny; _ok $? "T7 prod-db-guard: 판정기 부재 + DB 낱말 → deny"
_call "$HC/prod-db-guard.sh" 'ls -la'
_is_pass; _ok $? "T8 prod-db-guard: 판정기 부재 + 무관 명령 → 통과(빠른 경로)"
_call "$HK/prod-db-guard.sh" 'mysql -h localhost -e "select 1"'
_is_pass; _ok $? "T9 prod-db-guard: 판정기 정상 + 로컬 표준 포트 CLI → 통과(음성 대조)"

if _has sql-staging-guard; then
  echo "== sql-staging-guard 안내(S11·N14) — 따라 쳐도 추적 파일 삭제가 커밋되지 않는다 =="
  _repo 2; printf 'select 1;\n' > "$R/a.sql"; _g add a.sql; _g commit -qm tracked
  _g mv a.sql b.sql
  _call "$HK/sql-staging-guard.sh" 'git commit -m y'
  _fix=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' | grep -E '^  git restore --staged -- ' | sed 's/^  //')
  [ "$_fix" = "git restore --staged -- b.sql a.sql" ]; _ok $? "S1 이름 변경 R a.sql→b.sql → restore 에 새·옛 경로 함께" "got=[$_fix]"
  (cd "$R" && eval "$_fix") >/dev/null 2>&1
  [ -z "$(git -C "$R" diff --cached --name-status)" ] && [ -f "$R/b.sql" ]; _ok $? "S2 안내대로 치면 인덱스에 a.sql 삭제가 남지 않고 워킹트리 b.sql 보존"
  _repo 3; printf 'select 1;\n' > "$R/old.sql"; _g add old.sql; _g commit -qm tracked
  _g rm -q old.sql; printf 'completely different body\nline2\nline3\n' > "$R/new one.sql"; _g add "new one.sql"
  _call "$HK/sql-staging-guard.sh" 'git commit -m y'
  _rs=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
  printf '%s' "$_rs" | grep -qF 'git restore --staged -- new\ one.sql old.sql' && printf '%s' "$_rs" | grep -qF '그 삭제가 의도한 것이면'
  _ok $? "S3 D(추적 .sql 삭제) + A(공백 든 새 .sql) → 둘 다 인용해 안내 + 의도한 삭제 문구"
  R="$TMP/r4"; mkdir -p "$R"; _g init -q; printf 'x\n' > "$R/seed.sql"; _g add seed.sql
  _call "$HK/sql-staging-guard.sh" 'git commit -m y'
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' | grep -qF 'git rm --cached -- seed.sql'
  _ok $? "S4 HEAD 없음(첫 커밋 전) → git rm --cached 안내"
  _call "$HK/sql-staging-guard.sh" 'ALLOW_TEST_COUNT_DROP=1 ; git commit' GATE_LAYER=git GIT_INDEX_FILE="$R/.git/index"
  _is_deny; _ok $? "S5 층 A 경로도 같은 판정(신규 .sql → deny)"
else _skip 5; fi

if _has code-review-marker-reminder; then
  echo "== code-review-marker — PreToolUse 지문은 정규형 git commit(메시지 속 -a 낱말 무관) =="
  _repo 5; mkdir -p "$R/.claude"; printf 'staged\n' > "$R/s.txt"; _g add s.txt; printf 'dirty\n' >> "$R/base.txt"
  _h=$(. "$HK/lib/review-diff.sh"; review_diff_hash "$R" "git commit")
  printf '%s %s\n' "$(date +%F)" "$_h" > "$R/.claude/.last-review"
  _call "$HK/code-review-marker-reminder.sh" 'git commit -m "fix -a flag parsing"'
  _is_pass; _ok $? "R1 메시지 속 -a 낱말 + 스테이징 지문 마커 → 통과(S5 — 종전엔 워킹트리 지문으로 갈려 차단)"
  printf 'more\n' >> "$R/s.txt"; _g add s.txt
  _call "$HK/code-review-marker-reminder.sh" 'git commit -m "fix"'
  _is_deny && printf '%s' "$OUT" | grep -q '마커의 지문'; _ok $? "R2 마커 이후 스테이징 변경 → 차단(음성 대조)"
else _skip 2; fi

echo
echo "Tests run: $run, Passed: $passed, Skipped: $skipped"
[ "$run" -gt 0 ] || { echo "실행된 단언 0 — 미실행은 통과가 아니다"; exit 2; }
[ "$run" -eq "$passed" ]
