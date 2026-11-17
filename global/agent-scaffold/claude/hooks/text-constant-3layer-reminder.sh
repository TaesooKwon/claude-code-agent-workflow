#!/usr/bin/env bash
# PreToolUse(Bash) — 커밋 직전 '문구 상수 3층 잔존' 경고형 리마인더(차단하지 않는다).
#
# 왜 있나: 프로젝트 CLAUDE.md 커밋 게이트 "사용자에게 보이는 문구 상수를 바꾸면 소비 층 3개를
#   grep 해 잔존 0 을 실측한다"(2026-09-07 승격)가 절차로만 적혀 있어, 지적받은 상수 하나만 훑고
#   diff 가 바꾼 문구 전부를 놓치는 사고(4건 누락)가 실측됐다. 이 훅은 스테이징 diff 에서
#   **삭제된**(제거 라인) 한글 문자열 리터럴을 뽑아 세 층에 잔존하는지 기계적으로 대조만 한다
#   — 판정은 하지 않는다(잔존해도 다른 자리에 쓰이는 동명 문구일 수 있다). 근거: apply/PLAN.md
#   훅 표(project:검증:12).
#
# 대상 추출: staged diff(git diff --cached -U0)의 제거 라인(-, "---" 헤더 제외)에서
#   "…"/'…' 형 문자열 리터럴 중 한글(가-힣)을 포함하고 길이(따옴표 제외) 4자 이상인 것.
#   같은 리터럴이 diff 의 추가 라인(+)에도 그대로 남아 있어도(같은 파일 내 재배치 등) 걸러내지
#   않는다 — 이 훅은 단순 grep 대조이지 diff-aware 판정이 아니다(안내문에 그 가능성을 명시한다).
# 대조 3층(잔존 건수 = 세 층에서 그 리터럴을 바이트 그대로 포함한 줄 수의 합 — grep -F | wc -l 과 같은 축):
#   ①레포 소스 — SOURCE_EXTS 확장자(기본 .java/.xml/.js/.html), 레포 루트 기준 상대경로가 SOURCE_EXCLUDE_REGEX 에 맞으면 제외
#     (기본 = target/·static/html/ 하위 — 퍼블 원본이 다른 곳(예: src/main/html/)에 있는 레포는 그 줄 값에 더한다)
#   ②전역 회귀 스위트 — ~/.claude/skills/playwright-verify/suites/{{PROJECT_NAME}}(레포 밖이라 빌드가 안 잡는다)
#   ③설계 문서 — docs/*.md(docs 바로 아래만, 하위 디렉터리 제외) 중 agent_history.backup-* 제외(당시 사실이라 무관)
# 잔존 건수가 0 이 아닌 리터럴만 나열. 10개 넘으면 앞 10개 + "N개 더"(개수는 매 실행 시 재계산 — 문서에 고정 수치로 박지 않는다).
#
# ponytail: 문자열 리터럴 추출은 정규식 기반이라 여러 줄에 걸친 연결 문자열(+ 이어붙이기)·중첩 이스케이프
#   극단값은 놓칠 수 있다(위양성보다 미탐 쪽으로 치우침) / 업그레이드 경로 = 필요해지면 언어별 렉서 도입.
#
# 트러스트 경계: stdin 의 tool_input.command·cwd 만 신뢰하고, 파일 경로는 find -- 로 모아 NUL 구분 목록으로만
#   대조기(python3)에 넘긴다 — 리터럴·경로가 셸 단어나 grep 옵션으로 해석될 자리가 없다.
# 시한: 대조는 리터럴마다 코퍼스를 다시 훑지 않고 파일당 1회만 읽는다. 그래도 TEXT3_BUDGET_SEC(기본 10초) 를
#   넘기면 남은 파일을 건너뛰고 '검사 미완료' 경고를 낸다 — 등록 timeout 에 강제 종료되면 출력 없이 사라지므로
#   이 시한은 등록 timeout 보다 작아야 한다 — 아래 '시한 상한' 이 등록값으로 깎는다(등록값 조회: grep -n -A2 text-constant-3layer .claude/settings.json).
# 안전(fail-open, 차단 없음): jq/git/python3 부재 · 비커밋 명령 · 남의 레포 · 스테이징 없음 ·
#   제거된 한글 리터럴 없음 · 잔존 0건 → 조용히 exit 0. 추출·대조가 실패하거나 시한을 넘기면 조용히 끝내지 않고 경고한다.
set -u

