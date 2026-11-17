#!/usr/bin/env bash
# text-constant-3layer-reminder.sh 반증검사 — 양성(레포 소스 잔존 → 발화)·음성(잔존 0 → 미발화)·
# 우회(비커밋 명령 → 미발화)·경계(docs 백업 파일 제외)·절단(10개 초과 시 "N개 더")·설정 변수·
# 건수 축(줄 단위)·시한 값 10진 해석·시한 상한(등록 timeout)·미완료 경고(시한 초과·대조 실패·diff 읽기 실패) + 마지막 줄에 "Tests run: N, Passed: M".
#
# 매 케이스마다 독립된 임시 git 저장소를 만들어(mktemp -d) 실제 레포를 건드리지 않는다.
# ⚠️ HOME 을 임시 디렉터리로 덮어써 실행한다 — 훅이 참조하는 전역 회귀 스위트 경로
#   ($HOME/.claude/skills/playwright-verify/suites/{{PROJECT_NAME}})가 이 세션의 진짜 전역 디렉터리와
#   섞이지 않게 하기 위함(데이터손실 방지 — 실물 디렉터리를 읽지도 쓰지도 않는다).
# ⚠️ git add 는 항상 명시 경로만 쓴다(-A/--all/-u/. 금지 — 이 레포의 git-add-all-guard.sh 가
#   세션 전체 Bash 호출을 차단한다). 이 파일은 `bash text-constant-3layer-reminder.test.sh` 로만
#   실행한다(파일 내부의 'git commit' 문구가 이 테스트 스크립트를 감싸는 Bash 호출문 자체에는
#   나타나지 않아야 이 레포의 커밋 훅들이 오발동하지 않는다).
set -u
unset TEXT3_BUDGET_SEC  # 호출자 환경의 시한 값이 기본값 케이스에 섞이지 않게 한다

# HOOK 환경변수로 검사 대상 훅을 바꿀 수 있다(변이 반증용 사본 — 같은 폴더에 lib/ 가 있어야 한다).
HOOK="${HOOK:-$(cd "$(dirname "$0")" && pwd)/text-constant-3layer-reminder.sh}"
[ -x "$HOOK" ] || { echo "훅 파일이 없거나 실행권한이 없습니다: $HOOK" >&2; exit 1; }

run=0
pass=0

assert() {
  label="$1"; ok="$2"
  run=$((run + 1))
  if [ "$ok" -eq 0 ]; then
    pass=$((pass + 1))
    echo "PASS: $label"
  else
    echo "FAIL: $label"
  fi
}

# mk_repo <dir> — Sample.java(한글 리터럴 1개) + docs/readme.md 를 커밋한 baseline 저장소를 만든다.
mk_repo() {
  dir="$1"; lit="$2"
  mkdir -p "$dir/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test" "$dir/docs"
  cat > "$dir/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java" <<JAVA
package com.example.app.test;
public class Sample {
    public static final String MSG = "${lit}";
}
JAVA
  echo "# doc" > "$dir/docs/readme.md"
  ( cd "$dir" \
    && git init -q \
    && git config user.email t@example.com \
    && git config user.name test \
    && git add {{MODULE_CORE}} docs \
    && git commit -q -m init >/dev/null )
}

# stage_removal <dir> <old> <new> — Sample.java 의 리터럴을 바꿔 스테이징한다(제거 라인 생성).
stage_removal() {
  dir="$1"; old="$2"; new="$3"
  sed -i '' "s/${old}/${new}/" "$dir/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java"
  ( cd "$dir" && git add {{MODULE_CORE}} )
}

# run_hook <dir> [command] — 훅을 실행해 additionalContext 문자열만 표준출력에 낸다(없으면 빈 문자열).
run_hook() {
  dir="$1"; command_str="${2:-git commit -m t}"
  jq -n --arg cmd "$command_str" --arg cwd "$dir" '{tool_input:{command:$cmd}, cwd:$cwd}' \
    | HOME="$dir/fakehome" CLAUDE_PROJECT_DIR="$dir" "$HOOK" 2>/dev/null \
    | python3 -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('hookSpecificOutput',{}).get('additionalContext',''))
