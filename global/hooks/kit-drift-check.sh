#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# SessionStart 전역 훅 — 현재 레포의 .claude/hooks·.claude/workflows 를 킷(~/.claude/agent-scaffold/claude/…)과 대조해
# 드리프트를 보고하고 "지연 전파" 판정을 제안한다(경고형). 설정값 줄(VAR=)·# 주석은 비교에서 제외해
# 레포별 값 차이는 드리프트로 세지 않는다. 레포·일자당 1회 발화.
# workflows 를 모집단에 넣은 이유(2026-09-23): 리뷰 엔진(commit-review.js)이 형제 레포에서 구판으로 남아도
# hooks 만 대조하던 이 훅은 알리지 못했다 — 지연 전파 모델이 워크플로 드리프트를 구조적으로 못 봤다.
# 전역 층(라이브 ~/.claude ↔ 버전관리 킷 global/)도 대조한다(2026-10-02): 킷 doctor [5c] 는 CLAUDE.md·rules-rationale 을
# 스크럽 변종이라 빼고, doctor 는 감사 때만 돈다 — 라이브에 더한 조항이 킷에 안 가도 아무도 알리지 않았다.
# 내용은 스크럽으로 달라지므로 조항 머리(`- **…**`) 집합과 근거 문서의 파일 집합·`## ` 절 수만 본다. 머신·일자당 1회.
command -v jq >/dev/null 2>&1 || exit 0
proj="${CLAUDE_PROJECT_DIR:-$PWD}"
K="$HOME/.claude/agent-scaffold/claude/hooks"
R="$proj/.claude/hooks"
KW="$HOME/.claude/agent-scaffold/claude/workflows"
RW="$proj/.claude/workflows"
today=$(date +%F)

# 보고할 것이 있으면 JSON 1개로 내보내고 끝낸다(SessionStart 출력은 한 번뿐이라 두 절을 합친다).
# $1 = additionalContext(모델용 본문) / $2 = systemMessage(사용자 화면 요약 — 수치와 다음 행동만, 경로·파일명·해시 없음).
# 마커는 출력 전에 찍히므로 모델이 경고를 사용자에게 전하지 않으면 그날 다시 뜨지 않는다 — 그래서 요약은 화면에 직접 낸다.
finish() {
  [ -n "$1" ] || exit 0
  jq -n --arg c "$1" --arg s "${2:-}" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}} + (if $s != "" then {systemMessage:$s} else {} end)'
  exit 0
}
NEXT='처리하려면 "킷 드리프트 방향 제안해"'
cnt() { printf '%s\n' "$1" | grep -c .; }   # 비어 있으면 0

