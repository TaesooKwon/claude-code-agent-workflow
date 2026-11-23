#!/usr/bin/env bash
# kit-drift-check.sh 반증 테스트(세션 분기 + 전역 층 + 큐 + 레포 절 회귀) — 임시 디렉터리의 가짜 HOME 에서만 돈다(실제 ~/.claude 는 H 를 비웠을 때의 훅 경로로만 쓴다).
unset CLAUDE_CONFIG_DIR KIT_DIR   # 좌석에서 돌려도 좌석 env 를 물려받지 않는다(좌석 케이스는 runx 가 명시로 넣는다)
H=${H:-$HOME/.claude/hooks/kit-drift-check.sh}; H="$(cd "$(dirname "$H")" && pwd)/$(basename "$H")"   # runx 가 cd 하므로 절대경로로
KITROOT=$(cd "$(dirname "$0")" && pwd); S=$(mktemp -d)/kdc || { echo '임시 디렉터리 생성 실패 — 실행하지 않았다'; exit 2; }
trap 'case "${S%/kdc}" in /tmp/?*|/private/tmp/?*|/var/folders/?*|/private/var/folders/?*) rm -rf "${S%/kdc}" ;; esac' EXIT
rm -rf "$S"; mkdir -p "$S"
pass=0; fail=0
chk() { # 이름 기대(empty|문자열) 출력
  local name="$1" want="$2" out="$3"
  if [ "$want" = "empty" ]; then
    if [ -z "$out" ]; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); echo "FAIL $name — 출력 있음: ${out:0:200}"; fi
  else
    if printf '%s' "$out" | grep -qF -- "$want"; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); echo "FAIL $name — '$want' 없음: ${out:0:300}"; fi
  fi
}
gitc() { git -c user.name=t -c user.email=t@t "$@"; }
fresh() { # 새 가짜 HOME + 킷(git 레포, 원본 체크아웃 = $2, 기본 $d/kit) + 프로젝트 $d/proj = 킷의 worktree(훅 폴더 없음)
  local d="$S/$1" k="${2:-$S/$1/kit}"; mkdir -p "$d/home/.claude/rules-rationale" "$k/global/rules-rationale"
  printf -- '- **조항A** 본문\n- **조항B** 본문\n' > "$d/home/.claude/CLAUDE.md"
  cp "$d/home/.claude/CLAUDE.md" "$k/global/CLAUDE.md"
  printf '# a\n## 절1\n본문\n' > "$d/home/.claude/rules-rationale/a.md"
  cp "$d/home/.claude/rules-rationale/a.md" "$k/global/rules-rationale/a.md"
  git -C "$k" init -q 2>/dev/null && git -C "$k" add -A && gitc -C "$k" commit -qm init && git -C "$k" worktree add -q "$d/proj" 2>/dev/null \
    || echo "fresh 실패: $1" >&2
  echo "$d"
}
# runx <d> <프로젝트> [KIT_DIR — '-' 면 미설정] [CLAUDE_CONFIG_DIR] — 훅은 프로젝트 디렉터리를 cwd 로 돈다(실제 SessionStart 와 같은 자리).
runx() {
  local d="$1" p="$2" k="${3:-$1/kit}" c="${4:-}"
  ( cd "$p" 2>/dev/null || cd "$d" || exit 9
    export HOME="$d/home" CLAUDE_PROJECT_DIR="$p"
    if [ "$k" = - ]; then unset KIT_DIR; else export KIT_DIR="$k"; fi
    if [ -n "$c" ]; then export CLAUDE_CONFIG_DIR="$c"; fi
    bash "$H" )
}
run() { runx "$1" "$1/proj" "${2:-$1/kit}"; }

