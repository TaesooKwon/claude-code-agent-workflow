#!/usr/bin/env bash
# hook-policy: 강제=차단 · 도구부재=통과
# Stop hook: docs/agent_history.md 로테이션 반자동화.
# 40KB(=40960B) 초과 시 ①오늘자 전체 백업을 자동 생성(멱등) ②트림하라는 경고로 stop 을 1회 block.
# 자동 트림은 하지 않는다 — 활성/미커밋 항목 보존 판단이 필요하므로 에이전트가 판단해 트림한다.
# closed-loop-history.sh 와 동일한 규약: IdeaProjects 스코프 · jq · stop_hook_active loop-guard · 관측 로그.

input=$(cat)

LOG="$HOME/.claude/hooks/history-rotate.log"
log() { printf '%s [rotate] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null; }
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 1200 ]; then
  tail -n 800 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

command -v jq >/dev/null 2>&1 || { log "SKIP no-jq"; exit 0; }

stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

base="__PROJECTS_DIR__"
case "$cwd" in
  "$base"/*) ;;
  *) exit 0 ;;   # IdeaProjects 밖 — 관할 아님.
esac

[ "$stop_active" = "true" ] && { log "SKIP loop-guard"; exit 0; }

rel="${cwd#"$base"/}"
proj="${rel%%/*}"
root="$base/$proj"

hist=$(find "$root" -path "*/docs/agent_history.md" \
  -not -path "*/node_modules/*" -not -path "*/target/*" \
  -not -path "*/build/*" -not -path "*/.git/*" 2>/dev/null | head -1)

[ -n "$hist" ] && [ -f "$hist" ] || { log "$proj SKIP no-history-file"; exit 0; }

LIMIT=40960
sz=$(wc -c <"$hist" 2>/dev/null || echo 0)
[ "$sz" -le "$LIMIT" ] && { log "$proj PASS size=$sz"; exit 0; }

# ── 40KB 초과 ── 오늘자 백업 자동 생성(멱등) 후 트림 경고.
day=$(date '+%F')
dir=$(dirname "$hist")
# 백업 보관소가 있으면 거기에 떨군다(docs/ 최상위 비대 방지). 없으면 기존대로 history 파일 옆.
[ -d "$dir/archive/history" ] && dir="$dir/archive/history"
bak="$dir/agent_history.backup-$day.md"
# ⚠️ 백업 상태를 **메시지에 사실대로** 실어야 한다. 과거엔 else 분기(=복사 안 함)에서도
#    reason 이 무조건 "자동 생성했습니다"라고 말해, 같은 날 2회차부터 에이전트가 **1회차 스냅샷을
#    최신 백업으로 오인**했다. 그 스냅샷에는 1회차 이후 작성분이 빠져 있어, 믿고 트림하면 그만큼이
#    영구 소실된다(2026-08-31 예시 레포 3회차에서 실제로 6.9KB/13줄이 소실 직전까지 갔다).
if [ ! -f "$bak" ]; then
  if cp "$hist" "$bak" 2>/dev/null; then
    bak_state="fresh"; log "$proj BACKUP $bak (size=$sz)"
  else
    bak_state="failed"; log "$proj BACKUP-FAIL $bak"
  fi
else
  bak_state="stale"; log "$proj backup-exists $bak (size=$sz)"
fi

case "$bak_state" in
  fresh)
    bak_note="전체 백업을 ${bak} 에 이번 호출에서 새로 생성했습니다(현재 파일과 전문 일치)." ;;
  stale)
    bak_note="⚠️ 백업 ${bak} 이 이미 있어 **재생성하지 않았습니다(멱등)** — 그 스냅샷은 최초 생성 시점의 것이라 이후 작성분이 빠져 있을 수 있습니다. 트림 전에 이관 대상 문구가 백업에 실재하는지 grep 으로 확인하고, 없으면 구분선·경위 주석과 함께 백업에 append 한 뒤 트림하세요(백업을 최신이라 가정하고 트림하면 그만큼 영구 소실됩니다)." ;;
  failed)
    bak_note="⚠️ 백업 생성에 **실패**했습니다(${bak}). 백업 없이 트림하지 마세요 — 먼저 보존본을 수동으로 만드십시오." ;;
esac

kb=$((sz / 1024))
reason="[history 로테이션] ${proj} docs/agent_history.md 가 ${kb}KB로 40KB를 초과했습니다. ${bak_note} 이제 이 파일을 트림하세요: 완료·커밋된 오래된 항목은 백업으로 이관(백업은 보존)하고 활성·미커밋 작업 항목만 남깁니다. 이관 대상이 0건이면(엔트리가 1건뿐이고 그것이 활성) 헤더 압축만 하고 넘어가되, 같은 상황이 반복되면 파일 크기가 아니라 **구조**(트림 불가한 상시 섹션이 파일에 눌러앉았는지)를 의심하세요. 헤더에 로테이션 한 줄(날짜·백업파일·이관범위)을 추가한 뒤 세션을 종료하세요."
jq -n --arg r "$reason" '{decision:"block", reason:$r}'
exit 0
