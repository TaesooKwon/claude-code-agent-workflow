#!/usr/bin/env bash
# agent-audit 기계적 점검 — 머신층(킷)·훅 동작·memory·프로젝트층을 한 번에.
# 사용: audit.sh [프로젝트경로] [--fast]   (--fast = 킷 doctor·test-hooks 스킵)
set -u

proj=""; FAST=0
for a in "$@"; do case "$a" in --fast) FAST=1;; *) proj="$a";; esac; done
[ -n "$proj" ] || proj="${CLAUDE_PROJECT_DIR:-$PWD}"
KIT="${AGENT_KIT_DIR:-$HOME/claude-agent-kit}"
FAIL=0
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; FAIL=1; }

echo "=== agent-audit: $proj ==="

if [ "$FAST" = 0 ]; then
  echo "--- [A] 머신층 (킷 doctor) ---"
  if [ -x "$KIT/doctor.sh" ]; then
    # 1회만 실행 — 파이프(| tail)가 종료코드를 가리므로 출력은 변수에, 판정은 rc로.
    # ⚠·✗ 라인은 전부 노출(드리프트 경고가 tail 에 가려 침묵하는 것 방지), 정상 시 결과줄만.
    dout=$("$KIT/doctor.sh" 2>&1); drc=$?
    printf '%s\n' "$dout" | grep -E '⚠|✗' | sed 's/^/  /'
    printf '%s\n' "$dout" | tail -1 | sed 's/^/  /'
    [ "$drc" = 0 ] || FAIL=1
  else warn "킷 없음($KIT) — 머신층 검진 스킵(AGENT_KIT_DIR로 지정 가능)"; fi

  echo "--- [B] 훅 동작 회귀 (킷 test-hooks) ---"
  if [ -x "$KIT/test-hooks.sh" ]; then
    "$KIT/test-hooks.sh" >/dev/null 2>&1 && ok "test-hooks 전체 PASS" || bad "test-hooks 실패 — $KIT/test-hooks.sh 직접 실행해 확인"
  else warn "test-hooks.sh 없음 — 훅 동작 회귀 스킵"; fi
fi

echo "--- [C] memory (hygiene 스캔) ---"
SCAN="$HOME/.claude/skills/memory-hygiene/scripts/scan.sh"
if [ -f "$SCAN" ]; then
  # 왜: 출력 필터가 scan.sh 의 실패 라인(✗ memory 없음)을 걸러 없애고 종료코드도 무시해,
  # 위생 점검이 통째로 스킵됐는데 "정상"으로 보고되던 결함 → rc 판정 + ✗ 라인 통과.
  sout=$(bash "$SCAN" "$proj" 2>&1); src=$?
  printf '%s\n' "$sout" | grep -E '^(✗|파일 |--- |  )' | head -30
  if [ "$src" = 0 ]; then
    echo "  (전체 리포트: bash $SCAN $proj — 처분은 memory-hygiene SKILL §2)"
  else
    bad "memory 위생 스캔 실패(rc=$src) — bash $SCAN $proj 직접 실행해 확인"
  fi
else warn "memory-hygiene 스킬 없음 — 스캔 스킵"; fi

echo "--- [D] 프로젝트층 ---"
# 관측 래퍼(hook-obs.sh)로 감싼 등록: 래퍼가 없거나 문법 오류면 등록 형태가 원 훅으로 폴백해 조용히 관측만 끊긴다
# → 명령에 hook-obs.sh 가 있으면 래퍼 실존·bash -n 을 검사한다(같은 래퍼는 1회만 보고).
WCHECKED=" "
check_obs_wrapper() {
  case "$1" in *hook-obs.sh*) ;; *) return 0;; esac
  local w
  w=$(printf '%s' "$1" | grep -oE '[^" ;=]*hook-obs\.sh' | head -1)
  w="${w/#\~/$HOME}"; w="${w/#\$HOME/$HOME}"
  case "$WCHECKED" in *" $w "*) return 0;; esac
  WCHECKED="$WCHECKED$w "
  if [ ! -f "$w" ]; then bad "관측 래퍼 없음: $w (등록 훅은 원 훅으로 폴백 — 관측 끊김)"
  elif ! bash -n "$w" 2>/dev/null; then bad "관측 래퍼 문법 오류: $w (등록 훅은 원 훅으로 폴백 — 관측 끊김)"
  else ok "관측 래퍼 정상(실존·bash -n): $w"; fi
}
SJ="$proj/.claude/settings.json"
if [ -f "$SJ" ] && command -v jq >/dev/null 2>&1; then
  miss=0; total=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    check_obs_wrapper "$c"
    f=$(printf '%s' "$c" | grep -oE '\$CLAUDE_PROJECT_DIR/[^" ]+' | head -1 | sed "s#\$CLAUDE_PROJECT_DIR#$proj#")
    [ -n "$f" ] || continue
    total=$((total+1))
    [ -f "$f" ] || { bad "등록 훅 파일 없음: $f"; miss=1; }
  done < <(jq -r '.hooks[]?[]?.hooks[]?.command // empty' "$SJ" 2>/dev/null)
  [ "$miss" = 0 ] && ok "settings 등록 훅 ${total}개 전부 실존"