d=$(fresh t1); chk "T1 동일 → 무출력" empty "$(run "$d")"
d=$(fresh t2); printf -- '- **조항X** 새것\n' >> "$d/home/.claude/CLAUDE.md"; chk "T2 라이브에만 조항 → 보고" "조항X" "$(run "$d")"
d=$(fresh t3); printf -- '- **조항X** 새것\n' >> "$d/home/.claude/CLAUDE.md"; printf '# 주석\n- **조항X**\n' > "$d/kit/kit-drift-exclude.txt"; chk "T3 제외 목록 → 무출력" empty "$(run "$d")"
d=$(fresh t3b); printf -- '- **조항Y** 킷만\n' >> "$d/kit/global/CLAUDE.md"; chk "T3b 킷에만 조항 → 보고" "조항Y" "$(run "$d")"
d=$(fresh t4); printf '## 절2\n추가\n' >> "$d/home/.claude/rules-rationale/a.md"; chk "T4 절 수 차이 → 보고" "a.md(절 수)" "$(run "$d")"
d=$(fresh t4b); printf '추가 문단만\n' >> "$d/home/.claude/rules-rationale/a.md"; chk "T4b 문단만 추가 → 무출력(알려진 한계)" empty "$(run "$d")"
d=$(fresh t5); echo x > "$d/home/.claude/rules-rationale/b.md"; echo y > "$d/kit/global/rules-rationale/c.md"; o=$(run "$d"); chk "T5 킷없음" "b.md(킷없음)" "$o"; chk "T5 라이브없음" "c.md(라이브없음)" "$o"
d=$(fresh t5b); echo x > "$d/home/.claude/rules-rationale/b.md"; printf 'rules-rationale/b.md\n' > "$d/kit/kit-drift-exclude.txt"; chk "T5b 파일 제외 → 무출력" empty "$(run "$d")"
d=$(fresh t6); printf -- '- **조항X**\n' >> "$d/home/.claude/CLAUDE.md"; run "$d" >/dev/null; chk "T6 같은 날 재실행 → 무출력" empty "$(run "$d")"
d=$(fresh t7); o=$(run "$d" "$d/없는킷"); rc=$?; chk "T7 킷 없음 → 무출력" empty "$o"; [ $rc -eq 0 ] && { pass=$((pass+1)); echo "PASS T7 exit 0"; } || { fail=$((fail+1)); echo "FAIL T7 exit $rc"; }
# T8 레포 절 회귀 — 가짜 scaffold 훅과 레포 훅이 다르면 기존 보고가 그대로 나오고, 전역 차이가 있으면 두 절이 합쳐진다.
d=$(fresh t8); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/x.sh"
o=$(run "$d"); chk "T8 레포 절만" "로직 차이 1: x.sh" "$o"
printf '%s' "$o" | grep -q '전역 층' && { fail=$((fail+1)); echo "FAIL T8 전역 절이 섞임"; } || { pass=$((pass+1)); echo "PASS T8 전역 절 없음"; }
d=$(fresh t8b); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/x.sh"; printf -- '- **조항X**\n' >> "$d/home/.claude/CLAUDE.md"
o=$(run "$d"); chk "T8b 두 절 합침(레포)" "로직 차이 1: x.sh" "$o"; chk "T8b 두 절 합침(전역)" "조항X" "$o"
printf '%s' "$o" | jq -e . >/dev/null 2>&1 && { pass=$((pass+1)); echo "PASS T8b JSON 유효"; } || { fail=$((fail+1)); echo "FAIL T8b JSON 무효"; }
# T10 승인 지문 — 레포 .claude/kit-drift-accepted.txt 의 지문이 맞으면 무출력, 한쪽이 바뀌어 지문이 어긋나면 다시 보고한다.
d=$(fresh t10); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/x.sh"
o=$(run "$d"); chk "T10 미등록 → 지문 출력" "로직 차이 지문" "$o"
printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext' | sed -n '/로직 차이 지문/,$p' | tail -n +2 | sed 's/^  //; s/$/ # 사유/' > "$d/proj/.claude/kit-drift-accepted.txt"
rm -f "$d/home/.claude/.kit-drift-check"*
chk "T10 등록 → 무출력" empty "$(run "$d")"
echo 'echo 레포2' > "$d/proj/.claude/hooks/x.sh"; rm -f "$d/home/.claude/.kit-drift-check"*
chk "T10b 레포 변경 → 재보고" "로직 차이 1: x.sh" "$(run "$d")"
# T11~T14 systemMessage — 보고가 있으면 사용자 화면용 요약 한 줄(수치·다음 행동, 파일명·해시 없음), 없으면 출력 자체가 없다.
sm() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>/dev/null; }
d=$(fresh t11); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/x.sh"
echo 'echo 킷만' > "$d/home/.claude/agent-scaffold/claude/hooks/k.sh"
o=$(sm "$(run "$d")")
chk "T11 레포 차이 → systemMessage 요약" "[킷 드리프트] proj: 로직 차이 1 · 킷에만 1 · 레포에만 0" "$o"
chk "T11 다음 행동 안내" "킷 드리프트 방향 제안해" "$o"
printf '%s' "$o" | grep -qE 'x\.sh|k\.sh|[0-9a-f]{32}' && { fail=$((fail+1)); echo "FAIL T11 파일명·해시 노출"; } || { pass=$((pass+1)); echo "PASS T11 파일명·해시 없음"; }
[ "$(printf '%s\n' "$o" | grep -c .)" = 1 ] && { pass=$((pass+1)); echo "PASS T11 한 줄"; } || { fail=$((fail+1)); echo "FAIL T11 줄 수 $(printf '%s\n' "$o" | grep -c .)"; }
d=$(fresh t12); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 같음' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; cp "$d/home/.claude/agent-scaffold/claude/hooks/x.sh" "$d/proj/.claude/hooks/x.sh"
chk "T12 차이 없음 → 무출력(systemMessage 없음)" empty "$(run "$d")"
d=$(fresh t13); printf -- '- **조항X** 새것\n- **조항Z** 새것\n' >> "$d/home/.claude/CLAUDE.md"
chk "T13 전역 층만 → 전역 요약" "[킷 드리프트·전역] 라이브에만 조항 2 · 킷에만 조항 0 · 근거 문서 차이 0" "$(sm "$(run "$d")")"
d=$(fresh t14); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/x.sh"; printf -- '- **조항X**\n' >> "$d/home/.claude/CLAUDE.md"
o=$(sm "$(run "$d")"); chk "T14 두 층 → 레포 요약" "[킷 드리프트] proj: 로직 차이 1" "$o"; chk "T14 두 층 → 전역 요약" "[킷 드리프트·전역] 라이브에만 조항 1" "$o"
# T15 의도적 미설치(MISSING 지문) — 킷 해시가 맞으면 "킷에만 있음"에서 빠지고, 킷이 바뀌거나 줄 형식이 깨지면 다시 뜬다.
d=$(fresh t15); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 공통' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; cp "$d/home/.claude/agent-scaffold/claude/hooks/x.sh" "$d/proj/.claude/hooks/x.sh"
echo 'echo 킷만' > "$d/home/.claude/agent-scaffold/claude/hooks/k.sh"
o=$(run "$d"); chk "T15 미등록 → 킷에만 1 + MISSING 지문 안내" "k.sh MISSING " "$o"
printf '%s' "$o" | jq -r '.hookSpecificOutput.additionalContext' | sed -n '/킷에만 있음 지문/,$p' | tail -n +2 | grep MISSING | sed 's/^  //; s/$/  # 미설치 판정/' > "$d/proj/.claude/kit-drift-accepted.txt"
rm -f "$d/home/.claude/.kit-drift-check"*
chk "T15 등록 + 킷 해시 일치 → 무출력" empty "$(run "$d")"
echo 'echo 킷만 v2' > "$d/home/.claude/agent-scaffold/claude/hooks/k.sh"; rm -f "$d/home/.claude/.kit-drift-check"*
chk "T15b 킷 파일 변경(해시 불일치) → 다시 킷에만 1" "킷에만 있음 1: k.sh" "$(run "$d")"
d=$(fresh t15c); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
echo 'echo 킷만' > "$d/home/.claude/agent-scaffold/claude/hooks/k.sh"; echo 'echo 레포' > "$d/proj/.claude/hooks/r.sh"
h=$(md5 -q "$d/home/.claude/agent-scaffold/claude/hooks/k.sh" 2>/dev/null || md5sum "$d/home/.claude/agent-scaffold/claude/hooks/k.sh" | cut -d' ' -f1)
printf 'k.sh MISSING %s\n' "$(printf '%s' "$h" | tr 'a-f' 'A-F')" > "$d/proj/.claude/kit-drift-accepted.txt"   # 대문자 hex = 형식 위반
printf 'k.sh MISSING nothex\n' >> "$d/proj/.claude/kit-drift-accepted.txt"
chk "T15c 형식 깨진 MISSING 줄 → 무시(여전히 킷에만 1)" "킷에만 있음 1: k.sh" "$(run "$d")"
printf 'k.sh MISSING %s  # 사유\n' "$h" > "$d/proj/.claude/kit-drift-accepted.txt"; rm -f "$d/home/.claude/.kit-drift-check"*
o=$(run "$d"); chk "T15d 등록분은 요약 수치에서도 빠짐" "[킷 드리프트] proj: 로직 차이 0 · 킷에만 0 · 레포에만 1" "$(sm "$o")"
# T16 자리표시자 정규화 — 킷 {{NAME}} 을 레포 줄과 맞대어 값을 추론·치환한 뒤 같으면 차이 아님. 실로직 차이·값 충돌은 여전히 보고.
d=$(fresh t16); mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/proj/.claude/hooks"
printf '#!/bin/bash\ncd "{{ROOT}}" || exit 0\nmvn -q test -pl {{MODULE_CORE}} -am\necho done\n' > "$d/home/.claude/agent-scaffold/claude/hooks/p.sh"
printf '#!/bin/bash\ncd "/work/repoA" || exit 0\nmvn -q test -pl Core-A -am\necho done\n' > "$d/proj/.claude/hooks/p.sh"
chk "T16 자리표시자만 다름 → 차이 없음(무출력)" empty "$(run "$d")"
printf '#!/bin/bash\ncd "/work/repoA" || exit 0\nmvn -q test -pl Core-A -am\necho changed\n' > "$d/proj/.claude/hooks/p.sh"; rm -f "$d/home/.claude/.kit-drift-check"*
chk "T16b 자리표시자 없는 줄의 실로직 차이 → 보고" "로직 차이 1: p.sh" "$(run "$d")"
printf '#!/bin/bash\ncd "{{ROOT}}" || exit 0\nls "{{ROOT}}/x"\necho done\n' > "$d/home/.claude/agent-scaffold/claude/hooks/p.sh"
printf '#!/bin/bash\ncd "/work/repoA" || exit 0\nls "/work/repoB/x"\necho done\n' > "$d/proj/.claude/hooks/p.sh"; rm -f "$d/home/.claude/.kit-drift-check"*
chk "T16c 같은 자리표시자가 줄마다 다른 값(충돌) → 보고" "로직 차이 1: p.sh" "$(run "$d")"
printf '#!/bin/bash\ncd "{{ROOT}}" || exit 0\nmvn -q test -pl {{MODULE_CORE}} -am\necho done\n' > "$d/home/.claude/agent-scaffold/claude/hooks/p.sh"
printf '#!/bin/bash\ncd "/work/repoA" || exit 0\nmvn -q test -pl Core-A -am -o\necho done\n' > "$d/proj/.claude/hooks/p.sh"; rm -f "$d/home/.claude/.kit-drift-check"*
chk "T16d 자리표시자 줄의 실로직 차이(-o 추가) → 보고" "로직 차이 1: p.sh" "$(run "$d")"
# T17 lib/*.py 모집단 — 판정기(lib/cmdform.py 등)도 대조한다. 키 = `lib/<파일>`, 주석·shebang 만 다르면 차이 아님.
kp() { local d="$1"; mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks/lib" "$d/proj/.claude/hooks/lib"
  printf '#!/usr/bin/env python3\n# 판정기\nLIMIT_SEC = 5\nprint("a # b")\n' > "$d/home/.claude/agent-scaffold/claude/hooks/lib/cmdform.py"; }
