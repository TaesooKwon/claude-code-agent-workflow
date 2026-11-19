#!/usr/bin/env bash
# init-machine-env.sh — 새 머신에서 machine.env 를 자동 파악해 채운다.
# 자동 감지: PROJECTS_DIR(레포 모인 곳)·MAVEN_REPO(경로 존재)·STRICT_PROJECT(기본 비움).
# 보존: AGENT_REPOS — 사람이 고르는 목록이라 기존 machine.env 의 줄을 그대로 옮긴다(없으면 빈 값).
#
# 사용:
#   ./init-machine-env.sh                      # 자동감지
#   ./init-machine-env.sh --projects=<경로>     # PROJECTS_DIR 직접 지정
set -u
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$KIT_DIR/machine.env"

PROJECTS_OVERRIDE=""
for a in "$@"; do
  case "$a" in
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

PROJECTS_DIR="$(detect_projects)"
MAVEN_REPO="$(detect_maven)"
STRICT_PROJECT=""

# --- machine.env 쓰기(기존 있으면 백업) ---
# AGENT_REPOS 는 값에 백틱이 있어 작은따옴표 줄 원문을 그대로 옮긴다(재평가하지 않는다).
AR_LINE="$(grep -E '^AGENT_REPOS=' "$OUT" 2>/dev/null | tail -1 || true)"
if [ -f "$OUT" ]; then cp "$OUT" "$OUT.bak" && echo "기존 machine.env → machine.env.bak 백업"; fi
cat > "$OUT" <<EOF
# machine.env — init-machine-env.sh 자동 생성. 필요 시 손수 수정.
PROJECTS_DIR="$PROJECTS_DIR"
STRICT_PROJECT="$STRICT_PROJECT"
MAVEN_REPO="$MAVEN_REPO"
EOF
[ -n "$AR_LINE" ] || AR_LINE="AGENT_REPOS=''"
printf '%s\n' "$AR_LINE" >> "$OUT"

echo "=== machine.env 생성 완료 ==="
printf '  PROJECTS_DIR   = %s%s\n' "$PROJECTS_DIR" "$([ -d "$PROJECTS_DIR" ] && echo '' || echo '  (⚠ 아직 없음 — 맞는지 확인)')"
printf '  MAVEN_REPO     = %s%s\n' "$MAVEN_REPO" "$([ -d "$MAVEN_REPO" ] && echo '  (존재)' || echo '  (없음 — JVM 안 쓰면 무관)')"
printf '  STRICT_PROJECT = %s\n' "${STRICT_PROJECT:-(비움=OR모드)}"
echo "→ 확인 후: ./bootstrap-machine.sh && ./doctor.sh"