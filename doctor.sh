#!/usr/bin/env bash
# doctor.sh — 전역 에이전트 레이어 건강검진. 새 머신 셋업 후, 또는 "요즘 훅이 안 도는데?"
# 싶을 때 아무 때나 실행. 의존 프로그램·훅 설치/등록·경로 드리프트·스캐폴드·maven 레포를 점검.
# 종료코드: 문제 있으면 1.
set -u
DEST="$HOME/.claude"
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# machine.env 있으면 로드(MAVEN_REPO 등 머신고유값 반영). 없어도 진행.
[ -f "$KIT_DIR/machine.env" ] && . "$KIT_DIR/machine.env" || true
# 짝 = bootstrap-machine.sh 의 AGENT_REPOS 기본값(설치가 넣는 값과 대조해야 하므로 바꾸면 함께 바꾼다).
: "${AGENT_REPOS:=(machine.env 의 AGENT_REPOS 미설정 — 대상 레포를 채운다)}"
# 자유 텍스트라 sed 치환 특수문자(& # | \)를 이스케이프해 둔다.
AGENT_REPOS_SED="$(printf '%s' "$AGENT_REPOS" | sed 's/[&#|\\]/\\&/g')"
FAIL=0
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*"; FAIL=1; }

echo "=== [1] 의존 프로그램 ==="
for c in jq python3 git; do command -v "$c" >/dev/null 2>&1 && ok "$c ($(command -v $c))" || bad "$c 없음 (필수)"; done
for c in node mvn; do command -v "$c" >/dev/null 2>&1 && ok "$c ($(command -v $c))" || warn "$c 없음 (JVM/statusline 필요 시)"; done

echo "=== [2] 전역 자산 설치 ==="
for p in CLAUDE.md settings.json hooks skills/harness skills/bootstrap-project skills/playwright-verify agent-scaffold; do
  [ -e "$DEST/$p" ] && ok "~/.claude/$p" || bad "~/.claude/$p 없음 (bootstrap-machine.sh 실행?)"
done

echo "=== [3] 훅 설치·실행권한 ==="
for h in closed-loop-history.sh convention-gate.sh history-rotate-check.sh; do
  f="$DEST/hooks/$h"
  if [ -f "$f" ]; then [ -x "$f" ] && ok "$h (+x)" || bad "$h 실행권한 없음 (chmod +x)"; else bad "$h 미설치"; fi
done

echo "=== [4] Stop 훅 등록(settings.json) ==="
# 킷의 핵심 강제층이라 미등록 = 실패(경고 아님) — "doctor는 괜찮다는데 훅이 죽어있음"을 차단.
if [ -f "$DEST/settings.json" ] && command -v jq >/dev/null 2>&1; then
  reg="$(jq -r '[.hooks.Stop[]?.hooks[]?.command] | join(" ")' "$DEST/settings.json" 2>/dev/null)"
  for h in closed-loop-history convention-gate history-rotate-check; do
    printf '%s' "$reg" | grep -q "$h" && ok "Stop 등록: $h" || bad "Stop 미등록: $h (bootstrap-machine.sh 재실행 → settings.json hooks.Stop 을 킷 것으로 교체 — 라이브에만 있는 Stop 원소는 사라진다, 백업 .bak-<시각>)"
  done
elif [ ! -f "$DEST/settings.json" ]; then bad "settings.json 없음 — bootstrap-machine.sh 실행 필요"
else warn "jq 없음 — Stop 등록 확인 불가"; fi

echo "=== [5] 경로 드리프트(하드코딩 vs 실제) ==="
# 파일 "내용"에서 절대 홈경로를 뽑아 현재 홈과 다른 게 있으면 경고(파일명이 아니라 라인 검사).
# mac(/Users)·linux(/home) 양쪽 커버. 현재 홈으로 시작하지 않는 홈경로 = 드리프트.
# 테스트(*.test.sh)는 남의 홈 경로를 픽스처로 일부러 쓰므로 뺀다.
drift="$(grep -rhoE --exclude='*.log' --exclude='*.test.sh' "(/Users|/home)/[^/\"' ]+" "$DEST/hooks" "$DEST/settings.json" 2>/dev/null | sort -u | grep -v "^$HOME$" || true)"
# $HOME 자체(예 /Users/me)로 시작하는 경로는 정상 → 그 접두를 가진 라인 제거 후 남는 게 있으면 드리프트.
drift="$(printf '%s\n' "$drift" | grep -vE "^${HOME}(/|$)" | grep -E '.' || true)"
if [ -n "$drift" ]; then warn "훅/settings 내용에 현재 홈($HOME)과 다른 절대경로 잔존: $(printf '%s' "$drift" | tr '\n' ' ') — 재-bootstrap 필요"; else ok "홈 경로 정합"; fi
# 머신 토큰 잔존 — 치환이 빠진 설치본은 경로가 `__HOME__/…` 로 남아 훅·스킬이 조용히 무기능이 된다.
# 토큰 목록 = bootstrap-machine.sh 의 sed 치환 대상(허용 목록 — 새 토큰을 더하면 여기도 더한다).
# 테스트(*.test.sh)는 토큰을 픽스처로 일부러 쓰므로 뺀다. 백업(.bak-*)·로그도 뺀다.
tok="$(grep -rlE --exclude='*.test.sh' --exclude='*.bak*' --exclude='*.log' '__(HOME|PROJECTS_DIR|STRICT_PROJECT|MAVEN_REPO|AGENT_REPOS)__' \
  "$DEST/hooks" "$DEST/skills" "$DEST/agent-scaffold" "$DEST/agents" "$DEST/CLAUDE.md" "$DEST/settings.json" 2>/dev/null || true)"
if [ -n "$tok" ]; then warn "미치환 머신 토큰 잔존 $(printf '%s\n' "$tok" | grep -c .)개 파일: $(printf '%s' "$tok" | head -5 | tr '\n' ' ') — machine.env 확인 후 bootstrap-machine.sh 재실행"; else ok "머신 토큰 치환 정합"; fi
# statusline node 경로 유효성(있으면)
node_ref="$(jq -r '.statusLine.command // empty' "$DEST/settings.json" 2>/dev/null | grep -oE '/[^" ]+/bin/node' | head -1 || true)"
if [ -n "$node_ref" ]; then [ -x "$node_ref" ] && ok "statusline node 경로 유효($node_ref)" || warn "statusline node 경로 무효($node_ref) — 실제 node=$(command -v node 2>/dev/null || echo 없음)"; fi