d=$(fresh t17); kp "$d"
chk "T17 레포에 lib/cmdform.py 없음 → 킷에만 있음" "킷에만 있음 1: lib/cmdform.py" "$(run "$d")"
d=$(fresh t17b); kp "$d"; printf '#!/usr/bin/env python3\n# 판정기\nLIMIT_SEC = 9\nprint("a # b")\n' > "$d/proj/.claude/hooks/lib/cmdform.py"
chk "T17b 내용 다름(파이썬 대입값) → 로직 차이" "로직 차이 1: lib/cmdform.py" "$(run "$d")"
d=$(fresh t17c); kp "$d"; cp "$d/home/.claude/agent-scaffold/claude/hooks/lib/cmdform.py" "$d/proj/.claude/hooks/lib/cmdform.py"
chk "T17c 같음 → 무출력" empty "$(run "$d")"
d=$(fresh t17d); kp "$d"; printf '#!/usr/bin/python3\n# 판정기 v2 주석만 다름\n    # 들여쓴 주석\nLIMIT_SEC = 5\nprint("a # b")\n' > "$d/proj/.claude/hooks/lib/cmdform.py"
chk "T17d 주석·shebang 만 다름 → 무출력" empty "$(run "$d")"
d=$(fresh t17e); kp "$d"; cp "$d/home/.claude/agent-scaffold/claude/hooks/lib/cmdform.py" "$d/proj/.claude/hooks/lib/cmdform.py"; echo 'x = 1' > "$d/proj/.claude/hooks/lib/x.py"
chk "T17e 레포에만 lib/x.py → 레포에만 있음" "레포에만 있음 1: lib/x.py" "$(run "$d")"
# T9 실물 킷 — 가짜 HOME = 이 킷의 전역 규약·근거 문서 사본 + 제외 목록의 조항 머리·근거 문서 항목(라이브에만 있는 것의 대역)이면
# 실제 킷(제외 목록 포함) 대조에서 전역 절이 비어야 한다. 프로젝트 = 이 킷 트리(킷 세션).
d="$S/t9"; mkdir -p "$d/home/.claude"; cp "$KITROOT/global/CLAUDE.md" "$d/home/.claude/"; cp -R "$KITROOT/global/rules-rationale" "$d/home/.claude/"
grep -E '^- \*\*[^*]+\*\*$' "$KITROOT/kit-drift-exclude.txt" >> "$d/home/.claude/CLAUDE.md"
grep -E '^rules-rationale/[^/]+\.md$' "$KITROOT/kit-drift-exclude.txt" | while IFS= read -r x; do printf '# 제외 항목 대역\n' > "$d/home/.claude/$x"; done
chk "T9 실물(제외 반영) → 무출력" empty "$(runx "$d" "$KITROOT" "$KITROOT")"
chk "T9 전역 층이 실제로 돌았다(마커 = 오늘)" "$(date +%F)" "$(cat "$d/home/.claude/.kit-drift-check-global" 2>/dev/null)"

