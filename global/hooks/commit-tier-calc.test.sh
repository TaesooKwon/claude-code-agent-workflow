#!/usr/bin/env bash
# commit-tier-calc.sh 자가 테스트 — `bash commit-tier-calc.test.sh` 로 실행.
# ⚠️ 커밋 명령 문자열은 **이 파일 안에만** 둔다 — 호출 측 Bash 명령에 쓰면 그 문자열을 보는 PreToolUse 훅(모집단 = settings.json 의 PreToolUse 등록)이 반응할 수 있다.
# 픽스처는 mktemp -d 아래 임시 git 저장소이며 종료 시 삭제된다(실 저장소·실 파일은 건드리지 않는다).
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/commit-tier-calc.sh"
[ -f "$HOOK" ] || { echo "훅 파일 없음: $HOOK"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tiercalc.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

RUN=0; PASS=0

# 커밋 명령 문자열(테스트 입력) — 조립해서 이 파일 안에 가둔다.
GIT_BIN="git"
COMMIT_CMD="$GIT_BIN commit -m \"wip\""
COMMIT_CMD_BYPASS="SKIP_TIER_CALC=1 $GIT_BIN commit -m \"wip\""
NONCOMMIT_CMD="$GIT_BIN status --short"
QUOTED_ONLY_CMD="echo \"먼저 $GIT_BIN commit 을 치기 전에 리뷰하라\""

mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "t@e.st"
  git -C "$d" config user.name  "tier-test"
  printf '%s' "$d"
}

seed_commit() {  # $1=repo — HEAD 를 만들어 '수정' 시나리오를 쓸 수 있게 한다
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c core.hooksPath=/dev/null commit -q -m seed >/dev/null 2>&1
}