echo "=== [5b] settings.json 키 드리프트(라이브 vs 킷 템플릿) ==="
# 라이브 settings.json 의 top-level 키가 킷 템플릿에 다 있는지 = "새 설정 켰는데 킷에 역반영 안 함" 조기 경보.
# statusLine·enabledPlugins·extraKnownMarketplaces 는 절대경로/플러그인 고유라 의도적 제외(SETUP §7, 재설치로 재현 — 템플릿의 enabledPlugins 는 @builtin 끄기만 담는다).
# autoMode 는 레포 경로가 박힌 레포 전용 허용 규칙이라 의도적 제외.
TMPL="$KIT_DIR/global/settings.json.template"
# 킷 제외 훅(kit-drift-exclude.txt 의 hooks/<파일명> 줄) — 등록 집합·역방향 대조에서 뺀다.
HEXCL="$(grep -oE '^hooks/[^[:space:]]+' "$KIT_DIR/kit-drift-exclude.txt" 2>/dev/null | sed 's#^hooks/##' || true)"
if [ -f "$DEST/settings.json" ] && [ -f "$TMPL" ] && command -v jq >/dev/null 2>&1; then
  EXCL=' statusLine enabledPlugins extraKnownMarketplaces model autoMode '
  tmplkeys="$(jq -r 'keys[]' "$TMPL" 2>/dev/null)"
  missing=''
  for k in $(jq -r 'keys[]' "$DEST/settings.json" 2>/dev/null); do
    printf '%s\n' "$tmplkeys" | grep -qx "$k" && continue
    case "$EXCL" in *" $k "*) continue;; esac
    missing="$missing $k"
  done
  if [ -n "$missing" ]; then warn "라이브 settings.json 키가 킷 템플릿에 없음:$missing — 이식 대상이면 global/settings.json.template 에 반영(시크릿/회사식별자는 플레이스홀더로)"; else ok "settings.json 키 정합(플러그인 클러스터 제외 전부 템플릿 반영)"; fi
  # 이벤트별 등록 훅 "집합" 대조 — 라이브에서 훅을 해제/추가하고 킷 템플릿에 미반영하는 드리프트 조기 경보
  # (실례 2026-08-13: rules-size-check 해제 같은 변경이 한쪽에만 남는 것을 잡는다).
  # 파일명 = command 의 마지막 '/' 뒤에서 끝의 따옴표·공백 등 비이름 문자를 뗀 것(`node "/x/a.js"` → a.js).
  # 훅 파일 확장자(.sh·.py·.js·.mjs)로 끝나는 이름만 센다 — 외부 앱이 넣은 인라인 셸 명령(파일 없음)은 등록 훅이 아니다.
  hx="$(printf '%s\n' "$HEXCL" | jq -R . | jq -sc 'map(select(length > 0))')"
  for ev in Stop PreToolUse PostToolUse SessionStart; do
    lv="$(jq -r --arg e "$ev" --argjson x "$hx" '[.hooks[$e][]?.hooks[]?.command] | map(split("/")|last|sub("[^A-Za-z0-9._-]+$";"")) | map(select(test("\\.(sh|py|js|mjs)$"))) | map(select(. as $n | $x | index($n) | not)) | sort | join(",")' "$DEST/settings.json" 2>/dev/null)"
    tv="$(jq -r --arg e "$ev" --argjson x "$hx" '[.hooks[$e][]?.hooks[]?.command] | map(split("/")|last|sub("[^A-Za-z0-9._-]+$";"")) | map(select(test("\\.(sh|py|js|mjs)$"))) | map(select(. as $n | $x | index($n) | not)) | sort | join(",")' "$TMPL" 2>/dev/null)"
    [ "$lv" = "$tv" ] && ok "hooks.$ev 등록 집합 정합(${lv:-등록없음})" || warn "hooks.$ev 등록 집합 드리프트 — 라이브[${lv:-없음}] vs 킷[${tv:-없음}] (수동 판정 후 동기)"
  done
else warn "settings.json/템플릿/jq 없음 — 키 드리프트 확인 불가"; fi

echo "=== [5c] 내용 드리프트(라이브 vs 킷 사본, 토큰 치환 후 대조) ==="
# 규약 N벌 수동 동기의 기계 보완(0719 보류 → 2026-08-13 실드리프트 5건 재발로 추가). 방향 중립 "경고" —
# 어느 쪽이 신형인지는 사람이 판정한다(자동 덮어쓰기 금지 — 드리프트는 양방향, 형제/라이브에서 자란 자산을 지울 수 있다).
# CLAUDE.md 와 rules-rationale/ 은 스크럽 변종(METHOD §9 — 회사·프로젝트명 제거)이라 제외, bin/ 은 설치처가 ~/.local/bin 이라 제외.
# 텍스트는 머신 토큰(__HOME__ 등) 치환 후, 바이너리는 그대로 cmp.
drift_list=''; dchecked=0
for rel in hooks agent-scaffold skills agents; do
  src="$KIT_DIR/global/$rel"; [ -d "$src" ] || continue
  while IFS= read -r kf; do
    rp="${kf#"$src"/}"; lf="$DEST/$rel/$rp"; dchecked=$((dchecked+1))
    if [ ! -f "$lf" ]; then drift_list="$drift_list $rel/$rp(라이브없음)"; continue; fi
    if grep -Iq . "$kf" 2>/dev/null; then
      LC_ALL=C sed -e "s|__HOME__|$HOME|g" -e "s|__PROJECTS_DIR__|${PROJECTS_DIR:-}|g" \
        -e "s|__STRICT_PROJECT__|${STRICT_PROJECT:-}|g" \
        -e "s|__AGENT_REPOS__|$AGENT_REPOS_SED|g" "$kf" \
        | cmp -s - "$lf" || drift_list="$drift_list $rel/$rp"
    else
      cmp -s "$kf" "$lf" || drift_list="$drift_list $rel/$rp"
    fi
  done < <(find "$src" -type f ! -name '*.bak*' ! -name '.DS_Store' ! -path '*/node_modules/*')
