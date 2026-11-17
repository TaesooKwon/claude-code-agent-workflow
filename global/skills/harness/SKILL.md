---
name: harness
model: sonnet
description: >-
  Validate the agent-target legacy Spring/eGovFrame Maven projects under
  __PROJECTS_DIR__ — runs the MyBatis contract check plus a
  repo-pinned Maven compile. Use whenever asked to build / compile / 검증 /
  validate / "하네스 돌려" one of these repos, or after editing .java/.xml in them.
  Encapsulates the correct local Maven repository so bare `mvn` (which falls
  back to the dependency-less ~/.m2 stub repo and fails) is never used.
---

# eGov Harness — 빌드·MyBatis 계약 검증

이 스킬은 `__PROJECTS_DIR__` 하위 레거시 Spring + eGovFrame **Maven 레포**의
**계약검사 + 컴파일**을 일관되게 실행한다. 대상 = eGovFrame 3.9.0 + MyBatis(WAR)
**및** eGov Boot Starter 기반 Spring Boot(멀티모듈 포함, 예: EXAMPLE_REPO). Gradle 레포는 범위 밖.

## 핵심 사실 (왜 저장소 고정이 필요한가)
- 기본 `~/.m2/repository` 의 egov POM은 `install:install-file` 스텁(의존성 0개)이라
  spring-webmvc/web/jdbc·poi·log4j·mybatis 등이 누락 → bare `mvn`은 **반드시 실패**한다.
- 정상 저장소는 `__HOME__/maven_repo/maven/repository` (egov 정상 POM 보유).
- 따라서 항상 `-Dmaven.repo.local=<그 경로>` 를 고정한다. 환경변수
  `MAVEN_REPO_LOCAL` 이 설정돼 있으면 그 값을 우선한다.

## 대상/제외 레포
- **대상(허용목록 — 에이전트 작업 레포)**: __AGENT_REPOS__.
- **제외**: 위 목록 밖의 레포는 Maven 이어도 빌드·일괄스캔하지 않는다. 새 레포를 대상에 넣는 것은 사용자가 정한다.

## 실행 절차
1. **프로젝트 루트 결정**: 호출 인자로 경로가 오면(`harness --repo <경로>` — 리뷰용 worktree 처럼
   프로젝트 디렉터리 **밖**이어도 된다) **그 경로가 루트**다(2026-09-03). 인자가 없으면 현재 위치에서
   `pom.xml` 이 있는 디렉터리를 찾는다. 레포가 한 단계 중첩일 수 있다(예: `(예시레포C)/(예시레포C)/pom.xml`).
   중첩이면 그 내부가 루트. 멀티모듈(예: EXAMPLE_REPO)이면 **parent `pom.xml` 디렉터리**가 루트(거기서 전체
   모듈이 빌드된다). ⚠️worktree 는 git 격리분(`.claude/conventions.enabled`·`schema-snapshot.json`)이 없으면
   컨벤션 lint·룰 K 가 조용히 꺼진다 — `wt-prereview.sh --with-scaffold` 로 복사한 뒤 돌린다.
2. **저장소 경로 결정**: `REPO="${MAVEN_REPO_LOCAL:-__HOME__/maven_repo/maven/repository}"`
3. **MyBatis 계약검사(번들 체커 = 단일 정본)**: 레포 내 복사본이 아니라 **스킬 번들** 체커를 쓴다.
   ```bash
   python3 __HOME__/.claude/skills/harness/check_mybatis_contract.py --repo <PROJECT_ROOT> --changed-only
   ```
   - 매퍼 루트·XML 네이밍(`_SQL.xml`/`_sql.xml`/`*_SQL_maria.xml`/`Mapper.xml` 등)을 **내용 기반 자동탐지**,
     멀티모듈은 레포 전체 walk. per-repo 설정 불필요.
   - ⚠️ 각 레포의 `src/main/tools/check_mybatis_contract.py`·`run_codex_harness.sh`(로컬 복사본)는 매퍼 루트가
     하드코딩돼 **오설정 시 0개 검사(거짓 통과)** 위험이 있다(예: (예시레포B)). **번들 체커만 신뢰**하고 복사본은 무시.
   - 변경 매퍼/XML이 없으면 "0 contracts" 로 즉시 통과. 전수검사는 `--changed-only` 생략.
   - **오탐 억제 2종(스코프 인식)** — 없으면 정상 매퍼가 대량 오탐으로 잡힌다(실측 경고: EXAMPLE_REPO 50→3,
     (예시레포D) 147→61, (예시레포E) 17→0. **Errors 는 전부 불변** = 탐지력 손실 없음). 〔2026-08-05〕
     ① **XML 지역변수 제외**: `<bind name="x">`·`<foreach item="x" index="i">`로 XML 안에서 생성되는 이름은
     DTO 필드/메서드 파라미터가 아니므로 `#{x}` 대조에서 뺀다(include된 `<sql>` 프래그먼트의 bind 포함).
     ② **resultMap 중첩 타입 분리**: `<collection ofType="X">`·`<association javaType="X">` 하위 property 는
     바깥 타입이 아니라 X 와 대조한다(보고 id 는 `outerMap > prop`). `resultMap` 속성 참조는 그 정의에서 검사.
   - ⚠️ 체커 룰을 손볼 땐 **최소 픽스처로 반증부터**: 오탐 제거는 "탐지를 꺼버린 실패"와 실레포 숫자가 똑같이
     줄어 구분이 안 된다. 억제돼야 할 케이스와 **여전히 잡혀야 할 진짜 위반**을 같은 픽스처에 함께 넣고 확인한다.
