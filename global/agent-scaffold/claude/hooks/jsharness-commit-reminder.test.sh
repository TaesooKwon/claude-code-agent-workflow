#!/usr/bin/env bash
# jsharness-commit-reminder.sh 자체검사.
# 실행: bash .claude/hooks/jsharness-commit-reminder.test.sh
#
# 샌드박스 git 레포를 mktemp 로 만들어 실물 훅에 stdin JSON 을 먹인다. 이 레포의 .claude/.last-jsharness 는
# 건드리지 않는다(CLAUDE_PROJECT_DIR 을 샌드박스로 덮어쓴다). 정리는 trap EXIT.
# ※ 커밋 명령 문자열은 이 파일 안에만 둔다 — Bash 도구 명령줄에 직접 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
# GATE 환경변수로 검사 대상 훅을 바꿀 수 있다(변이 반증용 사본).
set -u

HOOKS_DIR="{{ROOT}}/.claude/hooks"
GATE="${GATE:-$HOOKS_DIR/jsharness-commit-reminder.sh}"

for f in "$GATE" "$(dirname "$GATE")/lib/git-cmd.sh"; do
  [ -f "$f" ] || { echo "선행조건 실패: $f 없음"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "선행조건 실패: jq 없음"; exit 1; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/jsharness-gate-XXXXXX") || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# 검사 대상 훅의 DEV_JS_PATH_REGEX 줄 값만 바꾼 사본을 만든다(lib 도 함께 — 훅이 dirname 기준으로 읽는다).
# 값은 환경변수로 넘겨 awk 이스케이프를 피한다. 설치 레포가 그 값을 바꿔도(예: js/front) 테스트가 깨지지 않게
# 기본 케이스도 아래에서 js/develop 를 **명시한** 사본으로 돈다 — 훅 동작이 아니라 테스트 가정이 레포 값에 묶이지 않게.
SRC_GATE=$GATE
variant() { # 이름 값(따옴표 포함 셸 리터럴) → 사본 경로
  local d="$SANDBOX/gv-$1"; mkdir -p "$d/lib"
  cp "$(dirname "$SRC_GATE")/lib/git-cmd.sh" "$d/lib/"
  V="$2" awk 'index($0, "DEV_JS_PATH_REGEX=") == 1 && !done { print "DEV_JS_PATH_REGEX=" ENVIRON["V"]; done = 1; next } { print }' \
    "$SRC_GATE" > "$d/jsharness-commit-reminder.sh"
  grep -q '^DEV_JS_PATH_REGEX=' "$SRC_GATE" || { echo "선행조건 실패: 검사 대상 훅에 DEV_JS_PATH_REGEX 줄 없음" >&2; exit 1; }
  printf '%s' "$d/jsharness-commit-reminder.sh"
}
GATE=$(variant develop "'(^|/)js/develop/.+\\.js\$'") || exit 1

COMMIT_CMD='git commit -m "feat: 샌드박스 커밋 명령(실행되지 않음)"'
JS_DIR='{{MODULE_ADMIN}}/src/main/resources/static/resources/js/develop/foo'

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
  mkdir -p "$r/{{MODULE_CORE}}/src/main/java" "$r/.claude" "$r/$JS_DIR"
  git -C "$r" init -q >/dev/null 2>&1
  git -C "$r" config user.email "t@example.com"
  git -C "$r" config user.name "t"
  : > "$r/.gitignore"
  git -C "$r" add .gitignore >/dev/null 2>&1
  git -C "$r" commit -q -m init >/dev/null 2>&1
  printf '%s' "$r"
}

stage() { # 레포 상대경로 → 파일 생성·스테이징
  mkdir -p "$(dirname "$1/$2")"
  printf 'var a = 1;\n' > "$1/$2"
  git -C "$1" add "$2" >/dev/null 2>&1
}

jmtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

pre_json() { jq -n --arg c "$1" --arg d "$2" \
  '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }

gate_raw() { # stdin원문 프로젝트루트 → "warn|none|deny|other|<exit>"
  local o rc d
  o=$(printf '%s' "$1" | CLAUDE_PROJECT_DIR="$2" bash "$GATE" 2>/dev/null); rc=$?
  if [ -z "$o" ]; then d=none
  elif [ -n "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" ]; then d=deny
  else
    case "$(printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)" in
      '[jsharness-commit] '*) d=warn ;;
      *) d=other ;;
    esac
  fi
  printf '%s|%s' "$d" "$rc"
}

check() { # 설명 기대 cmd repo [cwd] — 판정과 exit 0 을 함께 단언
  assert_eq "$1" "$2|0" "$(gate_raw "$(pre_json "$3" "${5:-$4}")" "$4")"
}

echo "── 게이트(PreToolUse, 경고 전용) ────────────────────"