# ── 세션 분기 ── 전역 차이(조항X)를 깔고 프로젝트 종류·좌석 env 별로 전역 절이 뜨는지·마커를 소비하는지 본다.
gd() { printf -- '- **조항X** 새것\n' >> "$1/home/.claude/CLAUDE.md"; }
gm() { cat "$1/home/.claude/.kit-drift-check-global" 2>/dev/null; }
mkgit() { mkdir -p "$1" && git -C "$1" init -q 2>/dev/null && : > "$1/f" && git -C "$1" add f && gitc -C "$1" commit -qm i; }
d=$(fresh s1); gd "$d"; chk "S1 원본 체크아웃 → 전역 보고" "조항X" "$(runx "$d" "$d/kit")"
d=$(fresh s2); gd "$d"; o=$(runx "$d" "$d/proj"); chk "S2 worktree → 전역 보고" "조항X" "$o"; chk "S2 보고 머리 = 원본 작업 트리 기준" "원본 작업 트리 기준" "$o"
chk "S2 등록 안내 = 이 세션 작업 트리에서 커밋" "이 세션 작업 트리에서 고쳐 커밋" "$o"
d=$(fresh s3); gd "$d"; mkdir -p "$d/proj/global/sub"; chk "S3 킷 worktree 하위 폴더 → 전역 보고" "조항X" "$(runx "$d" "$d/proj/global/sub")"
d=$(fresh s4); gd "$d"; mkgit "$d/other"; chk "S4 비킷 git → 무출력" empty "$(runx "$d" "$d/other")"
chk "S4 비킷은 전역 마커를 소비하지 않음" empty "$(gm "$d")"
chk "S4b 같은 날 뒤이은 킷 세션 → 전역 보고" "조항X" "$(runx "$d" "$d/proj")"
d=$(fresh s5); gd "$d"; mkdir -p "$d/plain"; chk "S5 비 git → 무출력" empty "$(runx "$d" "$d/plain")"; chk "S5 마커 미소비" empty "$(gm "$d")"
d=$(fresh s6); gd "$d"; printf '2000-01-01 | r | 훅 | x\n' > "$d/home/.claude/kit-candidates.md"
chk "S6 좌석(claude-team) 킷 worktree → 무출력" empty "$(runx "$d" "$d/proj" "$d/kit" "$d/home/.claude-team")"
chk "S6 좌석 마커 미소비" empty "$(gm "$d")"
mkgit "$d/other"; chk "S6b 좌석(claude-team) 비킷 + 묵은 큐 → 무출력" empty "$(runx "$d" "$d/other" "$d/kit" "$d/home/.claude-team")"
chk "S7 좌석(claude-api) 킷 worktree → 무출력" empty "$(runx "$d" "$d/proj" "$d/kit" "$d/home/.claude-api")"
chk "S7b 좌석(claude-api) 비킷 + 묵은 큐 → 무출력" empty "$(runx "$d" "$d/other" "$d/kit" "$d/home/.claude-api")"
chk "S7c 좌석 아님(양성 대조) 비킷 + 묵은 큐 → 적체 알림" "[킷 후보 큐] 적체 1건" "$(runx "$d" "$d/other" "$d/kit" "$d/home/.claude-x")"
# KIT_DIR 미설정 — 기본 킷 = $HOME/claude-agent-kit. cwd = 프로젝트라 `git -C ""`(cwd 에 머묾)로 판정하면 비킷 git 이 킷으로 뒤집힌다.
d="$S/s8"; fresh s8 "$d/home/claude-agent-kit" >/dev/null; gd "$d"; mkgit "$d/other"
chk "S8 KIT_DIR 미설정 + 비킷 git → 무출력" empty "$(runx "$d" "$d/other" -)"
chk "S8b KIT_DIR 미설정 + 기본 킷의 worktree → 전역 보고" "조항X" "$(runx "$d" "$d/proj" -)"
chk "S8c KIT_DIR 미설정 + 기본 킷 경로 없음 → 무출력" empty "$(runx "$S/s8none" "$d/other" -)"

