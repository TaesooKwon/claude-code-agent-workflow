#!/usr/bin/env bash
# bootstrap-machine.sh settings.json 병합 시험 — 킷 추적 파일 사본 + 가짜 HOME(케이스마다 하나)으로 bootstrap 을 돌려
# 기존 settings.json 이 있을 때 템플릿의 훅 등록이 빠짐없이 들어가는지, 기존 항목·사용자 설정이 보존되는지,
# 재실행이 동일인지, 이상 형식이면 기존 파일을 그대로 두고 안내하는지 본다.
# 실제 ~/.claude·킷 machine.env 는 쓰지 않는다(machine.env = 사본에서 init-machine-env.sh 로 생성).
# 등록 판정(이벤트·스크립트 파일명)은 doctor [5b] 와 같은 추출(command 의 마지막 '/' 뒤) — bootstrap 의 추출식과 독립.
#   BOOTSTRAP_SRC=<파일>  사본의 bootstrap-machine.sh 를 이 파일로 바꿔 돈다(수리 전 판 재현용)
#   KEEP_TMP=1            임시 폴더를 지우지 않고 경로만 출력
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d /private/tmp/bsm.XXXXXX 2>/dev/null || mktemp -d /tmp/bsm.XXXXXX) || exit 1
case "$ROOT" in /Users/*|/home/*) echo "✗ 가짜 HOME 경로가 홈 아래: $ROOT" >&2; exit 2 ;; esac
if [ "${KEEP_TMP:-0}" = 1 ]; then echo "임시 폴더 유지: $ROOT"
else trap 'case "$ROOT" in */bsm.*) rm -rf "$ROOT" ;; esac' EXIT; fi
K="$ROOT/kit"; mkdir -p "$K" "$ROOT/h0/projects"
T=0; F=0
ok() { T=$((T + 1)); echo "  ✓ $1"; }
ng() { T=$((T + 1)); F=$((F + 1)); echo "  ✗ $1"; }
chk() { if eval "$2"; then ok "$1"; else ng "$1"; fi; }

( cd "$HERE" && git ls-files -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf - ) | tar -xf - -C "$K" || { echo "✗ 사본 실패" >&2; exit 1; }
[ -n "${BOOTSTRAP_SRC:-}" ] && cp "$BOOTSTRAP_SRC" "$K/bootstrap-machine.sh"
HOME="$ROOT/h0" bash "$K/init-machine-env.sh" >/dev/null 2>&1 || { echo "✗ init-machine-env.sh 실패" >&2; exit 1; }
[ -f "$K/machine.env" ] || { echo "✗ machine.env 생성 안 됨" >&2; exit 1; }
TMPL="$K/global/settings.json.template"

# $1 = 케이스(가짜 HOME 이름) · $2 = 선생성 settings.json 내용 · $3.. = bootstrap 인자 → rc 는 $ROOT/<케이스>.rc, 출력 $ROOT/<케이스>.out
setup() { mkdir -p "$ROOT/$1/.claude"; printf '%s' "$2" > "$ROOT/$1/.claude/settings.json"; cp "$ROOT/$1/.claude/settings.json" "$ROOT/$1.orig"; }
boot() { local c="$1"; shift; HOME="$ROOT/$c" bash "$K/bootstrap-machine.sh" "$@" > "$ROOT/$c.out" 2>&1; echo $? > "$ROOT/$c.rc"; }
S() { printf '%s' "$ROOT/$1/.claude/settings.json"; }
# 등록 집합 = "이벤트 파일명" 줄(정렬, 중복 유지)
regs() { jq -r '.hooks | to_entries[] | .key as $e | .value[] | .hooks[]? | (.command // "") | split("/") | last | sub("[^A-Za-z0-9._-]+$"; "") | select(test("\\.(sh|py|js|mjs)$")) | "\($e) \(.)"' "$1" | sort; }
TSET="$(regs "$TMPL")"
[ -n "$TSET" ] || { echo "✗ 템플릿 등록 0건 — 판정 불가" >&2; exit 1; }