except Exception:
    pass" 2>/dev/null
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/tc3l-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# 검사 대상 훅의 SOURCE_EXCLUDE_REGEX 줄 값만 바꾼 사본(lib 함께 — 훅이 dirname 기준으로 읽는다). 값은 환경변수로 넘긴다.
# 설치 레포가 그 값을 바꿔도(예: src/main/html 추가) 같은 테스트가 통과하도록, 기본값을 전제로 하는 케이스까지
# 전부 기본값을 **명시한** 사본으로 돈다 — 설치값을 그대로 쓰는 케이스는 두지 않는다.
SRC_HOOK=$HOOK
svariant() { # 이름 값(따옴표 포함 셸 리터럴) → 사본 경로
  local d="$WORK/sv-$1"; mkdir -p "$d/lib"
  cp "$(dirname "$SRC_HOOK")/lib/git-cmd.sh" "$d/lib/"
  grep -q '^SOURCE_EXCLUDE_REGEX=' "$SRC_HOOK" || { echo "선행조건 실패: 훅에 SOURCE_EXCLUDE_REGEX 줄 없음" >&2; exit 1; }
  V="$2" awk 'index($0, "SOURCE_EXCLUDE_REGEX=") == 1 && !done { print "SOURCE_EXCLUDE_REGEX=" ENVIRON["V"]; done = 1; next } { print }' \
    "$SRC_HOOK" > "$d/text-constant-3layer-reminder.sh"
  chmod +x "$d/text-constant-3layer-reminder.sh"
  printf '%s' "$d/text-constant-3layer-reminder.sh"
}
HOOK=$(svariant default "'(^|/)(target|static/html)/'") || exit 1

# ---- 양성: 레포 소스(다른 파일)에 리터럴이 남아있으면 발화 ----
pos="$WORK/pos"
mk_repo "$pos" "저장되었습니다"
cp "$pos/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java" \
   "$pos/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Other.java"
( cd "$pos" && git add {{MODULE_CORE}} && git commit -q -m other >/dev/null )
stage_removal "$pos" "저장되었습니다" "완료되었습니다"
out_pos=$(run_hook "$pos")
case "$out_pos" in
  *"저장되었습니다"*"잔존"*) assert "양성(소스 잔존 → 발화)" 0 ;;
  *) assert "양성(소스 잔존 → 발화) — 실제출력: $out_pos" 1 ;;
esac

# ---- 음성: 잔존이 전혀 없으면 미발화(빈 문자열) ----
neg="$WORK/neg"
mk_repo "$neg" "유일무이한문구입니다"
stage_removal "$neg" "유일무이한문구입니다" "새문구로바뀜"
out_neg=$(run_hook "$neg")
if [ -z "$out_neg" ]; then
  assert "음성(잔존 0건 → 미발화)" 0
else
  assert "음성(잔존 0건 → 미발화) — 실제출력: $out_neg" 1
fi

# ---- 우회: 커밋 명령이 아니면(git status) 잔존이 있어도 미발화(트러스트 경계 — 커밋 시점에만 관여) ----
byp="$WORK/bypass"
mk_repo "$byp" "저장되었습니다"
cp "$byp/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java" \
   "$byp/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Other.java"
( cd "$byp" && git add {{MODULE_CORE}} && git commit -q -m other >/dev/null )
stage_removal "$byp" "저장되었습니다" "완료되었습니다"
out_byp=$(run_hook "$byp" "git status")
if [ -z "$out_byp" ]; then
  assert "우회(비커밋 명령 → 미발화)" 0
else
  assert "우회(비커밋 명령 → 미발화) — 실제출력: $out_byp" 1
fi

# ---- 경계: docs/agent_history.backup-* 에만 남은 리터럴은 잔존 취급하지 않는다 ----
docs_ex="$WORK/docsex"
mk_repo "$docs_ex" "백업에만남은문구"
echo '당시 기록: "백업에만남은문구" 를 사용했다.' > "$docs_ex/docs/agent_history.backup-2026-01-01.md"
( cd "$docs_ex" && git add docs && git commit -q -m backup >/dev/null )
stage_removal "$docs_ex" "백업에만남은문구" "새문구"
out_docs=$(run_hook "$docs_ex")
if [ -z "$out_docs" ]; then
  assert "경계(agent_history.backup-* 제외 → 미발화)" 0
else
  assert "경계(agent_history.backup-* 제외 → 미발화) — 실제출력: $out_docs" 1
fi

# ---- 절단: 잔존 리터럴이 10개 넘으면 앞 10개 + "N개 더" ----
trunc="$WORK/trunc"
mkdir -p "$trunc/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test" "$trunc/docs"
{
  echo "package com.example.app.test;"
  echo "public class Sample {"
  i=1
  while [ "$i" -le 12 ]; do
    echo "    public static final String M${i} = \"열두개문구중${i}번째\";"
    i=$((i + 1))
  done
  echo "}"
} > "$trunc/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java"
cp "$trunc/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java" \
   "$trunc/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Other.java"
