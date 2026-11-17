#!/usr/bin/env bash
# worktree 에서 리뷰·수리한 변경분을 메인 워킹트리로 회수한다(wt-prereview.sh 의 짝, 2026-09-03).
#
#   bash .claude/scripts/wt-collect.sh [--dry-run] [--force] <worktree경로> [--exclude <경로>...]
#
#  · 대상 = worktree 의 HEAD 대비 변경(스테이징·미스테이징·신규 전부, `git status --porcelain`).
#    삭제(D)와 rename(R) 의 옛 경로는 복사하지 않고 보고만 한다(메인에서 직접 지운다 — 되돌리기 어려운 조작은 사람 손으로).
#  · worktree 경로는 상대경로여도 되고(호출 위치 기준), 메인 워킹트리 자신을 넘기면 거부한다.
#  · 기본 제외 = git 격리 스캐폴드(CLAUDE.md·.claude/·docs/harness.md·docs/agent_history.md·application-local.properties)
#    + --exclude 로 넘긴 경로(접두 일치). 격리분은 worktree 에 복사본만 있으니 회수 대상이 아니다.
#  · 충돌 보호 = 메인의 같은 파일이 **worktree 가 시작한 내용**(wt-prereview 가 gitdir 에 남긴 prereview-base 지문,
#    없으면 worktree HEAD 의 blob)과 다르고 worktree 실물과도 다르면 **다른 세션이 그 사이 손댄 것**이라 덮어쓰지
#    않고 건너뛴다(--force 면 덮어쓴다). 메인 인덱스는 건드리지 않는다.
#  · 회수 후 파일마다 `cmp` 로 지문(동일/상이)을 보고한다 — 상이가 남으면 회수가 안 된 것이다.
set -euo pipefail

DRY=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --) shift; break ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { echo "사용: $0 [--dry-run] [--force] <worktree경로> [--exclude <경로>...]" >&2; exit 2; }
WT="$1"; shift
[ -d "$WT/.git" ] || [ -f "$WT/.git" ] || { echo "worktree 가 아니다: $WT" >&2; exit 1; }
# 아래에서 레포 루트로 cd 하므로 호출 위치 기준 상대경로는 여기서 절대경로로 고정한다
WT="$(cd "$WT" && pwd -P)"

EXCLUDES=(CLAUDE.md .claude/ docs/harness.md docs/agent_history.md)
if [ $# -gt 0 ]; then
  [ "$1" = "--exclude" ] || { echo "경로 인자는 --exclude 뒤에만" >&2; exit 2; }
  shift; EXCLUDES+=("$@")
fi

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
# 메인 자신을 넘기면 파일마다 자기 자신에게 cp 하게 된다(macOS cp 는 비0 종료 → set -e 로 회수가 중간에 끊긴다)
[ "$(pwd -P)" != "$WT" ] || { echo "worktree 경로가 메인 워킹트리 자신이다: $WT" >&2; exit 2; }
BASE=$(git -C "$WT" rev-parse HEAD)
BASEF="$(git -C "$WT" rev-parse --absolute-git-dir)/prereview-base"

base_sha() { # $1=경로 → worktree 가 시작한 내용의 blob sha(기록 없으면 HEAD blob, 그것도 없으면 빈 값)
  local p="$1" sha=""
  [ -f "$BASEF" ] && sha=$(awk -v p="$p" '$2==p{print $1; exit}' "$BASEF")
  [ -n "$sha" ] || sha=$(git rev-parse --verify -q "$BASE:$p" 2>/dev/null || true)
  printf '%s' "$sha"
}

excluded() { # $1=경로 → 제외면 0
  local p="$1" e
  case "$p" in */application-local.properties|application-local.properties) return 0 ;; esac
  for e in "${EXCLUDES[@]}"; do
    case "$p" in "$e"|"$e"*) return 0 ;; esac
  done
  return 1
}

copied=0; skipped=0; conflict=0; deleted=0; same=0; diff=0
while IFS= read -r -d '' line; do
  st="${line:0:2}"; p="${line:3}"
  # -z 형식의 rename(R)·copy(C) 는 "XY 새경로" 레코드 뒤에 옛 경로가 별도 레코드로 온다 — 그 레코드를 함께 읽어 소비한다.
  # rename 의 옛 경로는 메인에서 지워야 하므로 삭제 보고로 돌린다(copy 는 옛 경로가 남는다).
  if [ "${st:0:1}" = "R" ] || [ "${st:0:1}" = "C" ]; then
    IFS= read -r -d '' old || old=""
    if [ "${st:0:1}" = "R" ] && [ -n "$old" ] && ! excluded "$old"; then
      echo "삭제(수동 처리, rename 옛 경로): $old"; deleted=$((deleted+1))
    fi
  fi
  if excluded "$p"; then skipped=$((skipped+1)); continue; fi
  if [ "${st:0:1}" = "D" ] || [ "${st:1:1}" = "D" ]; then
    echo "삭제(수동 처리): $p"; deleted=$((deleted+1)); continue
  fi
  [ -f "$WT/$p" ] || continue
  # 충돌 보호: 메인 파일이 worktree 시작 내용(prereview-base, 없으면 HEAD blob)과 다르고 worktree 실물과도 다르면 다른 세션의 변경 → 건너뜀
  if [ "$FORCE" = 0 ] && [ -e "$p" ] && ! cmp -s "$p" "$WT/$p"; then
    if [ "$(git hash-object "$p")" != "$(base_sha "$p")" ]; then
      echo "충돌(건너뜀 — 메인에 worktree 시작 내용과 다른 내용, --force 로 덮어씀): $p"; conflict=$((conflict+1)); continue
    fi
  fi
  if [ "$DRY" = 1 ]; then echo "[dry] 복사: $p"; copied=$((copied+1)); continue; fi
  # 같은 파일(동일 inode — 심볼릭 링크로 이어진 경로 등)이면 cp 가 비0 종료하므로 복사 없이 동일로 센다
  if [ "$p" -ef "$WT/$p" ]; then copied=$((copied+1)); same=$((same+1)); echo "동일(같은 파일): $p"; continue; fi
  mkdir -p "$(dirname "$p")"; cp "$WT/$p" "$p"; copied=$((copied+1))
  if cmp -s "$p" "$WT/$p"; then same=$((same+1)); echo "동일: $p"; else diff=$((diff+1)); echo "상이(!): $p"; fi
done < <(git -C "$WT" status --porcelain -z --untracked-files=all)

echo "--- 회수 ${copied}건(지문 동일 ${same}·상이 ${diff}) / 제외 ${skipped} / 충돌 건너뜀 ${conflict} / 삭제 보고 ${deleted}"
[ "$diff" = 0 ] && [ "$conflict" = 0 ] || exit 1
