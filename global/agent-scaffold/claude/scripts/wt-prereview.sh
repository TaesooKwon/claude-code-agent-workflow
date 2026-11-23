#!/usr/bin/env bash
# 병행 세션과 인덱스를 공유할 때, 커밋 전 리뷰를 메인 인덱스에 손대지 않고 worktree 에서 먼저 돌리기 위한 도구.
#
#   bash .claude/scripts/wt-prereview.sh [--include-staged] [--with-scaffold] <worktree경로> [<내 변경 경로>...]
#
#  · <worktree경로> 는 레포 밖(스크래치패드)에 둔다 — 레포 안(.claude/worktrees 등)에 두면 MyBatis 계약검사가
#    같은 XML 을 두 번 읽어 Duplicate namespace 오탐을 낸다(2026-09-02 실측).
#  · 경로는 파일이든 디렉터리든 된다(신규·수정·삭제 모두). 넘긴 경로 아래에서 **실제로 달라진 파일만** 반영한다
#    (기본 = 인덱스 대비 워킹트리 차분 + 미추적 신규 / --include-staged = HEAD 대비 워킹트리 차분 + 스테이징 경로 + 미추적 신규).
#    경로는 리터럴로 읽는다(와일드카드·pathspec magic 미해석).
#    다른 세션 파일은 넘기지 마라 — 넘긴 것만 반영된다.
#  · 기본 모드에서 인덱스에만 있는 변경(남이 스테이징 — 수정·삭제 모두)은 반영하지 않고 "남의 스테이징(건너뜀)" 줄로 찍는다.
#  · 공유 파일(타 세션도 고친 파일)은 **인덱스 대비 워킹트리 차분**만 패치로 적용한다(기본):
#      - 타 세션이 그 파일을 스테이징해 둔 상태면 인덱스 = 그쪽 버전이라 **내 hunk 만** 남는다(정상).
#      - 스테이징돼 있지 않으면 HEAD 대비라 그쪽 hunk 도 섞인다 — 출력의 "공유 파일" 줄이 뜨지 않으면
#        그 파일은 통째로 복사된 것이니 `git diff --cached -- <파일>` 로 남의 hunk 가 섞였는지 확인하라.
#  · --include-staged : 인덱스에 올라간 변경이 **내 것**일 때. 넘긴 경로는 스테이징 여부와 무관하게 워킹트리
#        실물을 통째로 복사하고, 경로를 하나도 안 넘기면 `git diff --cached --name-only` 전부를 대상으로 삼는다.
#        (기본 동작은 "스테이징된 것 = 남의 것" 이라 내 스테이징 hunk 가 리뷰에서 빠진다 — 2026-09-03 개정.)
#  · --with-scaffold  : git 격리분(CLAUDE.md·.claude/·docs/harness.md·docs/agent_history.md·application-local.properties)을
#        worktree 에 복사한다 — worktree 에서 harness·리뷰 워크플로·로컬 프로파일 기동이 그대로 돌게.
#  · 리뷰: Workflow({scriptPath:"<레포>/.claude/workflows/commit-review.js", args:{repo:"<worktree>", stagedFiles, intent, facts}})
#    (stagedFiles = 끝에 찍히는 "리뷰:" 줄의 JSON 배열 = worktree 의 `git diff --cached --name-only`)
#  · worktree 쪽 상위 경로가 심볼릭 링크이거나 대상 자리가 디렉터리인 파일은 쓰지도 지우지도 않고 경고한 뒤 exit 3 으로 끝난다.
#  · 수리를 worktree 에서 했으면 회수: bash .claude/scripts/wt-collect.sh <worktree> (지문 대조·충돌 보호 포함)
#  · 상대 커밋이 HEAD 에 들어온 뒤: 메인에서 같은 경로를 `git add` → `git diff --cached | grep -v '^@@'` 를
#    worktree 의 것과 대조(hunk 헤더는 줄번호가 밀려 다르다) → mark-review.sh → 커밋(별도 호출).
#  · 정리: git worktree remove --force <worktree경로>
set -euo pipefail