else warn "프로젝트 settings.json 없음/파싱 불가 — 훅 등록 점검 스킵"; fi

# 왜: 킷 doctor.sh 의 전역 훅 점검 목록이 하드코딩이라 나중에 추가된 훅(PreToolUse 등)이 사각으로 남는다
# (삭제되거나 실행권한을 잃어도 전면감사가 통과). settings.json 등록분을 정본으로 삼아 실존·+x 를 여기서 검사.
GS="$HOME/.claude/settings.json"
if [ -f "$GS" ] && command -v jq >/dev/null 2>&1; then
  gmiss=0; gtotal=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    check_obs_wrapper "$c"
    # 대상 훅 = 마지막 절대경로 .sh 토큰 — 래퍼 등록 형태(…&& exec bash "$W" <훅> || exec <훅>)의 끝이 원 훅이다.
    # $HOME·~ 를 먼저 펼쳐야 "$HOME/x.sh" 가 "/x.sh" 로 잘려 잡히지 않는다.
    # ponytail: 공백 포함 경로·인라인 셸 커맨드(.sh 없는 명령)는 미검사 / 필요 시 셸 어휘분석으로 확장
    ce="${c//\$HOME/$HOME}"; ce="${ce//\~\//$HOME/}"
    f=$(printf '%s' "$ce" | grep -oE '/[^" ;|&]+\.sh' | tail -1)
    [ -n "$f" ] || continue
    gtotal=$((gtotal+1))
    if [ ! -f "$f" ]; then bad "전역 등록 훅 파일 없음: $f"; gmiss=1
    elif [ ! -x "$f" ]; then bad "전역 등록 훅 실행권한 없음: $f"; gmiss=1; fi
  done < <(jq -r '.hooks[]?[]?.hooks[]?.command // empty' "$GS" 2>/dev/null)
  [ "$gmiss" = 0 ] && ok "전역 settings 등록 훅 ${gtotal}개 전부 실존·실행가능"
else warn "전역 settings.json 없음/파싱 불가 — 전역 훅 등록 점검 스킵"; fi

[ -f "$proj/.claude/conventions.enabled" ] && ok "conventions.enabled 마커 있음(컨벤션 게이트 활성)" || warn "conventions.enabled 없음(비-harness 레포면 정상)"

if [ -d "$proj/.git" ]; then
  for f in CLAUDE.md .claude docs/agent_history.md; do
    p="$proj/$f"; [ -e "$p" ] || continue
    if git -C "$proj" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
      case "$f" in CLAUDE.md) warn "$f 가 tracked — 팀 공유 의도가 아니면 격리 검토";; *) bad "$f 가 tracked — AI 스캐폴딩 격리 위반(.git/info/exclude)";; esac
    elif git -C "$proj" check-ignore -q "$f" 2>/dev/null; then
      ok "$f 격리됨(ignore/exclude)"
    else
      warn "$f 미격리(untracked·exclude 없음) — .git/info/exclude 등록 검토"
    fi
  done
else warn "git 레포 아님 — 격리 점검 스킵"; fi

