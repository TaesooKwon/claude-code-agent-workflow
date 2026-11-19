# claude-code-agent-workflow

[![test](https://github.com/TaesooKwon/claude-code-agent-workflow/actions/workflows/test.yml/badge.svg)](https://github.com/TaesooKwon/claude-code-agent-workflow/actions/workflows/test.yml)

**Claude Code 에이전트를 "규약 → 훅 → 게이트"로 통제하는 개인 워크플로우 킷.**

레거시 eGovFrame/Spring + Maven 프로젝트에서 AI 코딩 에이전트를 실무에 쓰며 만든 규약(`CLAUDE.md`)·훅·커밋 게이트·폐쇄형 학습 루프·프로젝트 스캐폴드를 한 레포에 담았다. 새 머신에서도 몇 커맨드로 같은 환경을 재현한다.

> 이 레포는 개인적으로 개발·운영 중인 비공개 원본의 **공개용 스냅샷**이다(2026-06 ~ 2026-11 개발).
> 실무 프로젝트명·사내 식별자는 가명(`예시 레포`·`지역A`·`App.*`)으로 바꿨고, 회사 코드·데이터·접속정보는 포함하지 않는다.

**3분 요약 → [`docs/CASE_STUDY.md`](docs/CASE_STUDY.md)** (문제·설계 원칙·구현·실측 결과)

## 핵심 아이디어

- **선언은 어겨진다 → 강제로 승격한다.** 반복되는 실수는 규약(문서) → 스킬(절차) → 훅·게이트(차단) 순으로 올린다(`METHOD.md` §3).
- **리뷰 무게는 diff 크기가 아니라 성격에 비례한다.** staged diff 를 기계적으로 A/B 티어로 나눠, 실행 의미가 바뀐 변경에만 다각 리뷰를 건다(§5).
- **에이전트의 "확인했다"를 믿지 않는다.** 커밋 게이트·리뷰 마커·지문 대조·테스트 반증검사(일부러 깨뜨려 빨간불 확인)를 훅으로 강제한다.
- **상시 로드 토큰은 고정비다.** 규약엔 규칙만, 근거·사례는 `global/rules-rationale/` 로 밀어낸다(§9).
- 훅 동작은 `./test-hooks.sh` 회귀 테스트(167건)로 검증한다.

## 왜 있나

프로젝트 단위 부트스트랩(`/bootstrap-project`)은 한 레포 안에 에이전트 구성을 깔아준다. 하지만 그 위에 있는 **머신 전역 레이어**(전역 `CLAUDE.md`, 훅, harness 엔진, agent-scaffold, settings 템플릿)는 어디에도 버전관리되지 않는다 — PC를 바꾸면 통째로 공백이 된다. 이 킷이 그 전역 레이어를 **스크럽·토큰화**해 담아, 재현 가능한 이식 단위로 만든다.

## 새 PC 재현 (4스텝)

```bash
# 0) 전제: Claude Code 설치+로그인 (~/.claude 생성) — SETUP.md 0절

# 1) clone
git clone https://github.com/TaesooKwon/claude-code-agent-workflow ~/claude-agent-kit && cd ~/claude-agent-kit

# 2) machine.env 자동 생성 (머신 파악 — PROJECTS_DIR·MAVEN_REPO 감지)
./init-machine-env.sh

# 3) 전역 레이어 설치 (~/.claude/로 토큰치환 설치)
./bootstrap-machine.sh

# 4) 검진
./doctor.sh
```

출력된 값을 확인하고 필요하면 손수 고친다. Claude Code에게 "새 PC에서 machine.env 파악해서 채워줘"라고 해도 2)를 대신 돌려준다.

이후 프로젝트마다: `./analyze-stack.sh <repo>` 로 스택 판정 → Claude Code에서 `/bootstrap-project`.

- 전제: **Claude Code 설치+로그인**(이 킷이 보강하는 대상 — `~/.claude/` 생성). 상세 순서는 SETUP.md 0절.
- 필수: `jq` · `python3` · `git`. 선택: `node`(statusline) · `mvn`(JVM 빌드). — node/mvn 없으면 doctor가 경고만.

## 파일 레이아웃

| 경로 | 역할 |
|---|---|
| `METHOD.md` | 스택 불문 방법론 — 단일출처·폐쇄루프·승격사다리·게이트·위임경제·모듈격리·설정격리·스택적응 |
| `SETUP.md` | 상세 설치·머신 부트스트랩 가이드 |
| `analyze-stack.sh` | 대상 레포 스택 감지(빌드툴·Java버전·단일/멀티모듈·프레임워크·테스트) → 프로파일 권고·룰 취사 |
| `bootstrap-machine.sh` | `machine.env` 값으로 토큰 치환해 `global/` 자산을 `~/.claude/`로 설치(멱등·백업) |
| `doctor.sh` | 의존·훅 등록·경로 드리프트 검진 |
| `test-hooks.sh` | 훅 **동작** 회귀 테스트(167건) — 가드 차단/통과·SessionStart 주입/침묵·Stop 판정·fail-open 등 구간별 검사(doctor는 설치만, 이건 판정 로직) |
| `init-machine-env.sh` | 새 머신에서 `machine.env` 자동 파악·생성(PROJECTS_DIR·MAVEN_REPO 감지) |
| `machine.env.example` | 머신 고유값 템플릿(실값은 `machine.env`로 gitignore) |
| `test-kit-drift-check.sh` | 킷 ↔ 설치본 내용 드리프트 검사(`kit-drift-check.sh`) 회귀 테스트 |
| `test-fixtures/hooks/` | `test-hooks.sh` 가 직접 실행하는 토큰 미치환 훅 사본 |
| `global/` | 스크럽·토큰화된 전역 자산 — 훅·스킬(`global/skills/`)·agent-scaffold·전역 CLAUDE.md·규약 근거(`rules-rationale/`)·settings 템플릿 |
| (제외) `global/modules/team-seat/` | 보조 좌석 세션 위임 모듈 — 개인 환경 종속이라 공개 스냅샷에서는 뺐다. 규약·doctor 는 모듈이 없으면 메인 단독으로 동작한다 |

문서 속 `[[이름]]` 은 `global/rules-rationale/<이름>.md` 를 가리킨다. 그 폴더에 없는 이름은 비공개 원본의 개인 memory 링크라 이 스냅샷에는 없다.

`global/` 안의 값은 토큰(`__HOME__`·`__PROJECTS_DIR__`·`__STRICT_PROJECT__`·`__MAVEN_REPO__`·`__AGENT_REPOS__`)으로 비워져 있고, `bootstrap-machine.sh`가 `machine.env`의 실값으로 치환해 설치한다.

## 스택 적응

킷의 스캐폴드는 eGov/Maven/Java8 프로젝트에서 정립됐지만, **원칙은 불변·도구는 스택따라**다(METHOD.md §8). `analyze-stack.sh`가 대상 레포의 빌드툴·Java 버전·단일/멀티모듈을 판정해 **룰을 취사**한다:

- Java 8이면 "Java 9+ 문법 금지"(룰 H) 켜고, **Java 17이면 자동 비활성**.
- MyBatis 룰은 MyBatis 레포에서만, 모듈 격리 조항은 멀티모듈일 때만.
- Maven 컴파일 게이트가 안 맞으면 그 스택 빌드(`./gradlew build` 등)로 대체 권고.

eGov-Maven이면 스캐폴드 그대로, 다른 Maven이면 트리밍, Gradle·비-JVM이면 재작성 — 프로파일을 권고한다.

## 격리·프라이버시

- 회사 데이터·시크릿·운영 접속정보는 **킷에 미포함**(익명화·제외).
- 머신 고유값·시크릿은 `machine.env`에만 두며 `.gitignore`로 커밋 제외(`.example`만 커밋).
- 에이전트 구성은 팀 레포에 섞지 않는다 — 각 프로젝트에선 `.git/info/exclude` 로 격리한다(설정 격리, METHOD.md §7).
- 실무에서 나온 사례·수치는 프로젝트명·식별자를 가명 처리해 근거 문서에만 남겼다.

## 라이선스

[MIT](LICENSE)

## 더 읽기

- [`METHOD.md`](METHOD.md) — 왜 이렇게 하는가(스택 불문 방법론).
- [`SETUP.md`](SETUP.md) — 새 머신에 어떻게 까는가(설치 상세).