# ── 킷 후보 큐 ── 줄 = `YYYY-MM-DD | <레포> | <층·경로> | <내용>`. 내용은 출력하지 않고 건수·날짜만.
sm() { printf '%s' "$1" | jq -r '.systemMessage // empty' 2>/dev/null; }
ac() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
q() { printf '%s\n' "${@:2}" >> "$1/home/.claude/kit-candidates.md"; }
d=$(fresh q1); q "$d" '2026-11-10 | repoA | 훅·x.sh | 비밀값SECRETX' '2026-11-12 | repoB | 규약 | 둘째 | 파이프 포함' '' '자유 메모 SECRETY' '2026-13-01 | r | 층 | 월 범위 밖' '2026-11-11 | | 층 | 레포 칸 빔'
printf '%s\n' '2026-11-01 | repoC | 층 | 처리 중' '2026-11-02 | repoC | 층 | 처리 중2' > "$d/home/.claude/kit-candidates.processing-20261119-120000-1.md"
o=$(run "$d")
chk "Q1 킷 세션 큐 건수(processing 포함·형식 밖 따로)" "대기 4건(꺼내다 남은 processing 파일 2건 포함) · 형식 밖 3줄 · 가장 오래된 날짜 2026-11-01" "$(ac "$o")"
chk "Q1 화면 요약" "[킷 후보 큐] 대기 4건(처리 중 2) · 형식 밖 3줄" "$(sm "$o")"
printf '%s' "$o" | grep -qE 'SECRET|repoA|repoC|자유 메모' && { fail=$((fail+1)); echo "FAIL Q1 큐 내용 노출"; } || { pass=$((pass+1)); echo "PASS Q1 큐 내용 미노출"; }
chk "Q2 같은 날 재실행에도 큐 줄(마커 무관)" "대기 4건" "$(sm "$(run "$d")")"
d=$(fresh q3); printf '%s\n' 'x' '1999-99-99 | r | 층 | 날짜 깨짐' '2026-1-5 | r | 층 | 자리수' > "$d/home/.claude/kit-candidates.md"
o=$(run "$d"); rc=$?
chk "Q3 날짜 깨진 줄만 → 형식 밖 3줄, 가장 오래된 날짜 없음" "대기 0건(꺼내다 남은 processing 파일 0건 포함) · 형식 밖 3줄 · 가장 오래된 날짜 없음" "$(ac "$o")"
[ $rc -eq 0 ] && printf '%s' "$o" | jq -e . >/dev/null 2>&1 && { pass=$((pass+1)); echo "PASS Q3 exit 0 + JSON 유효"; } || { fail=$((fail+1)); echo "FAIL Q3 rc=$rc 또는 JSON 무효"; }
d=$(fresh q4); : > "$d/home/.claude/kit-candidates.md"; chk "Q4 빈 큐 파일 → 무출력" empty "$(run "$d")"
# 비킷 세션 적체 알림 — 가장 오래된 날짜가 7일 초과(오늘-8일부터) 또는 20줄 이상이면 systemMessage 단독 한 줄.
d8=$(date -v-8d +%F 2>/dev/null || date -d '8 days ago' +%F); d7=$(date -v-7d +%F 2>/dev/null || date -d '7 days ago' +%F); t0=$(date +%F)
nk() { mkgit "$1/other"; runx "$1" "$1/other"; }
d=$(fresh n1); q "$d" "$t0 | r | 층 | 오늘" "$t0 | r | 층 | 오늘2"; chk "N1 비킷 + 2줄·오늘 → 무출력" empty "$(nk "$d")"
d=$(fresh n2); q "$d" "$t0 | r | 층 | 오늘" '2000-01-01 | r | 층 | 묵음'; o=$(nk "$d")
chk "N2 비킷 + 묵은 줄 → 적체 알림" "[킷 후보 큐] 적체 2건(가장 오래된 날짜 2000-01-01 · 형식 밖 0줄) — 원본 체크아웃 킷 세션에서 꺼내 처리하세요" "$(sm "$o")"
printf '%s' "$o" | jq -e 'has("hookSpecificOutput") | not' >/dev/null 2>&1 && { pass=$((pass+1)); echo "PASS N2 systemMessage 단독(additionalContext 없음)"; } || { fail=$((fail+1)); echo "FAIL N2 단독 아님: ${o:0:200}"; }
[ "$(sm "$o" | grep -c .)" = 1 ] && { pass=$((pass+1)); echo "PASS N2 한 줄"; } || { fail=$((fail+1)); echo "FAIL N2 줄 수"; }
d=$(fresh n3); q "$d" "$d7 | r | 층 | 딱 7일"; chk "N3 오늘-7일 → 무출력(7일 초과 아님)" empty "$(nk "$d")"
d=$(fresh n4); q "$d" "$d8 | r | 층 | 8일"; chk "N4 오늘-8일 → 적체 알림" "적체 1건(가장 오래된 날짜 $d8" "$(sm "$(nk "$d")")"
d=$(fresh n5); for i in $(seq 1 19); do q "$d" "$t0 | r | 층 | $i"; done; chk "N5 19줄·오늘 → 무출력" empty "$(nk "$d")"
q "$d" "$t0 | r | 층 | 20"; chk "N5b 20줄 → 적체 알림" "적체 20건" "$(sm "$(runx "$d" "$d/other")")"
d=$(fresh n6); q "$d" '1999-99-99 | r | 층 | 깨짐' 'abc'; o=$(nk "$d"); rc=$?
chk "N6 날짜 깨진 줄만(20줄 미만) → 무출력" empty "$o"; [ $rc -eq 0 ] && { pass=$((pass+1)); echo "PASS N6 exit 0"; } || { fail=$((fail+1)); echo "FAIL N6 exit $rc"; }
q "$d" '2000-02-03 | r | 층 | 묵음'; chk "N6b 깨진 줄은 건너뛰고 유효한 묵은 줄로 판정" "적체 1건(가장 오래된 날짜 2000-02-03 · 형식 밖 2줄)" "$(sm "$(runx "$d" "$d/other")")"
d=$(fresh n7); printf '2000-01-01 | r | 층 | 처리 중\n' > "$d/home/.claude/kit-candidates.processing-1-1.md"; chk "N7 processing 잔존만 묵음 → 적체 알림" "적체 1건" "$(sm "$(nk "$d")")"
d=$(fresh n8); gd "$d"; q "$d" '2000-01-01 | r | 층 | 묵음'; nk "$d" >/dev/null; chk "N8 비킷 적체 알림은 전역 마커를 소비하지 않음" empty "$(gm "$d")"
# 비킷 + 레포 층 차이 + 적체 → 화면 = 레포 요약 + 큐 한 줄, 모델 본문 = 레포 절(전역·큐 절 없음).
d=$(fresh n9); mkgit "$d/other"; mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/other/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/other/.claude/hooks/x.sh"; q "$d" '2000-01-01 | r | 층 | 묵음'; gd "$d"
# 큐·라이브 scaffold 안내 = 킷 운영 파일(KIT_DIR 의 scripts/live-edit.sh)이 있을 때만 — 여기선 두고 아래 N9n 에서 뺀다.
mkdir -p "$d/kit/scripts"; : > "$d/kit/scripts/live-edit.sh"
o=$(runx "$d" "$d/other"); chk "N9 화면 레포 요약" "[킷 드리프트] other: 로직 차이 1" "$(sm "$o")"; chk "N9 화면 큐 줄" "[킷 후보 큐] 적체 1건" "$(sm "$o")"
ac "$o" | grep -qE '전역 층|킷 후보 큐' && { fail=$((fail+1)); echo "FAIL N9 모델 본문에 전역·큐 절"; } || { pass=$((pass+1)); echo "PASS N9 모델 본문 = 레포 절"; }
chk "N9 레포 안내 = 이 세션이 맞추고 큐에 한 줄" "킷(라이브 scaffold) 쪽 반영 후보는 큐" "$(ac "$o")"
chk "N9 지문 등록 안내의 \`# 사유\` 보존" '`# 사유` 와 함께 등록' "$(ac "$o")"
o3=$(ac "$o" | grep '③레포에만 있음')
chk "N9 ③ 안내 = 전역·라이브 scaffold 후보, 고쳤거나 정했으면 큐" "스택 불문이면 전역(라이브 ~/.claude/hooks·settings), 동일 스택 공유면 라이브 scaffold 반영 후보 — 고쳤거나 정했으면 큐에 한 줄" "$o3"
printf '%s' "$o3" | grep -qF '이 세션이 맞추고' && { fail=$((fail+1)); echo "FAIL N9 ③ 에 할 일 없는 '이 세션이 맞추고'"; } || { pass=$((pass+1)); echo "PASS N9 ③ 에 '이 세션이 맞추고' 없음"; }

