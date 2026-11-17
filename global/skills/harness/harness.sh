#!/usr/bin/env bash
# harness.sh — harness 스킬의 명령 진입점. 지금은 `test` 모드 하나다(계약검사·컨벤션 lint·compile 은 SKILL.md 「실행 절차」).
#
#   bash ~/.claude/skills/harness/harness.sh test <모듈>[,<모듈>…]
#
# 하는 일: 현재 디렉터리가 속한 git 레포의 루트(pom.xml 의 <module> 목록이 허용 목록)에서
#   mvn test -pl <모듈> -am -B -ntp -Dmaven.repo.local=<핀> 을 그대로 실행하고 출력을 자르지 않고 흘린 뒤,
#   끝에 모듈별 Tests run 총계와 BUILD SUCCESS/FAILURE 를 한 줄씩 요약한다. 종료코드 = mvn 의 종료코드.
#   핀 = ${MAVEN_REPO_LOCAL:-__HOME__/maven_repo/maven/repository}(SKILL.md 「핵심 사실」과 같은 규칙).
# 거부: test 밖의 모드·goal(install·clean·compile 등) · 허용 목록 밖 모듈 · 여분 인자 → exit 2.
# 커밋 게이트 호환: 레포 기록기 .claude/hooks/mvn-test-record.sh 가 이 호출형(경로 = ~/.claude/skills/harness/harness.sh)을
#   `mvn test -pl <모듈> -am` 실행으로 인식해 .last-mvn-test 를 남긴다. 그래서 요약 줄은 [harness] 접두로 찍는다 —
#   [INFO] 접두 Tests run 줄은 기록기가 총계로 더하므로 요약이 이중계산되지 않게 한다. 출력을 잘라도
#   마지막 [harness] 결과 줄로 성공 여부는 남지만 Tests run 총계가 빠져 게이트가 막을 수 있으니 자르지 않는다.
set -u

usage() {
  echo "사용: bash ~/.claude/skills/harness/harness.sh test <모듈>[,<모듈>…]   (모듈 = 레포 루트 pom.xml 의 <module>)" >&2
  exit 2
}

[ "${1:-}" = test ] || { [ -n "${1:-}" ] && echo "허용되지 않은 모드: $1 (test 만 — install·clean 등 다른 goal 은 실행하지 않는다)" >&2; usage; }
[ "$#" -eq 2 ] || usage
mods="$2"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "git 레포 안에서 실행하세요." >&2; exit 2; }
[ -f "$root/pom.xml" ] || { echo "레포 루트에 pom.xml 이 없습니다: $root" >&2; exit 2; }
allowed="$(sed -n 's:.*<module>[[:space:]]*\([^<[:space:]]*\)[[:space:]]*</module>.*:\1:p' "$root/pom.xml")"
# ponytail: 줄 단위 sed 라 주석 처리된 <module>·profile 안 module 도 허용 목록에 들고, 한 줄에 여러 module 이면 마지막만 잡는다
#   (실행은 고정 mvn test·인자 인용이라 주입 없음) / 업그레이드 = mvn help:evaluate 또는 xmllint 로 <modules> 파싱.
[ -n "$allowed" ] || { echo "루트 pom.xml 에 <module> 이 없습니다(멀티모듈 레포 전용): $root" >&2; exit 2; }
case "$mods" in ''|,*|*,|*,,*) usage ;; esac
IFS=',' read -r -a mod_list <<<"$mods"
for m in "${mod_list[@]}"; do
  printf '%s\n' "$allowed" | grep -Fxq -- "$m" || { echo "허용 목록 밖 모듈: $m (허용: $(printf '%s' "$allowed" | tr '\n' ' '))" >&2; exit 2; }
done

pin="${MAVEN_REPO_LOCAL:-__HOME__/maven_repo/maven/repository}"
[ -d "$pin" ] || { echo "Maven 저장소 핀이 없습니다: $pin" >&2; exit 2; }
command -v mvn >/dev/null 2>&1 || { echo "mvn 이 PATH 에 없습니다." >&2; exit 2; }

log="$(mktemp "${TMPDIR:-/tmp}/harness-test.XXXXXX")" || exit 2
trap 'rm -f "$log"' EXIT

echo "[harness] $root: mvn test -pl $mods -am -B -ntp -Dmaven.repo.local=$pin"
( cd "$root" && mvn test -pl "$mods" -am -B -ntp -Dmaven.repo.local="$pin" ) 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"

# 요약 — 모듈 경계 = "-----< group:artifact >-----" 줄, 모듈 총계 = 접두가 [INFO]/[ERROR]/[WARNING] 이고 "- in " 이 없는 Tests run 줄.
echo "[harness] ── 요약 ──"
esc="$(printf '\033')"
sed -E "s/${esc}\\[[0-9;]*m//g" "$log" | awk '
  /^\[INFO\] -+< [^:]+:[^ ]+ >-+$/ { m = $0; sub(/^.*:/, "", m); sub(/ >.*$/, "", m); if (!(m in seen)) { seen[m] = 1; order[++n] = m } next }
  /^\[(INFO|ERROR|WARNING)\][[:space:]]+Tests run:[[:space:]]*[0-9]+,/ && !/- in / && m != "" {
    s = $0; sub(/^.*Tests run:[[:space:]]*/, "", s); split(s, f, /,[[:space:]]*/)
    t[m] += f[1] + 0; for (i = 2; i <= 4; i++) { split(f[i], kv, /:[[:space:]]*/); v[m, kv[1]] += kv[2] + 0 }
    has[m] = 1
  }
  END {
    for (i = 1; i <= n; i++) { k = order[i]
      if (has[k]) printf "[harness] %s: Tests run %d, Failures %d, Errors %d, Skipped %d\n", k, t[k], v[k, "Failures"], v[k, "Errors"], v[k, "Skipped"]
      else printf "[harness] %s: Tests run 0 (테스트 요약 줄 없음)\n", k }
  }'
if grep -q 'BUILD FAILURE' "$log"; then echo "[harness] 결과: BUILD FAILURE (mvn 종료코드 $rc)"
elif grep -q 'BUILD SUCCESS' "$log"; then echo "[harness] 결과: BUILD SUCCESS (mvn 종료코드 $rc)"
else echo "[harness] 결과: 판정 불가 — 출력에 BUILD 줄 없음 (mvn 종료코드 $rc)"; fi
exit "$rc"
