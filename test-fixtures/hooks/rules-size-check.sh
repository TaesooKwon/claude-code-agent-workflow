#!/usr/bin/env bash
# Stop hook: 상시 로드 컨텍스트(전역/프로젝트 CLAUDE.md · MEMORY.md) 크기 상한 감시.
#
# 왜 필요한가: 이 세 파일은 **매 세션 무조건 로드**되는 고정비다(실측 2026-08-10: 전역 25.3KB +
# 프로젝트 47.3KB + MEMORY.md 19.5KB = 92KB ≈ 35~45k 토큰, 200k 컨텍스트의 20%). memory 본문·스킬은
# 회상/호출식이라 무관하고, 문제는 "상시" 층만 계속 자란다는 것이다. 규약에 "간결히"라는 취지가
# 이미 있었는데도 47KB 가 됐고 MEMORY.md 인덱스는 "한 줄 훅까지만" 규약을 124줄 중 119줄 위반했다
# ⇒ 선언으로는 안 지켜져 게이트로 승격(승격 사다리: 경험→교훈→절차→강제).
#
# history-rotate-check.sh 와 같은 규약: jq · stop_hook_active loop-guard · 관측 로그.
# 단 **스코프는 다르다** — 저쪽은 프로젝트 디렉터리 한정, 이쪽은 git 루트를 가진 모든 레포(아래 사유).
#
# ⚠️ history-rotate 와 다른 점 2가지:
#   ① **자동 백업을 만들지 않는다.** 규약 파일은 git 격리·수동 관리 대상이라 날짜별 사본이 쌓이면
#      그 자체가 잡음이다. 축소 작업 시 에이전트가 그 자리에서 백업하도록 안내만 한다.
#   ② **하루 1회만 알린다.** 규약 축소는 사용자 승인이 필요한 작업이라 매 세션 block 하면 잡음이 된다.
#      (code-review 마커의 "당일 1회 넛지는 구멍" 교훈은 **보안성 게이트**에 대한 것이고, 이건
#       위생 알림이라 성격이 다르다 — 통과시켜도 잃는 것이 없다.)

input=$(cat)

LOG="$HOME/.claude/hooks/rules-size.log"
log() { printf '%s [rules-size] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null; }
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 1200 ]; then
  tail -n 800 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

command -v jq >/dev/null 2>&1 || { log "SKIP no-jq"; exit 0; }

stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

[ "$stop_active" = "true" ] && { log "SKIP loop-guard"; exit 0; }

# ── 레포 루트 해석 ──
# ⚠️ 다른 훅들(convention-gate·history-rotate·closed-loop-history)과 달리 **프로젝트 디렉터리로
# 스코프하지 않는다.** 그것들은 스택 고유(Maven 빌드·이력 파일)라 관할을 좁히는 게 맞지만, 이 훅의
# 검사 대상(CLAUDE.md·MEMORY.md)은 **스택도 위치도 무관**하다 — 어디에 만든 레포든 규약은 자란다.
# 경로를 하드코딩하면 그 디렉터리 밖 신규 레포가 통째로 사각이 된다(2026-08-10 실측 구멍).
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
[ -n "$root" ] || root="$cwd"

case "$root" in
  ""|"/"|"$HOME") log "SKIP non-project ($cwd)"; exit 0 ;;
esac
# 프로젝트로 인정하는 조건 = 규약 파일이 있거나 git 레포다(홈·임의 디렉터리 잡음 차단).
[ -f "$root/CLAUDE.md" ] || [ -d "$root/.git" ] || { log "SKIP no-project-marker ($root)"; exit 0; }

proj=$(basename "$root")

# ── 상한(byte). 넘겨도 "즉시 잘라라"가 아니라 "사용자에게 보고하고 승인받아 줄여라"다. ──
LIMIT_GLOBAL=25600     # 25KB — 스택 무관 방법론 단일정본. 서사가 규칙 준수를 떠받치므로 과감히 줄이면 손해다.
LIMIT_PROJECT=30720    # 30KB — 규칙 문장 + 그 레포 판정축까지. 경위·실측은 memory 몫.
LIMIT_INDEX=12288      # 12KB — MEMORY.md 는 "그 파일을 열지 판단할 한 줄 훅"만. 본문 요약 인라인 금지.

gmd="$HOME/.claude/CLAUDE.md"
pmd="$root/CLAUDE.md"
# 프로젝트 memory 인덱스 경로: ~/.claude/projects/<slug>/memory/MEMORY.md (slug = 경로의 / → -)
slug=$(printf '%s' "$root" | sed 's|/|-|g')
imd="$HOME/.claude/projects/$slug/memory/MEMORY.md"

sz() { [ -f "$1" ] && wc -c <"$1" 2>/dev/null || echo 0; }
g=$(sz "$gmd"); p=$(sz "$pmd"); i=$(sz "$imd")

over=""
[ "$g" -gt "$LIMIT_GLOBAL" ]  && over="${over}전역 ~/.claude/CLAUDE.md $((g/1024))KB(상한 $((LIMIT_GLOBAL/1024))KB) · "
[ "$p" -gt "$LIMIT_PROJECT" ] && over="${over}프로젝트 CLAUDE.md $((p/1024))KB(상한 $((LIMIT_PROJECT/1024))KB) · "
[ "$i" -gt "$LIMIT_INDEX" ]   && over="${over}MEMORY.md $((i/1024))KB(상한 $((LIMIT_INDEX/1024))KB) · "

[ -z "$over" ] && { log "$proj PASS g=$g p=$p i=$i"; exit 0; }

# ── 하루 1회만 알린다 ──
day=$(date '+%F')
# 마커는 basename 이 아니라 경로 slug 로 — 다른 위치의 동명 레포끼리 서로의 알림을 잡아먹지 않게.
mark="$HOME/.claude/hooks/.rules-size-notified-$slug"
if [ -f "$mark" ] && [ "$(cat "$mark" 2>/dev/null)" = "$day" ]; then
  log "$proj SKIP already-notified-today (g=$g p=$p i=$i)"
  exit 0
fi
printf '%s' "$day" >"$mark" 2>/dev/null

total=$((g + p + i))
log "$proj OVER g=$g p=$p i=$i total=$total"

reason="[상시 로드 컨텍스트 상한] ${proj}: ${over%· }. 합계 $((total/1024))KB 가 매 세션 무조건 로드됩니다(대략 $((total/2400))k~$((total/1800))k 토큰). 줄이는 방법은 **규칙 문장은 남기고 경위·실측 서사·사고 사례·예시를 memory 로 밀어내고 규약엔 [[포인터]]만 남기는 것**입니다(배치 규칙 ④). MEMORY.md 는 '그 파일을 열지 판단할 한 줄 훅'까지만 두고 본문 요약을 인라인하지 마세요. ⚠️**규약 축소는 규칙 유실 위험이 있으므로 임의로 실행하지 말고 사용자에게 현황과 축소안을 보고해 승인받은 뒤** 진행하세요(승인 전이면 이 알림을 전달만 하고 종료해도 됩니다). 착수 시 ①이관처 memory 가 실재하는지 grep 선확인 ②삭제 전후 규칙 앵커 목록 대조 ③파일 백업. 이 알림은 프로젝트당 하루 1회만 뜹니다."
jq -n --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
