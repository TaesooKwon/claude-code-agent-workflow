#!/usr/bin/env bash
# 층 A git 훅 설치 — `.git/hooks/{pre-commit,pre-push,pre-merge-commit}` 에 얇은 스텁을 쓴다.
# 스텁은 메인 작업트리의 `.claude/hooks/git/<이름>` 을 exec 한다(worktree 에서도 git-common-dir 기준이라 같은 본문).
#   bash .claude/scripts/install-git-hooks.sh          설치(멱등 — 온전한 우리 스텁이면 실행 비트만 복구, 손상된 우리 스텁은 백업 뒤 다시 씀)
#   bash .claude/scripts/install-git-hooks.sh --check  설치 상태만 점검(rc 0 = 본문 3종 유효·스텁 3종 온전·실행 가능)
# 중단 조건(아무것도 쓰지 않는다): core.hooksPath 설정됨(.git/hooks 를 git 이 안 본다) · 우리 스텁이 아닌 기존 훅·깨진 링크 존재 ·
#   본문(.claude/hooks/git/<이름>) 무효 = 빈 파일·마지막 비공백 줄이 본문 끝 표지가 아님(잘림·CRLF)·bash 문법 오류.
# 우리 스텁(표지 줄 있음)인데 내용이 기대와 다르면(잘림·사용자 수정 등) --check 는 '스텁 손상'으로 실패하고,
#   설치는 원본을 같은 디렉터리 `<이름>.bak-<시각>-<pid>`(git 은 정확한 훅 이름만 실행 — 백업은 실행되지 않음)로 남긴 뒤 다시 쓴다.
set -u
mode=install
case "${1:-}" in
  --check) mode=check ;;
  "") ;;
  *) echo "사용: bash .claude/scripts/install-git-hooks.sh [--check]" >&2; exit 2 ;;
esac

common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "git 저장소가 아닙니다." >&2; exit 1; }
main_top=$(cd "$common/.." && pwd -P) || { echo "메인 작업트리 경로 판정 실패" >&2; exit 1; }
src_dir="$main_top/.claude/hooks/git"
hp=$(git config --get core.hooksPath 2>/dev/null || true)
if [ -n "$hp" ]; then
  echo "core.hooksPath=$hp 가 설정돼 있어 .git/hooks 스텁이 실행되지 않습니다 — 설치를 중단합니다(설정 출처: git config --show-origin --get core.hooksPath)." >&2
  exit 1
fi

