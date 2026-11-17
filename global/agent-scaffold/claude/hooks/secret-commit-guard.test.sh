#!/usr/bin/env bash
# secret-commit-guard.sh 회귀 — 임시 레포에서 게이트를 직접 부른다(가짜 PreToolUse stdin + GATE_LAYER=git,
#   층 A 디스패처가 넘기는 형태). 판정 = 출력의 permissionDecision 이 deny 인가.
# 대상: 이름 변경(R) 줄 스캔(옛·새 경로를 함께 넘겨 바뀐 줄만 본다)·값 비노출·예외 경로(EXCLUDE_PATH_REGEX 값이 기대를 정한다).
# 격리: mktemp 레포 + HOME 격리 + GIT_CONFIG_GLOBAL=/dev/null — 실레포·실 설정·.git/hooks 는 건드리지 않는다.
# 케이스 추가 = 아래 절에 `_fresh` → 파일 조작 → `_c <기대> "<설명>"` 한 묶음.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY CLAUDECODE

H="$(cd "$(dirname "$0")" && pwd)/secret-commit-guard.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/secret-guard-test.XXXXXX") || { echo "mktemp 실패"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$HOME"

REAL='Zq9realValue77'   # 가짜 실값 — 출력에 나오면 값 노출
run=0; passed=0; LAST_OUT=""
_ok() { # _ok <참이면 0> <설명>
  run=$((run + 1))
  if [ "$1" = 0 ]; then passed=$((passed + 1)); printf 'ok    %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; fi
}
_gate() {
  jq -n --arg c "git commit" --arg d "$R" \
    '{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' \
    | GATE_LAYER=git bash "$H" 2>/dev/null
}
_c() { # _c deny|allow <설명>
  local d
  LAST_OUT=$(_gate)
  if [ "$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = deny ]; then d=deny; else d=allow; fi
  [ "$d" = "$1" ]; _ok $? "$2 [기대=$1 실제=$d]"
}
_g() { git -C "$R" "$@" >/dev/null 2>&1; }
_fresh() { # 새 레포 + 기준 커밋
  R="$TMP/r$run"; rm -rf "$R"; mkdir -p "$R"
  _g init -q; _g config user.name t; _g config user.email t@example.invalid; _g config commit.gpgsign false
}
_java() { # 이름 변경 짝짓기(-M 유사도)가 성립할 만큼 긴 본문 + 기존 리터럴 한 줄
  printf 'package a;\n'
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'class L%s { int v%s = %s; }\n' "$i" "$i" "$i"; done
  printf 'class Fixture { String password = "abcdef12"; }\n'
}

echo "== 이름 변경(R) 줄 스캔 =="
_fresh
mkdir -p "$R/src"; _java > "$R/src/A.java"; _g add -A; _g commit -qm base
_g mv src/A.java src/B.java
_c allow "R1 git mv 만(내용 그대로, 기존 리터럴 있음) → 통과"

_fresh
mkdir -p "$R/src"; _java > "$R/src/A.java"; _g add -A; _g commit -qm base
_g mv src/A.java src/B.java
printf 'class Added { String password = "%s"; }\n' "$REAL" >> "$R/src/B.java"; _g add src/B.java
_c deny "R2 rename + 비밀 리터럴 추가 → 차단"
printf '%s' "$LAST_OUT" | grep -q "$REAL"; [ $? -ne 0 ]; _ok $? "R2 출력에 실값이 없다(마스킹)"
[ "$(git -C "$R" diff --cached -M --name-status | cut -c1)" = R ]; _ok $? "R2 전제: 인덱스가 R 로 짝지어졌다"

_fresh
mkdir -p "$R/src"; _java > "$R/src/A.java"; _g add -A
_c deny "R3 대조: 같은 리터럴의 신규 파일(A) → 차단"

# 예외 판정은 새 경로 기준 — 제외 경로(프로파일 설정)에서 제외 밖으로 이름을 바꾸며 리터럴을 더하면 스캔된다.
_fresh
FILL=$(for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do printf 'app.filler.entry%s=value-%s\\n' "$i" "$i"; done)   # rename 짝짓기 유사도 확보용
printf "${FILL}" > "$R/application-prod.properties"; _g add -A; _g commit -qm base
mkdir -p "$R/cfg"; _g mv application-prod.properties cfg/app.conf
printf 'spring.datasource.password=%s\n' "$REAL" >> "$R/cfg/app.conf"; _g add -A
[ "$(git -C "$R" diff --cached -M --name-status | cut -c1)" = R ]; _ok $? "R4 전제: 인덱스가 R 로 짝지어졌다"
_c deny "R4 제외 경로 → 제외 밖으로 rename + 리터럴 추가 → 차단"

echo "== 예외 경로(EXCLUDE_PATH_REGEX) — 프로파일 설정 =="
# 기대는 게이트의 EXCLUDE_PATH_REGEX 대입 줄이 정한다: 경로가 예외면 통과, 아니면(킷 기본 = 빈 값) 차단.
P=application-prod.properties
grep -q "^EXCLUDE_PATH_REGEX='" "$H"; _ok $? "P0 전제: 게이트의 EXCLUDE_PATH_REGEX 대입 줄을 읽었다"
_x=$(sed -n "s/^EXCLUDE_PATH_REGEX='\([^']*\)'.*/\1/p" "$H" | head -n 1)
_fresh
printf 'a=1\n' > "$R/$P"; _g add -A; _g commit -qm base
printf 'a=1\nspring.datasource.password=%s\n' "$REAL" > "$R/$P"; _g add -A
if [ -n "$_x" ] && printf '%s\n' "$P" | grep -qE -- "$_x"; then
  _c allow "P1 예외 경로 → 실값 추가도 통과"
else
  _c deny "P1 예외 경로 밖(빈 값 = 전 파일 스캔) → 실값 추가 차단"
fi

echo "Tests run: $run, Passed: $passed"
[ "$run" -gt 0 ] && [ "$run" = "$passed" ]
