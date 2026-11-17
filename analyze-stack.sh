#!/usr/bin/env bash
# analyze-stack.sh — 대상 프로젝트의 스택을 감지하고, 에이전트 구성(어느 게이트·룰·프로파일이
# 적용되는지)을 권고한다. 새 직장/새 스택에서 /bootstrap-project 를 적용하기 "전에" 돌려
# 무엇이 그대로 이식되고 무엇을 바꿔야 하는지 판단한다.
#
# 사용: ./analyze-stack.sh [프로젝트_경로]   (생략 시 현재 디렉터리)
# 출력: 스택 리포트 + 적용 권고(어느 규칙이 transfer/조정/비활성).
set -u
ROOT="${1:-$PWD}"
[ -d "$ROOT" ] || { echo "경로 없음: $ROOT" >&2; exit 1; }
cd "$ROOT"

say() { printf '%s\n' "$*"; }
hr()  { printf -- '----------------------------------------\n'; }

# ---------- 1. 빌드 툴 ----------
BUILD="unknown"; BUILD_FILE=""
if [ -f pom.xml ]; then BUILD="maven"; BUILD_FILE="pom.xml"
elif [ -f build.gradle.kts ]; then BUILD="gradle-kotlin"; BUILD_FILE="build.gradle.kts"
elif [ -f build.gradle ]; then BUILD="gradle-groovy"; BUILD_FILE="build.gradle"
elif [ -f package.json ]; then BUILD="node"; BUILD_FILE="package.json"
elif [ -f Cargo.toml ]; then BUILD="cargo"; BUILD_FILE="Cargo.toml"
elif [ -f go.mod ]; then BUILD="go"; BUILD_FILE="go.mod"
elif [ -f pyproject.toml ] || [ -f setup.py ]; then BUILD="python"; BUILD_FILE="pyproject.toml/setup.py"
fi

# ---------- 2. 언어 + 버전 ----------
LANG_="unknown"; VER=""
find_maven_java() {
  # 멀티모듈 대응: 전체 pom 재귀검색. java.version / compiler source|target|release.
  # 값 정규화: 1.8→8, 1.7→7. 여러 값이면 최고 버전.
  grep -rhoE "<(java\.version|maven\.compiler\.(source|target|release)|source|target|release)>[^<]+" --include=pom.xml . 2>/dev/null \
    | sed -E 's/.*>//' | sed -E 's/^1\.//' | grep -oE '^[0-9]+' | sort -un | tail -1
}
case "$BUILD" in
  maven)
    if grep -rqiE "kotlin" --include=pom.xml . 2>/dev/null; then LANG_="kotlin"; fi
    v="$(find_maven_java)"; [ -n "$v" ] && { LANG_="${LANG_/unknown/java}"; VER="$v"; }
    [ "$LANG_" = "unknown" ] && [ -d src/main/java ] && LANG_="java"
    ;;
  gradle-kotlin|gradle-groovy)
    if grep -rqiE "org.jetbrains.kotlin|kotlin\(\"jvm\"\)|apply plugin: 'kotlin'" build.gradle* 2>/dev/null; then LANG_="kotlin"; else LANG_="java"; fi
    # 값 추출 후 Maven과 동일 정규화(1.8→8, VERSION_21·languageVersion·of(17) 포함).
    VER="$(grep -rhoE "(sourceCompatibility|targetCompatibility|languageVersion|JavaLanguageVersion\.of|JavaVersion\.VERSION_)[^0-9]*[0-9._]+" build.gradle* 2>/dev/null \
      | grep -oE '[0-9.]+$' | sed -E 's/^1\.//' | grep -oE '^[0-9]+' | sort -un | tail -1)"
    ;;
  node) LANG_="js/ts"; VER="$(grep -oE '"node"[^,}]*' package.json 2>/dev/null | grep -oE '[0-9]+' | head -1)";;
  cargo) LANG_="rust";; go) LANG_="go";; python) LANG_="python";;
esac
# 버전 매니저 파일 보강
for vf in .java-version .sdkmanrc .tool-versions; do
  [ -f "$vf" ] && say_vf="$(head -1 "$vf" 2>/dev/null)" && [ -z "$VER" ] && VER="$(printf '%s' "$say_vf" | grep -oE '[0-9]+' | head -1)"
done

# ---------- 3. 모듈 구조 ----------
MODULES="single"
case "$BUILD" in
  maven)   n="$(find . -maxdepth 2 -name pom.xml -not -path './pom.xml' 2>/dev/null | wc -l | tr -d ' ')"; [ "$n" -gt 0 ] && MODULES="multi ($n 서브모듈)";;
  gradle*) n="$(find . -maxdepth 2 \( -name build.gradle -o -name build.gradle.kts \) -not -path './build.gradle*' 2>/dev/null | wc -l | tr -d ' ')"; [ "$n" -gt 0 ] && MODULES="multi ($n 서브모듈)";;
esac