GS="$HOME/.claude/settings.json"; LS="$proj/.claude/settings.local.json"
IP="$HOME/.claude/plugins/installed_plugins.json"
if command -v jq >/dev/null 2>&1 && [ -f "$GS" ]; then
  while IFS= read -r pl; do
    [ -n "$pl" ] || continue
    # 훅을 배포하지 않는 플러그인(statusline·lspServers 등)은 이중발동 무관 → 스킵.
    inst=$(jq -r --arg k "$pl" '.plugins[$k][0].installPath // empty' "$IP" 2>/dev/null)
    [ -n "$inst" ] && [ -e "$inst/hooks/hooks.json" ] || continue
    # 훅 본문을 읽고 로컬 훅과 겹치지 않는다고 판정한 플러그인은 plugin-hooks-ok.txt 에 `<id> <hooks.json sha256 앞 16자> # 사유` 로 둔다.
    # 해시에 묶는 이유 = 플러그인 업데이트로 훅이 바뀌면 판정이 무효가 되므로 경고가 되살아나야 한다.
    hsh=$(shasum -a 256 "$inst/hooks/hooks.json" | cut -c1-16)
    if grep -qE "^$(printf '%s' "$pl" | sed 's/[.[\*^$/]/\\&/g') $hsh( |$)" "$(dirname "$0")/../plugin-hooks-ok.txt" 2>/dev/null; then
      ok "플러그인 $pl: 훅 비중복 판정 기록 있음(hooks.json $hsh)"; continue
    fi
    if [ -d "$proj/.claude/hooks" ] && [ -n "$(ls "$proj/.claude/hooks"/*.sh 2>/dev/null)" ]; then
      # 주의: jq '//'는 false도 소거한다 — has() 로 키 존재를 판정해야 off=false 를 읽는다.
      off=$(jq -r --arg k "$pl" '.enabledPlugins // {} | if has($k) then (.[$k]|tostring) else "" end' "$LS" 2>/dev/null)
      [ "$off" = "false" ] && ok "플러그인 $pl: 로컬 off(이중발동 차단)" || bad "훅 배포 플러그인 $pl 전역 on + 로컬 훅 존재 + 로컬 off 없음 — 이중발동 위험(settings.local.json enabledPlugins false)"
    fi
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value==true) | .key' "$GS" 2>/dev/null)
fi