usage() {
  cat <<'USAGE'
사용: bash .claude/scripts/wt-prereview.sh [--include-staged] [--with-scaffold] <worktree경로> [<내 변경 경로>...]

병행 세션과 git 인덱스를 공유할 때, 커밋 전 리뷰를 메인 인덱스에 손대지 않고 worktree 에서 먼저 돌린다.

절차(순서 고정 — 2026-09-17 규약에서 이관):
  1) 선실행 : 이 스크립트로 worktree 를 만든다. <worktree경로> 는 **레포 밖(스크래치패드)** 에 둔다
              (레포 안이면 MyBatis 계약검사가 같은 XML 을 두 번 읽어 Duplicate namespace 오탐 — 2026-09-02 실측).
  2) 리뷰   : Workflow({scriptPath:"<레포>/.claude/workflows/commit-review.js",
                        args:{ repo:"<worktree>", stagedFiles, intent, facts }})
              stagedFiles = 1) 끝에 찍히는 "리뷰:" 줄의 JSON 배열(worktree 의 git diff --cached --name-only)
  3) 회수   : worktree 에서 수리했으면  bash .claude/scripts/wt-collect.sh <worktree>  (지문 대조·충돌 보호)
  4) 재스테이징 : 상대 커밋이 HEAD 에 들어온 뒤 메인에서 같은 경로만 `git add <경로…>`
              (일괄 스테이징 `git add -A/-u/.`·`commit -a` 는 훅 git-add-all-guard.sh 가 차단한다)
  5) 대조   : `git diff --cached | grep -v '^@@'` 를 worktree 의 것과 비교(hunk 헤더는 줄번호가 밀려 다르다)
  6) 마커   : bash .claude/hooks/mark-review.sh --result <리뷰 결과 JSON>   (2)의 워크플로 결과 · 또는 --skip-reason "<사유>")
              빌트인 Skill(code-review)(대체 엔진)로 리뷰했으면 리뷰 직전 --begin, 리뷰 뒤 --builtin <결과 JSON 파일>(레포 밖 파일)
              ← 커밋과 **별도 Bash 호출**(한 호출이면 구 지문으로 차단). 인자 없는 호출은 찍히지 않는다.
  7) 커밋   : 현재 브랜치에 커밋(푸시는 사용자 전담)
  8) 정리   : git worktree remove --force <worktree경로>

옵션:
  --include-staged  인덱스에 올라간 변경이 **내 것**일 때. 넘긴 경로를 스테이징 여부와 무관하게 워킹트리 실물로
                    통째 복사하고, 경로를 하나도 안 넘기면 `git diff --cached --name-only` 전부를 대상으로 삼는다.
  --with-scaffold   git 격리분(CLAUDE.md·.claude/·docs/harness.md·docs/agent_history.md·application-local.properties)을
                    worktree 에 복사 — worktree 에서 harness·리뷰 워크플로·로컬 프로파일 기동이 그대로 돌게.
  -h, --help        이 도움말.

경위·함정 = memory [[parallel-session-worktree-prereview]] · [[worktree-parallel-limits]]
USAGE
}

INCLUDE_STAGED=0; WITH_SCAFFOLD=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --include-staged) INCLUDE_STAGED=1; shift ;;
    --with-scaffold) WITH_SCAFFOLD=1; shift ;;
    --) shift; break ;;
    -*) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