# ---------- 4. 프레임워크 / 테스트 ----------
FW=""; TESTFW=""
case "$BUILD" in
  maven|gradle*)
    # 멀티모듈 대응: 전체 빌드파일 재귀검색(서브모듈 pom/build.gradle 포함).
    INC="--include=pom.xml --include=build.gradle --include=build.gradle.kts"
    grep -rqiE "spring-boot" $INC . 2>/dev/null && FW="Spring Boot"
    grep -rqiE "egovframe|egov" $INC . 2>/dev/null && FW="$FW${FW:+ / }eGovFrame"
    grep -rqiE "mybatis" $INC . 2>/dev/null && FW="$FW${FW:+ / }MyBatis"
    grep -rqiE "junit-jupiter|junit5" $INC . 2>/dev/null && TESTFW="JUnit5"
    grep -rqiE "junit:junit|<artifactId>junit</artifactId>" $INC . 2>/dev/null && TESTFW="$TESTFW${TESTFW:+ + }JUnit4"
    grep -rqiE "mockito" $INC . 2>/dev/null && TESTFW="$TESTFW${TESTFW:+ + }Mockito"
    ;;
  node)
    grep -qiE '"(react|next)"' package.json 2>/dev/null && FW="React/Next"
    grep -qiE '"(vue|nuxt)"' package.json 2>/dev/null && FW="$FW${FW:+ / }Vue/Nuxt"
    grep -qiE '"(jest|vitest)"' package.json 2>/dev/null && TESTFW="Jest/Vitest"
    ;;
esac

# ========== 리포트 ==========
hr; say "STACK ANALYSIS — $ROOT"; hr
printf '  %-14s %s\n' "빌드 툴"   "$BUILD${BUILD_FILE:+  ($BUILD_FILE)}"
printf '  %-14s %s\n' "언어"      "$LANG_${VER:+  버전 $VER}"
printf '  %-14s %s\n' "모듈"      "$MODULES"
printf '  %-14s %s\n' "프레임워크" "${FW:-(감지 안 됨)}"
printf '  %-14s %s\n' "테스트"    "${TESTFW:-(감지 안 됨)}"
hr

# ========== 적용 권고 ==========
say "에이전트 구성 적용 권고"
say ""
# 프로파일 매칭
if [ "$BUILD" = "maven" ] && printf '%s' "$FW" | grep -q "eGovFrame"; then
  say "  ✅ 프로파일 = egov-maven (킷의 agent-scaffold가 그대로 적합)"
  say "     → /bootstrap-project 로 CLAUDE.md·harness·훅·conventions.enabled 이식."
elif [ "$BUILD" = "maven" ]; then
  say "  ◐ 프로파일 = maven-generic (eGov 아님)"
  say "     → agent-scaffold 사용하되 eGov 전용 조항(egovframework mapper 경로·eGov Boot Starter) 트리밍."
elif printf '%s' "$BUILD" | grep -q gradle; then
  say "  ⚠ 프로파일 = gradle (신규 필요)"
  say "     → harness의 Maven 컴파일 게이트는 미적용. Gradle용 검증(./gradlew build·test)으로 대체."
  say "     → agent-scaffold의 BUILD/모듈/harness.md 섹션을 Gradle 기준으로 재작성 필요."
else
  say "  ⚠ 프로파일 = non-JVM ($BUILD)"
  say "     → METHOD.md의 스택무관 코어(단일출처 CLAUDE.md·폐쇄루프·승격사다리)만 이식."
  say "     → harness/컨벤션 게이트는 이 스택 린터/빌드로 대체 설계."
fi
say ""
# 룰별 transfer 판정
say "  컨벤션 룰(harness check_conventions) 적용 판정:"
javaver="$(printf '%s' "$VER" | grep -oE '^[0-9]+' || true)"
if [ "$LANG_" = "java" ] && [ -n "$javaver" ] && [ "$javaver" -le 8 ] 2>/dev/null; then
  say "    · 룰 H(Java 9+ 금지) = ✅ 적용(이 프로젝트 Java $VER)"
elif [ "$LANG_" = "java" ] && [ -n "$javaver" ]; then
  say "    · 룰 H(Java 9+ 금지) = ❌ 비활성(Java $VER — 9+ 문법 허용됨). conventions.enabled에서 H 제외."
else
  say "    · 룰 H(Java 9+ 금지) = N/A(Java 아님)"
fi
if printf '%s' "$FW" | grep -q "MyBatis"; then
  say "    · 룰 A/E/F(SELECT*·CDATA·물리DELETE) = ✅ 적용(MyBatis)"
else
  say "    · 룰 A/E/F(MyBatis) = ❌ 비활성(MyBatis 아님)"
fi
say "    · 룰 B(매퍼 id 동작접두어)·D(퍼블 공통JS)·G(FQN) = 팀 컨벤션에 맞으면 유지, 아니면 conventions.enabled에서 제외(레포별 옵트인)."
say ""
say "  → 요약: METHOD.md의 방법론은 스택 불문 이식. 게이트/스캐폴드는 위 판정대로 프로파일 선택·룰 취사."
hr