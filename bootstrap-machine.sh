#!/usr/bin/env bash
# bootstrap-machine.sh — 새(또는 재설정) 머신에 전역 에이전트 레이어를 설치한다.
# 킷의 global/ 자산을 machine.env 값으로 토큰 치환해 ~/.claude/ 로 편다.
#   토큰: __HOME__ → $HOME · __PROJECTS_DIR__ · __STRICT_PROJECT__ · __MAVEN_REPO__ · __AGENT_REPOS__
# 안전: 기존 파일은 내용이 다를 때만 .bak-<시각>으로 백업 후 덮어씀(멱등). --dry-run 지원.
#
# 사용:
#   cp machine.env.example machine.env && vi machine.env   # 머신 고유값 채우기
#   ./bootstrap-machine.sh [--dry-run]
set -eu

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
G="$KIT_DIR/global"
DEST="$HOME/.claude"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

# --- 필수 도구 얼리 가드 ---
#   설치되는 Stop 훅(목록 = 템플릿 hooks.Stop)이 전부 런타임에 jq를 쓰고,
#   이력 스크립트가 python3·git에 의존한다. 없으면 "설치는 성공, 매 턴 훅은 조용히 깨짐"이
#   되므로 신규 머신 경로(settings.json 없음)까지 포함해 여기서 먼저 막는다(doctor 필수 3종과 동일 계약).
missing=""
for c in jq python3 git; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
if [ -n "$missing" ]; then
  echo "✗ 필수 도구 없음:$missing — 훅/이력이 동작하지 않는다. 먼저 설치:" >&2
  echo "    brew install$missing" >&2
  exit 1
fi

# --- machine.env 로드 ---
ENV_FILE="$KIT_DIR/machine.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "✗ machine.env 없음. 먼저: cp machine.env.example machine.env 후 값 채우기." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${PROJECTS_DIR:=$HOME/projects}"
: "${STRICT_PROJECT:=}"
: "${MAVEN_REPO:=$HOME/maven_repo/maven/repository}"
# 짝 = doctor.sh 의 AGENT_REPOS 기본값(바꾸면 함께 바꾼다).
: "${AGENT_REPOS:=(machine.env 의 AGENT_REPOS 미설정 — 대상 레포를 채운다)}"
# 자유 텍스트라 sed 치환 특수문자(& # | \)를 이스케이프해 둔다.
AGENT_REPOS_SED="$(printf '%s' "$AGENT_REPOS" | sed 's/[&#|\\]/\\&/g')"

stamp="$(date '+%Y%m%d-%H%M%S')"
subst() {  # stdin→stdout 토큰 치환
  sed -e "s#__HOME__#$HOME#g" \
      -e "s#__PROJECTS_DIR__#$PROJECTS_DIR#g" \
      -e "s#__STRICT_PROJECT__#$STRICT_PROJECT#g" \
      -e "s#__MAVEN_REPO__#$MAVEN_REPO#g" \
      -e "s#__AGENT_REPOS__#$AGENT_REPOS_SED#g"
}

install_file() {  # $1=src(킷) $2=dest  — 토큰치환 후 설치(내용 다르면 백업)
  local src="$1" dst="$2" tmp
  tmp="$(mktemp)"
  # 텍스트만 토큰치환(sed). 바이너리(xlsx·sqlite·이미지 등)는 그대로 복사 — sed 는 non-UTF8 에
  # "illegal byte sequence"로 실패해 자산을 깨뜨린다. grep -I 로 바이너리 판별.
  if grep -Iq . "$src" 2>/dev/null; then subst < "$src" > "$tmp"; else cp "$src" "$tmp"; fi
  # 셸 스크립트는 문법 검사 후에만 설치 — 등록된 PreToolUse 훅이 문법 오류면 그 도구 호출이 전부 막힌다(기존 설치본 유지).
  case "$dst" in *.sh) if ! bash -n "$tmp" 2>/dev/null; then rm -f "$tmp"; echo "  ✗ 문법 오류로 설치 안 함 ${dst/#$HOME/~} (킷 $src 확인 — bash -n)"; return 0; fi ;; esac
  # 원본이 -x 면 설치본에 -x 를 붙인다(mktemp 사본은 0600 이라 mv 만으로는 -x 가 빠진다) — 내용이 같아도 빠진 -x 는 복구한다.
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; echo "  = 동일  ${dst/#$HOME/~}"
    if [ "$DRY" = 0 ] && [ -x "$src" ] && [ ! -x "$dst" ]; then chmod +x "$dst" && echo "  ↻ 실행 비트 복구 ${dst/#$HOME/~}" || echo "  ✗ 실행 비트 복구 실패 ${dst/#$HOME/~}"; fi
    return 0; fi
  if [ "$DRY" = 1 ]; then echo "  [dry] 설치 ${dst/#$HOME/~}"; rm -f "$tmp"; return; fi
  mkdir -p "$(dirname "$dst")"
  [ -f "$dst" ] && cp "$dst" "$dst.bak-$stamp" && echo "  ↻ 백업 ${dst/#$HOME/~}.bak-$stamp"
  mv "$tmp" "$dst"
  if [ -x "$src" ]; then chmod +x "$dst" || echo "  ✗ 실행 비트 설정 실패 ${dst/#$HOME/~}"; fi
  echo "  ✓ 설치  ${dst/#$HOME/~}"
}