done
# 역방향: 라이브에서 자란 전역 훅이 킷에 없음(2026-08-03 실사고 방향 — code-review-marker 류)
for lf in "$DEST"/hooks/*.sh; do
  [ -f "$lf" ] || continue
  printf '%s\n' "$HEXCL" | grep -qxF "$(basename "$lf")" && continue
  [ -f "$KIT_DIR/global/hooks/$(basename "$lf")" ] || drift_list="$drift_list hooks/$(basename "$lf")(킷없음)"
done
# 역방향(스킬): 킷이 관리하는 스킬 폴더(킷 global/skills/<이름>) 안에서 라이브에만 있는 파일 — 라이브에서 자란 테스트·자료가
#   킷에 안 올라간 방향. 킷에 없는 스킬 폴더(개인·플러그인 스킬)는 대상이 아니다.
#   제외 = kit-drift-exclude.txt 의 skills/<경로> 줄(완전일치, '/' 로 끝나면 그 아래 전부) · *.bak* · .DS_Store · __pycache__ · node_modules.
SEXCL="$(grep -oE '^skills/[^[:space:]]+' "$KIT_DIR/kit-drift-exclude.txt" 2>/dev/null || true)"
_sexcl() { # $1 = skills/<상대경로> → 0 이면 제외
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in */) case "$1" in "$e"*) return 0;; esac;; *) [ "$1" = "$e" ] && return 0;; esac
  done <<EOF_SEXCL
