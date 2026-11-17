#!/usr/bin/env bash
# init-machine-env.sh — 새 머신에서 machine.env 를 자동 파악해 채운다.
# 자동 감지: PROJECTS_DIR(레포 모인 곳)·MAVEN_REPO(경로 존재)·STRICT_PROJECT(기본 비움).
# 자동 불가: NTFY_TOPIC — 폰 앱 구독과 짝이라 재사용/신규 중 선택.
# 보존: AGENT_REPOS — 사람이 고르는 목록이라 기존 machine.env 의 줄을 그대로 옮긴다(없으면 빈 값).
#
# 사용:
#   ./init-machine-env.sh                      # 자동감지 + ntfy 새 토픽 생성
#   ./init-machine-env.sh --ntfy=<기존토픽>     # ntfy 기존 토픽 재사용(폰 재구독 불필요)
#   ./init-machine-env.sh --no-ntfy            # ntfy 비움(폰 알림 없이 맥 배너만)
#   ./init-machine-env.sh --projects=<경로>     # PROJECTS_DIR 직접 지정
set -u
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$KIT_DIR/machine.env"

NTFY_MODE="new"; NTFY_GIVEN=""; PROJECTS_OVERRIDE=""
for a in "$@"; do
  case "$a" in
    --ntfy=*) NTFY_MODE="reuse"; NTFY_GIVEN="${a#--ntfy=}";;
    --no-ntfy) NTFY_MODE="none";;
    --projects=*) PROJECTS_OVERRIDE="${a#--projects=}";;
    *) echo "알 수 없는 인자: $a" >&2; exit 1;;
  esac
done

# --- PROJECTS_DIR 감지: 흔한 워크스페이스 디렉터리 중 실재하고 git레포를 담은 곳 ---
detect_projects() {
  [ -n "$PROJECTS_OVERRIDE" ] && { printf '%s' "$PROJECTS_OVERRIDE"; return; }
  local best="" bestn=0 d n
  for d in "$HOME/IdeaProjects" "$HOME/projects" "$HOME/Projects" "$HOME/work" "$HOME/workspace" "$HOME/src" "$HOME/dev" "$HOME/repos"; do
    [ -d "$d" ] || continue
    n=$(find "$d" -maxdepth 2 -name .git -maxdepth 2 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -gt "$bestn" ] && { best="$d"; bestn="$n"; }
  done
  printf '%s' "${best:-$HOME/projects}"
}

# --- MAVEN_REPO 감지 ---
detect_maven() {
  local c
  for c in "$HOME/maven_repo/maven/repository" "$HOME/.m2/repository"; do
    [ -d "$c" ] && { printf '%s' "$c"; return; }
  done
  printf '%s' "$HOME/maven_repo/maven/repository"   # 기본(없으면 doctor 경고)
}

# --- NTFY 토픽 결정 ---
gen_topic() {
  local rnd
  if command -v openssl >/dev/null 2>&1; then rnd="$(openssl rand -hex 6)"
  else rnd="$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | cut -c1-12)"; fi
  [ -z "$rnd" ] && rnd="$(date +%s)"
  printf 'claude-%s-%s' "$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')" "$rnd"
}

PROJECTS_DIR="$(detect_projects)"
MAVEN_REPO="$(detect_maven)"
STRICT_PROJECT=""
case "$NTFY_MODE" in
  reuse) NTFY_TOPIC="$NTFY_GIVEN";;
  none)  NTFY_TOPIC="";;
  new)   NTFY_TOPIC="$(gen_topic)";;
esac

# --- machine.env 쓰기(기존 있으면 백업) ---
# AGENT_REPOS 는 값에 백틱이 있어 작은따옴표 줄 원문을 그대로 옮긴다(재평가하지 않는다).
AR_LINE="$(grep -E '^AGENT_REPOS=' "$OUT" 2>/dev/null | tail -1 || true)"
if [ -f "$OUT" ]; then cp "$OUT" "$OUT.bak" && echo "기존 machine.env → machine.env.bak 백업"; fi
cat > "$OUT" <<EOF
# machine.env — init-machine-env.sh 자동 생성. 필요 시 손수 수정.
PROJECTS_DIR="$PROJECTS_DIR"
NTFY_TOPIC="$NTFY_TOPIC"
STRICT_PROJECT="$STRICT_PROJECT"
MAVEN_REPO="$MAVEN_REPO"
EOF
[ -n "$AR_LINE" ] || AR_LINE="AGENT_REPOS=''"
printf '%s\n' "$AR_LINE" >> "$OUT"

echo "=== machine.env 생성 완료 ==="
printf '  PROJECTS_DIR   = %s%s\n' "$PROJECTS_DIR" "$([ -d "$PROJECTS_DIR" ] && echo '' || echo '  (⚠ 아직 없음 — 맞는지 확인)')"
printf '  MAVEN_REPO     = %s%s\n' "$MAVEN_REPO" "$([ -d "$MAVEN_REPO" ] && echo '  (존재)' || echo '  (없음 — JVM 안 쓰면 무관)')"
printf '  STRICT_PROJECT = %s\n' "${STRICT_PROJECT:-(비움=OR모드)}"
case "$NTFY_MODE" in
  new)   printf '  NTFY_TOPIC     = %s  (신규 생성 → 폰 ntfy 앱에서 이 토픽 구독해야 폰 알림 옴)\n' "$NTFY_TOPIC";;
  reuse) printf '  NTFY_TOPIC     = %s  (재사용 — 기존 폰 구독 그대로)\n' "$NTFY_TOPIC";;
  none)  printf '  NTFY_TOPIC     = (비움 — 폰 알림 없이 맥 배너만)\n';;
esac
echo "→ 확인 후: ./bootstrap-machine.sh && ./doctor.sh"