echo "=== bootstrap-machine → ~/.claude 설치 ${DRY:+(DRY-RUN)} ==="
echo "  PROJECTS_DIR=$PROJECTS_DIR · STRICT_PROJECT=${STRICT_PROJECT:-(비움=OR모드)}"

# 1) 훅
for f in "$G"/hooks/*.sh; do install_file "$f" "$DEST/hooks/$(basename "$f")"; [ "$DRY" = 0 ] && chmod +x "$DEST/hooks/$(basename "$f")" 2>/dev/null || true; done
# 2) 스킬(harness·bootstrap-project·playwright-verify) — 개별 파일 치환 설치
find "$G/skills" -type f | while IFS= read -r f; do install_file "$f" "$DEST/skills/${f#"$G"/skills/}"; done
[ "$DRY" = 0 ] && find "$DEST/skills" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
# 3) agent-scaffold
find "$G/agent-scaffold" -type f | while IFS= read -r f; do install_file "$f" "$DEST/agent-scaffold/${f#"$G"/agent-scaffold/}"; done
[ "$DRY" = 0 ] && find "$DEST/agent-scaffold" -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
# 4) 에이전트
[ -d "$G/agents" ] && for f in "$G"/agents/*; do install_file "$f" "$DEST/agents/$(basename "$f")"; done
# 5) 전역 CLAUDE.md
install_file "$G/CLAUDE.md" "$DEST/CLAUDE.md"
# 5-1) 전역 규약 근거 저장소 — README(운용 규칙)만 설치. 근거 파일 본문은 머신마다 쌓이는
#      개인 자산이라 킷에 담지 않는다(식별자 반출 금지). 상시 로드가 아니라 크기 게이트 대상도 아니다.
install_file "$G/rules-rationale/README.md" "$DEST/rules-rationale/README.md"
# 6) settings.json — 없으면 설치. 있으면 병합(기존 파일 = 백업 .bak-<시각> 후 교체):
#    ① hooks.Stop 을 킷 것으로 통째 교체(라이브에만 있는 Stop 원소는 사라진다).
#    ② PreToolUse 의 destructive-cmd-ask 등록 보장(운영 DB MCP 확인창 — 없으면 킷 항목 추가, 있으면 matcher 가
#       킷 것으로 바뀔 수 있다 — 조건은 아래 jq).
#    ③ 킷 등록 보장 — Stop 밖 이벤트마다 템플릿의 훅이 기존 settings 의 같은 이벤트 어디에도 없으면 그 훅을 템플릿의
#       matcher 그룹째 뒤에 붙인다(그룹 안 이미 등록된 훅은 뺀다). "있음" = 같은 스크립트 파일명(hnames — hook-obs 래퍼
#       꼴 command 도 감싼 훅 이름으로 센다). 기존 항목·순서·matcher·사용자 고유 훅은 그대로.
#    ④ permissions.deny 가 아예 없을 때만 킷 deny 를 넣는다(이미 있는 deny 는 사용자 큐레이션이라 건드리지 않는다).
#    Claude Code 가 첫 실행 시 settings.json 을 선생성하는 흔한 경로에서도 킷 훅이 등록되게.
#    기존 파일이 이상 형식(객체가 아님·hooks 가 객체가 아님·이벤트 값이 배열이 아님·그룹이 객체가 아님 등)이면 jq 가
#    실패하고 기존 파일은 그대로 둔 채 안내만 낸다.
# ponytail: "있음" 판정은 command 안 '/hooks/<이름>.(sh|py|js|mjs)' 파일명 일치 — 다른 경로의 같은 이름 훅도 있음으로 친다 / 오판이 관측되면 경로까지 비교.
SETTINGS_JQ_DEFS='def hnames: (.command // "") as $c
    | ([$c | scan("/hooks/([A-Za-z0-9._-]+\\.(?:sh|py|js|mjs))") | .[0]] - ["hook-obs.sh"]) as $n
    | if ($n | length) > 0 then $n else [$c] end;
  def evnames($e): [(.hooks[$e] // [])[] | .hooks[]? | hnames[]] | unique;'
if [ ! -f "$DEST/settings.json" ]; then
  install_file "$G/settings.json.template" "$DEST/settings.json"
else  # jq 는 상단 얼리 가드로 보장됨
  tmpl="$(mktemp)"; subst < "$G/settings.json.template" > "$tmpl"
  merged="$(mktemp)"
  # 형식 검사 → ① → ② → ③ → ④. jq 가 실패해도(set -e) 멈추지 않고 아래 검사가 기존 파일을 지킨다.
  jq -s "$SETTINGS_JQ_DEFS"'
         if length != 2 or (.[0] | type) != "object" or ((.[0].hooks // {}) | type) != "object"
            or any((.[0].hooks // {})[]; type != "array" or any(.[]; type != "object" or ((.hooks // []) | type) != "array"))
         then error("settings.json 형식이 예상과 다름") else . end
         | .[0] as $cur | .[1] as $kit | $cur | .hooks = (($cur.hooks // {}) + {Stop: $kit.hooks.Stop})
         | ($kit.hooks.PreToolUse // [] | map(select(any(.hooks[]?; (.command // "") | test("destructive-cmd-ask\\.sh")))) | .[0]) as $kd
         | def isd: any(.hooks[]?; (.command // "") | test("destructive-cmd-ask\\.sh"));
           if $kd == null then .
           elif any((.hooks.PreToolUse // [])[]; isd) then
             .hooks.PreToolUse |= map(if isd and (((.matcher // "") | test("__PROJECT__")) or ((.matcher // "") | test("mcp__") | not)) then .matcher = $kd.matcher else . end)
           else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [$kd]) end
         | reduce ($kit.hooks // {} | to_entries[] | select(.key != "Stop") | .key as $e | .value[] | {e: $e, g: .}) as $x (.;
             evnames($x.e) as $have
             | ($x.g | .hooks |= map(select(any(hnames[]; IN($have[])) | not))) as $g
             | if ($g.hooks | length) > 0 then .hooks[$x.e] = ((.hooks[$x.e] // []) + [$g]) else . end)
         | if (($cur.permissions == null) or ((($cur.permissions | type) == "object") and $cur.permissions.deny == null)) then .permissions = (((.permissions | objects) // {}) + {deny: ($kit.permissions.deny // [])}) else . end' "$DEST/settings.json" "$tmpl" > "$merged" 2>/dev/null || :
  if [ -s "$merged" ] && jq -e . "$merged" >/dev/null 2>&1; then
    # ③ 으로 새로 들어갈 등록(이벤트:파일명) — 안내용
    adds="$(jq -rs "$SETTINGS_JQ_DEFS"' .[0] as $c | .[1] as $m
            | [$m.hooks | keys[] | select(. != "Stop") as $e | ($m | evnames($e)) - ($c | evnames($e)) | .[] | select(test("\\.(sh|py|js|mjs)$")) | "\($e):\(.)"]
            | join(" ")' "$DEST/settings.json" "$merged" 2>/dev/null || :)"
    what="hooks.Stop 을 킷 것으로 교체(라이브에만 있는 Stop 원소는 사라진다)·킷 훅 등록 추가[${adds:-없음}]·destructive-cmd-ask 등록 보장·deny 없으면 킷 deny 주입·그 밖 설정 보존"
    if cmp -s "$merged" "$DEST/settings.json"; then echo "  = 동일  settings.json (hooks.Stop·킷 훅 등록·destructive-cmd-ask·deny 이미 정합)"
    elif [ "$DRY" = 1 ]; then echo "  [dry] settings.json 갱신 예정 — $what (백업 .bak-<시각>)"
    else cp "$DEST/settings.json" "$DEST/settings.json.bak-$stamp"; mv "$merged" "$DEST/settings.json"
         echo "  ✓ 갱신  settings.json — $what (백업 .bak-$stamp)"; fi
  else echo "  ✗ settings.json 갱신 실패(jq — 형식이 예상과 다르거나 jq 오류) — 수동 확인 필요(기존 settings.json 은 그대로)"; fi
  rm -f "$tmpl" "$merged" 2>/dev/null
fi

# 7) jdtls 심(Java LSP, 선택) — ~/.local/bin 에 설치(~/.claude 밖). jdtls 미설치 머신에서도
#    무해(호출 시 안내 후 종료). 실사용 셋업은 SETUP.md 11절(brew jdtls + jdtls-lsp 플러그인).
install_file "$G/bin/jdtls" "$HOME/.local/bin/jdtls"
[ "$DRY" = 0 ] && chmod +x "$HOME/.local/bin/jdtls" 2>/dev/null || true

echo "=== 완료. 검진: ./doctor.sh ==="