$SEXCL
EOF_SEXCL
  return 1
}
for kd in "$KIT_DIR"/global/skills/*/; do
  sk="$(basename "$kd")"; [ -d "$DEST/skills/$sk" ] || continue
  while IFS= read -r lf; do
    rp="skills/${lf#"$DEST/skills/"}"
    _sexcl "$rp" && continue
    [ -f "$KIT_DIR/global/$rp" ] || drift_list="$drift_list $rp(킷없음)"
  done < <(find "$DEST/skills/$sk" -type f ! -name '*.bak*' ! -name '.DS_Store' ! -path '*/__pycache__/*' ! -path '*/node_modules/*')
done
if [ -n "$drift_list" ]; then warn "라이브↔킷 드리프트(수동 판정·동기 필요):$drift_list"; else ok "내용 드리프트 없음(${dchecked}파일 대조)"; fi

echo "=== [5d] 팀 좌석+Paseo 모듈(선택 — 좌석 폴더가 있거나 모듈 훅이 등록됐을 때만) ==="
# 읽기 전용: 아무 파일도 쓰지 않는다(경고만, FAIL 불변). 설치 절차 = global/modules/team-seat/INSTALL.md(공개 스냅샷에는 모듈 미포함 → 아래 "건너뜀")
MOD="$KIT_DIR/global/modules/team-seat"; TEAM="$HOME/.claude-team"; SJ="$DEST/settings.json"
if [ ! -d "$MOD" ]; then ok "모듈 패키지 없음 — 건너뜀"
else
  mhooks=""; for f in "$MOD"/hooks/*.sh; do [ -f "$f" ] && mhooks="$mhooks $(basename "$f")"; done
  # 등록 = command 마다 파일명 1개(split("/")|last — hook-obs 래퍼의 "… 경로 || exec 경로" 는 마지막 경로 1개로 센다.
  #   끝의 따옴표·공백은 [5b] 와 같이 뗀다).
  sj_ok=0; [ -f "$SJ" ] && command -v jq >/dev/null 2>&1 && jq -e 'type=="object"' "$SJ" >/dev/null 2>&1 && sj_ok=1
  reg_of() { [ "$sj_ok" = 1 ] && jq -r --arg e "$1" '[.hooks[$e][]?.hooks[]?.command // empty | split("/") | last | sub("[^A-Za-z0-9._-]+$";"")] | unique | .[]' "$SJ" 2>/dev/null; }
  nreg=0; for b in $mhooks; do for ev in PreToolUse SessionStart UserPromptSubmit; do reg_of "$ev" | grep -qxF "$b" && nreg=$((nreg+1)); done; done
  if [ ! -d "$TEAM" ] && [ "$nreg" = 0 ]; then
    if [ -f "$SJ" ] && [ "$sj_ok" = 0 ]; then warn "settings.json 을 JSON 으로 못 읽음(jq 없음 또는 깨짐) — 모듈 훅 등록 여부를 몰라 [5d] 건너뜀"
    else ok "좌석 폴더(~/.claude-team) 없음·모듈 훅 미등록 — 건너뜀(메인 단독)"; fi
  else
    n5d=0; w5d() { warn "$*"; n5d=$((n5d+1)); }
    [ -f "$SJ" ] && [ "$sj_ok" = 0 ] && w5d "settings.json 을 JSON 으로 못 읽음(jq 없음 또는 깨짐) — 등록 점검 생략"
    [ -d "$TEAM" ] || w5d "모듈 훅이 등록돼 있는데 좌석 폴더(~/.claude-team)가 없음 — INSTALL.md 1단계 또는 등록 해제"
    # 훅 설치·실행권한·패키지와 동일성
    for b in $mhooks; do
      lf="$DEST/hooks/$b"
      if [ ! -f "$lf" ]; then w5d "모듈 훅 미설치: hooks/$b"; continue; fi
      [ -x "$lf" ] || w5d "모듈 훅 실행권한 없음: hooks/$b"
      cmp -s "$MOD/hooks/$b" "$lf" || w5d "모듈 훅 내용이 패키지와 다름: hooks/$b (어느 쪽이 신형인지 사람이 판정)"
    done
    # 등록 대조 = 패키지 조각(settings.hooks.json)의 (이벤트, 파일명) 쌍이 라이브에 있는가
    if [ "$sj_ok" = 1 ] && jq -e . "$MOD/settings.hooks.json" >/dev/null 2>&1; then
      while IFS=$'\t' read -r ev b; do
        [ -n "$b" ] || continue
        reg_of "$ev" | grep -qxF "$b" || w5d "모듈 훅 미등록: $ev → $b (INSTALL.md 7단계)"
      done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[] | .hooks[] | "\($e)\t\(.command | split("/") | last | sub("[^A-Za-z0-9._-]+$";""))"' "$MOD/settings.hooks.json" 2>/dev/null)
    elif [ "$sj_ok" = 1 ]; then w5d "패키지 settings.hooks.json 을 JSON 으로 못 읽음 — 등록 대조 생략"; fi
    if [ -d "$TEAM" ]; then
      # 필수 링크 — 좌석이 훅·스킬을 메인과 공유하는지(→ ~/.claude)
      for n in settings.json hooks skills rules-rationale; do
        if [ ! -e "$TEAM/$n" ]; then w5d "좌석 링크 없음: ~/.claude-team/$n"
        elif ! [ "$TEAM/$n" -ef "$DEST/$n" ]; then w5d "좌석 ~/.claude-team/$n 이 ~/.claude/$n 과 같은 대상이 아님(링크 확인)"; fi
      done
      # 좌석 규약 링크 — CLAUDE.md → rules-lite.md(Paseo 는 --append-system-prompt-file 이 무효라 이 링크가 규약을 싣는 유일한 경로)
      if [ ! -e "$TEAM/CLAUDE.md" ]; then w5d "좌석 링크 없음: ~/.claude-team/CLAUDE.md (→ rules-lite.md, INSTALL.md 2단계)"
      elif ! [ "$TEAM/CLAUDE.md" -ef "$TEAM/rules-lite.md" ]; then w5d "좌석 ~/.claude-team/CLAUDE.md 가 rules-lite.md 를 가리키지 않음 — 좌석에 좌석 규약이 안 실린다(INSTALL.md 2단계)"; fi
      # lite.json — 유효 JSON + 메인 전역 규약 제외(비우면 좌석이 위임 조항을 읽어 rules-lite 와 충돌) + 좌석 CLAUDE.md 는 제외하면 안 됨
      LJ="$TEAM/lite.json"
      if [ ! -f "$LJ" ]; then w5d "좌석 설정 없음: ~/.claude-team/lite.json (INSTALL.md 2단계)"
      elif ! command -v jq >/dev/null 2>&1 || ! jq -e 'type=="object"' "$LJ" >/dev/null 2>&1; then w5d "lite.json 을 JSON 으로 못 읽음 — 확인 필요"
      else
        jq -e --arg x "$HOME/.claude/CLAUDE.md" '(.claudeMdExcludes // []) | index($x)' "$LJ" >/dev/null 2>&1 \
          || w5d "lite.json claudeMdExcludes 에 필수 경로 없음: $HOME/.claude/CLAUDE.md"
        jq -e --arg x "$HOME/.claude-team/CLAUDE.md" '(.claudeMdExcludes // []) | index($x)' "$LJ" >/dev/null 2>&1 \
          && w5d "lite.json claudeMdExcludes 에 $HOME/.claude-team/CLAUDE.md 가 있음 — 좌석 규약(rules-lite)이 안 실린다(그 줄 삭제)"
      fi
      # 병합본 폴더 — claude-seat 래퍼가 만든다(있을 때만, 권한 700 이어야 한다)
      if [ -d "$TEAM/run" ]; then
        rp=$(stat -f %Lp "$TEAM/run" 2>/dev/null || stat -c %a "$TEAM/run" 2>/dev/null)
        [ "$rp" = 700 ] || w5d "~/.claude-team/run 권한이 700 아님(${rp:-?}) — chmod 700(래퍼가 exit 2 로 막는다)"
      fi
      [ -f "$TEAM/rules-lite.md" ] || w5d "좌석 규약 없음: ~/.claude-team/rules-lite.md (INSTALL.md 2단계)"
      # 옛 판 별칭 — append 가 남아 있으면 CLAUDE.md 링크와 겹쳐 rules-lite 가 두 번 실린다(셸 rc 를 읽기만 한다)
      for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$rc" ] || continue
        grep -E '^[[:space:]]*alias claude-team=' "$rc" 2>/dev/null | grep -qF -- '--append-system-prompt-file' \
          && w5d "$rc 의 claude-team 별칭에 --append-system-prompt-file 이 남아 있음 — CLAUDE.md 링크와 겹쳐 rules-lite 가 두 번 실린다(INSTALL.md 4단계)"
      done
      # bin — 설치된 것만 패키지와 대조(래퍼를 설치하지 않은 머신은 bin 이 없어도 된다)
      for f in "$MOD"/claude-team/bin/*; do
        b="$(basename "$f")"; [ -e "$TEAM/bin/$b" ] || continue
        cmp -s "$f" "$TEAM/bin/$b" || w5d "좌석 bin 내용이 패키지와 다름: ~/.claude-team/bin/$b"
      done
    fi
    # 전역 조항 — 킷판에 없는 「추가」 조항 머리가 라이브 CLAUDE.md 에 있는가(bootstrap 재실행으로 지워졌는지)
    if [ -f "$MOD/claude-md-clauses.md" ] && [ -f "$DEST/CLAUDE.md" ]; then
      while IFS= read -r h; do
        [ -n "$h" ] || continue
        grep -qF -- "$h" "$DEST/CLAUDE.md" || w5d "전역 조항 없음: ${h} (claude-md-clauses.md 「추가」 — bootstrap 재실행 뒤면 INSTALL.md 8단계 재수행)"
      done < <(awk '/^## 추가/{f=1;next} /^## /{f=0} f' "$MOD/claude-md-clauses.md" | grep -oE '^- \*\*[^*]+\*\*')
    fi
    # Paseo provider — config.json 에서 claude-team provider 키만 jq 로 읽는다(같은 폴더의 자격 증명 파일은 열지 않는다)
    PC="$HOME/.paseo/config.json"
    if [ -f "$PC" ] && command -v jq >/dev/null 2>&1; then
      if ! jq -e 'type=="object"' "$PC" >/dev/null 2>&1; then w5d "Paseo 설정을 JSON 으로 못 읽음 — provider 점검 생략"
      elif ! jq -e '.agents.providers["claude-team"] | type=="object"' "$PC" >/dev/null 2>&1; then
        w5d "Paseo 설정에 claude-team provider 없음 — Paseo 에서 좌석을 못 연다(INSTALL.md 9단계, Paseo 미사용이면 무시)"
      else
        # command 원소를 한 줄에 하나씩(배열이 아니면 빈 출력)
        pcmd=$(jq -r '.agents.providers["claude-team"].command | if type=="array" then .[] | tostring else empty end' "$PC" 2>/dev/null)
        # 래퍼는 필수 — 없으면 Paseo 가 붙이는 --settings 가 lite.json 을 덮거나(--settings 있음) lite.json 이 아예 안 실린다(없음)
        swrap=$(printf '%s\n' "$pcmd" | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' | grep -E '(^|/)claude-seat\.sh$' | head -1)  # 대입 원소(CLAUDE_SEAT_BIN=… 등)는 래퍼 후보에서 뺀다
        if [ -z "$swrap" ]; then
          if printf '%s\n' "$pcmd" | grep -qE '^--settings(=|$)'; then
            w5d "Paseo claude-team provider 가 claude-seat.sh 없이 --settings 를 넘김 — Paseo 가 붙이는 --settings 가 lite.json 을 덮는다(INSTALL.md 9단계)"
          else
            w5d "Paseo claude-team provider 에 claude-seat.sh 가 없음 — Paseo 좌석에 lite.json(전역 제외·auto memory off)이 안 실린다(INSTALL.md 9단계)"
          fi
        else
          # 래퍼가 있으면 래퍼 파일·CLAUDE_SEAT_BIN·CLAUDE_SEAT_LITE 가 모두 있어야 한다(하나라도 없으면 래퍼가 매 기동 exit 2)
          [ -f "$swrap" ] && [ -x "$swrap" ] || w5d "Paseo claude-team provider 의 claude-seat.sh 가 실행 파일이 아님($swrap) — INSTALL.md 9단계 래퍼 설치"
          # 래퍼 계약 = 두 값 모두 절대경로(아니면 exit 2), BIN 이 래퍼 자신이면 exit 2
          sbin=$(printf '%s\n' "$pcmd" | sed -n 's/^CLAUDE_SEAT_BIN=//p' | head -1)
          case "$sbin" in /*) sbin_ok=1 ;; *) sbin_ok=0 ;; esac
          [ "$sbin_ok" = 1 ] && [ -x "$sbin" ] && [ -f "$sbin" ] || w5d "Paseo claude-team provider 의 CLAUDE_SEAT_BIN 이 없거나 절대경로 실행 파일이 아님(${sbin:-없음}) — command -v claude 절대경로로(INSTALL.md 9단계)"
          [ -n "$sbin" ] && [ -e "$swrap" ] && [ "$sbin" -ef "$swrap" ] && w5d "Paseo claude-team provider 의 CLAUDE_SEAT_BIN 이 claude-seat.sh 자신을 가리킴 — 실 claude 경로로(INSTALL.md 9단계)"
          slite=$(printf '%s\n' "$pcmd" | sed -n 's/^CLAUDE_SEAT_LITE=//p' | head -1)
          case "$slite" in /*) slite_ok=1 ;; *) slite_ok=0 ;; esac
          [ "$slite_ok" = 1 ] && [ -f "$slite" ] && [ -r "$slite" ] || w5d "Paseo claude-team provider 의 CLAUDE_SEAT_LITE 가 없거나 읽을 수 있는 절대경로 파일이 아님(${slite:-없음}) — ~/.claude-team/lite.json 절대경로로(INSTALL.md 9단계)"
          # 순서 — 첫 원소가 env 이고 모든 대입(CLAUDE_CONFIG_DIR=·CLAUDE_SEAT_*=)과 -u 가 래퍼 원소보다 앞이어야 env 가 처리한다(뒤면 래퍼 인자가 된다)
          # ponytail: 순서·첫 원소만 본다(env 옵션 문법 전체는 미검증) / 업그레이드 = INSTALL 9단계 7원소 모양과 자리표시 대조
          jq -e '.agents.providers["claude-team"].command as $c
            | ($c | to_entries | map(select((.value|tostring) as $s | ($s|test("(^|/)claude-seat\\.sh$")) and ($s|test("^[A-Za-z_][A-Za-z0-9_]*=")|not))) | .[0].key) as $w
            | ($c | to_entries | map(select((.value|tostring|test("^[A-Za-z_][A-Za-z0-9_]*=")) or .value == "-u")) | map(.key) | max // -1) as $v
            | ($c[0]|tostring|test("(^|/)env$")) and $v < $w' "$PC" >/dev/null 2>&1 \
            || w5d "Paseo claude-team provider 원소 순서가 어긋남 — 첫 원소 env, -u 와 모든 NAME=값 대입(CLAUDE_CONFIG_DIR=·CLAUDE_SEAT_* 등)은 claude-seat.sh 앞(INSTALL.md 9단계)"
        fi
        printf '%s\n' "$pcmd" | grep -qF -- '--append-system-prompt-file' \
          && w5d "Paseo claude-team provider 에 --append-system-prompt-file 이 있음 — Paseo(SDK 경로)에선 무효다, 빼고 CLAUDE.md 링크로 싣는다(INSTALL.md 9단계)"
      fi
    else ok "Paseo 설정 없음 — provider 점검 생략(Paseo 를 쓰지 않는 머신이면 정상)"; fi
    [ "$n5d" = 0 ] && ok "팀 좌석 모듈 정합(훅·등록·링크·lite.json·bin·조항)"
  fi
fi

echo "=== [5e] 운영 DB MCP 확인창(destructive-cmd-ask) 등록 · 킷 실명 반출 ==="
# 훅 판정 = 서버명 규칙(소문자화해 -db 로 끝나고 개발 DB 접미사가 아니면 ask). 개발 DB 접미사 = 명시 목록(-dev-db·-devserver-db) —
#   destructive-cmd-ask.sh 의 제거 목록과 아래 awk 를 함께 고친다. matcher 가 그 이름을 안 받으면 훅이 아예 안 돈다(무음 소실).
# 대조 표본 = example-*-db 이름(실명 아님) — Claude Code matcher 를 정규식 전체일치로 근사해 jq test 로 본다.
# ponytail: matcher 의 단순 문자열(정규식 아님) 판정 규칙은 근사 / 오판이 관측되면 Claude Code 의 matcher 판정 규칙으로 맞춘다.
if [ -f "$DEST/settings.json" ] && command -v jq >/dev/null 2>&1; then
  dm="$(jq -r '[.hooks.PreToolUse[]? | select(any(.hooks[]?; (.command // "") | test("destructive-cmd-ask\\.sh"))) | (.matcher // "")] | .[]' "$DEST/settings.json" 2>/dev/null)"
  if [ -z "$dm" ]; then warn "destructive-cmd-ask 가 PreToolUse 에 등록돼 있지 않음 — 파괴 명령·운영 DB MCP 확인창 없음(bootstrap-machine.sh 재실행)"
  else
    miss="$(printf '%s\n' "$dm" | jq -Rr 'select(length > 0) as $m | ["Bash","mcp__example-real-db__q","mcp__example-prod-db__q","mcp__example-prd-db__q"] | map(select(test("^(" + $m + ")$") | not)) | .[]' 2>/dev/null | sort -u | tr '\n' ' ')"
    [ -z "$miss" ] && ok "destructive-cmd-ask matcher 가 Bash·운영 DB MCP(-db 규칙) 를 받음" \
      || warn "destructive-cmd-ask matcher 가 받지 않는 호출: ${miss}— 킷 matcher(Bash|mcp__.*-[Dd][Bb]__.*) 로 교체(bootstrap 의 matcher 교체 조건은 bootstrap-machine.sh 의 settings jq)"
  fi
else warn "settings.json/jq 없음 — destructive-cmd-ask 등록 확인 불가"; fi
# 실명 반출 — 이 머신의 MCP 서버명 중 규칙상 운영 DB 인 이름이 킷(추적 + 미추적·무시 제외)에 있으면 경고. 이름만 다루고 접속정보는 읽지 않는다.
if command -v jq >/dev/null 2>&1; then
  pnames="$( { jq -r '.. | objects | .mcpServers? // empty | objects | keys[]' "$HOME/.claude.json" 2>/dev/null
               for f in "${PROJECTS_DIR:-$HOME/projects}"/*/.mcp.json; do [ -f "$f" ] && jq -r '.mcpServers // {} | keys[]' "$f" 2>/dev/null; done; } \
             | awk '{l=tolower($0); gsub(/-(dev|devserver)-db$/, "", l)} l ~ /-db$/' | sort -u)"
  if [ -z "$pnames" ]; then ok "운영 DB MCP 서버명 없음(~/.claude.json·PROJECTS_DIR/*/.mcp.json) — 반출 검사 대상 없음"
  else
    if git -C "$KIT_DIR" rev-parse --git-dir >/dev/null 2>&1; then kfiles="$(cd "$KIT_DIR" && git ls-files -co --exclude-standard)"
    else kfiles="$(cd "$KIT_DIR" && find . -type f ! -path './.git/*' ! -name machine.env)"; fi
    leak="$(cd "$KIT_DIR" && printf '%s\n' "$kfiles" | tr '\n' '\0' | xargs -0 grep -IlF -e "$(printf '%s\n' "$pnames")" 2>/dev/null | tr '\n' ' ')"
    [ -z "$leak" ] && ok "킷 실명 반출 0건(운영 DB 서버명 $(printf '%s\n' "$pnames" | grep -c .)개 대조)" \
      || warn "킷에 운영 DB MCP 실명 잔존: ${leak}— example-* 로 바꾸거나 플레이스홀더로(실명 비반출)"
  fi
