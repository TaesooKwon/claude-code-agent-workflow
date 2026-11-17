#!/usr/bin/env bash
# sql-staging-guard.sh 회귀 — 새 경로가 생기는 상태(A·C·R)의 .sql 은 차단, 기존 .sql 수정(M)은 통과.
#   diff.renames 설정(기본·false·copies)마다 같은 판정이어야 한다(copies 설정의 C 상태가 새던 결함의 회귀).
# 훅 경로 기본값 = 라이브. 사본을 볼 땐 HOOKS_DIR_OVERRIDE=<디렉터리>.
# 임시 레포는 mktemp 아래에서만 만들고 끝에 지운다(현재 레포 인덱스는 건드리지 않는다).
set -u
H="${HOOKS_DIR_OVERRIDE:-{{ROOT}}/.claude/hooks}/sql-staging-guard.sh"
[ -f "$H" ] || { echo "훅 없음: $H"; exit 2; }
command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 || { echo "전제 도구 없음(jq/git) — 테스트를 실행하지 않았다"; exit 2; }

R=$(mktemp -d "${TMPDIR:-/tmp}/sqlguard-test.XXXXXX") || exit 2
trap 'rm -rf "$R"' EXIT
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t && git -C "$R" config commit.gpgsign false
printf 'select 1;\nselect 2;\nselect 3;\nselect 4;\n' > "$R/old.sql"
printf 'aaaa\nbbbb\ncccc\ndddd\n' > "$R/old.txt"
git -C "$R" add -A && git -C "$R" commit -qm init

run=0; passed=0
_dec() { printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$R" | bash "$H" \
  | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
_case() { # $1=deny|none $2=설명
  local got; got=$(_dec); [ -n "$got" ] || got=none
  run=$((run + 1))
  if [ "$got" = "$1" ]; then passed=$((passed + 1)); printf 'ok    %-40s [%s]\n' "$2" "$got"
  else printf 'FAIL  %-40s 기대=%s 실제=%s\n' "$2" "$1" "$got"; fi
}
_reset() { git -C "$R" reset -q --hard; git -C "$R" clean -qfd; git -C "$R" config --unset diff.renames; [ "$1" = default ] || git -C "$R" config diff.renames "$1"; }

for cfg in default false copies; do
  _reset "$cfg"; printf 'x;\n' > "$R/new.sql"; git -C "$R" add -A
  _case deny "A 신규 .sql [$cfg]"
  _reset "$cfg"; git -C "$R" mv old.txt new.sql
  _case deny "R txt→sql 이름 변경 [$cfg]"
  _reset "$cfg"; cp "$R/old.sql" "$R/new.sql"; printf 'select 5;\n' >> "$R/old.sql"; git -C "$R" add -A
  _case deny "C 복사+원본 수정 [$cfg]"
  _reset "$cfg"; printf 'select 9;\n' >> "$R/old.sql"; git -C "$R" add -A
  _case none "M 기존 .sql 수정(음성) [$cfg]"
done
_reset default; printf 'x;\n' > "$R/new.sql"; git -C "$R" add -A
out=$(printf '{"tool_input":{"command":"git status"},"cwd":"%s"}' "$R" | bash "$H")
run=$((run + 1)); if [ -z "$out" ]; then passed=$((passed + 1)); echo "ok    커밋 아닌 명령 무출력(음성)"; else echo "FAIL  커밋 아닌 명령에 출력"; fi

echo
echo "Tests run: $run, Passed: $passed"
[ "$run" -eq "$passed" ] || exit 1
