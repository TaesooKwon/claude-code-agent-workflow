#!/usr/bin/env bash
# PreToolUse(Bash) 소프트 리마인더 — 소스 삭제 후 증분 mvn 빌드 시 stale target 경고.
# 삭제한 .java/.xml 이 target/classes 에 잔존 → 런타임 ClassNotFound/매퍼 파싱실패
# (컴파일은 SUCCESS로 통과해 조용히 터짐). 실측 사례: MbrInfoMapper_sql.xml 삭제 후
# 증분 compile → 기동 시 ClassNotFoundException(2026-07-23).
# 발동(AND): ①mvn ②compile|package|test|install|verify 골 ③clean 없음
#            ④git에 삭제된(D) .java/.xml 존재.
# 비차단 리마인더. 자가게이팅(mvn 아니면 미발동)이라 전역 배치. fail-open.
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# 1) mvn 빌드골 + clean 없음
printf '%s' "$cmd" | grep -Eq '(^|[|;&[:space:]/])mvn([[:space:]]|$)' || exit 0
printf '%s' "$cmd" | grep -Eq '(compile|package|test|install|verify)' || exit 0
# clean 판정은 명령 전체가 아니라 'mvn 인자 토큰'으로만 — 리다이렉션 대상(> clean.log)·
# -D/-P 옵션 값(-Pclean)·다른 명령의 'clean' 때문에 리마인더가 통째로 억제되던 결함 수정.
# fd 복제 리다이렉션(2>&1, 1>&2, 2>&-)은 토큰화 전에 제거한다 — 남겨두면 sed 가 `2 > & 1` 로 쪼개고
# awk 의 redir 상태가 끈적하게 남아 뒤따르는 명령경계(&&·|)를 먹어치운다. 그 결과
#   `mvn compile 2>&1 && rm -rf clean` → 뒤 명령의 clean 을 mvn 골로 오인해 **침묵**(원 결함 재발)
#   `echo x > run.log 2>&1 && mvn clean install` → mvn 이 리다이렉션 대상으로 소비돼 **오탐**
# 이 되던 회귀를 막는다(2026-08-05 적대적 재검에서 발견 — 고친 결함이 다른 형태로 되살아난 사례).
has_clean=$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E -e 's/[0-9]*>&[0-9-]+//g' -e 's/([|;&<>])/ \1 /g' | awk '
{
  for (i = 1; i <= NF; i++) {
    t = $i
    gsub(/^["'"'"']+|["'"'"']+$/, "", t)                       # 따옴표 골(mvn "clean" install) 정규화
    if (t == "|" || t == ";" || t == "&") { in_mvn = 0; redir = 0; continue }  # 명령 경계는 redir 보다 우선
    if (redir) { redir = 0; continue }                         # 리다이렉션 대상 파일명 1토큰 소비
    if (t == ">" || t == "<") { redir = 1; continue }
    if (t ~ /^-/) continue                                     # -D/-P 등 옵션(값에 clean 포함 가능)
    if (t ~ /(^|\/)mvn$/) { in_mvn = 1; continue }
    if (in_mvn && t == "clean") { print "yes"; exit }
  }
}')
[ -n "$has_clean" ] && exit 0

# 2) git 에 삭제된(D) .java/.xml 있나
proj="${CLAUDE_PROJECT_DIR:-$cwd}"
git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || exit 0
del=$(git -C "$proj" status --porcelain 2>/dev/null \
      | awk '($0 ~ /^.D/ || $0 ~ /^D /) && /\.(java|xml)$/' | wc -l | tr -d ' ')
[ "${del:-0}" -gt 0 ] || exit 0

reason="[stale target 리마인더] 삭제된 .java/.xml 소스가 있는데 'mvn clean' 없이 빌드하려 합니다. 증분 compile은 삭제된 소스를 target/classes 에서 지우지 않아, 잔존 XML/클래스가 런타임에 ClassNotFound·매퍼 파싱실패를 일으킵니다(컴파일은 SUCCESS로 통과해 조용히 터짐). 삭제가 있었다면 'mvn clean' 을 붙여 재빌드하세요. (리소스 삭제와 무관한 빌드면 무시.)"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