echo "--- [D2] 처분 도달 대장(역방향) ---"
# 왜: 위 점검은 "등록된 훅 → 파일 실존" 한 방향뿐이라, 파일만 만들고 등록하지 않은 게이트는 아무도 묻지 않는다
# (2026-09-18 실측: 전역 Stop 훅 rules-size-check 가 규약 다이어트 전부터 미등록이었는데 발견까지 감사가 통과했다).
# ①훅 파일 → 어느 settings 에든 등록됐나(basename 대조). 의도적 미등록은 파일 헤더에
#   `# audit: unregistered-ok — <사유>` 를 달아 파일 자신이 선언한다(표식 없는 미등록 = ✗).
# ②규약의 [[포인터]] → 정본 파일 실존(전역 = rules-rationale / 프로젝트 = memory 또는 rules-rationale).
#   인라인 코드(`…`) 안의 [[…]] 는 설명 문구라 뺀다.
# ponytail: 등록은 basename 부분일치로만 본다(동명 훅·주석 속 언급은 등록으로 셈) · 최근 발화 흔적은 훅마다
#   로그 계약이 달라 미검사 / 업그레이드 경로 = 훅 공통 발화 로그를 두고 N일 무발화를 경고.
if command -v jq >/dev/null 2>&1; then
  reg=$(for s in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
                 "$proj/.claude/settings.json" "$proj/.claude/settings.local.json"; do
          [ -f "$s" ] && jq -r '.. | objects | select(has("command")) | .command' "$s" 2>/dev/null
        done)
  umiss=0; uok=0; utotal=0
  for f in "$HOME/.claude/hooks"/*.sh "$proj/.claude/hooks"/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in *.test.sh) continue;; esac
    utotal=$((utotal+1))
    printf '%s\n' "$reg" | grep -qF -- "$(basename "$f")" && continue
    if head -5 "$f" | grep -q '^# audit: unregistered-ok'; then uok=$((uok+1))
    else bad "훅 파일이 어느 settings 에도 미등록: $f (의도면 헤더에 '# audit: unregistered-ok — 사유')"; umiss=1; fi
  done
  [ "$umiss" = 0 ] && ok "훅 파일 ${utotal}개 전부 등록됨(의도적 미등록 표식 ${uok}개)"
else warn "jq 없음 — 역방향 등록 점검 스킵"; fi

echo "--- [D3] 훅 정책 줄(강제 수준·도구 부재 시 동작) ---"
# 정책 줄이 없으면 은퇴 후보 리포트(hook-obs-report.sh)가 기록용 훅을 걸러내지 못한다. 경고만 —
# 킷에서 줄을 더한 뒤 bootstrap-machine.sh 재설치 전까지는 설치본에 줄이 없는 게 정상이라서.
pdirs=("$HOME/.claude/hooks"); [ -d "$proj/.claude/hooks" ] && pdirs+=("$proj/.claude/hooks")
pm=$(bash "$(dirname "$0")/hook-policy-report.sh" --missing "${pdirs[@]}")
if [ -n "$pm" ]; then warn "정책 줄 없음·형식 오류 $(printf '%s\n' "$pm" | grep -c .)개 — 표·목록 = hook-policy-report.sh (킷 갱신분이면 bootstrap 재설치)"
else ok "훅 정책 줄 전부 있음"; fi

pmiss=0; ptotal=0
_ptr() { sed 's/`[^`]*`//g' "$1" | grep -oE '\[\[[^]]+\]\]' | tr -d '[]' | sort -u; }
MEMD="$HOME/.claude/projects/$(printf '%s' "$proj" | sed 's|/|-|g')/memory"
RAT="$HOME/.claude/rules-rationale"
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
  while IFS= read -r n; do [ -n "$n" ] || continue; ptotal=$((ptotal+1))
    [ -f "$RAT/$n.md" ] || { bad "전역 규약 죽은 포인터: [[$n]] ($RAT/$n.md 없음)"; pmiss=1; }
  done < <(_ptr "$HOME/.claude/CLAUDE.md")
fi
if [ -f "$proj/CLAUDE.md" ]; then
  while IFS= read -r n; do [ -n "$n" ] || continue; ptotal=$((ptotal+1))
    [ -f "$MEMD/$n.md" ] || [ -f "$RAT/$n.md" ] || { bad "프로젝트 규약 죽은 포인터: [[$n]] (memory·rules-rationale 둘 다 없음)"; pmiss=1; }
  done < <(_ptr "$proj/CLAUDE.md")
fi
[ "$pmiss" = 0 ] && ok "규약 포인터 ${ptotal}개 전부 도달"

# 왜: 규약이 인용한 파일·스크립트가 지워지거나 이름이 바뀌면 그 조항은 소리 없이 죽는다 — 공식 claude-md-management 의 red flag("삭제된 파일 참조·실패할 명령")를 흡수(2026-11-04).
# ponytail: 백틱 안·확장자/접두 허용목록만 본다(맨 문장 속 경로·디렉터리 미검사) · 부재 = warn(rc 불변 — 새 휴리스틱)
#   · 전역 상대 토큰은 그 레포에 있을 때만 대조("그 스크립트를 둔 레포에서만" 조건부 인용이라 없으면 건너뜀)
#   · 프로젝트 토큰은 git 추적 파일 접미 일치 폴백(축약 경로 대응, 비 git 이면 생략)
#   / 업그레이드 경로 = 디렉터리 토큰·SKILL.md 까지 확장, 오탐이 안정되면 bad 로 승격
cmiss=0; ctotal=0
_cite() { grep -oE '`[^`]+`' "$1" | tr -d '`' | sort -u; }
_cite_pick() {
  case "$1" in *'*'*|*'<'*|*'>'*|*'{'*|*'$'*|*' '*|*'|'*|http*|-*) return 1;; esac
  case "$1" in '~/'*|.claude/*|*.sh|*.py|*.js|*.mjs|*.md|*.json|*.yaml) return 0;; esac
  return 1
}
_cite_git() {  # 추적 파일 중 경로 접미가 토큰과 같은 것이 있나 — 문자열 비교라 정규식 메타 무해
  git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$proj" -c core.quotepath=off ls-files 2>/dev/null | awk -v t="$1" '
    $0 == t || (length($0) > length(t) && substr($0, length($0) - length(t)) == "/" t) { f = 1; exit }
    END { exit !f }'
}
_cite_exists() {  # $1 = 토큰, $2 = global|project → 0 실재 / 1 미발견 / 2 건너뜀
  case "$1" in '~/'*) [ -e "$HOME/${1:2}" ]; return;; esac
  case "$1" in
    */*) [ -e "$proj/$1" ] && return 0
         if [ "$2" = global ]; then [ -e "$HOME/$1" ] && return 0; return 2; fi
         _cite_git "$1"; return;;
  esac
  [ -n "$(find "$HOME/.claude" "$proj/.claude" "$HOME/.claude-team" "$HOME/.claude-api" -maxdepth 4 -name "$1" -print -quit 2>/dev/null)" ] && return 0
  [ "$2" = project ] && _cite_git "$1"
}
for pair in "global:$HOME/.claude/CLAUDE.md" "project:$proj/CLAUDE.md"; do
  scope="${pair%%:*}"; md="${pair#*:}"
  [ -f "$md" ] || continue
  while IFS= read -r t; do [ -n "$t" ] || continue
    _cite_pick "$t" || continue
    _cite_exists "$t" "$scope"; crc=$?
    [ "$crc" = 2 ] && continue
    ctotal=$((ctotal+1))
    [ "$crc" = 0 ] || { warn "규약 인용 경로 미발견: $t ($md)"; cmiss=1; }
  done < <(_cite "$md")