echo "# doc" > "$trunc/docs/readme.md"
( cd "$trunc" \
  && git init -q \
  && git config user.email t@example.com \
  && git config user.name test \
  && git add {{MODULE_CORE}} docs \
  && git commit -q -m init >/dev/null )
i=1
while [ "$i" -le 12 ]; do
  sed -i '' "s/열두개문구중${i}번째/바뀐문구${i}/" "$trunc/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java"
  i=$((i + 1))
done
( cd "$trunc" && git add {{MODULE_CORE}} )
out_trunc=$(run_hook "$trunc")
case "$out_trunc" in
  *"2개 더"*)
    n_listed=$(printf '%s\n' "$out_trunc" | grep -c '잔존 [0-9]*건')
    if [ "$n_listed" -eq 10 ]; then
      assert "절단(12개 잔존 → 앞 10개 + '2개 더')" 0
    else
      assert "절단(12개 잔존 → 앞 10개 + '2개 더') — 목록 줄수: $n_listed" 1
    fi
    ;;
  *) assert "절단(12개 잔존 → 앞 10개 + '2개 더') — 실제출력: $out_trunc" 1 ;;
esac

# ---- 소스 층 제외 경로 변수(SOURCE_EXCLUDE_REGEX) ----
# svariant() 는 위(WORK 생성 직후)에 정의돼 있다 — 모든 케이스가 값을 명시한 사본으로 돈다.
# mk_pub <dir> <경로> — 리터럴을 지운 뒤 그 문구가 퍼블 원본 경로 한 곳에만 남은 레포
mk_pub() {
  mk_repo "$1" "퍼블원본에만남은문구"
  mkdir -p "$(dirname "$1/$2")"; echo '<p>퍼블원본에만남은문구</p>' > "$1/$2"
  ( cd "$1" && git add "$2" && git commit -q -m pub >/dev/null )
  stage_removal "$1" "퍼블원본에만남은문구" "새문구"
}
WITH_SRC_HTML=$(svariant srchtml "'(^|/)(target|static/html|src/main/html)/'") || exit 1
EMPTY_EX=$(svariant empty "''") || exit 1
ORIG_HOOK=$HOOK

d="$WORK/pub-static"; mk_pub "$d" "Web/src/main/resources/static/html/p.html"
[ -z "$(run_hook "$d")" ]; assert "제외 기본값: static/html 에만 남은 문구 → 미발화" $?
d="$WORK/pub-src"; mk_pub "$d" "Web/src/main/html/p.html"
case "$(run_hook "$d")" in *퍼블원본에만남은문구*) assert "기본값 대조: src/main/html 에 남은 문구 → 잔존으로 발화" 0 ;; *) assert "기본값 대조: src/main/html 에 남은 문구 → 잔존으로 발화" 1 ;; esac
HOOK=$WITH_SRC_HTML; [ -z "$(run_hook "$d")" ]; assert "변수에 src/main/html/ 추가 → 그 경로 문구는 잔존에서 빠짐(미발화)" $?; HOOK=$ORIG_HOOK
# 빈 값: bash [[ =~ ]] 는 빈 정규식에 rc 2(불일치)라 기본값 대입이 없으면 static/html 도 안 빠진다 → 기본값이어야 미발화.
d="$WORK/pub-static2"; mk_pub "$d" "Web/src/main/resources/static/html/p.html"
HOOK=$EMPTY_EX; [ -z "$(run_hook "$d")" ]; r=$?; HOOK=$ORIG_HOOK
assert "변수 빈 값 → 기본값(static/html 제외 유지 → 미발화)" $r