if [ $# -lt 1 ]; then
  echo "사용: $0 [--include-staged] [--with-scaffold] <worktree경로> [<경로>...]" >&2
  exit 2
fi
WT="$1"; shift
REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"

PATHS=("$@")
if [ ${#PATHS[@]} -eq 0 ]; then
  if [ "$INCLUDE_STAGED" = 1 ]; then
    # --no-renames: rename 이면 옛 경로(삭제)도 대상에 넣는다(--name-only 기본은 새 경로만 낸다).
    while IFS= read -r -d '' p; do [ -n "$p" ] && PATHS+=("$p"); done < <(git diff --cached --name-only --no-renames -z)
    [ ${#PATHS[@]} -gt 0 ] || { echo "스테이징된 변경이 없다(--include-staged 인데 대상 0건)" >&2; exit 1; }
  else
    echo "복사할 경로를 넘기거나 --include-staged 를 쓰라" >&2; exit 2
  fi
fi

# 인자는 리터럴 경로로만 읽는다 — 와일드카드·`:(glob)` 같은 pathspec magic 은 해석하지 않는다(허용 목록 = 실제 경로).
export GIT_LITERAL_PATHSPECS=1
# 레포 밖으로 나가는 경로(../ 등)는 git 이 거부한다 — worktree 를 만들기 전에 멈춘다.
# 레포 안을 가리키는 절대경로는 받되, 아래 펼침에서 git 이 낸 레포 상대경로만 쓴다.
if ! git ls-files -- "${PATHS[@]}" >/dev/null; then
  echo "레포 밖이거나 잘못된 경로가 있다(위 git 메시지 참고)" >&2; exit 2
fi

# 처리 대상 = 넘긴 경로 아래에서 실제로 달라진 파일(허용 목록). 펼친 전체 파일에서 "없으면 삭제"를 추론하지 않는다.
# 목록은 인자 전체를 한 번에 넘긴 git 호출로 구한다 — worktree 생성 전.
# git 실패(fatal)는 set -e 로 여기서 멈춘다 — 프로세스 치환 안에서 삼켜지지 않게 파일로 받는다.
# 무시(ignored) 파일은 옮기지 않는다(worktree 스테이징에도 안 오른다).
LIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wt-prereview.XXXXXX")"
trap 'rm -rf "$LIST_DIR"' EXIT
# 인자마다 git 이 아는 경로(HEAD·인덱스·미추적 비무시)인지 — 오타·magic 문자열은 여기서 걸러진다.
KNOWN=0
for p in "${PATHS[@]}"; do
  git ls-tree -r -z --name-only HEAD -- "$p" > "$LIST_DIR/one"
  git ls-files -z -c -o --exclude-standard -- "$p" >> "$LIST_DIR/one"
  if [ -s "$LIST_DIR/one" ]; then KNOWN=1; else echo "경로 없음(건너뜀): $p" >&2; fi
done
[ "$KNOWN" = 1 ] || { echo "넘긴 경로에서 반영할 파일이 없다" >&2; exit 1; }

# --no-renames: rename 은 옛 경로(삭제)와 새 경로(추가)로 나뉘어 둘 다 대상이 된다.
git ls-files -z -o --exclude-standard -- "${PATHS[@]}" > "$LIST_DIR/untracked"
git diff --cached --name-only --no-renames -z -- "${PATHS[@]}" > "$LIST_DIR/staged"
if [ "$INCLUDE_STAGED" = 1 ]; then
  # 스테이징도 내 것 → HEAD 대비 워킹트리 차분 + 스테이징 경로(워킹트리 실물로 맞춘다)
  git diff HEAD --name-only --no-renames -z -- "${PATHS[@]}" > "$LIST_DIR/changed"
  cat "$LIST_DIR/staged" >> "$LIST_DIR/changed"
else
  # 스테이징 = 남의 것 → 인덱스 대비 워킹트리 차분만 내 것
  git diff --name-only --no-renames -z -- "${PATHS[@]}" > "$LIST_DIR/changed"
fi
cat "$LIST_DIR/untracked" >> "$LIST_DIR/changed"
TARGETS=(); STAGED=(); UNTRACKED=()
while IFS= read -r -d '' f; do TARGETS+=("$f"); done < <(LC_ALL=C sort -zu "$LIST_DIR/changed")
while IFS= read -r -d '' f; do STAGED+=("$f"); done < "$LIST_DIR/staged"
while IFS= read -r -d '' f; do UNTRACKED+=("$f"); done < "$LIST_DIR/untracked"

# $1 이 나머지 인자 중에 있으면 참(0). 목록은 모두 "달라진 파일"이라 선형 탐색으로 충분하다.
in_list() {
  local x="$1" s; shift
  for s in "$@"; do [ "$s" = "$x" ] && return 0; done
  return 1
}
if [ "$INCLUDE_STAGED" = 0 ]; then
  for s in ${STAGED[@]+"${STAGED[@]}"}; do
    in_list "$s" ${TARGETS[@]+"${TARGETS[@]}"} || echo "남의 스테이징(건너뜀 — 인덱스에만 있는 변경): $s"
  done
fi
[ ${#TARGETS[@]} -gt 0 ] || echo "⚠️ 넘긴 경로에 반영할 내 변경이 없다 — worktree 는 HEAD 그대로다." >&2

# worktree 안 경로 "$WT/$1" 의 상위 성분 중 심볼릭 링크가 있으면 참(0). 그 링크를 따라가면 worktree 밖을 쓰거나 지운다.
wt_parent_is_link() {
  local d
  d="$(dirname "$1")"
  while [ "$d" != "." ] && [ "$d" != "/" ]; do
    [ -L "$WT/$d" ] && return 0
    d="$(dirname "$d")"
  done
  return 1
}

if [ -e "$WT" ]; then
  echo "이미 존재한다: $WT (먼저 git worktree remove --force '$WT')" >&2
  exit 1
fi
git worktree add --detach "$WT" HEAD >/dev/null

SKIPPED=0
for f in ${TARGETS[@]+"${TARGETS[@]}"}; do
  # worktree 쪽 대상 자리가 실제 디렉터리면 cp 가 그 안에 중첩 복사하고 rm 이 실패한다 — 링크 상위와 같은 안전 쪽 처리.
  if wt_parent_is_link "$f" || { [ -d "$WT/$f" ] && [ ! -L "$WT/$f" ]; }; then
    # 판정 불가 = 안전 쪽: 쓰지도 지우지도 않는다. 이 파일은 메인 스테이징과 worktree 가 어긋나므로 끝에서 실패로 알린다.
    echo "⚠️ 건너뜀(worktree 쪽 상위 경로가 심볼릭 링크이거나 대상 자리가 디렉터리 — worktree 밖·엉뚱한 자리를 건드린다): $f" >&2
    SKIPPED=$((SKIPPED+1)); continue
  fi
  # 기본 모드에서 인덱스에도 변경이 올라간 추적 파일 = 타 세션 것과 겹친 공유 파일 → 인덱스 대비 내 hunk 만 패치.
  # (내가 워킹트리에서 지운 공유 파일은 아래 삭제로 간다 — 메인에서 git add 하면 삭제가 스테이징된다.)
  # 패치 파일은 worktree 밖(mktemp 디렉터리)에 쓴다 — worktree 안 같은 이름 링크를 따라 밖을 덮지 않게.
  if [ "$INCLUDE_STAGED" = 0 ] && { [ -f "$f" ] || [ -L "$f" ]; } \
     && in_list "$f" ${STAGED[@]+"${STAGED[@]}"} && ! in_list "$f" ${UNTRACKED[@]+"${UNTRACKED[@]}"}; then
    git diff -- "$f" > "$LIST_DIR/patch"
    if [ -s "$LIST_DIR/patch" ]; then
      git -C "$WT" apply "$LIST_DIR/patch"
      echo "공유 파일(내 hunk 만 적용): $f"
    else
      echo "공유 파일이나 내 차분 없음(건너뜀): $f"
    fi
  elif [ -f "$f" ] || [ -L "$f" ]; then
    # 대상이 링크면 cp 가 링크를 따라 밖에 쓴다 — 링크 자체를 먼저 지운다(rm 은 링크만 지우고 대상은 남긴다).
    if [ -L "$WT/$f" ]; then rm -f "$WT/$f"; fi
    mkdir -p "$WT/$(dirname "$f")"; cp -R "$f" "$WT/$f"
  else
    # 메인 워킹트리에 파일로 없다(삭제됐거나 디렉터리로 바뀜) → worktree 에서도 지운다(링크면 링크만).
    rm -f "$WT/$f"
  fi
  # ponytail: 파일↔디렉터리 전환 중 worktree 자리가 디렉터리인 쪽은 건너뜀(exit 3)으로만 처리 / 필요해지면 삭제 먼저·복사 나중 2패스 + 빈 디렉터리 정리로
done

if [ "$WITH_SCAFFOLD" = 1 ]; then
  n=0
  for s in CLAUDE.md docs/harness.md docs/agent_history.md; do
    [ -e "$s" ] || continue
    mkdir -p "$WT/$(dirname "$s")"; cp "$s" "$WT/$s"; n=$((n+1))
  done
  if [ -d .claude ]; then
    mkdir -p "$WT/.claude"
    # worktrees/·로그·마커 파일은 제외(마커는 레포 공유라 worktree 에서 찍으면 안 된다)
    # xargs -I 는 BSD(macOS)에서 치환 결과를 255바이트로 자르고 실패해 set -e 가 스크립트를 여기서 끊는다
    # (2026-09-14 실측 — 뒤의 worktree 스테이징이 안 돌아 리뷰가 빈 diff 를 봤다). 그래서 루프로 복사한다.
    (cd .claude && find . -type f ! -path './worktrees/*' ! -name '*.log' ! -name '.review-marker*' -print0 \
      | while IFS= read -r -d '' p; do mkdir -p "$WT/.claude/$(dirname "$p")" && cp "$p" "$WT/.claude/$p"; done)
    n=$((n+1))
  fi
  while IFS= read -r lp; do
    [ -n "$lp" ] || continue
    mkdir -p "$WT/$(dirname "$lp")"; cp "$lp" "$WT/$lp"; n=$((n+1))
  done < <(find . -path ./target -prune -o -path '*/target' -prune -o -name 'application-local.properties' -print 2>/dev/null | sed 's#^\./##')
  echo "스캐폴드 복사: ${n}건(CLAUDE.md·.claude/·docs 지정 파일·application-local.properties). git 격리분이라 worktree 스테이징엔 안 올라간다."
fi

(cd "$WT" && git add -A && echo "--- worktree 스테이징:" && git diff --cached --stat | tail -1)
# 회수 시 충돌 판정용 기준 지문 — "worktree 가 시작한 내용"(복사 직후 인덱스)의 blob sha 를 worktree gitdir 에 남긴다.
# (wt-collect.sh 가 메인 파일이 이 기준과 같으면 내 것, 다르면 다른 세션의 변경으로 본다.)
git -C "$WT" ls-files -s | awk '{print $2" "$4}' > "$(git -C "$WT" rev-parse --absolute-git-dir)/prereview-base"
# 리뷰 args 의 stagedFiles = worktree 의 `git diff --cached --name-only` — JSON 배열로 찍어 그대로 붙여 넣게 한다.
STAGED_JSON="$(git -C "$WT" diff --cached --name-only -z | python3 -c 'import json,sys; print(json.dumps([p for p in sys.stdin.buffer.read().decode("utf-8","surrogateescape").split("\0") if p], ensure_ascii=False))')" \
  || STAGED_JSON='"(목록 생성 실패 — worktree 에서 git diff --cached --name-only 로 직접 채워라)"'
echo "리뷰: Workflow({scriptPath:\"$REPO/.claude/workflows/commit-review.js\", args:{repo:\"$WT\", stagedFiles:$STAGED_JSON, intent:..., facts:[...]}})"
if [ "$SKIPPED" -gt 0 ]; then
  echo "🔴 ${SKIPPED}개 경로를 건너뛰었다(위 ⚠️ 줄) — 이 worktree 는 메인 스테이징과 다르다. 그 경로를 직접 확인하기 전엔 리뷰 결과로 쓰지 마라." >&2
  exit 3
fi
echo "회수: bash $REPO/.claude/scripts/wt-collect.sh '$WT'"
echo "정리: git worktree remove --force '$WT'"