done
[ "$cmiss" = 0 ] && ok "규약 인용 경로 ${ctotal}개 전부 실재"

echo "--- [E] 프로젝트 스킬 스크립트 스모크 ---"
# 왜: 에이전트 자기 도구가 팀의 설정 리팩터링에 소리 없이 깨진다(실증 2026-07-27 — 팀이 DB 접속정보를
# application.properties → application-<프로파일>.properties 로 옮기자 dev-ddl-apply 가 5일간 전면
# 작동 불능, 그동안 스키마 스냅샷도 갱신 불가라 컨벤션 룰 K 가 stale 기준으로 대조 중이었음).
# 규약(--check 자가점검 모드를 지원하는 스킬 스크립트)을 발견해 실행만 해본다.
# 출력은 삼키고 성공/실패만 보고 — 접속정보·계정이 감사 로그에 남지 않게(민감정보 비노출).
smoked=0
for s in "$proj"/.claude/skills/*/scripts/*.py; do
  [ -f "$s" ] || continue
  grep -q -- '--check' "$s" 2>/dev/null || continue
  smoked=$((smoked+1))
  name="${s#$proj/.claude/skills/}"
  out=$(mktemp); rc=""
  ( python3 "$s" --check >"$out" 2>&1; echo $? >"$out.rc" ) &
  pid=$!
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; bad "$name --check 응답 없음(30초 타임아웃)"
  else
    wait "$pid" 2>/dev/null; rc=$(cat "$out.rc" 2>/dev/null)
    if [ "$rc" = 0 ]; then ok "$name --check 정상"
    else bad "$name --check 실패(rc=$rc): $(head -1 "$out" | cut -c1-120)"; fi
  fi
  rm -f "$out" "$out.rc"
done
[ "$smoked" = 0 ] && warn "--check 지원 스킬 스크립트 없음 — 스모크 대상 0건(자가점검 모드 추가 검토)"

echo "--- [F] 훅 로그 최근 BLOCK/deny(7일) ---"
# 게이트가 막은 기록의 가시화 — BLOCK 이 찍혀도 아무도 tail 하지 않으면 죽은 관측이 된다(2026-08-13 감사 보완).
since="$(date -v-7d +%F 2>/dev/null || date -d '7 days ago' +%F 2>/dev/null || echo 1970-01-01)"
blk_found=0
for lg in "$HOME/.claude/hooks"/*.log; do
  [ -f "$lg" ] || continue
  hits="$(awk -v d="$since" '$1 >= d' "$lg" 2>/dev/null | grep 'BLOCK\|deny' || true)"
  if [ -n "$hits" ]; then
    echo "  ⚠ $(basename "$lg"): $(printf '%s\n' "$hits" | wc -l | tr -d ' ')건 — 최근분: $(printf '%s\n' "$hits" | tail -1 | cut -c1-110)"
    blk_found=1
  fi
done
[ "$blk_found" = 0 ] && echo "  ✓ 최근 7일 BLOCK/deny 없음(정상 통과만 기록됨)"

echo
[ "$FAIL" = 0 ] && echo "== 기계적 점검: 정상(경고는 판단 대상) — 이어서 SKILL §2 판단 체크리스트 ==" || echo "== 문제 있음(위 ✗ 조치) =="
exit $FAIL
