#!/usr/bin/env bash
# kit-drift-check.sh 반증 테스트(전역 층 + 레포 절 회귀) — 임시 디렉터리의 가짜 HOME 에서만 돈다(실제 ~/.claude 는 T9 에서 읽기만).
H=${H:-$HOME/.claude/hooks/kit-drift-check.sh}
KITROOT=$(cd "$(dirname "$0")" && pwd); S=$(mktemp -d)/kdc
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
fresh() { # 새 가짜 HOME + 킷 + 프로젝트(훅 폴더 없음)
  local d="$S/$1"; mkdir -p "$d/home/.claude/rules-rationale" "$d/kit/global/rules-rationale" "$d/proj"
  printf -- '- **조항A** 본문\n- **조항B** 본문\n' > "$d/home/.claude/CLAUDE.md"
  cp "$d/home/.claude/CLAUDE.md" "$d/kit/global/CLAUDE.md"
  printf '# a\n## 절1\n본문\n' > "$d/home/.claude/rules-rationale/a.md"
  cp "$d/home/.claude/rules-rationale/a.md" "$d/kit/global/rules-rationale/a.md"
  echo "$d"
}
run() { local d="$1"; HOME="$d/home" KIT_DIR="${2:-$d/kit}" CLAUDE_PROJECT_DIR="$d/proj" bash "$H"; }

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
# T9 실물 사본 — 라이브 전역 규약·근거 문서 사본 + 실제 킷(제외 목록 포함)이면 전역 절이 비어야 한다.
d="$S/t9"; mkdir -p "$d/home/.claude" "$d/proj"; cp "$HOME/.claude/CLAUDE.md" "$d/home/.claude/"; cp -R "$HOME/.claude/rules-rationale" "$d/home/.claude/"
chk "T9 실물(제외 반영) → 무출력" empty "$(run "$d" "$KITROOT")"
echo "합계 PASS $pass / FAIL $fail"