3.5. **컨벤션 정적검사(옵트인 레포 한정)**: 규약 중 컴파일·계약검사로 안 잡히던 텍스트 룰을 강제.
   ```bash
   python3 __HOME__/.claude/skills/harness/check_conventions.py --repo <PROJECT_ROOT> --changed-only
   ```
   - 룰 목록·판정 기준·예외 마커의 정본 = `check_conventions.py` 머리 docstring(살아 있는 룰 = `grep -n '^  [A-Z]\. ' check_conventions.py`). 위반 출력에 `[룰:태그] 설명` 이 함께 나오므로 평소엔 열 필요 없다 — 출력 해석이 막히거나 예외 마커가 필요할 때만 그 머리를 Read.
   - **옵트인 격리**: 레포 루트 `.claude/conventions.enabled` 마커가 있을 때만 실행(룰셋은 레포별 규약 — 마커 없는 형제 레포는 자동 skip). 강제 실행은 `--force`.
   - **예외 = 룰 V(select* 안의 쓰기, 경고 전용)**: 옵트인 마커와 별개로 레포 basename `__SELECT_WRITE_ALWAYS_REPO__`(킷 자리표시 — bootstrap 이 치환하지 않아 그대로면 그 밖의 레포와 같이 XML 탐지만 돈다. 라이브 사본을 직접 바꾸면 재설치 때 덮어써지고(백업 남음) doctor 가 드리프트로 보고하며 test_rule_tx 의 basename 테스트도 함께 바꿔야 한다 — 근본 해결 = rule_tx.py 룰 V 절의 자리표시 ponytail(`grep -n __SELECT_WRITE_ALWAYS_REPO__ rule_tx.py`) 업그레이드 경로) 는 항상, 그 밖은 `context-transaction.xml` 에 `select*` read-only 규칙·`masterSelect` 가 있을 때만 돈다(마커 없는 레포에선 룰 V 만). 예외 마커 `lint-select-write-ok`. 단위테스트 = `python3 -m unittest discover -s __HOME__/.claude/skills/harness -p 'test_*.py'`.
   - `--changed-only`는 **변경된 라인**에 걸린 위반만 잡는다(레거시 파일 무관 라인 수정 시 기존 위반 미발화). **줄을 지우기만 한 diff(삭제 헝크)는 추가 줄이 0이라 그 파일의 모든 라인 룰이 침묵한다** — 가드·방어 코드를 걷은 커밋은 전수(생략 모드)로 한 번 더 돌린다. 위반=exit 1 → 빌드 게이트. 전수 audit는 `--changed-only` 생략.
3.6. **ArchUnit 구조검사(옵트인·로컬 전용, 독립 프로젝트)**: 텍스트로 못 잡는 **바이트코드 의존 구조룰**(컨트롤러→Mapper 직접호출 금지·모듈격리)을 강제. `.claude/conventions.enabled` 마커 + `.claude/archunit/`(독립 Maven 프로젝트)가 있는 레포만 해당. **선행조건: 대상 모듈이 먼저 컴파일돼 있어야 한다**(아래 4단계 compile 후 실행 — ArchUnit이 `target/classes` 바이트코드를 직접 읽는다).
   ```bash
   ROOT=<PROJECT_ROOT>
   mvn -Dmaven.repo.local="$REPO" -f "$ROOT/.claude/archunit/pom.xml" test \
     -Darch.classesDirs="$ROOT/<ADMIN_MODULE>/target/classes,$ROOT/<FRONT_MODULE>/target/classes,$ROOT/<CORE_MODULE>/target/classes"
   ```
   - 룰: `@Mapper`·`*ServiceImpl`은 <CORE_MODULE>에만(웹 모듈 격리) / `@Controller`는 `..mapper..` 직접 의존 금지(Service 경유). 위반=BUILD FAILURE(테스트가 위치 콕 집어 출력).
   - **팀 pom 무수정 격리(중요)**: ArchUnit은 **팀 레포 pom·테스트를 전혀 건드리지 않는** `.claude/archunit/` 독립 Maven 프로젝트로 산다(`.claude/`가 `.git/info/exclude` 격리라 자동 미커밋). **skip-worktree로 팀 pom에 archunit 의존을 얹는 방식은 폐기** — 팀이 그 pom을 수정하면 git 이 로컬 변경을 못 덮어써 pull/merge 가 막히는 사고를 유발한다. 독립 프로젝트는 컴파일된 `target/classes`를 `importPaths`로 읽고, 애노테이션 매칭은 **FQN 문자열 오버로드**(`areAnnotatedWith("...Mapper")`)라 스프링/마이바티스를 클래스패스에 둘 필요가 없다(archunit-junit4 의존 하나면 됨). archunit 1.3.0은 고정 저장소에 선반영 필요(`dependency:get`, 최초 1회). 룰이 `allowEmptyShould(true)`라 임포트 0개면 공허 통과 위험 → 셋업 검증 시 룰 하나를 일부러 깨 위반이 잡히는지(이빨) 1회 확인.