run_ctx() {  # $1=cwd $2=command → additionalContext(없으면 빈 문자열)
  local out
  out=$(jq -n --arg c "$2" --arg d "$1" \
        '{session_id:"t",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | bash "$HOOK" 2>/dev/null)
  [ -n "$out" ] || return 0
  printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

ok()   { RUN=$((RUN+1)); PASS=$((PASS+1)); echo "  ok   $1"; }
nok()  { RUN=$((RUN+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '       ---- 실제 출력 ----\n%s\n       -------------------\n' "$2"; }

assert_has()     { if printf '%s' "$2" | grep -Fq -- "$3"; then ok "$1"; else nok "$1 (기대 문자열 '$3' 없음)" "$2"; fi; }
assert_not_has() { if printf '%s' "$2" | grep -Fq -- "$3"; then nok "$1 (있으면 안 되는 '$3' 발견)" "$2"; else ok "$1"; fi; }
assert_empty()   { if [ -z "$2" ]; then ok "$1"; else nok "$1 (출력이 있어야 하지 않음)" "$2"; fi; }

echo "== commit-tier-calc.sh =="

# ── 양성 ⓐ 서버 소스 ───────────────────────────────────────────────────────────
R=$(mkrepo a_java)
mkdir -p "$R/CMS-Core/src/main/java/kr/example"
echo 'public class Foo {}' > "$R/CMS-Core/src/main/java/kr/example/Foo.java"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "양성ⓐ .java staged → A티어"            "$OUT" "A티어"
assert_has "양성ⓐ 축 ⓐ 근거 출력"                   "$OUT" "ⓐ 서버 소스"
assert_has "양성ⓐ 소형 A 후보 = 예(1파일·인증 아님)" "$OUT" "소형 A 후보: **예**"

# ── 양성 ⓑ 매퍼 XML ────────────────────────────────────────────────────────────
R=$(mkrepo b_mapper)
mkdir -p "$R/CMS-Core/src/main/resources/egovframework/mapper/mbr"
cat > "$R/CMS-Core/src/main/resources/egovframework/mapper/mbr/Mbr_sql.xml" <<'XML'
<mapper namespace="x"><select id="readMbr">SELECT MBR_NO FROM tn_mbr</select></mapper>
XML
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "양성ⓑ 매퍼 XML → A티어"   "$OUT" "A티어"
assert_has "양성ⓑ 축 ⓑ 근거 출력"      "$OUT" "ⓑ 매퍼/쿼리 XML"

# ── 양성 ⓒ 템플릿 <script> 안쪽 추가 라인(수정 시나리오) ────────────────────────
R=$(mkrepo c_script)
mkdir -p "$R/CMS-Admin/src/main/resources/templates/edu"
cat > "$R/CMS-Admin/src/main/resources/templates/edu/lsnIndex.html" <<'HTML'
<html>
<body>
  <h1>수업 관리</h1>
  <p>안내 문구</p>
  <script>
    var a = 1;
  </script>
</body>
</html>
HTML
seed_commit "$R"
# script 블록 **안쪽** 한 줄만 추가
perl -i -pe 's/^    var a = 1;$/    var a = 1;\n    var b = 2;/' "$R/CMS-Admin/src/main/resources/templates/edu/lsnIndex.html"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has     "양성ⓒ script 안쪽 추가 → A티어" "$OUT" "A티어"
assert_has     "양성ⓒ 축 ⓒ 근거 출력"            "$OUT" "ⓒ 템플릿 <script> 블록 안쪽"
assert_not_has "양성ⓒ 바인딩 축은 안 걸림"        "$OUT" "ⓓ 템플릿 바인딩"

# ── 양성 ⓒ-2: 추가 라인이 **2줄 이상**(실제 diff 의 정상 형태) ─────────────────
# 회귀 근거: awk -v 대입값에 개행이 들어가면 BSD awk 가 "newline in string" 으로 죽어 ⓒ 축이 통째로
# 사라졌다(2026-09-18 실측). 한 줄 추가만 검사하던 위 케이스는 그 결함을 통과시켰다.
R=$(mkrepo c2_script_multi)
mkdir -p "$R/CMS-Admin/src/main/resources/templates/edu"
cat > "$R/CMS-Admin/src/main/resources/templates/edu/lsnForm.html" <<'HTML'
<html>
<body>
  <h1>수업 등록</h1>
  <script>
    var a = 1;
  </script>
</body>
</html>
HTML
seed_commit "$R"
perl -i -pe 's/^    var a = 1;$/    var a = 1;\n    var b = 2;\n    var c = 3;\n    var d = 4;/' \
  "$R/CMS-Admin/src/main/resources/templates/edu/lsnForm.html"
git -C "$R" add -A >/dev/null 2>&1
# 변이 전제: 추가 라인이 실제로 3줄 이상이어야 이 케이스가 결함을 태운다.
ADDN=$(git -C "$R" diff --cached -U0 -- CMS-Admin/src/main/resources/templates/edu/lsnForm.html \
       | grep -c '^+[^+]')
if [ "$ADDN" -ge 3 ]; then ok "양성ⓒ-2 전제: 추가 라인 ${ADDN}줄(≥3)"; else nok "양성ⓒ-2 전제 실패(추가 라인 ${ADDN}줄)"; fi
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "양성ⓒ-2 다줄 추가에도 ⓒ 축 생존 → A티어" "$OUT" "A티어"
assert_has "양성ⓒ-2 축 ⓒ 근거 출력"                  "$OUT" "ⓒ 템플릿 <script> 블록 안쪽"

# ── 양성 ⓒⓓ-3: **하위 디렉터리 cwd** 에서도 템플릿 축이 살아 있어야 한다 ───────
# 회귀 근거: diff --name-only 의 경로는 레포 루트 기준인데 cwd 로 pathspec 을 조합해, 하위 디렉터리에서
# 커밋하면 ⓒⓓ 가 통째로 사라지고 A 가 B 로 뒤집혔다(2026-09-18 실측).
R=$(mkrepo j_subcwd)
mkdir -p "$R/CMS-Front/src/main/resources/templates/mbr" "$R/docs/deep/dir"
cat > "$R/CMS-Front/src/main/resources/templates/mbr/sub.html" <<'HTML'
<html>
<body>
  <h1>제목</h1>
  <script>
    var a = 1;
  </script>
</body>
</html>
HTML
seed_commit "$R"
perl -i -pe 's|^  <h1>제목</h1>$|  <h1>제목</h1>\n  <div th:each="r : \$\{rows\}">행</div>\n  <div th:if="\$\{ok\}">예</div>|' \
  "$R/CMS-Front/src/main/resources/templates/mbr/sub.html"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "하위cwd 전제: 루트 cwd 에서는 A티어" "$OUT" "ⓓ 템플릿 바인딩"
OUT=$(run_ctx "$R/docs/deep/dir" "$COMMIT_CMD")
assert_has     "하위cwd 에서도 ⓓ 축 생존 → A티어" "$OUT" "ⓓ 템플릿 바인딩"
assert_not_has "하위cwd 에서 B 로 뒤집히지 않음"   "$OUT" "B티어 후보"

# ── 양성 ⓓ 바인딩 속성 추가 라인 ────────────────────────────────────────────────
R=$(mkrepo d_bind)
mkdir -p "$R/CMS-Front/src/main/resources/templates/mbr"
cat > "$R/CMS-Front/src/main/resources/templates/mbr/myHome.html" <<'HTML'
<html>
<body>
  <h1>마이홈</h1>
</body>
</html>
HTML
seed_commit "$R"
perl -i -pe 's|^  <h1>마이홈</h1>$|  <h1>마이홈</h1>\n  <div th:if="\$\{hasLsn\}">수업 있음</div>|' \
  "$R/CMS-Front/src/main/resources/templates/mbr/myHome.html"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has     "양성ⓓ th:if 추가 → A티어"  "$OUT" "A티어"
assert_has     "양성ⓓ 축 ⓓ 근거 출력"       "$OUT" "ⓓ 템플릿 바인딩"
assert_not_has "양성ⓓ script 축은 안 걸림"   "$OUT" "ⓒ 템플릿 <script>"

# ── 음성 B티어: 마크업·문구만(스크립트 바깥 수정) ───────────────────────────────
R=$(mkrepo e_markup)
mkdir -p "$R/CMS-Admin/src/main/resources/templates/comn" "$R/CMS-Admin/src/main/resources/static/resources/css"
cat > "$R/CMS-Admin/src/main/resources/templates/comn/notice.html" <<'HTML'
<html>
<body>
  <h1>공지</h1>
  <p class="desc">옛 문구</p>
  <script>
    var keep = 1;
  </script>
</body>
</html>
HTML
echo '.desc { color: #333; }' > "$R/CMS-Admin/src/main/resources/static/resources/css/x.css"
seed_commit "$R"
perl -i -pe 's|<p class="desc">옛 문구</p>|<p class="desc">새 문구</p>|' \
  "$R/CMS-Admin/src/main/resources/templates/comn/notice.html"
echo '.desc { color: #444; }' > "$R/CMS-Admin/src/main/resources/static/resources/css/x.css"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has     "음성 마크업·CSS만 → B티어 후보" "$OUT" "B티어 후보"
assert_has     "음성 B 판정을 사용자에게 말하라" "$OUT" "사용자에게 말해야 한다"
assert_not_has "음성 A티어로 오판하지 않음"      "$OUT" "**A티어**"

# ── 우회 1: SKIP_TIER_CALC=1 접두 ───────────────────────────────────────────────
R=$(mkrepo f_bypass)
mkdir -p "$R/src"
echo 'public class Bar {}' > "$R/src/Bar.java"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has  "우회 전제: 우회 없으면 A티어가 나온다" "$OUT" "A티어"
OUT=$(run_ctx "$R" "$COMMIT_CMD_BYPASS")
assert_empty "우회 SKIP_TIER_CALC=1 → 출력 없음" "$OUT"
OUT=$(SKIP_TIER_CALC=1 run_ctx "$R" "$COMMIT_CMD")
assert_empty "우회 환경변수 SKIP_TIER_CALC=1 → 출력 없음" "$OUT"

# ── 음성: 커밋 아닌 명령 / 인용된 문구뿐인 명령 ────────────────────────────────
OUT=$(run_ctx "$R" "$NONCOMMIT_CMD")
assert_empty "음성 비커밋 명령 → 침묵" "$OUT"
OUT=$(run_ctx "$R" "$QUOTED_ONLY_CMD")
assert_empty "음성 따옴표 안 문구뿐 → 침묵(오탐 억제)" "$OUT"

# ── staged 없음 → 침묵 ─────────────────────────────────────────────────────────
R=$(mkrepo g_empty)
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_empty "staged 없음 → 침묵" "$OUT"

# ── 프로젝트 확장: tier.conf extra_a_globs / auth_paths ─────────────────────────
R=$(mkrepo h_conf)
mkdir -p "$R/.claude" "$R/CMS-Admin/src/main/resources/static/resources/js/develop/edu"
cat > "$R/.claude/tier.conf" <<'CONF'
# 프로젝트 확장 축
extra_a_globs=*/js/develop/*.js
auth_paths=comn/gate/
CONF
echo 'function readLsn(){}' > "$R/CMS-Admin/src/main/resources/static/resources/js/develop/edu/lsn.js"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "확장 js/develop → A티어"      "$OUT" "A티어"
assert_has "확장 축 ⓔ 근거 출력"           "$OUT" "ⓔ 프로젝트 확장 축"
assert_has "확장 설정 경로를 보고에 표기"   "$OUT" "tier.conf"

# 같은 레포에 conf 의 auth_paths 에 걸리는 파일을 추가 → 소형 A 실격
mkdir -p "$R/CMS-Core/src/main/java/kr/example/comn/gate"
echo 'public class G {}' > "$R/CMS-Core/src/main/java/kr/example/comn/gate/G.java"
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "auth_paths 히트 → 소형 A 아니오" "$OUT" "소형 A 후보: **아니오**"
assert_has "실격 사유에 인증/인가 경로 표기"  "$OUT" "인증/인가 추정 경로"

# tier.conf 값은 훅 프로세스 cwd 의 파일명으로 펼쳐지지 않는다 — cwd 에 글롭과 맞는 실제 파일·디렉터리를 두고 빈 cwd 와 결과 대조
R=$(mkrepo h_cwdglob)
mkdir -p "$R/.claude" "$R/sub" "$R/src/gate"
printf 'extra_a_globs=*.sh\nauth_paths=[g]ate/\n' > "$R/.claude/tier.conf"
echo 'echo x' > "$R/sub/x.sh"; echo 'g' > "$R/src/gate/G.txt"
git -C "$R" add -A >/dev/null 2>&1
CW_E="$TMP/cwd_empty"; CW_G="$TMP/cwd_glob"; mkdir -p "$CW_E" "$CW_G/gate"; echo x > "$CW_G/a.sh"
OUT_E=$(cd "$CW_E" && run_ctx "$R" "$COMMIT_CMD"); OUT_G=$(cd "$CW_G" && run_ctx "$R" "$COMMIT_CMD")
assert_has "cwd 에 a.sh 가 있어도 sub/x.sh → A티어(extra_a_globs 미확장)" "$OUT_G" "A티어"
assert_has "cwd 에 a.sh 가 있어도 ⓔ 근거에 sub/x.sh"                     "$OUT_G" "- sub/x.sh"
assert_has "auth_paths 글롭 문자는 리터럴 — cwd 무관 소형 A 예"          "$OUT_G" "소형 A 후보: **예**"
if [ "$OUT_E" = "$OUT_G" ]; then ok "빈 cwd 와 글롭 일치 cwd 의 보고문 동일"; else nok "빈 cwd 와 글롭 일치 cwd 의 보고문 다름" "$OUT_G"; fi
# 값 안의 명령 치환 꼴은 실행되지 않는다(source·eval 없음)
R=$(mkrepo h_confcmd); mkdir -p "$R/.claude"
printf 'extra_a_globs=$(touch %s/pwned) `touch %s/pwned2`\n' "$TMP" "$TMP" > "$R/.claude/tier.conf"
echo x > "$R/a.txt"; git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
if [ ! -e "$TMP/pwned" ] && [ ! -e "$TMP/pwned2" ]; then ok "tier.conf 값의 명령 치환 미실행"; else nok "tier.conf 값의 명령 치환이 실행됨" "$OUT"; fi

# ── 소형 A 실격: 파일 수 상한 초과 ─────────────────────────────────────────────
R=$(mkrepo i_many)
mkdir -p "$R/src"
for i in 1 2 3 4 5 6; do echo "public class C$i {}" > "$R/src/C$i.java"; done
git -C "$R" add -A >/dev/null 2>&1
OUT=$(run_ctx "$R" "$COMMIT_CMD")
assert_has "6파일 → 소형 A 아니오"      "$OUT" "소형 A 후보: **아니오**"
assert_has "실격 사유에 파일 수 표기"    "$OUT" "staged 6개 > 5"

# ── 인덱스 밖 커밋 형태 → 판정 불가(A 로 간주) — 2026-11-05 ───────────────────
R=$(mkrepo j_nonindex)
echo 'x' > "$R/README.md"; git -C "$R" add README.md >/dev/null 2>&1
for form in "commit -m \"wip\" README.md" "commit -am \"wip\"" "commit -a -m \"wip\"" "commit --all -m x" \
            "commit -o -m x README.md" "commit -i -m x README.md" "commit -m x -- README.md" \
            "commit --pathspec-from-file=list.txt -m x"; do
  OUT=$(run_ctx "$R" "$GIT_BIN $form")
  assert_has "판정 불가 A 간주: $form" "$OUT" "판정 불가 — **A 로 간주**"
done
for form in "commit -m \"wip\"" "commit -m \"don't a.txt\"" "commit -F msg.txt" "commit --amend --no-edit" \
            "commit -m x --author \"A <a@b>\"" "commit -C HEAD"; do
  OUT=$(run_ctx "$R" "$GIT_BIN $form")
  assert_not_has "인덱스 커밋은 계산: $form" "$OUT" "판정 불가"
done
# 2026-11-05 층 B 리뷰(rvB attack#3·#7·#8, fp#3) — 줄 이음 · 리다이렉트·히어독 낱말 · 같은 명령 안 앞선 add
for form in "$GIT_BIN commit \\
  -a -m x" "$GIT_BIN add README.md && $GIT_BIN commit -m x" "$GIT_BIN rm -q --cached x.txt; $GIT_BIN commit -m x" \
            "$GIT_BIN commit -m x > out.log README.md" "$GIT_BIN commit -m x README.md 2>&1 | tail -3"; do
  OUT=$(run_ctx "$R" "$form")
  assert_has "판정 불가 A 간주(rvB): $form" "$OUT" "판정 불가 — **A 로 간주**"
done
for form in "$GIT_BIN commit -m \"\$(cat <<'EOF'
fix: x
EOF
)\"" "$GIT_BIN commit -F - <<'EOF'
fix: x
EOF" "$GIT_BIN commit \\
  -m x" "$GIT_BIN commit -m \"fix\" 2>&1 | tail -3" "$GIT_BIN commit -m x > out.log" "$GIT_BIN status --short && $GIT_BIN commit -m x"; do
  OUT=$(run_ctx "$R" "$form")
  assert_not_has "인덱스 커밋은 계산(rvB): $form" "$OUT" "판정 불가"
  assert_has "인덱스 커밋은 티어 출력(rvB): $form" "$OUT" "커밋 티어"
done
OUT=$(run_ctx "$R" "$GIT_BIN commit -m \"don't\" -a -m 'x'")
assert_has "판정 불가(rvB): 겹따옴표 속 ' 뒤의 -a" "$OUT" "판정 불가 — **A 로 간주**"
OUT=$(run_ctx "$R" "$GIT_BIN commit -m \"don't\" -m 'x'")
assert_not_has "계산(rvB): 겹따옴표 속 ' + 뒤 '" "$OUT" "판정 불가"

# ── 안전: 훅 입력이 깨져도 fail-open ───────────────────────────────────────────
OUT=$(printf 'not-json' | bash "$HOOK" 2>/dev/null)
assert_empty "깨진 stdin → fail-open 침묵" "$OUT"

echo "== 선형 줄 잇기 펴기(2026-11-06) =="
_lsh=$(mktemp -d "${TMPDIR:-/tmp}/unfold-sed.XXXXXX") || exit 2
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/log"\nexec /usr/bin/sed "$@"\n' "$_lsh" > "$_lsh/sed"; chmod +x "$_lsh/sed"; : > "$_lsh/log"
_unf_used() { grep -qF 'H;${x;s/' "$_lsh/log" && echo yes || echo no; }   # 선형 펴기 sed 스크립트가 불렸는가
_tj() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"/tmp"}'; }
_tj "$(printf 'git commit \\\n -m x')" | PATH="$_lsh:$PATH" bash "$HOOK" >/dev/null 2>&1
if [ "$(_unf_used)" = yes ]; then ok "선형 펴기: 줄 잇기 있으면 sed 1회 경로"; else nok "선형 펴기: 줄 잇기 있으면 sed 1회 경로"; fi
: > "$_lsh/log"; _tj 'git commit -m x' | PATH="$_lsh:$PATH" bash "$HOOK" >/dev/null 2>&1
if [ "$(_unf_used)" = no ]; then ok "선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; else nok "선형 펴기: 줄 잇기 없으면 sed 를 부르지 않음"; fi
rm -rf "$_lsh"

echo "== r2 리뷰: 채택·감지·드리프트 =="
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
R=$(mkrepo r2_adopt); mkdir -p "$R/CMS-Core/src/main/java/kr/example"; echo 'public class Foo {}' > "$R/CMS-Core/src/main/java/kr/example/Foo.java"; git -C "$R" add -A >/dev/null 2>&1
_fake adopt "$COMMIT_CMD"; OUT=$(PATH="$_fsh:$PATH" run_ctx "$R" "$(printf 'git status \\\n-s')")
assert_has "r2 펴기: 센티널 있는 sed 출력 채택(가짜 = 커밋 → A티어)" "$OUT" "A티어"
if [ "$(_fake_n)" = 1 ]; then ok "r2 펴기: sed 호출 1회(채택)"; else nok "r2 펴기: sed 호출 1회(채택) — $(_fake_n)회"; fi
_fake nosent "$COMMIT_CMD"; OUT=$(PATH="$_fsh:$PATH" run_ctx "$R" "$(printf 'git status \\\n-s')")
assert_empty "r2 펴기: 센티널 없으면 종전 치환(감지 → 무출력)" "$OUT"
if [ "$(_fake_n)" = 1 ]; then ok "r2 펴기: sed 호출 1회(감지)"; else nok "r2 펴기: sed 호출 1회(감지) — $(_fake_n)회"; fi
# 대조 lib = 이 테스트 위치 기준 스캐폴드 lib(킷 위치면 킷 스캐폴드), 없으면 $HOME 설치본
_kl="$(cd "$(dirname "$0")" && pwd)/../agent-scaffold/claude/hooks/lib/git-cmd.sh"; [ -f "$_kl" ] || _kl="$HOME/.claude/agent-scaffold/claude/hooks/lib/git-cmd.sh"; _d=$(_unf_drift "$_kl" "$HOOK")
if [ "$_d" = nolib ]; then echo "  (건너뜀 — 킷 lib 없음: $_kl)"; elif [ "$_d" = same ]; then ok "r2 드리프트: 인라인 펴기 = 킷 lib git_unfold_lines"; else nok "r2 드리프트: 인라인 펴기 ≠ 킷 lib"; fi
rm -rf "$_fsh"

echo
echo "Tests run: $RUN, Passed: $PASS"
[ "$RUN" -gt 0 ] || { echo "치명: 테스트가 한 건도 실행되지 않았다(미실행 = 미반증)"; exit 1; }
[ "$RUN" -eq "$PASS" ]
