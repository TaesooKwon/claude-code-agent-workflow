#!/usr/bin/env bash
# bootstrap-machine.sh — 새(또는 재설정) 머신에 전역 에이전트 레이어를 설치한다.
# 킷의 global/ 자산을 machine.env 값으로 토큰 치환해 ~/.claude/ 로 편다.
#   토큰: __HOME__ → $HOME · __PROJECTS_DIR__ · __STRICT_PROJECT__ · __MAVEN_REPO__ · __AGENT_REPOS__
# 안전: 기존 파일은 내용이 다를 때만 .bak-<날짜>로 백업 후 덮어씀(멱등). --dry-run 지원.
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
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; echo "  = 동일  ${dst/#$HOME/~}"; return; fi
  if [ "$DRY" = 1 ]; then echo "  [dry] 설치 ${dst/#$HOME/~}"; rm -f "$tmp"; return; fi
  mkdir -p "$(dirname "$dst")"
  [ -f "$dst" ] && cp "$dst" "$dst.bak-$stamp" && echo "  ↻ 백업 ${dst/#$HOME/~}.bak-$stamp"
  mv "$tmp" "$dst"; echo "  ✓ 설치  ${dst/#$HOME/~}"
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
# 6) settings.json — 없으면 설치. 있으면 hooks.Stop 을 킷 것으로 통째 교체(라이브에만 있는 Stop 원소는 사라진다 — 백업 .bak-<시각>)하고 그 밖(권한/statusline/MCP)은 보존.
#    Claude Code가 첫 실행 시 settings.json을 선생성하는 흔한 경로에서도 Stop 훅이 반드시 등록되게.
if [ ! -f "$DEST/settings.json" ]; then
  install_file "$G/settings.json.template" "$DEST/settings.json"
else  # jq 는 상단 얼리 가드로 보장됨
  tmpl="$(mktemp)"; subst < "$G/settings.json.template" > "$tmpl"
  merged="$(mktemp)"
  # 기존 전체 보존 + hooks.Stop 을 킷 템플릿 것으로 세팅(다른 hooks 이벤트·권한·statusline·MCP 유지). 백업 후 교체.
  jq -s '.[0] as $cur | .[1] as $kit | $cur | .hooks = (($cur.hooks // {}) + {Stop: $kit.hooks.Stop})' "$DEST/settings.json" "$tmpl" > "$merged" 2>/dev/null
  if [ -s "$merged" ] && jq -e . "$merged" >/dev/null 2>&1; then
    if cmp -s "$merged" "$DEST/settings.json"; then echo "  = 동일  settings.json (hooks.Stop 이미 정합)"
    elif [ "$DRY" = 1 ]; then echo "  [dry] settings.json hooks.Stop 을 킷 것으로 교체(라이브에만 있는 Stop 원소는 사라진다 — 백업 .bak-<시각>, 그 밖 설정 보존)"
    else cp "$DEST/settings.json" "$DEST/settings.json.bak-$stamp"; mv "$merged" "$DEST/settings.json"
         echo "  ✓ 갱신  settings.json (hooks.Stop 을 킷 것으로 교체 — 라이브에만 있던 Stop 원소는 사라짐·그 밖 설정 보존, 백업 .bak-$stamp)"; fi
  else echo "  ✗ settings.json 갱신 실패(jq) — 수동 확인 필요(라이브 settings.json 은 그대로)"; fi
  rm -f "$tmpl" "$merged" 2>/dev/null
fi

# 7) jdtls 심(Java LSP, 선택) — ~/.local/bin 에 설치(~/.claude 밖). jdtls 미설치 머신에서도
#    무해(호출 시 안내 후 종료). 실사용 셋업은 SETUP.md 11절(brew jdtls + jdtls-lsp 플러그인).
install_file "$G/bin/jdtls" "$HOME/.local/bin/jdtls"
[ "$DRY" = 0 ] && chmod +x "$HOME/.local/bin/jdtls" 2>/dev/null || true

echo "=== 완료. 검진: ./doctor.sh ==="