4. **저장소 고정 컴파일(변경-모듈 스코프 기본)**: `local` 프로파일이 있으면(`grep '<id>local</id>' pom.xml`) `-Plocal`, 없으면 뺀다.
   ```bash
   cd <PROJECT_ROOT> && mvn -Dmaven.repo.local="$REPO" [-Plocal] [-pl <모듈목록> -am] compile
   ```
   - **스코프 판정(멀티모듈)**: `git status --porcelain`(변경+스테이징+신규)의 파일 경로 최상위 디렉터리로 변경 모듈을 판정해 `-pl`로 좁힌다 — `-am`이 상류 의존(예: <ADMIN_MODULE> → <CORE_MODULE>)을 함께 빌드하므로 **변경 모듈만 나열**하면 된다. 예: Core만 변경 → `-pl <CORE_MODULE>`, Admin(+Core) 변경 → `-pl <ADMIN_MODULE> -am`, Admin·Front 둘 다 → `-pl <ADMIN_MODULE>,<FRONT_MODULE> -am`.
   - **전체 빌드 폴백(스코프 금지 조건)**: ①parent/루트 `pom.xml` 변경 ②모듈 판정 불가 경로(루트 파일·스크립트만 변경) ③`git pull` 직후 스모크(타 모듈에 팀 변경 유입) ④의존 그래프 신뢰 불가(직전 빌드가 깨졌거나 브랜치 전환 직후) — 이때는 `-pl` 없이 전체.
   - **`clean` 생략 기본**: 증분 컴파일로 충분하다. `clean`은 ①pom/의존 변경 ②리소스·생성물 이상 의심 ③빌드 결과가 소스와 안 맞는 징후(stale class) 때만.
   - 테스트는 HSQL 등 별도 셋업이 필요할 수 있으니 `compile`까지만; `test`는 요청 시에만.
     요청 시(멀티모듈) = `bash ~/.claude/skills/harness/harness.sh test <모듈>[,<모듈>…]` — 레포 루트에서 `mvn test -pl <모듈> -am -B -ntp -Dmaven.repo.local=<핀>` 을 대신 돌리고 끝에 모듈별 `Tests run`·BUILD 결과를 한 줄씩 요약(모듈 = 루트 pom `<module>` 허용 목록, 다른 goal 거부, 출력을 자르지 말 것).
     래퍼를 쓰기 전에 그 레포 기록기가 래퍼를 인식하는지 확인한다 — `grep -n 'harness/harness.sh' .claude/hooks/mvn-test-record.sh` 가 0건이면 기록이 안 남아 커밋 게이트가 막으니 `mvn test -pl <모듈> -am -Dmaven.repo.local=<핀>` 을 직접 돌린다(인식하는 명령 형태는 그 기록기 주석이 정본).
5. **범위 가드**: 위 3·4는 **Maven 레포**(루트 `pom.xml` O, `build.gradle` X) 전용 — eGov WAR이든 Spring
   Boot이든 동일 처리. Gradle/제외 레포는 위 [대상/제외]대로 손대지 않는다. Maven인데 사내 nexus/VPN
   의존으로 빌드가 깨지면 추측 말고 아래 **실패 분류**로 보고한다.

## 실패 시 분류(자가 진단)
- `maven-default-http-blocker ... blocked` → `pom.xml` 의 `<repository><url>` 이 http다.
  https로 교정한다(레퍼런스 (예시레포A)): `mvn2`→`https://repo1.maven.org/maven2/`,
  `egovframe`→`https://maven.egovframe.go.kr/maven/`.
- `invalid target release: 11` → 프로젝트가 Java 11 타깃인데 JDK 8로 실행됨.
  `JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home` 로 재실행.
- `... (absent) ... nexus.internal.example.com` 등 사내 nexus 의존 → 로컬 부재 + 사내
  저장소(VPN) 필요. 오프라인 해결 불가임을 보고한다.
- `present, but unavailable` (캐시 출처 불명) → 위 http 교정으로 대부분 해소된다.

## 출력
1. 계약검사 결과(PASS/위반)
2. 컨벤션 정적검사 결과(옵트인 레포: PASS/위반·skip)
3. 빌드 결과(BUILD SUCCESS/FAILURE) + 실패 시 핵심 ERROR 줄과 위 분류
4. 변경 파일 요약

## 주의
- 절대 bare `mvn (clean) compile` 로 검증하지 말 것(스텁 저장소 폴백).
- 빌드 산출물(target) 외 소스/DB를 변경하지 말 것.
- 검증 통과 후에는 프로젝트 규약대로 `docs/agent_history.md` 기록을 잊지 말 것.