fi

echo "=== [5f] 킷 push 검사 훅(githooks/pre-push) · 실명 목록 ==="
# 경고만(FAIL 불변). hooksPath 는 원본 체크아웃 githooks 의 절대경로여야 한다 — 상대경로면 githooks 가 없는 worktree 에서
#   훅을 못 찾아 무검사로 push 된다. 목록 파일 내용은 출력하지 않는다 — 판정 = 읽기(없음 / 있는데 못 읽음·유무 판정 불가)
#   뒤 권한·형식(BOM·CR·빈 줄). 읽기 판정 짝 = githooks/pre-push 의 실명 목록 정제부(dir_blocked 포함).
# hooksPath 점검 대상 = $KIT_DIR 클론 + machine.env 의 PUBLIC_SNAPSHOT_DIR(공개 스냅샷 클론 — 비우면 확인 안 함 정보 줄).
#   기준은 클론마다 그 클론 원본 체크아웃(git-common-dir 의 상위)의 githooks 절대경로다.
if git -C "$KIT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  kcommon="$(cd "$KIT_DIR" && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)"
  want_hp="$(dirname "$kcommon")/githooks"
  hp="$(git -C "$KIT_DIR" config --get core.hooksPath 2>/dev/null || true)"
  case "$hp" in
    "") warn "킷 core.hooksPath 미설정 — push 검사 없음(실명 목록 먼저 → git -C <원본> config core.hooksPath $want_hp)" ;;
    /*) if [ "$(cd "$hp" 2>/dev/null && pwd -P)" = "$want_hp" ]; then ok "킷 core.hooksPath = 원본 체크아웃 githooks 절대경로"
        else warn "킷 core.hooksPath($hp)가 원본 체크아웃 githooks($want_hp)가 아님"; fi ;;
    *) warn "킷 core.hooksPath 가 상대경로($hp) — githooks 가 없는 worktree 에서 무검사 push(절대경로 $want_hp 로)" ;;
  esac
  if [ -f "$want_hp/pre-push" ]; then [ -x "$want_hp/pre-push" ] && ok "githooks/pre-push (+x)" || warn "githooks/pre-push 실행권한 없음(chmod +x)"
  else warn "원본 체크아웃에 githooks/pre-push 없음($want_hp)"; fi
else warn "킷이 git 체크아웃이 아님 — push 검사 훅 확인 생략"; fi
_tl() {  # 표시용 — 홈 절대경로 앞부분을 ~ 로($HOME 과 그 물리 경로(pwd -P) 둘 다)
  local tl='~' v ph; ph=$(cd "$HOME" 2>/dev/null && pwd -P) || ph=$HOME
  v=${1/#"$HOME"/$tl}; printf '%s' "${v/#"$ph"/$tl}"
}
PSD="${PUBLIC_SNAPSHOT_DIR:-}"
if [ -z "$PSD" ]; then ok "공개 스냅샷 클론 hooksPath 확인 안 함(정보) — machine.env 의 PUBLIC_SNAPSHOT_DIR 미설정"
elif ! git -C "$PSD" rev-parse --git-dir >/dev/null 2>&1; then warn "PUBLIC_SNAPSHOT_DIR($(_tl "$PSD"))가 git 클론이 아님 — 경로를 확인"
else
  [ -e "$PSD/.public-snapshot" ] || warn "공개 스냅샷 클론($(_tl "$PSD")) 루트에 .public-snapshot 없음 — 공개 레포 경로가 맞는지 확인"
  pcommon="$(cd "$PSD" && cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)"
  pwant="$(dirname "$pcommon")/githooks"
  php="$(git -C "$PSD" config --get core.hooksPath 2>/dev/null || true)"
  case "$php" in
    "") warn "공개 스냅샷 클론($(_tl "$PSD")) core.hooksPath 미설정 — push 검사 없음(실명 목록 먼저 → git -C <클론> config core.hooksPath $(_tl "$pwant"))" ;;
    /*) if [ "$(cd "$php" 2>/dev/null && pwd -P)" = "$pwant" ]; then ok "공개 스냅샷 클론 core.hooksPath = 그 클론 원본 체크아웃 githooks 절대경로"
        else warn "공개 스냅샷 클론 core.hooksPath($(_tl "$php"))가 그 클론 원본 체크아웃 githooks($(_tl "$pwant"))가 아님"; fi ;;
    *) warn "공개 스냅샷 클론 core.hooksPath 가 상대경로($(_tl "$php")) — githooks 가 없는 worktree 에서 무검사 push(절대경로 $(_tl "$pwant") 로)" ;;
  esac
  if [ -f "$pwant/pre-push" ]; then [ -x "$pwant/pre-push" ] || warn "공개 스냅샷 클론 githooks/pre-push 실행권한 없음(chmod +x)"
  else warn "공개 스냅샷 클론 원본 체크아웃에 githooks/pre-push 없음($(_tl "$pwant"))"; fi
fi
SNF="${SCRUB_NAMES_FILE:-$DEST/scrub-names.txt}"
dir_blocked() {  # $1 = 경로 → 가장 가까운 존재 조상이 탐색(x) 불가 디렉터리면 rc 0. 짝 = githooks/pre-push 의 같은 이름 함수
  local d=$1 up
  while up=$(dirname -- "$d") && [ "$up" != "$d" ]; do
    d=$up
    if [ -e "$d" ] || [ -L "$d" ]; then [ -d "$d" ] && [ ! -x "$d" ]; return; fi
  done
  return 1
}
if [ ! -e "$SNF" ] && [ ! -L "$SNF" ] && ! dir_blocked "$SNF"; then
  warn "실명 목록 없음($SNF) — pre-push 실명 검사가 꺼진다(공개 레포는 push 차단)"
elif [ ! -f "$SNF" ] || [ ! -r "$SNF" ]; then
  warn "실명 목록을 읽을 수 없음($SNF) — pre-push 가 모든 push 를 차단(읽을 수 있는 일반 파일인지·상위 디렉터리 탐색 권한을 확인)"
else
  sp=$(stat -f %Lp "$SNF" 2>/dev/null || stat -c %a "$SNF" 2>/dev/null)
  [ "$sp" = 600 ] && ok "실명 목록 권한 600" || warn "실명 목록 권한이 600 아님(${sp:-?}) — chmod 600 $SNF"
  sfmt=""
  [ "$(head -c 3 "$SNF" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = efbbbf ] && sfmt="$sfmt BOM"
  LC_ALL=C grep -q "$(printf '\r')" "$SNF" 2>/dev/null && sfmt="$sfmt CR"
  LC_ALL=C grep -qE '^[[:space:]]*$' "$SNF" 2>/dev/null && sfmt="$sfmt 빈줄"
  [ -s "$SNF" ] || sfmt="$sfmt 빈파일"
  if ! sed -e "1s/^$(printf '\357\273\277')//" "$SNF" 2>/dev/null | tr -d '\r' | LC_ALL=C grep -q '[^[:space:]]'; then
    warn "실명 목록이 비어 있음($SNF) — pre-push 실명 검사가 꺼진다(공개 레포는 push 차단)"
  elif [ -z "$sfmt" ]; then ok "실명 목록 형식 정상(BOM·CR·빈 줄 없음)"
  else warn "실명 목록 형식:${sfmt} — 훅은 정제해 쓰지만 원본을 정리하세요(한 줄에 하나)"; fi
fi

echo "=== [5g] 전역 deny 대조(라이브 vs 킷 템플릿 · 의도 차이 등록 = settings-deny-kit-only.txt) ==="
# 경고만(FAIL 불변) · 읽기 전용. permissions.deny 가 문자열 배열이 아니면(키 없음·다른 형·JSON 깨짐) 판정 불가 경고.
# 판정: 라이브에만 = 템플릿 반영 후보 / 템플릿에만 있고 미등록 = 등록 또는 라이브 반영 / 등록돼 있는데 템플릿에 없음 = 등록이 낡음.
#   등록 = 이 사용자가 라이브에서 뺀 규칙 목록이다 — 등록 항목이 라이브·템플릿에 다 있으면(킷 기본값 그대로) 경고가 아니라 ✓ 정보 줄.
# ponytail: 규칙을 줄 단위로 대조한다(개행이 든 deny 문자열은 쪼개진다) / 업그레이드 = jq 안에서 집합 연산
DREG="$KIT_DIR/settings-deny-kit-only.txt"
_deny() { jq -r 'if (.permissions.deny | type) == "array" and all(.permissions.deny[]; type == "string") then .permissions.deny[] else error("deny") end' "$1" 2>/dev/null; }
_dl() { local l tl='~'; printf '%s\n' "$1" | while IFS= read -r l; do printf ' [%s]' "${l//"$HOME"/$tl}"; done; }   # 홈 절대경로는 ~ 로
if ! command -v jq >/dev/null 2>&1; then warn "jq 없음 — 전역 deny 대조 판정 불가"
elif [ ! -f "$DEST/settings.json" ]; then warn "라이브 settings.json 없음 — 전역 deny 대조 판정 불가"
elif ! dlv="$(_deny "$DEST/settings.json")"; then warn "라이브 settings.json 의 permissions.deny 를 문자열 배열로 못 읽음(키 없음·형식·JSON) — 전역 deny 대조 판정 불가"
elif ! dtv="$(_deny "$TMPL")"; then warn "킷 템플릿 permissions.deny 를 문자열 배열로 못 읽음 — 전역 deny 대조 판정 불가"
elif [ ! -f "$DREG" ] || [ ! -r "$DREG" ]; then warn "의도 차이 등록 파일 없음·못 읽음(settings-deny-kit-only.txt) — 전역 deny 대조 판정 불가"
else
  dlv="$(printf '%s\n' "$dlv" | LC_ALL=C sort -u | grep -v '^$')"; dtv="$(printf '%s\n' "$dtv" | LC_ALL=C sort -u | grep -v '^$')"
  drg="$(grep -v -e '^#' -e '^$' "$DREG" | LC_ALL=C sort -u)"
  d_a="$(LC_ALL=C comm -23 <(printf '%s\n' "$dlv") <(printf '%s\n' "$dtv") | grep -v '^$')"
  d_b="$(LC_ALL=C comm -13 <(printf '%s\n' "$dlv") <(printf '%s\n' "$dtv") | LC_ALL=C comm -23 - <(printf '%s\n' "$drg") | grep -v '^$')"
  d_c="$(LC_ALL=C comm -12 <(printf '%s\n' "$drg") <(printf '%s\n' "$dlv") | LC_ALL=C comm -12 - <(printf '%s\n' "$dtv") | grep -v '^$')"
  d_c2="$(LC_ALL=C comm -23 <(printf '%s\n' "$drg") <(printf '%s\n' "$dtv") | grep -v '^$')"
  [ -n "$d_a" ] && warn "deny 라이브에만:$(_dl "$d_a") — 킷 템플릿(global/settings.json.template) 반영 후보"
  [ -n "$d_b" ] && warn "deny 템플릿에만(의도 차이 미등록):$(_dl "$d_b") — 의도면 settings-deny-kit-only.txt 에 등록, 아니면 라이브에 반영"
  [ -n "$d_c" ] && ok "등록된 의도 차이 중 이 머신 라이브에 있는 것:$(_dl "$d_c") — 킷 기본값 그대로(새 머신이면 정상)"
  [ -n "$d_c2" ] && warn "deny 등록이 낡음(템플릿에 없음):$(_dl "$d_c2") — settings-deny-kit-only.txt 에서 삭제"
  [ -z "$d_a$d_b$d_c2" ] && ok "전역 deny 정합(라이브 $(printf '%s\n' "$dlv" | grep -c .) · 템플릿 $(printf '%s\n' "$dtv" | grep -c .) · 등록된 의도 차이 $(printf '%s\n' "$drg" | grep -c .))"
fi

echo "=== [6] JVM 빌드 관문(선택) ==="
if [ -n "${MAVEN_REPO:-}" ]; then :; else MAVEN_REPO="$HOME/maven_repo/maven/repository"; fi
[ -d "$MAVEN_REPO" ] && ok "maven 로컬레포 존재($MAVEN_REPO)" || warn "maven 오프라인 레포 없음($MAVEN_REPO) — eGov 오프라인 빌드 시 필요(SETUP.md 참조)"

echo "=== [7] Playwright 시각검증 의존(선택) ==="
PV="$DEST/skills/playwright-verify"
if [ -d "$PV" ]; then
  [ -d "$PV/node_modules" ] && ok "playwright node_modules 설치됨" || warn "playwright 의존 미설치 — 시각검증 쓰려면: (cd $PV && npm ci && npx playwright install chromium)"
else warn "playwright-verify 스킬 없음"; fi

echo "=== [8] Java LSP(jdtls, 선택) ==="
SHIM="$HOME/.local/bin/jdtls"
BREW_JDTLS=""
for c in /opt/homebrew/bin/jdtls /usr/local/bin/jdtls; do [ -x "$c" ] && BREW_JDTLS="$c" && break; done
if [ -n "$BREW_JDTLS" ]; then
  ok "jdtls 바이너리($BREW_JDTLS)"
  [ -x "$SHIM" ] && ok "jdtls 심 설치됨(~/.local/bin/jdtls)" || warn "jdtls 심 없음 — bootstrap-machine.sh 재실행(JAVA_HOME21+Lombok 주입 심)"
  res="$(command -v jdtls 2>/dev/null || true)"
  [ "$res" = "$SHIM" ] && ok "PATH 선순위 정상(심이 brew보다 앞)" || warn "PATH에서 심이 아닌 jdtls가 잡힘(${res:-없음}) — ~/.local/bin 을 PATH 앞에 두기(구버전 JAVA_HOME이면 기동 실패·Lombok 미주입)"
  if [ -x /usr/libexec/java_home ]; then
    /usr/libexec/java_home -v 21 >/dev/null 2>&1 && ok "Java 21+ 존재(jdtls 런타임)" || warn "Java 21+ 없음 — jdtls 기동 불가(예: brew install --cask zulu@21)"
  fi
else warn "jdtls 없음 — Java LSP 쓰려면 SETUP.md 11절(brew install jdtls + jdtls-lsp 플러그인)"; fi

echo "=== [9] 상시 로드 규약 크기 · 백업(.bak) 잔존 (비차단 경고) ==="
# 전역 CLAUDE.md 는 매 세션 무조건 로드되는 고정비 — 상한(기본 20KB)을 넘으면 경고만 한다(축소는 사용자 승인 후·유실 대조표 필수).
RULES_MAX_KB="${RULES_MAX_KB:-20}"
if [ -f "$DEST/CLAUDE.md" ]; then
  rsz=$(wc -c < "$DEST/CLAUDE.md" | tr -d ' ')
  if [ "$rsz" -gt $((RULES_MAX_KB * 1024)) ]; then warn "전역 CLAUDE.md ${rsz}B > ${RULES_MAX_KB}KB — 규칙 문장+포인터 3줄로 줄이고 서사는 rules-rationale/ 로(승인 후)"
  else ok "전역 CLAUDE.md ${rsz}B (≤ ${RULES_MAX_KB}KB)"; fi
fi
# .bak 은 편집 직후의 안전망일 뿐 — 원본은 킷 git 이 보존한다. 오래 남으면 드리프트 대조(위 [5])의 잡음이 된다.
bak_n=$(find "$DEST/hooks" "$DEST/agents" "$DEST/rules-rationale" "$DEST/skills" -maxdepth 2 -name '*.bak*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$bak_n" -gt 0 ]; then warn "라이브 .bak 잔존 ${bak_n}개 — 원본이 킷 git 에 있으면 정리(사용자 확인 후): find ~/.claude/{hooks,agents,rules-rationale,skills} -maxdepth 2 -name '*.bak*'"
else ok ".bak 잔존 없음"; fi

echo
echo "(설치·등록 검진만 수행 — 훅 판정 로직의 동작 검증은: ./test-hooks.sh)"
[ "$FAIL" = 0 ] && echo "== 결과: 정상(경고는 스택/선택 항목) ==" || echo "== 결과: 문제 있음(위 ✗ 조치) =="
exit $FAIL