# N9n 킷 운영 파일 없는 설치(공개 스냅샷 등) — 레포 안내 ①③ 이 큐·라이브 scaffold 없이 일반 문구.
rm -r "$d/kit/scripts"; rm -f "$d/home/.claude"/.kit-drift-check*   # 레포 층 일자 마커를 지워 다시 발화시킨다
o=$(ac "$(runx "$d" "$d/other")")
case "$o" in *"로직 차이 1"*) pass=$((pass+1)); echo "PASS N9n (전제) 레포 절 발화" ;; *) fail=$((fail+1)); echo "FAIL N9n (전제) 레포 절 없음: $o" ;; esac
chk "N9n ① 일반 문구" "실차이면 최신 쪽으로 통일(킷이 정본이면 레포 갱신, 레포가 개선판이면 킷 갱신)" "$o"
chk "N9n ③ 일반 문구" "③레포에만 있음 = 스택 불문이면 전역으로, 동일 스택 공유면 킷으로 승격 후보. 도메인 전용이면 그대로." "$o"
printf '%s' "$o" | grep -qE 'kit-candidates|라이브 scaffold|큐에 한 줄' && { fail=$((fail+1)); echo "FAIL N9n 운영 파일 없는데 큐·라이브 scaffold 안내"; } || { pass=$((pass+1)); echo "PASS N9n 큐·라이브 scaffold 안내 없음"; }