r=$(mkrepo 1)
stage "$r" "{{MODULE_CORE}}/src/main/java/A.java"
check "G1 음성: js/develop .js 스테이징 없음(.java 만) → 무출력" none "$COMMIT_CMD" "$r"

r=$(mkrepo 2)
stage "$r" "{{MODULE_ADMIN}}/src/main/resources/static/resources/js/design/x.js"
check "G2 음성: js/design .js 만 스테이징 → 무출력" none "$COMMIT_CMD" "$r"

r=$(mkrepo 3)
stage "$r" "$JS_DIR/a.js"
check "G3 ①: 기록 없음 → 경고" warn "$COMMIT_CMD" "$r"

r=$(mkrepo 4)
stage "$r" "$JS_DIR/a.js"
printf 'garbage line\n' > "$r/.claude/.last-jsharness"
check "G4 ①: 기록 형식 깨짐 → 경고" warn "$COMMIT_CMD" "$r"

r=$(mkrepo 5)
stage "$r" "$JS_DIR/a.js"
m=$(jmtime "$r/$JS_DIR/a.js")
printf '%s 12 1\n' "$((m + 10))" > "$r/.claude/.last-jsharness"
check "G5 ②: Failures>0(신선) → 경고" warn "$COMMIT_CMD" "$r"

r=$(mkrepo 6)
stage "$r" "$JS_DIR/a.js"
m=$(jmtime "$r/$JS_DIR/a.js")
printf '%s 0 0\n' "$((m + 10))" > "$r/.claude/.last-jsharness"
check "G6 ③: Tests run 0(신선) → 경고" warn "$COMMIT_CMD" "$r"

r=$(mkrepo 7)
stage "$r" "$JS_DIR/a.js"
m=$(jmtime "$r/$JS_DIR/a.js")
printf '%s 12 0\n' "$((m - 10))" > "$r/.claude/.last-jsharness"
check "G7 ④: 기록이 스테이징 JS 보다 오래됨(초록) → 경고" warn "$COMMIT_CMD" "$r"

r=$(mkrepo 8)
stage "$r" "$JS_DIR/a.js"
m=$(jmtime "$r/$JS_DIR/a.js")
printf '%s 12 0\n' "$((m + 10))" > "$r/.claude/.last-jsharness"
check "G8 음성: 신선·초록 기록 → 무출력" none "$COMMIT_CMD" "$r"
r=$(mkrepo 9)
stage "$r" "$JS_DIR/a.js"
check "G9 음성: 커밋 아닌 명령(git status, js 스테이징·기록 없음) → 무출력" none "git status" "$r"

r=$(mkrepo 10)
stage "$r" "$JS_DIR/a.js"
assert_eq "G10 음성: 깨진 JSON → 무출력·exit 0" "none|0" "$(gate_raw 'not a json {' "$r")"

r=$(mkrepo 11)
stage "$r" "$JS_DIR/a.js"
check "G11 ①: 하위 디렉터리 cwd 에서 커밋해도 레포 루트 기준으로 판정 → 경고" warn "$COMMIT_CMD" "$r" "$r/$JS_DIR"

echo "── 개발 JS 경로 변수(DEV_JS_PATH_REGEX) ─────────────"
# variant() 는 위(설정 직후)에 정의돼 있다 — 기본 케이스 G1~G11 도 같은 방식으로 값을 명시한 사본을 쓴다.
FRONT=$(variant front "'(^|/)js/front/.+\\.js\$'")
EMPTY=$(variant empty "''")
ORIG_GATE=$GATE

r=$(mkrepo 12)
stage "$r" "Web/src/main/resources/static/js/front/b.js"
GATE=$FRONT; check "G12 변수=js/front: js/front 스테이징·기록 없음 → 경고" warn "$COMMIT_CMD" "$r"; GATE=$ORIG_GATE

r=$(mkrepo 13)
stage "$r" "$JS_DIR/a.js"
GATE=$FRONT; check "G13 변수=js/front: js/develop 만 스테이징 → 무출력" none "$COMMIT_CMD" "$r"; GATE=$ORIG_GATE

r=$(mkrepo 14)
stage "$r" "$JS_DIR/a.js"
GATE=$EMPTY; check "G14 변수 빈 값 → 기본값(js/develop) 판정 → 경고" warn "$COMMIT_CMD" "$r"; GATE=$ORIG_GATE

# 빈 정규식은 grep -E 에서 모든 줄에 맞는다 — 기본값 대입이 빠지면 개발 JS 가 아닌 스테이징에도 경고가 난다.
r=$(mkrepo 15)
stage "$r" "Web/src/main/resources/static/js/front/b.js"
GATE=$EMPTY; check "G15 변수 빈 값 + js/front 만 스테이징 → 무출력(빈 정규식 전부 매치 방지)" none "$COMMIT_CMD" "$r"; GATE=$ORIG_GATE

echo
echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ] || exit 1
