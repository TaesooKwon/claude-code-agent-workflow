#!/usr/bin/env bash
# hook-policy: 강제=안내 · 도구부재=통과
# PostToolUse(Write|Edit) 전역 훅 — 에이전트 세팅 층(규약·훅·settings·킷·스킬·워크플로)을 편집하면
# "이 변경은 어느 층 몫인가 + 전파는 어떤 모드인가"를 additionalContext 로 상기시켜 에이전트가
# 먼저 방향을 제안하게 한다. 경고형(차단 없음). 같은 세션·같은 층은 1회만 발화(마커).
# 근거·판정표 = 도입 레포의 docs/agent-propagation-plan-20260910.md.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
fp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)
[ -n "$fp" ] || exit 0
case "$fp" in /*) ;; *) fp="$PWD/$fp" ;; esac
# 편집 경로를 두 형태로 분류해 걸린 갈래를 모두 안내한다(합집합) — 어느 한쪽이라도 세팅 층이면 발화.
#  ⓐ 문자 경로: `.`·`..` 만 글자 단위로 접는다(링크는 따라가지 않음) → 레포 안 세팅 파일이 층 밖을 가리키는 링크여도 원래 자리로 잡힌다.
#  ⓑ 실경로: 파일 자체가 링크면 readlink 로 따라가고(상대 대상은 링크가 있는 디렉터리 기준, 순환 대비 상한),
#     디렉터리는 pwd -P 로 푼다. 디렉터리가 없으면(신규 경로) 그 시점 경로를 그대로 쓴다 → 링크 대상의 층으로 잡힌다.
lexnorm(){
  local IFS=/ parts out s n
  parts=(); out=()
  read -r -d '' -a parts < <(printf '%s' "$1") || true   # read -a 는 글롭 확장을 하지 않는다
  for s in "${parts[@]}"; do
    case "$s" in
      ''|.) ;;
      ..) n=${#out[@]}; [ "$n" -gt 0 ] && unset "out[$((n-1))]" ;;
      *) out+=("$s") ;;
    esac
  done
  printf '/%s' "${out[*]}"
}
physpath(){
  local p="$1" d t i=0
  while [ -L "$p" ] && [ $i -lt 16 ]; do
    t=$(readlink "$p") || break
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    i=$((i+1))
  done
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return; }
  printf '%s/%s' "${d%/}" "$(basename "$p")"
}
physdir(){ (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
# classify <경로> <전역 디렉터리> <좌석 디렉터리> → slug·layer 설정(세팅 밖이면 둘 다 빈 값)
classify(){
  local p="$1" H="$2" TS="$3"
  layer=""; slug=""
  case "$p" in
    "$H/rules-rationale/"*) ;;                              # 근거 문서 = 배치 판정 대상 아님
    "$TS/rules-lite.md"|"$TS/CLAUDE.md"|"$TS/lite.json") layer="팀 좌석 규약"; slug=t-rule ;;   # 레포 규약 갈래보다 앞
    "$H/CLAUDE.md")                    layer="전역 규약";     slug=g-rule ;;
    "$H/settings.json"|"$H/settings.local.json") layer="전역 settings"; slug=g-set ;;
    "$H/hooks/"*)                      layer="전역 훅";       slug=g-hook ;;
    "$H/agent-scaffold/"*)             layer="킷 템플릿";     slug=kit ;;
    "$H/skills/"*)                     layer="전역 스킬";     slug=g-skill ;;
    */.claude/settings*.json)          layer="레포 settings"; slug=r-set ;;
    */.claude/hooks/*)                 layer="레포 훅";       slug=r-hook ;;
    */.claude/skills/*/SKILL.md)       layer="레포 스킬";     slug=r-skill ;;
    */.claude/workflows/*)             layer="레포 워크플로"; slug=r-wf ;;
    */CLAUDE.md)                       layer="레포 규약";     slug=r-rule ;;
  esac
}
lexfp=$(lexnorm "$fp")
physfp=$(physpath "$fp")
seen=" "; out=""
for which in lex phys; do
  if [ "$which" = lex ]; then
    classify "$lexfp" "$(lexnorm "$HOME/.claude")" "$(lexnorm "$HOME/.claude-team")"; p="$lexfp"
  else
    classify "$physfp" "$(physdir "$HOME/.claude")" "$(physdir "$HOME/.claude-team")"; p="$physfp"
  fi
  [ -n "$slug" ] || continue
  case "$seen" in *" $slug "*) continue ;; esac            # 두 형태가 같은 갈래면 한 번만
  seen="$seen$slug "
  marker="${TMPDIR:-/tmp}/setting-placement-${sid}-${slug}"
  [ -e "$marker" ] && continue
  : > "$marker" 2>/dev/null || true
  fp="$p"; ctx=""
