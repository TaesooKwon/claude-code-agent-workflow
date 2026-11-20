#!/usr/bin/env bash
# bootstrap-machine.sh 실행 비트 시험 — 킷 추적 파일 사본 + 가짜 HOME 으로 bootstrap 을 돌려
# 원본 100755 파일이 설치본에서도 -x 인지, 100644 파일은 -x 가 붙지 않는지, 내용 동일 재실행이 빠진 -x 를 복구하는지 본다.
# 실제 ~/.claude·킷 machine.env 는 쓰지 않는다(machine.env = 사본에서 init-machine-env.sh 로 생성).
#   BOOTSTRAP_SRC=<파일>  사본의 bootstrap-machine.sh 를 이 파일로 바꿔 돈다(수리 전 판 재현용)
#   KEEP_TMP=1            임시 폴더를 지우지 않고 경로만 출력
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d /private/tmp/bme.XXXXXX 2>/dev/null || mktemp -d /tmp/bme.XXXXXX) || exit 1
case "$ROOT" in /Users/*|/home/*) echo "✗ 가짜 HOME 경로가 홈 아래: $ROOT" >&2; exit 2 ;; esac
if [ "${KEEP_TMP:-0}" = 1 ]; then echo "임시 폴더 유지: $ROOT"
else trap 'case "$ROOT" in */bme.*) rm -rf "$ROOT" ;; esac' EXIT; fi
H="$ROOT/home"; K="$H/kit"; mkdir -p "$K" "$H/projects"
T=0; F=0
ok() { T=$((T + 1)); echo "  ✓ $1"; }
ng() { T=$((T + 1)); F=$((F + 1)); echo "  ✗ $1"; }

# 추적 파일만 작업 트리 모드 그대로 복사(지워진 추적 파일은 건너뜀)
( cd "$HERE" && git ls-files -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf - ) | tar -xf - -C "$K" || { echo "✗ 사본 실패" >&2; exit 1; }
[ -n "${BOOTSTRAP_SRC:-}" ] && cp "$BOOTSTRAP_SRC" "$K/bootstrap-machine.sh"
HOME="$H" bash "$K/init-machine-env.sh" >/dev/null 2>&1 || { echo "✗ init-machine-env.sh 실패" >&2; exit 1; }
[ -f "$K/machine.env" ] || { echo "✗ machine.env 생성 안 됨" >&2; exit 1; }

run_boot() { HOME="$H" bash "$K/bootstrap-machine.sh" > "$ROOT/boot.out" 2>&1; }
run_boot || { ng "bootstrap rc≠0 (출력 $ROOT/boot.out)"; }
grep -q '✗ 문법 오류로 설치 안 함' "$ROOT/boot.out" && ng "문법 오류로 설치 안 한 파일 있음"

# 대상 = bootstrap 이 파일 단위로 설치하는 원본 중 실행 비트 있는 것(.sh 포함 전부) / 대조군 = 실행 비트 없는 비-.sh 파일 1개
map_dst() {  # $1 = global/ 아래 상대경로 → 설치 경로
  case "$1" in
    hooks/*.sh) printf '%s' "$H/.claude/hooks/${1#hooks/}" ;;
    skills/*|agent-scaffold/*|agents/*) printf '%s' "$H/.claude/$1" ;;
    bin/jdtls) printf '%s' "$H/.local/bin/jdtls" ;;
  esac
}
n=0; miss=0
while IFS= read -r rel; do
  dst=$(map_dst "$rel"); [ -n "$dst" ] || continue
  n=$((n + 1))
  [ -x "$dst" ] || { miss=$((miss + 1)); echo "    -x 없음: ${dst#"$H"/}"; }
done < <(cd "$K/global" && find hooks skills agent-scaffold agents bin -type f -perm -u+x 2>/dev/null | grep -v '^hooks/.*/' )
[ "$n" -gt 0 ] || ng "대상 0건 — 판정 불가"
[ "$miss" -eq 0 ] && ok "원본 -x ${n}건 전부 설치본 -x" || ng "원본 -x ${n}건 중 ${miss}건 설치본 -x 없음"

ctrl=$(cd "$K/global" && find agent-scaffold -type f ! -perm -u+x ! -name '*.sh' | head -1)
if [ -z "$ctrl" ]; then ng "대조군(실행 비트 없는 비-.sh) 0건 — 판정 불가"
elif [ -x "$H/.claude/$ctrl" ]; then ng "대조군 $ctrl 에 -x 가 붙음"
else ok "대조군 $ctrl -x 없음"; fi

# 내용 동일 재실행이 빠진 실행 비트를 복구하는가
probe="$H/.claude/agent-scaffold/claude/hooks/git/pre-commit"
if [ -f "$probe" ]; then
  chmod -x "$probe"; run_boot
  [ -x "$probe" ] && ok "동일 내용 재실행이 pre-commit -x 복구" || ng "동일 내용 재실행 뒤에도 pre-commit -x 없음"
else ng "pre-commit 설치본 없음 — 판정 불가"; fi

echo "결과: ${T}건 중 실패 ${F}건"
[ "$F" -eq 0 ]
