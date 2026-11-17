#!/usr/bin/env bash
# hook-policy: 강제=기록 · 도구부재=통과
# PostToolUse(Write|Edit): 폐쇄형 루프의 두 저장소를 개인 백업으로 미러링한다.
#   (a) docs/agent_history.md (레거시 작업로그)
#   (b) 이 프로젝트의 Claude native memory 디렉터리(현 1차 지식 저장소)
# 백업 = 팀 레포와 무관한 개인 git 레포(버전 보존). 오프사이트 push 는
# MIRROR_PUSH=1 옵트인 시에만(백그라운드 — 훅을 막지 않음).
# memory 는 레포 밖(~/.claude/projects/<encoded-cwd>/memory/)에 살지만 Write|Edit
# 매처가 경로 무관하게 발동하므로 file_path 로 식별해 미러링한다.
#
# ⚠️ 백업 제외(보안): 계정·비밀번호 등 자격증명을 담은 memory 파일은 미러에 넣지 않는다.
#    백업 레포는 MIRROR_PUSH=1 이면 오프사이트로 나가므로 "로컬 memory 에는 둬도 되지만
#    백업에는 안 되는" 파일이 생긴다. 아래 기본값에 파일명(basename)을 공백구분으로 등재할 것
#    (환경변수로 덮어쓸 수 있다 — 테스트 주입용). 부트스트랩 시 프로젝트의 테스트계정 memory 등을 추가.
MIRROR_MEMORY_EXCLUDE="${MIRROR_MEMORY_EXCLUDE:-}"   # 예: "test-login.md verify-accounts.md"

fp=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -n "$fp" ] || exit 0

dest="$HOME/.claude/history-backups/{{PROJECT_NAME}}"
mkdir -p "$dest" || exit 0
# 임시·이전본·잠금은 미러 git 워크트리 밖(같은 파일시스템 — mv 가 rename 이 되게) 형제 경로에 둔다.
_side="${dest%/*}/.${dest##*/}"
_lock="$_side.mirror.flock"
_memsrc="$HOME/.claude/projects/{{ENCODED_CWD}}/memory"

# 사용자에게 보이는 알림: stderr + 훅 JSON(systemMessage = 사용자 화면, PostToolUse additionalContext = 모델 문맥).
#   stderr 는 로그용이고 화면에 싣는 정본은 JSON 출력이다. 한 실행에서 한 번만 낸다(_noticed).
_noticed=0
_notice() {
  [ "$_noticed" = "1" ] && return 0
  _noticed=1
  _m="[mirror-history] $1"
  printf '%s\n' "$_m" >&2
  jq -cn --arg m "$_m" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}' 2>/dev/null
}

# 직렬화 잠금 = 잠금 파일에 대한 OS advisory 잠금(flock — 셸 명령이 아니라 python3 fcntl 로 건다).
#   병행 세션의 훅·백그라운드 커밋이 복사·교체·git add 사이에 끼어들면 중첩 복사(memory/memory)·제외 파일 커밋이 생긴다.
# 구조: 이 셸이 잠금 파일을 fd 9 로 열고, python3 자식이 그 fd(같은 열린 파일 설명)에 flock(LOCK_EX) 을 건 뒤 끝난다.
#   flock 은 열린 파일 설명에 붙으므로 잠금은 fd 9 를 가진 이 셸(과 fd 를 물려받은 자손)이 쥔 채로 남고,
#   그 모두가 끝나면(정상·신호·SIGKILL 무관) OS 가 푼다 → 죽은 보유자 판정·회수 경로가 없다.
# 불변식: 잠금 파일은 지우거나 바꿔치지 않는다(지우면 다음 회차가 다른 inode 를 잠가 상호배제가 깨진다).
# 불변식: 대기 시한(_lock_wait 초) + 전경 임계 구역 < 등록 timeout(settings.json 의 이 훅 timeout) — 시한이 그 timeout 에
#   닿으면 훅이 TERM 으로 끊겨 아래 건너뜀 알림이 출력되지 않는다. timeout 을 줄이면 이 값도 함께 줄인다.
_lock_wait=6
_lock_py='
import fcntl, os, stat, sys, time
path, limit = sys.argv[1], float(sys.argv[2])
try:
    st, ls = os.fstat(9), os.lstat(path)
except OSError:
    sys.exit(3)
# 연 것이 그 경로의 일반 파일 자신인지(링크·디렉터리·바꿔치기 아님) 대조한다
if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(ls.st_mode) or (st.st_dev, st.st_ino) != (ls.st_dev, ls.st_ino):
    sys.exit(2)
end = time.monotonic() + limit
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(0)
    except BlockingIOError:
        pass
    except OSError:
        sys.exit(3)
    if time.monotonic() >= end:
        sys.exit(1)
    time.sleep(0.05)