MARK='# claude-layer-a-stub v1'
BODY_END='# claude-layer-a-body-end v1'   # 본문 3종의 마지막 줄(잘림 감지)
_stub() { # $1 = 훅 이름 → 기대 스텁 내용(설치가 쓰는 것과 같은 바이트 — 비교·쓰기 공용)
  # 스텁도 CLAUDECODE 를 먼저 본다 — 본문이 지워져도 사용자 터미널·IDE 커밋은 막히지 않게.
  # 본문은 bash 로 실행한다(.claude 는 git 격리라 실행 비트가 보장되지 않는다).
  printf '#!/usr/bin/env bash\n%s\n[ "${CLAUDECODE:-}" = 1 ] || exit 0\nexec bash "$(git rev-parse --path-format=absolute --git-common-dir)/../.claude/hooks/git/%s" "$@"\n' "$MARK" "$1"
}
_body_ok() { # $1 = 본문 경로 → 0 = 비어 있지 않고·마지막 비공백 줄이 BODY_END·bash 문법 오류 없음
  # 표지 뒤 빈 줄(공백·탭뿐인 줄 포함)은 무시한다(편집기 끝 개행). CR 은 공백으로 치지 않는다 → CRLF 본문은 무효(실행도 깨진다).
  # ponytail: 표지는 잘림 검출이지 무결성 검증이 아니다(잘린 본문에 표지만 덧붙이면 통과) / 업그레이드 = 본문 sha 를 킷 기준 목록과 대조.
  [ -s "$1" ] && [ "$(sed -n -e '/[^[:blank:]]/h' -e '${x;p;}' "$1")" = "$BODY_END" ] && bash -n "$1" 2>/dev/null
}
_stub_same() { # $1 = 훅 이름 $2 = 설치된 스텁 → 0 = 기대 스텁과 바이트 동일
  # cmp 가 있으면 바이트 비교(NUL 포함). 없으면(도구를 줄인 PATH) 명령치환 비교로 폴백 — 끝 개행까지 보지만 NUL 은 놓친다.
  # ponytail: cmp 없는 PATH 에선 NUL 이 낀 손상 스텁을 온전으로 본다 / 업그레이드 = od 등 다른 바이트 비교 도구 폴백.
  if command -v cmp >/dev/null 2>&1; then _stub "$1" | cmp -s "$2" -
  else [ "$(cat "$2"; printf x)" = "$(_stub "$1"; printf x)" ]; fi   # x = 끝 개행까지 비교
}
names="pre-commit pre-push pre-merge-commit"
missing=0; noexec=0; damaged=0
# 1차: 전부 검사만 한다(하나라도 남의 훅이면 아무것도 쓰지 않고 중단 — 반쯤 설치된 상태를 만들지 않는다).
# 깨진 심볼릭 링크는 -e 가 거짓이라 "없음"으로 보이므로 -L 로 먼저 가른다(사용자 링크를 덮어쓰지 않는다).
# 우리 스텁이라도 실행 비트가 없으면 git 이 훅을 건너뛴다 → --check 는 미설치로 보고, 설치는 chmod +x 로 고친다.
for n in $names; do
  [ -f "$src_dir/$n" ] || { echo "본문 부재: $src_dir/$n" >&2; exit 1; }
  _body_ok "$src_dir/$n" || { echo "본문 무효(빈 파일·끝 표지 없음 = 잘림·bash 문법 오류): $src_dir/$n — 표지 줄만 덧붙이지 말고 원본(킷 global/agent-scaffold·~/.claude/agent-scaffold)으로 되돌린 뒤 다시 실행하세요." >&2; exit 1; }
  dst="$common/hooks/$n"
  if [ -L "$dst" ] && [ ! -e "$dst" ]; then
    echo "깨진 심볼릭 링크가 있습니다: $dst -> $(readlink "$dst" 2>/dev/null) — 덮어쓰지 않고 중단합니다. 링크를 확인해 정리한 뒤 다시 실행하세요." >&2
    exit 1
  elif [ -e "$dst" ]; then
    if ! grep -qF "$MARK" "$dst" 2>/dev/null; then
      echo "기존 훅이 있습니다(우리 스텁 아님): $dst — 덮어쓰지 않고 중단합니다. 내용을 확인해 옮긴 뒤 다시 실행하세요." >&2
      exit 1
    fi
    [ -x "$dst" ] || noexec=$((noexec + 1))
    _stub_same "$n" "$dst" || damaged=$((damaged + 1))
  else
    missing=$((missing + 1))
  fi
done

if [ "$mode" = check ]; then
  [ "$missing" -eq 0 ] && [ "$noexec" -eq 0 ] && [ "$damaged" -eq 0 ] && { echo "층 A git 훅 설치됨($names)"; exit 0; }
  echo "층 A git 훅 미설치 ${missing}건·실행 비트 없음 ${noexec}건·스텁 손상 ${damaged}건 — bash .claude/scripts/install-git-hooks.sh" >&2
  exit 1
fi

mkdir -p "$common/hooks"
for n in $names; do
  dst="$common/hooks/$n"
  if [ -e "$dst" ] && _stub_same "$n" "$dst"; then   # 1차를 통과했고 내용도 온전한 우리 스텁 — 실행 비트만 복구
    [ -x "$dst" ] || { chmod +x "$dst" && echo "실행 비트 복구: $dst"; } || { echo "chmod 실패: $dst" >&2; exit 1; }
    continue
  fi
  # 여기 = 없음 또는 손상된 우리 스텁(1차가 남의 훅은 걸렀다) → 손상본은 백업한 뒤 새로 써서 원자 교체
  bak=""
  if [ -e "$dst" ]; then
    bak="$dst.bak-$(date +%Y%m%d%H%M%S)-$$"
    cp -p "$dst" "$bak" || { echo "손상 스텁 백업 실패: $dst — 쓰지 않고 중단합니다." >&2; exit 1; }
  fi
  tmp="$dst.tmp.$$"
  _stub "$n" > "$tmp" \
    && chmod +x "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; echo "쓰기 실패: $dst" >&2; exit 1; }
  if [ -n "$bak" ]; then echo "덮어씀(손상된 우리 스텁 — 백업 = $bak): $dst"; else echo "설치: $dst"; fi
done
echo "층 A git 훅 설치 완료"