echo "── ⓐ settings.json = '{}' 선생성"
setup a '{}'; boot a
chk "ⓐ rc 0" '[ "$(cat "$ROOT/a.rc")" = 0 ]'
chk "ⓐ 등록 집합 = 템플릿 등록 집합" '[ "$(regs "$(S a)" | sort -u)" = "$(printf "%s\n" "$TSET" | sort -u)" ]'
chk "ⓐ 중복 등록 0" '[ -z "$(regs "$(S a)" | uniq -d)" ]'
HOME="$ROOT/a" SCRUB_NAMES_FILE="$ROOT/none" bash "$K/doctor.sh" > "$ROOT/a.doctor" 2>&1
for ev in Stop PreToolUse PostToolUse SessionStart; do
  chk "ⓐ doctor [5b] hooks.$ev 등록 집합 정합" 'grep -qF "✓ hooks.$ev 등록 집합 정합" "$ROOT/a.doctor"'
done

echo "── ⓑ·ⓓ 일부만 등록(hook-obs 래퍼 형태 포함) + 사용자 고유 설정"
# hook-obs 래퍼 형태 = 라이브 settings.json 의 command 꼴($1 = 래퍼 뒤 인터프리터 접두 — destructive-cmd-ask 는 'bash ')
cmd_obs() { printf 'W=$HOME/.claude/hooks/hook-obs.sh; bash -n "$W" 2>/dev/null && exec bash "$W" %s~/.claude/hooks/%s || exec %s~/.claude/hooks/%s' "$1" "$2" "$1" "$2"; }
B=$(jq -n --arg gp "$(cmd_obs '' git-push-guard.sh)" --arg am "$ROOT/b/.claude/hooks/mvn-am-guard.sh" \
  --arg dc "$(cmd_obs 'bash ' destructive-cmd-ask.sh)" --arg tw "$(cmd_obs '' twin-file-reminder.sh)" '
{statusLine:{type:"command",command:"node /opt/x/hud.js"},
 permissions:{allow:["Bash(ls:*)"],deny:["Bash(my-own-deny)"]},
 hooks:{
  PreToolUse:[
   {matcher:"Read",hooks:[{type:"command",command:"/opt/u/my-own.sh"}]},
   {matcher:"Bash",hooks:[{type:"command",command:$gp},{type:"command",command:$am,timeout:7}]},
   {matcher:"Bash",hooks:[{type:"command",command:$dc}]}
  ],
  PostToolUse:[{matcher:"Write|Edit",hooks:[{type:"command",command:$tw}]}],
  UserPromptSubmit:[{hooks:[{type:"command",command:"/opt/u/user-prompt.sh"}]}]
 },
 model:"opus"}')
setup b "$B"; jq -e . "$(S b)" >/dev/null || { echo "✗ ⓑ 입력 JSON 오류" >&2; exit 1; }
boot b
chk "ⓑ rc 0" '[ "$(cat "$ROOT/b.rc")" = 0 ]'
WANT="$(printf '%s\nPreToolUse my-own.sh\nUserPromptSubmit user-prompt.sh\n' "$TSET" | sort -u)"
chk "ⓑ 등록 집합 = 템플릿 ∪ 사용자 고유" '[ "$(regs "$(S b)" | sort -u)" = "$WANT" ]'
chk "ⓑ 중복 등록 0" '[ -z "$(regs "$(S b)" | uniq -d)" ]'
chk "ⓑ 기존 PreToolUse[0](사용자 Read 그룹) 그대로" '[ "$(jq -c ".hooks.PreToolUse[0]" "$(S b)")" = "$(jq -c ".hooks.PreToolUse[0]" "$ROOT/b.orig")" ]'
chk "ⓑ 기존 PreToolUse[1](hook-obs git-push·timeout 붙은 mvn-am) 그대로" '[ "$(jq -c ".hooks.PreToolUse[1]" "$(S b)")" = "$(jq -c ".hooks.PreToolUse[1]" "$ROOT/b.orig")" ]'
KM="$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | test("destructive-cmd-ask"))) | .matcher' "$TMPL")"
chk "ⓑ destructive-cmd-ask 등록 1개·자리 [2]·matcher = 킷 것·command 그대로" '[ "$(jq "[.hooks.PreToolUse[].hooks[] | select(.command | test(\"destructive-cmd-ask\"))] | length" "$(S b)")" = 1 ] && [ "$(jq -r ".hooks.PreToolUse[2].matcher" "$(S b)")" = "$KM" ] && [ "$(jq -c ".hooks.PreToolUse[2].hooks" "$(S b)")" = "$(jq -c ".hooks.PreToolUse[2].hooks" "$ROOT/b.orig")" ]'
chk "ⓑ 기존 PostToolUse[0] 그대로" '[ "$(jq -c ".hooks.PostToolUse[0]" "$(S b)")" = "$(jq -c ".hooks.PostToolUse[0]" "$ROOT/b.orig")" ]'
chk "ⓑ 백업 .bak-<시각> = 원본" 'bk=$(ls "$ROOT/b/.claude/" | grep "^settings.json.bak-" | head -1); [ -n "$bk" ] && cmp -s "$ROOT/b/.claude/$bk" "$ROOT/b.orig"'
for k in statusLine permissions.allow permissions.deny hooks.UserPromptSubmit model; do
  chk "ⓓ $k 보존" '[ "$(jq -c ".$k" "$(S b)")" = "$(jq -c ".$k" "$ROOT/b.orig")" ]'
done

echo "── ⓒ 재실행 = 동일"
for c in a b; do
  cp "$(S $c)" "$ROOT/$c.after1"; nb=$(ls "$ROOT/$c/.claude/" | grep -c '^settings.json.bak-'); boot "$c"
  chk "ⓒ $c 재실행 '= 동일  settings.json'·파일 불변·새 백업 없음" 'grep -qF "= 동일  settings.json" "$ROOT/$c.out" && cmp -s "$(S $c)" "$ROOT/$c.after1" && [ "$(ls "$ROOT/$c/.claude/" | grep -c "^settings.json.bak-")" = "$nb" ]'
done

echo "── DRY(--dry-run) = 쓰기 0·추가 항목 안내"
setup r '{}'; boot r --dry-run
chk "DRY rc 0·settings.json 불변" '[ "$(cat "$ROOT/r.rc")" = 0 ] && cmp -s "$(S r)" "$ROOT/r.orig"'
chk "DRY 안내에 추가될 등록(PreToolUse:git-push-guard.sh) 표시" 'grep "\[dry\] settings.json" "$ROOT/r.out" | grep -qF "PreToolUse:git-push-guard.sh"'

echo "── ⓔ 이상 형식 = 기존 파일 불변·안내·중단 없음"
i=0
for bad in '{"hooks":[]}' '{"hooks":{"PreToolUse":{}}}' '{"hooks":{"PreToolUse":["str"]}}' '[]' '' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":"x"}]}}'; do
  i=$((i + 1)); c="e$i"; setup "$c" "$bad"; boot "$c"
  chk "ⓔ$i [$bad] 기존 파일 불변" 'cmp -s "$(S $c)" "$ROOT/$c.orig"'
  chk "ⓔ$i [$bad] rc 0·완료까지 진행·✗ 갱신 실패 안내" '[ "$(cat "$ROOT/$c.rc")" = 0 ] && grep -qF "=== 완료" "$ROOT/$c.out" && grep -qF "✗ settings.json 갱신 실패" "$ROOT/$c.out"'
done

echo "결과: ${T}건 중 실패 ${F}건"
[ "$F" -eq 0 ]