# ── 큐 꺼내기 주체 ── 원본 체크아웃 킷 세션. worktree 세션엔 원본 체크아웃 몫임을 붙인다.
d=$(fresh q5); q "$d" '2026-11-10 | r | 층 | x'
o=$(ac "$(run "$d")"); chk "Q5 worktree → 꺼내기 주체 안내" "꺼내기 = 원본 체크아웃 킷 세션이 사용자에게 제안한 뒤(절차 = 킷 memory kit-operating-rulings 의 큐 절" "$o"
chk "Q5 worktree → 원본 체크아웃 세션 몫" "이 worktree 세션 몫이 아니다(원본 체크아웃 세션 몫)" "$o"
o=$(ac "$(runx "$d" "$d/kit")"); chk "Q5b 원본 체크아웃 → 이 세션이 주체" "이 세션(원본 체크아웃)이 그 주체다" "$o"
printf '%s' "$o" | grep -qF 'worktree 세션 몫' && { fail=$((fail+1)); echo "FAIL Q5b 원본에 worktree 문구"; } || { pass=$((pass+1)); echo "PASS Q5b 원본에 worktree 문구 없음"; }

# ── 비킷 적체 알림 일자 마커 ── 같은 날 두 번째는 무출력, 마커 날짜가 오늘이 아니면 다시 발화. 킷 세션 큐 줄은 마커와 무관.
amk() { cat "$1/home/.claude/.kit-candidates-alert" 2>/dev/null; }
d=$(fresh n11); q "$d" '2000-01-01 | r | 층 | 묵음'
chk "N11 첫 실행 → 적체 알림" "적체 1건" "$(sm "$(nk "$d")")"; chk "N11 알림 마커 = 오늘" "$t0" "$(amk "$d")"
chk "N11b 같은 날 두 번째 → 무출력" empty "$(runx "$d" "$d/other")"
printf '2000-01-01' > "$d/home/.claude/.kit-candidates-alert"; chk "N11c 마커 날짜가 오늘 아님 → 다시 발화" "적체 1건" "$(sm "$(runx "$d" "$d/other")")"
chk "N11d 비킷 알림 마커가 있어도 킷 세션 큐 줄" "대기 1건" "$(sm "$(run "$d")")"

# ── 큐 파일에 NUL ── grep 이 이진 취급하면 날짜 판정이 조용히 꺼진다.
d=$(fresh n12); printf '2026-11-19 | r | 층 | a\000b\n2000-01-01 | r | 층 | 묵음\n' > "$d/home/.claude/kit-candidates.md"
chk "N12 NUL 섞인 큐 + 묵은 줄 → 적체 알림(건수·날짜)" "적체 2건(가장 오래된 날짜 2000-01-01 · 형식 밖 0줄)" "$(sm "$(nk "$d")")"