'
# 잠금을 못 얻으면 이번 회차를 건너뛰고 _notice 로 알린다(훅은 막지 않는다 — 다음 쓰기가 다시 동기화한다).
_lock_take() {
  command -v python3 >/dev/null 2>&1 || { _notice "python3 이 없어 잠금을 걸 수 없으므로 이번 백업 동기화를 건너뜁니다."; return 1; }
  if [ -L "$_lock" ] || { [ -e "$_lock" ] && [ ! -f "$_lock" ]; }; then
    _notice "잠금 경로 $_lock 이(가) 일반 파일이 아니라 이번 백업 동기화를 건너뜁니다 — 그 경로를 직접 확인하세요."; return 1
  fi
  exec 9>>"$_lock" || { _notice "잠금 파일 $_lock 을(를) 열 수 없어 이번 백업 동기화를 건너뜁니다."; return 1; }
  python3 -I -c "$_lock_py" "$_lock" "$_lock_wait" 2>/dev/null
  case $? in
    0) return 0 ;;
    1) _notice "다른 회차가 잠금 $_lock 을(를) ${_lock_wait}초 넘게 쥐고 있어 이번 백업 동기화를 건너뜁니다(다음 쓰기가 다시 동기화)." ;;
    2) _notice "잠금 경로 $_lock 이(가) 일반 파일이 아니거나 바뀌어 이번 백업 동기화를 건너뜁니다 — 그 경로를 직접 확인하세요." ;;
    *) _notice "잠금 $_lock 획득 중 오류로 이번 백업 동기화를 건너뜁니다." ;;
  esac
  exec 9>&-
  return 1
}

# 신호(TERM·INT·HUP)로 끊겨도 임시본을 남기지 않는다. 교체 도중이면 이전본을 제자리로 되돌린다.
#   잠금은 프로세스 종료로 OS 가 푼다(별도 해제 없음).
_tmp=; _old=; _t=   # 환경에서 들어온 값이 아래 rm 대상이 되지 않게 비워 둔다
_on_sig() {
  if [ -n "$_old" ] && [ -e "$_old" ] && [ ! -e "$dest/memory" ]; then mv "$_old" "$dest/memory"; fi
  [ -n "$_old" ] && [ -e "$dest/memory" ] && rm -rf "$_old"   # 복귀에 실패한 이전본은 지우지 않는다
  [ -n "$_tmp" ] && rm -rf "$_tmp"
  [ -n "$_t" ] && rm -f "$_t"
  exit "$1"
}
trap '_on_sig 143' TERM; trap '_on_sig 130' INT; trap '_on_sig 129' HUP

# 원자 교체 복사: 임시 경로에 먼저 완성한 뒤 rename. 실패하면 기존 백업을 그대로 둔다.
_put_file() { # src dst
  _t=$(mktemp "$_side.file.XXXXXX") || return 1
  if cp "$1" "$_t" && mv -f "$_t" "$2"; then _t=; return 0; fi
  rm -f "$_t"; _t=; return 1
}