# 소스 층에서 뺄 경로(레포 루트 기준 상대경로에 bash [[ =~ ]] ERE 로 대조) — 레포마다 이 줄의 값만 바꾼다.
# 비어 있으면 기본값 — bash 3.2 의 [[ =~ ]] 는 빈·깨진 정규식에 rc 2 를 내 아무것도 빼지 않는다(기본 제외까지 사라짐).
SOURCE_EXCLUDE_REGEX='(^|/)(target|static/html)/'
[ -n "$SOURCE_EXCLUDE_REGEX" ] || SOURCE_EXCLUDE_REGEX='(^|/)(target|static/html)/'
# 소스 층 확장자(공백 구분, 대소문자 무시) — JSP 레포는 jsp 를 더한다. 영숫자 토큰만 인정하고,
# 인정된 토큰이 하나도 없으면(빈 값·이상한 값) 기본 4종으로 돈다. read -a 로 나눠 글롭 확장이 일어나지 않는다.
SOURCE_EXTS='java xml js html'
# 자기 시한(초) — 두 자리 이하 10진 정수만 인정(08·09 도 10진으로 읽는다), 그 밖(빈 값·문자·음수)은 기본 10.
#   상한은 아래 proj 확정 뒤 등록 timeout 으로 깎는다. 시계는 훅 시작 시각부터 잰다.
_t0=$(date +%s 2>/dev/null || echo 0)
TEXT3_BUDGET_SEC="${TEXT3_BUDGET_SEC:-10}"
case "$TEXT3_BUDGET_SEC" in ''|*[!0-9]*) TEXT3_BUDGET_SEC=10 ;; esac
[ "${#TEXT3_BUDGET_SEC}" -le 2 ] || TEXT3_BUDGET_SEC=10
TEXT3_BUDGET_SEC=$((10#$TEXT3_BUDGET_SEC))

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

_lib="$(dirname "$0")/lib/git-cmd.sh"
[ -f "$_lib" ] && . "$_lib" || exit 0
git_has_subcommand "$(git_strip_quoted "$(git_strip_heredoc "$cmd")")" commit || exit 0

proj="${CLAUDE_PROJECT_DIR:-$cwd}"

# 시한 상한 — 불변식: 자기 시한은 등록 timeout 보다 작아야 한다(넘으면 강제 종료로 출력 없이 사라진다).
#   상한 = 프로젝트 settings(.json·.local.json)에서 이 훅 등록 항목의 timeout 최솟값 − 여유 3초(시한 검사는 파일
#   경계에서만 하므로 마지막 파일 대조·후처리 몫). 등록값을 못 읽으면(파일 없음·timeout 생략·숫자 아님) 보수적 고정값 12.
_cap=12
_reg=$(cat "$proj/.claude/settings.json" "$proj/.claude/settings.local.json" 2>/dev/null \
  | jq -rs '[.[] | .. | objects | select((.command? | type) == "string" and (.command | contains("text-constant-3layer-reminder.sh")))
            | .timeout | select(type == "number")] | min // empty | floor' 2>/dev/null)
case "$_reg" in
  ''|*[!0-9]*) ;;
  *) [ "${#_reg}" -le 4 ] && { _reg=$((10#$_reg)); _cap=$((_reg > 3 ? _reg - 3 : 0)); } ;;
esac
[ "$TEXT3_BUDGET_SEC" -le "$_cap" ] || TEXT3_BUDGET_SEC=$_cap

# 이 프로젝트의 커밋만 본다(세션 스코프 훅이라 다른 레포 커밋에도 발동한다 — 형제 훅과 같은 계약).
_target_dir="$cwd"
_gc=$(printf '%s' "$cmd" | sed -n 's/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -1)
_cd=$(printf '%s' "$cmd" | sed -n 's/^[[:space:]]*cd[[:space:]]\{1,\}\([^&;|]\{1,\}\).*/\1/p' | head -1)
[ -n "$_cd" ] && _target_dir=$(printf '%s' "$_cd" | sed 's/[[:space:]]*$//' | sed "s|^~|$HOME|")
[ -n "$_gc" ] && _target_dir=$(printf '%s' "$_gc" | sed "s|^~|$HOME|")
if [ -d "$_target_dir" ]; then
  _t_top=$(git -C "$_target_dir" rev-parse --show-toplevel 2>/dev/null)
  _p_top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$_t_top" ] && [ -n "$_p_top" ] && [ "$_t_top" != "$_p_top" ] && exit 0
fi

[ -n "$(git -C "$proj" diff --cached --name-only 2>/dev/null)" ] || exit 0

# 미완료 경고 — 대조를 끝내지 못했을 때 조용히 빠지지 않게 한다(차단하지 않는다).
warn_incomplete() {
  local why="$1" partial="${2:-}"
  local c="[문구 상수 잔존 리마인더] ⚠️검사 미완료 — ${why}. 이번 커밋이 지운 한글 문구의 3층 잔존 대조가 끝나지 않았으니, 바꾼 문구마다 레포 소스·전역 회귀 스위트(~/.claude/skills/playwright-verify/suites/{{PROJECT_NAME}})·docs/*.md 를 직접 grep -F 해 잔존을 확인하세요."
  [ -n "$partial" ] && c="${c}
여기까지 대조한 범위에서 잔존이 보인 리터럴:
${partial}"
  jq -n --arg c "$c" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
  exit 0
}

# ── ①제거된 한글 문자열 리터럴 추출(python3, NUL 구분 출력) ──────────────────
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/tc3l.XXXXXX" 2>/dev/null) || warn_incomplete "임시 디렉터리 생성 실패"
[ -n "$tmpd" ] && [ -d "$tmpd" ] || warn_incomplete "임시 디렉터리 생성 실패"
trap 'rm -rf -- "$tmpd"' EXIT
tmp_py="$tmpd/extract.py"; tmp_lits="$tmpd/lits"

cat > "$tmp_py" <<'PY'
import re, sys

HANGUL = re.compile(r'[가-힣]')
STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'')

seen = set()
out = sys.stdout.buffer
for raw in sys.stdin.buffer:
    line = raw.decode('utf-8', errors='replace')
    if not line.startswith('-') or line.startswith('---'):
        continue
    body = line[1:]
    for m in STR_RE.finditer(body):
        lit = m.group(1) if m.group(1) is not None else m.group(2)
        if lit is None or len(lit) < 4 or lit in seen:
            continue
        if not HANGUL.search(lit):
            continue
        seen.add(lit)
        out.write(lit.encode('utf-8'))
        out.write(b'\x00')
PY

git -C "$proj" diff --cached -U0 -- . 2>/dev/null | python3 "$tmp_py" > "$tmp_lits" 2>/dev/null
_rcs=("${PIPESTATUS[@]}"); _rc_diff=${_rcs[0]}; _rc_extract=${_rcs[1]}
# 추출기 실패를 먼저 본다 — 추출기가 먼저 죽으면 git 은 SIGPIPE 로 덩달아 비0 이 된다.
[ "$_rc_extract" -eq 0 ] || warn_incomplete "삭제 리터럴 추출 실패(python3 rc=${_rc_extract})"
[ "$_rc_diff" -eq 0 ] || warn_incomplete "스테이징 diff 읽기 실패(git diff --cached rc=${_rc_diff})"
[ -s "$tmp_lits" ] || exit 0

# ── ②대조 3층 파일 코퍼스(1회만 구성) ────────────────────────────────────────
src_name_args=(); n_ext=0; src_exts=()
read -r -a src_exts <<< "$SOURCE_EXTS"
for e in ${src_exts[@]+"${src_exts[@]}"}; do
  case "$e" in ''|*[!A-Za-z0-9]*) continue ;; esac
  [ "$n_ext" -gt 0 ] && src_name_args+=(-o)
  src_name_args+=(-iname "*.$e"); n_ext=$((n_ext + 1))
done
[ "$n_ext" -gt 0 ] || src_name_args=(-iname '*.java' -o -iname '*.xml' -o -iname '*.js' -o -iname '*.html')
# 층마다 NUL 구분 경로 목록 파일 하나(빈 층 = 빈 파일).
while IFS= read -r -d '' f; do
  [[ "${f#"$proj"/}" =~ $SOURCE_EXCLUDE_REGEX ]] && continue
  printf '%s\0' "$f"
done < <(find "$proj" -path '*/target/*' -prune -o -type f \
  \( "${src_name_args[@]}" \) -print0 2>/dev/null) > "$tmpd/l1"

suites_dir="$HOME/.claude/skills/playwright-verify/suites/{{PROJECT_NAME}}"
: > "$tmpd/l2"
if [ -d "$suites_dir" ]; then
  find "$suites_dir" -type f -print0 2>/dev/null > "$tmpd/l2"
fi

find "$proj/docs" -maxdepth 1 -type f -name '*.md' ! -name 'agent_history.backup-*' -print0 2>/dev/null > "$tmpd/l3"

# ── ③리터럴별 잔존 건수 판정(파일당 1회 읽기) ─────────────────────────────────
# 출력 = 첫 레코드 상태("done" | "timeout <대조한 파일 수>/<전체>") + 리터럴마다 lit, 소스, 스위트, 문서 건수(NUL 구분).
# 건수 = 그 리터럴을 포함한 줄 수(grep -F | wc -l 축). 시한을 넘기면 남은 파일을 건너뛰고 그때까지의 건수를 낸다.
# ponytail: 바이너리 파일도 줄 단위로 센다(grep 은 "Binary file matches" 1줄) — 0/비0 판정은 같다 / 정확한 건수가 필요해지면 NUL 검출로 1건 처리.
cat > "$tmpd/count.py" <<'PY'
import sys, time

lits_path, deadline, l1, l2, l3 = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]

def nul_list(path):
    with open(path, 'rb') as f:
        return [x for x in f.read().split(b'\x00') if x]

lits = nul_list(lits_path)
layers = [nul_list(l1), nul_list(l2), nul_list(l3)]
counts = [[0, 0, 0] for _ in lits]
total = sum(len(x) for x in layers)
scanned = 0
timed_out = False
for li, files in enumerate(layers):
    for path in files:
        if time.time() > deadline:
            timed_out = True
            break
        scanned += 1
        try:
            with open(path, 'rb') as f:
                data = f.read()
        except OSError:
            continue
        for ki, lit in enumerate(lits):
            i = data.find(lit)
            n = 0
            while i >= 0:
                n += 1
                e = data.find(b'\n', i)
                if e < 0:
                    break
                i = data.find(lit, e + 1)
            counts[ki][li] += n
    if timed_out:
        break

out = sys.stdout.buffer
status = 'timeout %d/%d' % (scanned, total) if timed_out else 'done'
out.write(status.encode() + b'\x00')
for lit, c in zip(lits, counts):
    out.write(lit + b'\x00' + b'\x00'.join(str(x).encode() for x in c) + b'\x00')
PY

_deadline=$((_t0 + TEXT3_BUDGET_SEC))
python3 "$tmpd/count.py" "$tmp_lits" "$_deadline" "$tmpd/l1" "$tmpd/l2" "$tmpd/l3" > "$tmpd/counts" 2>/dev/null
_rc_count=$?
[ "$_rc_count" -eq 0 ] || warn_incomplete "잔존 대조 실패(python3 rc=${_rc_count})"

results=""
shown=0
status=""
{
  IFS= read -r -d '' status
  while IFS= read -r -d '' lit && IFS= read -r -d '' c1 && IFS= read -r -d '' c2 && IFS= read -r -d '' c3; do
    case "$c1$c2$c3" in ''|*[!0-9]*) continue ;; esac
    total=$((c1 + c2 + c3))
    [ "$total" -eq 0 ] && continue
    shown=$((shown + 1))
    if [ "$shown" -le 10 ]; then
      results="${results}  \"${lit}\" — 잔존 ${total}건(소스${c1}/스위트${c2}/문서${c3})
"
    fi
  done
} < "$tmpd/counts"