# ── 날짜 계산 실패 ── -v·-d 모두 실패하고 stdout 에 글자를 내는 date 심(오늘 +%F 는 실제 date) → 날짜 조건만 꺼지고 20줄 규칙은 남는다.
RD=$(command -v date); mkdir -p "$S/dshim"
printf '#!/bin/sh\n[ "$#" = 1 ] && [ "$1" = +%%F ] && exec %s "$@"\necho "usage: date"; exit 1\n' "$RD" > "$S/dshim/date"; chmod +x "$S/dshim/date"
d=$(fresh n10); mkgit "$d/other"; q "$d" '2000-01-01 | r | 층 | 묵음'
o=$(PATH="$S/dshim:$PATH" runx "$d" "$d/other"); rc=$?
chk "N10 date 실패 + 묵은 1줄 → 날짜 알림 없음" empty "$o"; [ $rc -eq 0 ] && { pass=$((pass+1)); echo "PASS N10 exit 0"; } || { fail=$((fail+1)); echo "FAIL N10 exit $rc"; }
for i in $(seq 1 19); do q "$d" "$t0 | r | 층 | $i"; done
chk "N10b date 실패 + 20줄 → 줄 수 규칙으로 적체 알림" "적체 20건" "$(sm "$(PATH="$S/dshim:$PATH" runx "$d" "$d/other")")"

# ── 세션 판정 경계 ──
# S5b git 아닌 프로젝트 + 없는 KIT_DIR — 양쪽 판정이 모두 비어도 킷이 아니다(빈 값끼리 같음 ≠ 킷).
d=$(fresh s5b); mkdir -p "$d/plain"; q "$d" '2000-01-01 | r | 층 | 묵음'; o=$(sm "$(runx "$d" "$d/plain" "$d/없는킷")")
chk "S5b 비 git + 없는 KIT_DIR + 묵은 큐 → 적체 알림" "적체 1건" "$o"
printf '%s' "$o" | grep -qF '대기' && { fail=$((fail+1)); echo "FAIL S5b 킷 세션 큐 줄('대기')"; } || { pass=$((pass+1)); echo "PASS S5b '대기' 없음"; }
# S9 세션 env 에 GIT_DIR=<킷>/.git 이 있어도 비킷 git 프로젝트는 킷이 아니다.
d=$(fresh s9); gd "$d"; mkgit "$d/other"
chk "S9 GIT_DIR=킷 + 비킷 git → 무출력" empty "$(GIT_DIR="$d/kit/.git" runx "$d" "$d/other")"; chk "S9 전역 마커 미소비" empty "$(gm "$d")"
# S11 HOME 이 git(dotfiles)이고 기본 킷 경로가 git 아닌 사본 → 그 아래 git 아닌 프로젝트는 킷이 아니다.
d="$S/s11"; mkdir -p "$d/home/.claude" "$d/home/claude-agent-kit/global" "$d/home/plain"
printf -- '- **조항A**\n- **조항X**\n' > "$d/home/.claude/CLAUDE.md"; printf -- '- **조항A**\n' > "$d/home/claude-agent-kit/global/CLAUDE.md"; mkgit "$d/home"
chk "S11 HOME git + 킷 사본 git 아님 → 무출력" empty "$(runx "$d" "$d/home/plain" -)"; chk "S11 전역 마커 미소비" empty "$(gm "$d")"
git -C "$d/home/claude-agent-kit" init -q 2>/dev/null
chk "S11b 양성 대조: 킷 사본을 git 으로 → 전역 보고" "조항X" "$(runx "$d" "$d/home/claude-agent-kit" -)"
# S10 좌석은 레포 층도 끈다(무출력·레포 마커 미소비) → 같은 날 메인이 레포 요약을 받는다.
d=$(fresh s10); mkgit "$d/other"; mkdir -p "$d/home/.claude/agent-scaffold/claude/hooks" "$d/other/.claude/hooks"
echo 'echo 킷' > "$d/home/.claude/agent-scaffold/claude/hooks/x.sh"; echo 'echo 레포' > "$d/other/.claude/hooks/x.sh"
chk "S10 좌석(claude-team) + 레포 차이 → 무출력" empty "$(runx "$d" "$d/other" "$d/kit" "$d/home/.claude-team")"
chk "S10 좌석(claude-api 끝 슬래시) + 레포 차이 → 무출력" empty "$(runx "$d" "$d/other" "$d/kit" "$d/home/.claude-api/")"
ls "$d/home/.claude/".kit-drift-check-* >/dev/null 2>&1 && { fail=$((fail+1)); echo "FAIL S10 좌석이 레포 마커 소비"; } || { pass=$((pass+1)); echo "PASS S10 레포 마커 미소비"; }
chk "S10b 같은 날 뒤이은 메인 → 레포 요약" "[킷 드리프트] other: 로직 차이 1" "$(sm "$(runx "$d" "$d/other")")"
# S10c 좌석 판정 = 경로 마지막 성분 — 위쪽 경로에 claude-team 글자가 든 메인 설정 디렉터리는 좌석이 아니다.
d=$(fresh s10c); mkgit "$d/other"; q "$d" '2000-01-01 | r | 층 | 묵음'
chk "S10c 상위 경로에 claude-team 글자 → 좌석 아님(적체 알림)" "적체 1건" "$(sm "$(runx "$d" "$d/other" "$d/kit" "$d/claude-team/.claude")")"
echo "합계 PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