# ---- 소스 층 확장자 변수(SOURCE_EXTS) ----
# 기본 제외값을 명시한 사본($ORIG_HOOK)에서 SOURCE_EXTS 줄 값만 바꾼다 — 설치값과 무관하게 같은 결과.
xvariant() { # 이름 값(따옴표 포함 셸 리터럴) → 사본 경로
  local d="$WORK/xv-$1"; mkdir -p "$d/lib"
  cp "$(dirname "$SRC_HOOK")/lib/git-cmd.sh" "$d/lib/"
  grep -q '^SOURCE_EXTS=' "$ORIG_HOOK" || { echo "선행조건 실패: 훅에 SOURCE_EXTS 줄 없음" >&2; exit 1; }
  V="$2" awk 'index($0, "SOURCE_EXTS=") == 1 && !done { print "SOURCE_EXTS=" ENVIRON["V"]; done = 1; next } { print }' \
    "$ORIG_HOOK" > "$d/text-constant-3layer-reminder.sh"
  chmod +x "$d/text-constant-3layer-reminder.sh"
  printf '%s' "$d/text-constant-3layer-reminder.sh"
}
EXT_DEFAULT=$(xvariant default "'java xml js html'") || exit 1
EXT_JSP=$(xvariant jsp "'java xml js html jsp'") || exit 1
EXT_EMPTY=$(xvariant empty "''") || exit 1
EXT_GLOB=$(xvariant glob "'*'") || exit 1
d="$WORK/jsp"; mk_pub "$d" "Web/src/main/webapp/WEB-INF/p.jsp"
HOOK=$EXT_DEFAULT; [ -z "$(run_hook "$d")" ]; r=$?; HOOK=$ORIG_HOOK
assert "확장자 기본값: .jsp 에만 남은 문구 → 미발화(대조)" $r
HOOK=$EXT_JSP; case "$(run_hook "$d")" in *퍼블원본에만남은문구*) r=0 ;; *) r=1 ;; esac; HOOK=$ORIG_HOOK
assert "변수에 jsp 추가 → .jsp 잔존 발화" $r
d="$WORK/ext-html"; mk_pub "$d" "Web/src/main/html/p.html"
HOOK=$EXT_EMPTY; case "$(run_hook "$d")" in *퍼블원본에만남은문구*) r=0 ;; *) r=1 ;; esac; HOOK=$ORIG_HOOK
assert "확장자 빈 값 → 기본 4종(.html 잔존 발화)" $r
HOOK=$EXT_GLOB; case "$(run_hook "$d")" in *퍼블원본에만남은문구*) r=0 ;; *) r=1 ;; esac; HOOK=$ORIG_HOOK
assert "확장자 '*' → 글롭 미확장·무시 → 기본 4종(.html 잔존 발화)" $r

# ---- 건수 축: 잔존 건수 = 리터럴을 포함한 줄 수(한 줄 두 번 = 1건) ----
d="$WORK/count-axis"
mk_repo "$d" "줄단위로세는문구"
printf '%s\n' 'a = "줄단위로세는문구" + "줄단위로세는문구";' 'b = "줄단위로세는문구";' > "$d/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Two.java"
( cd "$d" && git add {{MODULE_CORE}} && git commit -q -m two >/dev/null )
stage_removal "$d" "줄단위로세는문구" "새문구"
case "$(run_hook "$d")" in *"잔존 2건(소스2/스위트0/문서0)"*) r=0 ;; *) r=1 ;; esac
assert "건수 축: 두 줄(한 줄에 두 번 포함) → 잔존 2건" $r

# ---- 미완료 경고: 시한 초과면 조용히 빠지지 않고 '검사 미완료' 를 낸다 ----
d="$WORK/budget0"
mk_repo "$d" "유일무이한문구입니다"
stage_removal "$d" "유일무이한문구입니다" "새문구로바뀜"
out=$(TEXT3_BUDGET_SEC=0 run_hook "$d")
case "$out" in *"검사 미완료"*"시한 0초"*) r=0 ;; *) r=1 ;; esac
assert "시한 초과(TEXT3_BUDGET_SEC=0) → '검사 미완료' 경고" $r
# 시한 값 검증: 두 자리 이하 정수 밖은 기본값 — 잔존이 있는 레포($pos)에서 정상 완료 경고가 나와야 한다(빈 출력 = 실패).
for v in abc 999 -1 ''; do
  out=$(TEXT3_BUDGET_SEC="$v" run_hook "$pos")
  case "$out" in *"검사 미완료"*) r=1 ;; *"저장되었습니다"*"잔존"*) r=0 ;; *) r=1 ;; esac
  assert "시한 값 '$v' → 기본값으로 정상 완료(잔존 발화)" $r
done
# 0 으로 시작하는 두 자리 값은 10진으로 읽는다(8진 산술 오류로 무출력 종료하면 실패).
for v in 08 09; do
  out=$(TEXT3_BUDGET_SEC="$v" run_hook "$pos")
  case "$out" in *"검사 미완료"*) r=1 ;; *"저장되었습니다"*"잔존"*) r=0 ;; *) r=1 ;; esac
  assert "시한 값 '$v' → 10진 해석으로 정상 완료(잔존 발화)" $r
done