# ── 전역 층 ── 킷이 없는 머신이면 조용히 건너뛴다(KIT_DIR 로 경로를 바꿀 수 있다).
gsec=''; gsum=''
KG="${KIT_DIR:-$HOME/claude-agent-kit}/global"
gmarker="$HOME/.claude/.kit-drift-check-global"
if [ -f "$KG/CLAUDE.md" ] && [ -f "$HOME/.claude/CLAUDE.md" ] && [ "$(cat "$gmarker" 2>/dev/null)" != "$today" ]; then
  printf '%s' "$today" > "$gmarker" 2>/dev/null || true
  # 의도적으로 킷에 넣지 않는 항목(조항 머리 원문 또는 rules-rationale/<파일>) — 한 줄 하나, # 주석 허용.
  gexcl="${KG%/global}/kit-drift-exclude.txt"
  heads() { grep -oE '^- \*\*[^*]+\*\*' "$1" 2>/dev/null | sort -u; }
  excl() { if [ -f "$gexcl" ]; then grep -vxF -f <(grep -vE '^[[:space:]]*(#|$)' "$gexcl"); else cat; fi; }
  glive=$(comm -23 <(heads "$HOME/.claude/CLAUDE.md") <(heads "$KG/CLAUDE.md") | excl)
  gkit=$(comm -13 <(heads "$HOME/.claude/CLAUDE.md") <(heads "$KG/CLAUDE.md") | excl)
  rdiff=()
  for lf in "$HOME/.claude/rules-rationale"/*.md; do
    [ -f "$lf" ] || continue
    key="rules-rationale/$(basename "$lf")"
    [ -n "$(printf '%s\n' "$key" | excl)" ] || continue
    if [ ! -f "$KG/$key" ]; then rdiff+=("$key(킷없음)"); continue; fi
    [ "$(grep -c '^## ' "$lf")" = "$(grep -c '^## ' "$KG/$key")" ] || rdiff+=("$key(절 수)")
  done
  for kf in "$KG/rules-rationale"/*.md; do
    [ -f "$kf" ] || continue
    key="rules-rationale/$(basename "$kf")"
    [ -f "$HOME/.claude/$key" ] || rdiff+=("$key(라이브없음)")
  done
  if [ -n "$glive$gkit" ] || [ ${#rdiff[@]} -gt 0 ]; then
    gsec="[킷 드리프트·전역 층] 라이브 ~/.claude ↔ ${KG} 대조(조항 머리 집합·근거 문서 절 수 — 내용은 스크럽 변종이라 보지 않는다):
 라이브에만 있는 조항:
$(printf '%s\n' "${glive:-  없음}" | sed 's/^/  /')
 킷에만 있는 조항:
$(printf '%s\n' "${gkit:-  없음}" | sed 's/^/  /')
 근거 문서: ${rdiff[*]:-없음}
작업 시작 전에 사용자에게 제안하라: 라이브가 보통 정본이다 → 킷에 스크럽본(회사·프로젝트명 제거)을 반영한다. 킷에 넣지 않기로 한 항목은 ${gexcl} 에 한 줄씩 등록한다(사용자 승인 후)."
    gsum="[킷 드리프트·전역] 라이브에만 조항 $(cnt "$glive") · 킷에만 조항 $(cnt "$gkit") · 근거 문서 차이 ${#rdiff[@]} — $NEXT"
  fi
fi

[ -d "$R" ] && [ -d "$K" ] || finish "$gsec" "$gsum"
slug=$(printf '%s' "$proj" | sed 's#/#-#g')
marker="$HOME/.claude/.kit-drift-check${slug}"
[ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$today" ] && finish "$gsec" "$gsum"
printf '%s' "$today" > "$marker" 2>/dev/null || true

norm() { grep -vE '^[[:space:]]*#|^[[:space:]]*[A-Z_]+=' "$1" 2>/dev/null | md5 -q 2>/dev/null || md5sum 2>/dev/null | cut -d' ' -f1; }
diffs=(); missing=(); extra=(); hashes=(); mhashes=()
# 승인된 차이 = 레포 .claude/kit-drift-accepted.txt 의 `<키> <킷 해시> <레포 해시>` 줄(# 뒤는 사유). 킷 쪽은 플레이스홀더가
# 치환 전이라 치환된 레포와 늘 다르다 — 의도된 차이는 지문으로 등록하고, 어느 한쪽이라도 바뀌면 지문이 어긋나 다시 보고된다.
# 자리표시자 정규화(2026-10-08): 킷 파일의 {{NAME}} 은 설치 때 레포 값으로 치환돼, 치환만 한 파일도 "로직 차이"로 떴다.
# 자리표시자가 든 킷 줄을 정규식(자리 = 공백·따옴표 없는 값)으로 만들어 레포 파일에서 줄 전체가 맞는 줄을 찾고 값을 뽑는다.
# 같은 이름이 줄마다 다른 값이면 정규화하지 않는다(보고 유지). 자리표시자가 없는 줄의 차이는 그대로 잡힌다.
read -r -d '' PH_PY <<'PY' || true
import re, sys
kit = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
repo = open(sys.argv[2], encoding="utf-8", errors="replace").read().split("\n")
ph = re.compile(r"\{\{([A-Z_][A-Z0-9_]*)\}\}")
vals = {}
for line in kit:
    names = ph.findall(line)
    if not names:
        continue
    parts = ph.split(line)
    pat = "".join(re.escape(p) if i % 2 == 0 else r"([^\s'\"`]+)" for i, p in enumerate(parts))
    rx = re.compile(r"\A" + pat + r"\Z")
    cands = {m.groups() for m in (rx.match(r) for r in repo) if m}
    if len(cands) != 1:
        continue
    for n, v in zip(names, next(iter(cands))):
        if vals.setdefault(n, v) != v:
            sys.exit(3)
if not vals:
    sys.exit(4)
sys.stdout.write("\n".join(ph.sub(lambda m: vals.get(m.group(1), m.group(0)), l) for l in kit))
PY
ACC="$proj/.claude/kit-drift-accepted.txt"
logic_diff() {  # $1=키 $2=킷 파일 $3=레포 파일 — 다르고 승인 지문도 없으면 diffs 에 싣는다
  local kh rh
  kh=$(norm "$2"); rh=$(norm "$3")
  [ "$kh" = "$rh" ] && return 0
  # 자리표시자를 레포 값으로 치환한 킷 사본이 레포와 같으면 차이 아님(지문 해시는 원래 킷 해시 그대로).
  if grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$2" 2>/dev/null && command -v python3 >/dev/null 2>&1; then
    local sub; sub=$(mktemp "${TMPDIR:-/tmp}/kdc-sub.XXXXXX" 2>/dev/null) || sub=""
    if [ -n "$sub" ]; then
      if python3 -I -c "$PH_PY" "$2" "$3" > "$sub" 2>/dev/null && [ "$(norm "$sub")" = "$rh" ]; then rm -f "$sub"; return 0; fi
      rm -f "$sub"
    fi
  fi
  [ -f "$ACC" ] && awk -v k="$1" -v a="$kh" -v b="$rh" '$1==k && $2==a && $3==b {f=1} END {exit !f}' "$ACC" && return 0
  diffs+=("$1"); hashes+=("$1 $kh $rh")
}
# 의도적 미설치 = 같은 파일의 `<키> MISSING <킷 해시>` 줄. 키는 경로 허용 문자만, 해시는 hex 32자일 때만 인정하고
# 킷 파일 해시가 그 값과 같을 때만 "킷에만 있음"에서 뺀다 — 킷 쪽이 바뀌면 어긋나 다시 보고된다(지연 전파).
kit_only() {  # $1=키 $2=킷 파일 — 승인 지문이 없으면 missing 에 싣고 등록용 지문을 모은다
  local kh
  kh=$(norm "$2")
  [ -f "$ACC" ] && awk -v k="$1" -v h="$kh" '$1==k && $2=="MISSING" && $3==h && $1 ~ /^[A-Za-z0-9._\/-]+$/ && length($3)==32 && $3 !~ /[^0-9a-f]/ {f=1} END {exit !f}' "$ACC" && return 0
  missing+=("$1"); mhashes+=("$1 MISSING $kh")
}
# 모집단 = 훅 최상위 *.sh + lib/ 의 *.sh·*.py (lib 는 `lib/` 접두를 키로 — 최상위와 이름이 같아도 섞이지 않게).
#   .py 도 norm 의 제외 규칙(`#` 시작 줄 = 주석·shebang, 공백 없는 대문자 `NAME=` 줄)을 그대로 받는다 — `NAME = v` 꼴 대입은 비교에 남는다.
# ponytail: .py 에선 대문자 무공백 대입·여러 줄 호출 안 대문자 키워드 인자(`    DEBUG=True)`)·여러 줄 문자열 안 `#` 시작 줄도
#           비교에서 빠진다 / 업그레이드 = .py 전용 norm(python3 tokenize 로 COMMENT 토큰·shebang 만 제외)
for f in "$K"/*.sh "$K"/lib/*.sh "$K"/lib/*.py; do
  [ -f "$f" ] || continue
  b=${f#"$K"/}
  if [ -f "$R/$b" ]; then logic_diff "$b" "$f" "$R/$b"
  else kit_only "$b" "$f"; fi
done
for f in "$R"/*.sh "$R"/lib/*.sh "$R"/lib/*.py; do [ -f "$f" ] || continue; b=${f#"$R"/}; [ -f "$K/$b" ] || extra+=("$b"); done
# 모집단 = 워크플로(.js·.md) — 키는 `workflows/` 접두. 레포에 workflows 폴더가 없으면 설치 전이라 세지 않는다.
if [ -d "$KW" ] && [ -d "$RW" ]; then
  for f in "$KW"/*.js "$KW"/*.md; do
    [ -f "$f" ] || continue
    b=${f#"$KW"/}
    if [ -f "$RW/$b" ]; then logic_diff "workflows/$b" "$f" "$RW/$b"
    else kit_only "workflows/$b" "$f"; fi
  done
  for f in "$RW"/*.js "$RW"/*.md; do [ -f "$f" ] || continue; b=${f#"$RW"/}; [ -f "$KW/$b" ] || extra+=("workflows/$b"); done
fi
[ ${#diffs[@]} -eq 0 ] && [ ${#missing[@]} -eq 0 ] && [ ${#extra[@]} -eq 0 ] && finish "$gsec" "$gsum"

join() { local IFS=' '; echo "$*"; }
ctx="[킷 드리프트] $(basename "$proj") ↔ agent-scaffold 훅·워크플로 대조(설정값·# 주석 제외):
 로직 차이 ${#diffs[@]}: $(join "${diffs[@]}")
 킷에만 있음 ${#missing[@]}: $(join "${missing[@]}")
 레포에만 있음 ${#extra[@]}: $(join "${extra[@]}")
착수 전에 사용자에게 방향을 제안하라(지연 전파 원칙 — 이 레포에서 실제 작업할 때만 맞춘다, 다른 레포는 건드리지 않는다):
 ①로직 차이 = 킷의 플레이스홀더를 레포 값으로 치환한 뒤 diff 로 실차이를 본다 → 실차이면 최신 쪽으로 통일(킷이 정본이면 레포 갱신, 레포가 개선판이면 킷 갱신) / 치환·스크럽·레포 전용 차이뿐이면 사용자 승인 후 아래 지문 줄을 ${ACC#"$proj"/} 에 `# 사유` 와 함께 등록(다음부터 조용해지고, 한쪽이 바뀌면 다시 뜬다).
 ②킷에만 있음 = 이 레포에 필요한지 판정(스택·팀 방침 격리 항목이면 미설치가 정답일 수 있다) → 의도적 미설치로 정했으면 사용자 승인 후 아래 MISSING 지문 줄을 같은 파일에 `# 사유` 와 함께 등록(킷 파일이 바뀌면 다시 뜬다).
 ③레포에만 있음 = 스택 불문이면 전역으로, 동일 스택 공유면 킷으로 승격 후보. 도메인 전용이면 그대로.
 제안만 하고 사용자 승인 후 실행.
 로직 차이 지문(키 킷해시 레포해시):
$(printf '  %s\n' "${hashes[@]}")
 킷에만 있음 지문(키 MISSING 킷해시):
$(printf '  %s\n' "${mhashes[@]}")"
[ -n "$gsec" ] && ctx="$ctx

$gsec"
# 레포명은 basename 의 제어문자(개행 포함)를 걷어 화면 한 줄을 지킨다.
rname=$(basename "$proj" | tr -d '[:cntrl:]')
msg="[킷 드리프트] ${rname}: 로직 차이 ${#diffs[@]} · 킷에만 ${#missing[@]} · 레포에만 ${#extra[@]} — $NEXT"
[ -n "$gsum" ] && msg="$msg
$gsum"
finish "$ctx" "$msg"