# 상대 경로로 오는 file_path 는 절대경로로 정규화(아래 레포 앵커 비교의 전제).
case "$fp" in /*) ;; *) fp="$PWD/$fp" ;; esac

# 레포 앵커 — 부분 글롭 `*/docs/agent_history.md` 은 추가 작업 디렉터리의 **다른 레포** 이력까지
#   이 레포의 백업 파일로 덮어써(파일명·커밋 메시지가 같아 겉으로 드러나지 않음) 조용한 치환을
#   일으킨다(2026-08-05 감사). memory 축이 이미 인코딩 절대경로로 앵커된 것과 대칭으로 맞춘다.
_proj="${CLAUDE_PROJECT_DIR:-$PWD}"

changed=0
case "$fp" in
  # (a) 작업로그 — 이 프로젝트 것만(중첩 프로젝트 대비 접두 매칭 허용)
  "$_proj"/docs/agent_history.md|"$_proj"/*/docs/agent_history.md)
    _lock_take || exit 0   # 잠금을 못 얻으면 이번 회차는 건너뛴다
    [ -f "$fp" ] && _put_file "$fp" "$dest/agent_history.md" && changed=1
    ;;
  # (b) 이 프로젝트 native memory 의 .md 쓰기 → memory 디렉터리 전체 동기화
  #     인코딩 경로({{ENCODED_CWD}})로 앵커 — 부분문자열 글롭은 이름 충돌·인코딩
  #     불일치 시 무증상 실패라 금지.
  #     복사 원본은 file_path 에서 유도하지 않고 고정 경로(_memsrc)다 — `..` 가 섞인 경로가 다른 디렉터리를
  #     미러로 끌어오지 못하게. file_path 는 발동 트리거로만 쓴다.
  "$_memsrc/"*.md)
    _lock_take || exit 0   # 건너뛴 회차는 다음 memory 쓰기가 전체를 다시 동기화한다
    if [ -d "$_memsrc" ]; then
      _tmp=$(mktemp -d "$_side.memory.tmp.XXXXXX") || { _notice "임시 디렉터리를 만들지 못해 이번 memory 백업을 건너뜁니다."; exit 0; }
      # 내용물(/.)을 빈 임시 디렉터리로 복사 — `cp -R a b` 는 b 가 있으면 b/a 로 중첩된다.
      if cp -R "$_memsrc/." "$_tmp/"; then
        _exfail=0
        for _ex in $MIRROR_MEMORY_EXCLUDE; do   # basename 계약 → 하위 디렉터리의 같은 이름까지 제거
          find "$_tmp" -name "$_ex" -exec rm -rf {} + 2>/dev/null
          [ -z "$(find "$_tmp" -name "$_ex" 2>/dev/null)" ] || _exfail=1
        done
        if [ "$_exfail" != "0" ]; then
          _notice "제외 대상을 임시본에서 지우지 못해 이번 memory 백업을 건너뜁니다(기존 백업 유지)."
        else
          _old="$_side.memory.old.$$"
          rm -rf "$_old"
          if [ ! -e "$dest/memory" ] || mv "$dest/memory" "$_old"; then
            if mv "$_tmp" "$dest/memory"; then changed=1
            else
              [ -e "$_old" ] && mv "$_old" "$dest/memory"   # 교체 실패 → 이전본 복귀
              _notice "memory 백업 교체에 실패해 이전본을 유지했습니다."
            fi
          else
            _notice "기존 memory 백업을 옮기지 못해 이번 memory 백업을 건너뜁니다."
          fi
          rm -rf "$_old"; _old=
        fi
      else
        _notice "memory 원본 복사에 실패해 이번 memory 백업을 건너뜁니다(기존 백업 유지)."
      fi
      rm -rf "$_tmp"; _tmp=   # 실패 경로의 임시본 정리(성공 시엔 이미 rename 되어 없다) — 기존 백업은 손대지 않는다
    fi
    ;;
  *) exit 0 ;;
esac

[ "$changed" = "1" ] || exit 0

# 커밋 + (MIRROR_PUSH=1 옵트인 시) push 는 백그라운드로 — 네트워크/잠금이 훅을 막지 않게.
# 잠금은 백그라운드 커밋이 끝날 때까지 이어 잡고(커밋 도중 다음 회차의 교체가 끼지 않게) push 전에 놓는다
#   — push 단계가 워크트리에 쓰는 것은 .mirror-push-blocked 표지(쓰기·지우기)뿐이고, 네트워크 지연이 다음 회차의 대기 시한을 잡아먹지 않게.
# 서브셸은 fd 9(잠금이 붙은 열린 파일 설명)를 물려받는다 → 전경이 먼저 끝나도 잠금은 서브셸이 끝까지 쥔다.
#   서브셸이 어떻게 끝나든(신호 포함) OS 가 풀므로 trap 이 필요 없다.
# gc.autoDetach=false: 자동 gc 가 fd 9 를 물려받은 채 분리되어 커밋 뒤까지 잠금을 쥐지 않게 커밋 안에서 끝낸다.
# ponytail: 백그라운드 커밋 실패는 훅 출력이 이미 끝나 화면에 못 싣는다(다음 회차의 add -A 가 함께 커밋한다) / 업그레이드 경로 = 실패 표지 파일을 남기고 다음 회차 전경에서 _notice
if [ -d "$dest/.git" ]; then
  (
    git -C "$dest" add -A
    git -C "$dest" -c gc.autoDetach=false commit -q -m "mirror $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null
    exec 9>&-
    if [ "$MIRROR_PUSH" = "1" ] && git -C "$dest" remote get-url origin >/dev/null 2>&1; then
      # 제외 대상은 워킹트리에서만 지워지고(cp 후 rm) **커밋 이력에는 blob 이 남는다**.
      # push 는 이력 전체를 보내므로, 오프사이트를 켜는 순간 과거 자격증명이 그대로 나간다
      # ("제외했으니 안전"이라는 계약이 미성립 — 2026-08-05 감사). 이력이 오염돼 있으면 push 를 막는다.
      _pat=$(printf '%s' "$MIRROR_MEMORY_EXCLUDE" | tr ' ' '|')
      if [ -n "$_pat" ]; then
        _leak=$(git -C "$dest" log --all --pretty=format: --name-only 2>/dev/null \
                | sort -u | grep -Ex "(.*/)?(${_pat})" | head -3)
      else
        _leak=""
      fi
      if [ -n "$_leak" ]; then
        printf '[mirror-history] push 중단 — 제외 대상이 백업 이력에 남아 있습니다:\n%s\n조치: 미러 레포 이력을 정리(orphan 재시작 또는 filter-repo)한 뒤 MIRROR_PUSH 를 켜세요.\n' \
          "$_leak" > "$dest/.mirror-push-blocked" 2>/dev/null
      else
        rm -f "$dest/.mirror-push-blocked" 2>/dev/null
        git -C "$dest" push -q origin HEAD 2>/dev/null
      fi
    fi
  ) >/dev/null 2>&1 &
fi
exit 0