# ---- 시한 상한: 등록 timeout 보다 작게 깎인다(등록 timeout 3 → 여유 3초를 빼 상한 0 → 즉시 '시한 0초') ----
# mk_pos_settings <dir> <settings.json 내용|-> [settings.local.json 내용] — 잔존이 있는 레포 + 등록 설정(미추적)
mk_pos_settings() {
  mk_repo "$1" "저장되었습니다"
  cp "$1/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Sample.java" "$1/{{MODULE_CORE}}/src/main/java/{{PKG_PATH}}/test/Other.java"
  ( cd "$1" && git add {{MODULE_CORE}} && git commit -q -m other >/dev/null )
  stage_removal "$1" "저장되었습니다" "완료되었습니다"
  mkdir -p "$1/.claude"
  [ "$2" = "-" ] || printf '%s' "$2" > "$1/.claude/settings.json"
  [ -z "${3:-}" ] || printf '%s' "$3" > "$1/.claude/settings.local.json"
}
reg() { # reg <timeout JSON 값> → 이 훅을 등록한 settings 조각
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \\"$CLAUDE_PROJECT_DIR/.claude/hooks/text-constant-3layer-reminder.sh\\"","timeout":%s}]}]}}' "$1"
}
d="$WORK/cap-env"; mk_pos_settings "$d" "$(reg 3)"
out=$(TEXT3_BUDGET_SEC=30 run_hook "$d")
case "$out" in *"검사 미완료"*"시한 0초"*) r=0 ;; *) r=1 ;; esac
assert "상한: 등록 timeout 3 + TEXT3_BUDGET_SEC=30 → 시한 0초로 깎여 '검사 미완료'" $r
d="$WORK/cap-default"; mk_pos_settings "$d" "$(reg 3)"
case "$(run_hook "$d")" in *"검사 미완료"*"시한 0초"*) r=0 ;; *) r=1 ;; esac
assert "상한: 등록 timeout 3 + 시한 미설정(기본 10) → 시한 0초로 깎임" $r
d="$WORK/cap-local"; mk_pos_settings "$d" "$(reg 15)" "$(reg 3)"
case "$(run_hook "$d")" in *"검사 미완료"*"시한 0초"*) r=0 ;; *) r=1 ;; esac
assert "상한: settings.local.json 등록 timeout 3 이 더 작으면 그 값 기준" $r
# 대조: 등록 timeout 이 넉넉하면 깎이지 않고 정상 완료
d="$WORK/cap-wide"; mk_pos_settings "$d" "$(reg 60)"
out=$(TEXT3_BUDGET_SEC=30 run_hook "$d")
case "$out" in *"검사 미완료"*) r=1 ;; *"저장되었습니다"*"잔존"*) r=0 ;; *) r=1 ;; esac
assert "상한 대조: 등록 timeout 60 + 시한 30 → 정상 완료(잔존 발화)" $r
# 등록값이 숫자가 아니면 보수적 고정값으로 돌고 정상 완료(무출력 실패 아님)
d="$WORK/cap-bad"; mk_pos_settings "$d" "$(reg '"abc"')"
case "$(run_hook "$d")" in *"검사 미완료"*) r=1 ;; *"저장되었습니다"*"잔존"*) r=0 ;; *) r=1 ;; esac
assert "상한: 등록 timeout 이 숫자가 아니면 고정 상한으로 정상 완료" $r

# ---- 미완료 경고: 대조기(count.py)가 실패하면 '검사 미완료' ----
shim="$WORK/shim"; mkdir -p "$shim"
REAL_PY=$(command -v python3)
cat > "$shim/python3" <<SH
#!/usr/bin/env bash
case "\${1:-}" in */count.py) exit 7 ;; esac
exec "$REAL_PY" "\$@"
SH
chmod +x "$shim/python3"
d="$WORK/countfail"
mk_repo "$d" "유일무이한문구입니다"
stage_removal "$d" "유일무이한문구입니다" "새문구로바뀜"
out=$(PATH="$shim:$PATH" run_hook "$d")
case "$out" in *"검사 미완료"*"rc=7"*) r=0 ;; *) r=1 ;; esac
assert "대조기 실패(rc=7) → '검사 미완료' 경고" $r

# ---- 미완료 경고: 스테이징 diff(-U0) 읽기가 실패하면 '검사 미완료' ----
gshim="$WORK/gshim"; mkdir -p "$gshim"
REAL_GIT=$(command -v git)
cat > "$gshim/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-U0" ] && exit 128; done
exec "$REAL_GIT" "\$@"
SH
chmod +x "$gshim/git"
d="$WORK/difffail"
mk_repo "$d" "유일무이한문구입니다"
stage_removal "$d" "유일무이한문구입니다" "새문구로바뀜"
out=$(PATH="$gshim:$PATH" run_hook "$d")
case "$out" in *"검사 미완료"*"rc=128"*) r=0 ;; *) r=1 ;; esac
assert "스테이징 diff 읽기 실패(git rc=128) → '검사 미완료' 경고" $r

echo "Tests run: $run, Passed: $pass"
[ "$run" -eq "$pass" ]