case "$slug" in
  r-*) ctx="[세팅 배치 판정] ${layer} 편집: $fp
이 변경의 성격을 먼저 판정하고 사용자에게 방향을 제안하라(복사 전파 금지):
 ①스택 불문 방법론·가드 → 전역(~/.claude/CLAUDE.md 또는 ~/.claude/hooks + ~/.claude/settings.json)으로 올리면 전 레포 자동 적용·복제 0.
 ②동일 스택 공유 → 킷 템플릿(~/.claude/agent-scaffold)에 반영. 활성 형제 레포엔 지금 전파하지 말고 다음 착수 시 kit-drift-check 가 제안한다(지연 전파). 휴면 레포는 손대지 않는다.
 ③도메인값·접속정보·포트 → 이 레포에서 끝. 훅 스크립트에 값을 박지 말고 설정 변수(상단 VAR= 또는 .claude/hook-config.env)로 분리해 로직은 킷과 동일하게 유지.
 규약 산문을 늘리는 변경이면: 기계 검사 가능한가(훅/lint) · 특정 순간에만 필요한가(절차 스킬) · 경위·수치인가(rationale/memory)를 먼저 물어 상시 로드에 남기지 않는다." ;;
  g-rule|g-set|g-hook|g-skill) ctx="[세팅 배치 판정] ${layer} 편집: $fp
전 레포에 즉시 적용되는 층이다. ①스택 종속 내용(Maven·MyBatis·Thymeleaf·포트·경로)이 섞이지 않았는지 ②상시 로드 분량(조항 3줄 초과·사고 날짜·수치는 rules-rationale 로) ③훅이면 다른 스택 레포에서 오탐·오류 없이 조용히 exit 0 하는지 확인하고 결과를 사용자에게 한 줄로 보고하라." ;;
  t-rule) ctx="[세팅 배치 판정] ${layer} 편집: $fp
좌석은 전역 규약(~/.claude/CLAUDE.md)을 로드하지 않고 rules-lite.md(+ lite.json 설정)를 읽는다. ①정책 개정이면 정본(전역·레포 CLAUDE.md)부터 고치고 이 사본을 같은 편집 단위에서 맞춘다 ②좌석 전용 예외(토큰 경제·상시 금지/허용)인지 정본 조항의 사본인지 구분해, 사본이면 정본 문구와 어긋나지 않게 한다 ③상시 로드 분량(경위·수치는 rules-rationale 로). 결과를 사용자에게 한 줄로 보고하라." ;;
  kit) ctx="[세팅 배치 판정] ${layer} 편집: $fp
킷은 복사 원본이다. 형제 레포에 지금 밀어넣지 마라 — 활성 동일 스택 레포는 다음 착수 세션의 kit-drift-check 가 드리프트를 보고하면 그때 맞춘다(지연 전파). 휴면 레포는 제외. 이 변경이 실은 스택 불문이면 킷이 아니라 전역이 맞는지 다시 판정하라." ;;
esac
# 팀 좌석은 전역 규약을 로드하지 않고 rules-lite.md 의 사본만 읽는다 — 사본이 옛 규칙을 계속 적용하지 않게 상기.
[ "$slug" = g-rule ] && ctx="${ctx}
 ④팀 좌석 규약 ~/.claude-team/rules-lite.md 에 이 조항의 사본이 있으면 같은 편집 단위에서 맞춘다(좌석은 전역을 로드하지 않는다)."
  if [ -n "$out" ]; then out="${out}

${ctx}"; else out="$ctx"; fi
done
[ -n "$out" ] || exit 0
jq -n --arg c "$out" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
