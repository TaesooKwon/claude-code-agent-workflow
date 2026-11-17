#!/usr/bin/env bash
# Closed-loop history enforcement (Antigravity "Hermes" protocol) for the
# IdeaProjects Spring repos. On Stop, if this session edited source files in
# a repo but never recorded the learning afterwards, block the stop with a
# reminder. Otherwise exit 0 silently.
#
# "Recorded" is satisfied by EITHER (2026-06-25, claude-only transition):
#   (a) a write to that repo's docs/agent_history.md   (legacy / sibling repos)
#   (b) a write to that project's Claude native memory  (~/.claude/projects/<cwd>/memory/*.md)
# 예외(2026-07-02): 프로젝트명이 STRICT_PROJECT와 일치할 때만 (a) AND (b) 둘 다 요구
# (CLAUDE.md 2채널 의무). 그 외 레포·판별 불확실 시엔 기존 OR 유지(안전측 폴백).
#
# Detection is transcript-based (which files were Edit/Write'd this session),
# NOT mtime-based, to avoid false positives from build output / fresh checkouts.
#
# F1(2026-06-26): .html(Thymeleaf 템플릿)·.css 도 소스로 포함(템플릿만 고친 세션 누락 방지).
# F2(2026-06-26): 관측성 — 매 실행 결과를 로그에 남겨 "조용한 fail-open(작동≠죽음 구분불가)"을
#   탐지 가능하게. jq 부재 시 침묵 대신 로그. 로그 = ~/.claude/hooks/closed-loop-history.log.
# F3(2026-08-05): 감지 사각 2건 보완.
#   (1) 서브에이전트/Workflow 가 한 편집은 부모 transcript 가 아니라
#       <세션디렉터리>/subagents/**/*.jsonl 에 기록된다 → 수집 대상에 포함.
#       세션디렉터리 = transcript_path 에서 .jsonl 을 뗀 경로.
#   (2) Bash 로 쓴 파일(heredoc·리다이렉트·tee·sed -i)도 보조 신호로 인정.
#       오탐(늑대소년) 방지를 위해 "쓰기 연산자의 대상 토큰"만 뽑아 검사하고,
#       /tmp·scratchpad·target 등 산출물 경로는 제외한다.
#   여러 파일을 합치면 파일 내 라인 인덱스로는 선후를 못 가리므로,
#   순서 기준을 인덱스 → 레코드 timestamp(ISO-8601, 사전순=시간순)로 교체.

input=$(cat)

# 타임스탬프 문자열 비교([[ > ]])·sort 를 바이트 순서로 고정(로케일 collation 영향 차단).
export LC_ALL=C

LOG="$HOME/.claude/hooks/closed-loop-history.log"
log() { printf '%s [enforce] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null; }
# 로그 무한증식 방지: 1200줄 초과 시 최근 800줄로 트림.
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 1200 ]; then
  tail -n 800 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
fi

# F2: jq 는 이 훅의 핵심 의존 — 없으면 enforcer 전체가 무력화된다. 침묵 대신 로그.
if ! command -v jq >/dev/null 2>&1; then
  log "SKIP no-jq (enforcer 무력화 — PATH에 jq 필요)"
  exit 0
fi

# Don't re-block if we already blocked once this stop cycle (loop guard).
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

[ -n "${CLAUDE_PROJECT_DIR:-}" ] || exit 0
base="$(dirname "$CLAUDE_PROJECT_DIR")"
case "$cwd" in
  "$base"/*) ;;
  *) exit 0 ;;  # IdeaProjects 밖 — 이 enforcer 관할 아님(로그 불필요).
esac

rel="${cwd#"$base"/}"
proj="${rel%%/*}"
root="$base/$proj"

[ "$stop_active" = "true" ] && { log "$proj SKIP loop-guard"; exit 0; }

# Locate agent_history.md anywhere under the repo (top-level OR nested project dir).
hist=$(find "$root" -path "*/docs/agent_history.md" \
  -not -path "*/node_modules/*" -not -path "*/target/*" \
  -not -path "*/build/*" -not -path "*/.git/*" 2>/dev/null | head -1)

[ -n "$hist" ] && [ -f "$hist" ] || { log "$proj SKIP no-history-file"; exit 0; }
[ -n "$transcript" ] && [ -f "$transcript" ] || { log "$proj SKIP no-transcript"; exit 0; }

# F3(1): 부모 transcript + 같은 세션의 서브에이전트/Workflow jsonl 을 모두 수집.
sess_dir="${transcript%.jsonl}"
srcs=("$transcript")
if [ -d "$sess_dir" ]; then
  while IFS= read -r sf; do
    [ -n "$sf" ] && srcs+=("$sf")
  done < <(find "$sess_dir" -type f -name '*.jsonl' 2>/dev/null)
fi

# F3(2): Bash command 문자열에서 "쓰기 연산자의 대상 토큰"만 뽑는다(오탐 최소화).
#   - `> path` / `>> path` (heredoc `cat > path <<EOF` 포함)
#   - `tee [-a] path`
#   - `sed -i ... path`
# ponytail: 인터프리터 내부 쓰기(python/node 스크립트가 open(...,'w'))는 여전히 미탐지 /
#   업그레이드 경로 = PostToolUse 단계에서 실제 mtime 변화를 마커로 적재.
bash_write_targets() {
  local cmd="$1"
  {
    printf '%s\n' "$cmd" | grep -oE '>>?[[:space:]]*[^[:space:];|&<>"'"'"'`)]+' | sed -E 's/^>>?[[:space:]]*//'
    printf '%s\n' "$cmd" | grep -oE '(^|[[:space:];|&])tee[[:space:]]+(-a[[:space:]]+)?[^[:space:];|&<>"'"'"'`)]+' \
      | sed -E 's/^[[:space:];|&]*tee[[:space:]]+(-a[[:space:]]+)?//'
    printf '%s\n' "$cmd" | grep -oE '(^|[[:space:];|&])sed[[:space:]]+-i[^;|&]*' | tr '[:space:]' '\n'
  } 2>/dev/null
}