case "$status" in
  done) ;;
  timeout\ *) warn_incomplete "자기 시한 ${TEXT3_BUDGET_SEC}초 초과로 대조 파일 ${status#timeout }개만 봤습니다(TEXT3_BUDGET_SEC)" "$results" ;;
  *) warn_incomplete "대조 결과 형식 이상" ;;
esac

[ "$shown" -gt 0 ] || exit 0

more=""
[ "$shown" -gt 10 ] && more=" (그 외 $((shown - 10))개 더)"

ctx="[문구 상수 잔존 리마인더] 이번 커밋이 지운 한글 문자열 리터럴 중 세 층 어딘가에 아직 남아있는 것이 있습니다${more}:
${results}
대조 3층 = 레포 소스(SOURCE_EXTS 확장자, SOURCE_EXCLUDE_REGEX 경로 제외) / 전역 회귀 스위트(~/.claude/skills/playwright-verify/suites/{{PROJECT_NAME}}) / 설계 문서(docs/*.md, 이력 백업 제외). CLAUDE.md 커밋 게이트대로 지적받은 상수 하나만이 아니라 diff 가 바꾼 문구 전부를 판정 대상으로 보세요. 같은 문구가 다른 자리에서 독립적으로 쓰이는 것이라면 무시하고 진행해도 됩니다(이 훅은 판정하지 않습니다 — grep 대조만)."

jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
exit 0