# Track the timestamp of the last source edit vs the last write that records
# learning (history OR memory).
last_src=""
last_hist=""
last_mem=""
srcfile=""
classify() {
  local ts="$1" f="$2"
  [ -z "$f" ] && return 0
  # (b) A write to THIS project's Claude native memory closes the loop too.
  case "$f" in
    "$HOME/.claude/projects/"*"/memory/"*.md)
      case "$f" in *"$proj"*"/memory/"*) last_mem="$ts" ;; esac
      return 0 ;;
  esac
  case "$f" in
    "$root"/*) ;;
    *) return 0 ;;
  esac
  if [ "$f" = "$hist" ]; then
    last_hist="$ts"
  else
    case "$f" in
      # .ipynb = NotebookEdit(입력 필드가 notebook_path) 커버용. 확장자 목록에 없으면
      # 필드명만 고쳐도 영구 0건이라 "매처에 이름만 있는 착시"가 그대로 남는다.
      *.java|*.xml|*.sql|*.js|*.ts|*.vue|*.jsx|*.tsx|*.html|*.css|*.ipynb) last_src="$ts"; srcfile="$f" ;;
    esac
  fi
}

while IFS=$'\t' read -r ts kind val; do
  [ -z "$val" ] && continue
  if [ "$kind" = "F" ]; then
    classify "$ts" "$val"
    continue
  fi
  # kind=B — Bash 쓰기 보조 신호.
  # 사전필터(순수 bash, 포크 0): 쓰기 연산자도 소스 확장자도 없는 명령은 즉시 스킵.
  # 세션당 Bash 수백 건 × grep/sed 5회면 Stop 지연이 초 단위로 커진다.
  case "$val" in
    *"sed -i"*|*tee*|*">"*) ;;
    *) continue ;;
  esac
  case "$val" in
    *.java*|*.xml*|*.sql*|*.js*|*.ts*|*.vue*|*.jsx*|*.tsx*|*.html*|*.css*|*.ipynb*|*.md*) ;;
    *) continue ;;
  esac
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      *.java|*.xml|*.sql|*.js|*.ts|*.vue|*.jsx|*.tsx|*.html|*.css|*.ipynb|*.md) ;;
      *) continue ;;
    esac
    # 산출물·임시 경로는 소스 변경으로 보지 않는다(게이트 늑대소년 방지).
    case "$t" in
      /tmp/*|/private/tmp/*|/var/folders/*|*/scratchpad/*|*/node_modules/*|*/target/*|*/build/*|*/.git/*) continue ;;
    esac
    t="${t#./}"
    case "$t" in /*) ;; *) t="$cwd/$t" ;; esac   # 상대경로는 cwd 기준(cwd 는 레포 안)
    # Bash 휴리스틱은 텍스트 스캔이라 '쓰기'와 '언급'을 구분하지 못한다. 두 겹으로 좁힌다.
    #  (1) 실재 파일만 — 다른(스크래치) 레포의 상대토큰이 레포 루트로 절대화되거나,
    #      미전개 셸 변수(`$J/X.java`), 리포트 heredoc 본문의 마크다운 인용부호(`> .../Foo.java`)를 배제.
    #  (2) **파일 mtime 이 그 명령 시각 이후**여야 인정 — 진짜 썼다면 mtime 이 갱신된다.
    #      (1)만으로는 레포에 실재하는 파일을 명령문에서 언급만 해도 통과했다
    #      (실사고 2026-08-05 09:13 `BLOCK … app.js` — 전날 커밋 파일, 워킹트리 무변경).
    [ -e "$t" ] || continue
    if [ -n "$ts" ]; then
      ts_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null || printf '')
      if [ -n "$ts_epoch" ]; then
        f_epoch=$(stat -f %m "$t" 2>/dev/null || printf '')
        [ -n "$f_epoch" ] && [ "$f_epoch" -lt "$((ts_epoch - 5))" ] && continue
      fi
    fi
    classify "$ts" "$t"
  # ponytail: 서브에이전트 jsonl 중 하나가 깨지면 jq 가 그 지점에서 멈춰 뒤 파일들이 스캔되지 않는다
  #   (fail-open 방향이고 부모 transcript 는 항상 srcs[0] 이라 주신호는 보존). 파일별 jq 호출로
  #   바꾸면 해소되지만 서브에이전트 수만큼 프로세스가 늘어 Stop 지연이 커진다 — 업그레이드 경로는
  #   jq 한 번에 --slurp 대신 스트리밍하되 파일 경계에서 오류를 흡수하는 래퍼.
  done <<< "$(bash_write_targets "$val")"
done < <(jq -rc 'select(.message.content) | (.timestamp // "") as $ts | .message.content[]?
  | select(.type=="tool_use")
  | if (.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
    then (((.input.file_path // .input.notebook_path) // empty) | "\($ts)\tF\t\(.)")
    elif .name=="Bash"
    then ((.input.command // empty) | gsub("[\n\r]";" ") | "\($ts)\tB\t\(.)")
    else empty end' "${srcs[@]}" 2>/dev/null | sort)

# Block only when source was edited and the learning was NOT recorded afterwards.
# 기본(형제 레포) = OR: history 또는 memory 한쪽만 기록해도 통과.
# STRICT_PROJECT 한정 = AND: 두 채널(history + memory) 모두 마지막 소스수정 이후 기록돼야 통과.
# CLAUDE_STRICT_PROJECT(env) 와 일치할 때만 AND, 미설정/그 외엔 기존 OR(형제 레포 회귀 금지).
block=""
if [ -n "$last_src" ]; then
  if [ -n "${CLAUDE_STRICT_PROJECT:-}" ] && [ "$proj" = "$CLAUDE_STRICT_PROJECT" ]; then
    if [[ "$last_src" > "$last_hist" || "$last_src" > "$last_mem" ]]; then
      block="and"
    fi
  else
    if [[ "$last_src" > "$last_hist" && "$last_src" > "$last_mem" ]]; then
      block="or"
    fi
  fi
fi

if [ -n "$block" ]; then
  log "$proj BLOCK mode=$block src=${srcfile#"$root"/}"
  if [ "$block" = "and" ]; then
    reason="[폐쇄형 학습 루프 / Hermes] 이번 세션에서 ${proj} 소스를 수정했지만 2채널 기록이 완결되지 않았습니다 (최근 수정: ${srcfile#"$root"/} / hist=$([[ "$last_hist" > "$last_src" ]] && echo 기록됨 || echo 누락) · memory=$([[ "$last_mem" > "$last_src" ]] && echo 기록됨 || echo 누락)). 해당 프로젝트는 두 채널 모두 필수입니다: (1) 이 프로젝트의 Claude native memory에 재사용 교훈/진행상태 memory 파일 write/update(MEMORY.md 인덱스 갱신 포함), 그리고 (2) ${hist} 하단에 항목 추가: ## [YYYY-MM-DD] 작업명 / [FACTS] 목적·범위(영향받은 Java·XML·테이블) / [FACTS] 핵심 설계결정 / [PROCEDURES] 재사용 스킬 / Next Step. 누락된 쪽을 기록한 뒤 작업을 종료하세요."
  else
    reason="[폐쇄형 학습 루프 / Hermes] 이번 세션에서 ${proj} 소스를 수정했지만 학습을 기록하지 않았습니다 (최근 수정: ${srcfile#"$root"/}). 작업을 마치기 전에 둘 중 하나로 기록하세요: (1) 이 프로젝트의 Claude native memory에 재사용 교훈/진행상태를 담은 memory 파일 write/update(MEMORY.md 인덱스 갱신 포함) — memory 기반 레포 권장, 또는 (2) ${hist} 하단에 항목 추가: ## [YYYY-MM-DD] 작업명 / [FACTS] 목적·범위(영향받은 Java·XML·테이블) / [FACTS] 핵심 설계결정 / [PROCEDURES] 재사용 스킬 / Next Step. 그 다음 작업을 종료하세요."
  fi
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
else
  log "$proj PASS (src=$last_src hist=$last_hist mem=$last_mem)"
fi
exit 0
