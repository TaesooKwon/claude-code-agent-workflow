# SETUP — 새 머신에서 전역 에이전트 레이어 세우기 (런북)

> 이 킷으로 **새 머신**에 개인 Claude Code 에이전트 워크플로우(규약·훅·게이트·
> 폐쇄형 학습루프·스캐폴드)를 세운다. 아래 순서를 그대로 따르면 된다.
> 방법론(스택 불문 원칙)은 `METHOD.md`, 스택 판정은 `analyze-stack.sh` 참조.
> **문제 생기면 무엇이든 `./doctor.sh` 부터.**

---

## 0. Claude Code 설치 + 로그인 (전제)

이 킷은 **Claude Code를 보강**하는 레이어다. 먼저 Claude Code 자체를 설치하고 로그인한다(설치 시 `~/.claude/`와 자격증명 생성).

```bash
# 설치 방법은 공식 문서 기준(예: npm i -g @anthropic-ai/claude-code 또는 네이티브 설치)
claude --version          # 설치 확인
# 최초 로그인(브라우저 인증) — ~/.claude/ 생성
```

> 순서 주의: Claude Code를 한 번 띄우면 `~/.claude/settings.json`이 선생성될 수 있다. 그래도 킷 훅 등록은 들어간다 —
> `bootstrap-machine.sh`는 기존 `settings.json`을 통째로 덮어쓰지 않고 병합한다 — **`hooks.Stop` 을 킷 템플릿 것으로 통째 교체**(라이브에만 있는 Stop 원소는 사라진다)하고, PreToolUse 에 `destructive-cmd-ask` 등록을 보장하고(matcher 가 킷 것으로 바뀔 수 있다 — 조건은 `bootstrap-machine.sh` 의 settings jq), Stop 밖 이벤트에서 템플릿의 훅이 같은 이벤트에 없으면(스크립트 파일명 기준 — hook-obs 래퍼 꼴도 등록으로 센다) 템플릿의 matcher 그룹째 뒤에 붙이고, `permissions.deny` 가 아예 없으면 킷 deny 를 넣는다. 그 밖(statusline·MCP·기존 hooks 등록·순서·matcher·기존 권한)은 보존, 바꾸기 전 `.bak-<시각>` 백업(4절). 기존 파일이 이상 형식이면 건드리지 않고 `✗ settings.json 갱신 실패` 를 안내한다.

## 1. 사전 프로그램 설치 (mac)

Homebrew → 필수(`jq`·`python3`·`git`) + 선택(`node`·`maven`, JVM 빌드/statusline용).

```bash
# Homebrew (없으면)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install jq python3 git      # 필수
brew install node maven          # 선택(JVM 빌드·statusline 시)
```

확인:

```bash
jq --version && python3 --version && git --version   # 필수 3종
node --version && mvn --version                       # 선택 2종
```

`jq`·`python3`·`git` 없으면 부트스트랩/훅/doctor가 동작 안 함. `node`·`mvn`은 없어도 설치는 되고 doctor가 경고만 낸다.

## 2. 킷 clone

```bash
git clone https://github.com/TaesooKwon/claude-code-agent-workflow ~/claude-agent-kit
cd ~/claude-agent-kit
```

(로컬 킷을 그대로 복사해 왔다면 clone 생략, 해당 디렉터리로 `cd`.)

## 3. machine.env 설정

머신 고유값은 `machine.env`에 담고 **이 파일은 gitignore로 커밋 제외**(시크릿·경로). `.example`만 커밋된다.

**자동(권장)** — `init-machine-env.sh`가 이 머신을 파악해 채운다(PROJECTS_DIR·MAVEN_REPO 감지, STRICT_PROJECT 비움):

```bash
./init-machine-env.sh                    # 자동 감지
# ./init-machine-env.sh --projects=<경로>  # PROJECTS_DIR 직접 지정
```

출력된 값을 확인하고 필요하면 손수 수정한다. (Claude Code에게 "새 PC에서 machine.env 파악해서 채워줘"라고 해도 이 스크립트를 돌려준다.)

**수동** — 직접 채우려면:

```bash
cp machine.env.example machine.env
vi machine.env
```

채울 값:

| 변수 | 의미 | 기본/권장 |
|---|---|---|
| `PROJECTS_DIR` | 레포들이 모인 루트 디렉터리. 훅의 스코프 판정에 쓰임. | `$HOME/projects` (실제 작업 디렉터리로) |
| `STRICT_PROJECT` | 폐쇄루프 2채널(history AND memory) 강제를 걸 프로젝트명(정확히 일치). 비우면 전 프로젝트 OR 모드(history 또는 memory 하나면 통과). | **비움 권장**(새 머신 기본) |
| `MAVEN_REPO` | (선택) maven 오프라인 로컬 저장소. eGov 오프라인 빌드용. 없으면 doctor가 경고만. | `$HOME/maven_repo/maven/repository` |
| `AGENT_REPOS` | 하네스·E2E 대상 레포 허용목록(harness 스킬 "대상" 줄에 치환). 값에 백틱이 있으면 **작은따옴표로 감싼다**. 비우면 안내 문구가 설치된다. `init-machine-env.sh` 를 다시 돌려도 기존 줄을 보존한다. | `` '`repoA`·`repoB`' `` |

## 4. bootstrap-machine.sh 실행

`global/` 자산을 `machine.env` 값으로 **토큰 치환**(`__HOME__`·`__PROJECTS_DIR__`·`__STRICT_PROJECT__`·`__MAVEN_REPO__`·`__AGENT_REPOS__`)해 `~/.claude/`로 설치한다. **멱등**(내용 다를 때만 `.bak-<시각>` 백업 후 덮어씀).

```bash
./bootstrap-machine.sh --dry-run    # 무엇이 설치되는지 먼저 확인(권장)
./bootstrap-machine.sh              # 실제 설치
```

설치되는 것:

- `~/.claude/hooks/*.sh` — 킷 `global/hooks/` 의 훅(설치 후 `+x`)
- `~/.claude/skills/` — `global/skills/` 아래 스킬 폴더(목록 = `ls global/skills`, 파일별 치환 설치)
- `~/.claude/agent-scaffold/` — 새 레포 부트스트랩용 스캐폴드
- `~/.claude/agents/` — 에이전트 정의(있으면)
- `~/.claude/CLAUDE.md` — 전역 규약
- `~/.claude/settings.json` — 없으면 설치. **이미 있으면 jq로 `hooks.Stop` 을 킷 템플릿 것으로 통째 교체**(라이브에만 있는 Stop 원소는 사라진다)하고, PreToolUse 에 `destructive-cmd-ask` 등록을 보장하고(matcher 가 킷 것으로 바뀔 수 있다 — 조건은 `bootstrap-machine.sh` 의 settings jq), 템플릿의 그 밖 이벤트 훅 중 같은 이벤트에 없는 것을 추가하고(스크립트 파일명 기준 — 판정 규칙은 그 jq 의 `hnames`), `permissions.deny` 가 아예 없으면 킷 deny 를 넣는다. 그 밖(statusline·MCP·기존 hooks 등록·기존 권한)은 보존, 바꾸기 전 `.bak-<시각>` 백업. 멱등(이미 정합이면 "동일") · `--dry-run` 은 추가될 등록(`이벤트:파일명`)을 안내만 한다 · 기존 파일이 이상 형식이면 그대로 두고 실패 안내. `jq`/`python3`/`git` 없으면 스크립트가 **최상단에서 즉시 중단**(exit 1)하고 `brew install` 안내 — 설치되는 훅 전부가 이 3종에 의존하므로 "설치는 됐는데 훅이 조용히 깨짐"을 원천 차단.

## 5. doctor.sh 검진

설치 직후, 또는 "훅이 안 도는데?" 싶을 때 아무 때나 실행. 문제 있으면 exit 1.

```bash
./doctor.sh
```

점검 항목:

1. **의존 프로그램** — `jq`/`python3`/`git` 없으면 **✗ 실패**, `node`/`mvn` 없으면 ⚠ 경고.
2. **전역 자산 설치** — `CLAUDE.md`·`settings.json`·`hooks`·`skills/harness`·`skills/bootstrap-project`·`agent-scaffold` 존재.
3. **훅 설치·실행권한** — 킷 핵심 Stop 훅(`closed-loop-history`·`convention-gate`·`history-rotate-check`)의 파일+`+x`.
4. **Stop 훅 등록** — `settings.json`의 `hooks.Stop`에 [3]의 핵심 훅이 등록됐는지. **미등록이면 ✗ 실패**(킷의 핵심 강제층이라 "doctor는 괜찮다는데 훅이 죽어있음"을 차단 → bootstrap 재실행으로 Stop 을 킷 템플릿 것으로 교체).
5. **경로 드리프트** — 훅/settings **내용**에 현재 홈(`$HOME`)과 다른 절대경로(예: 이전 사용자 `/Users/olduser/…`)가 박혀있지 않은지, statusline node 경로 유효성.
   - **5b. settings.json 키 드리프트** — 라이브 top-level 키가 킷 템플릿에 있는지, 이벤트별 훅 등록 집합이 같은지(⚠ — `kit-drift-exclude.txt` 의 `hooks/` 줄은 뺀다).
   - **5c. 내용 드리프트** — `hooks`·`agent-scaffold`·`skills`·`agents` 를 토큰 치환 후 라이브와 대조, 라이브에만 있는 전역 훅 역방향 검출(⚠).
   - **5d. 팀 좌석+Paseo 모듈(선택)** — (공개 스냅샷에는 모듈이 없어 "모듈 패키지 없음 — 건너뜀"으로 끝난다) `~/.claude-team` 이 있거나 모듈 훅이 등록된 머신에서만: 모듈 훅 설치·`+x`·패키지와 동일성, 등록, 좌석 필수 링크(`CLAUDE.md` → `rules-lite.md`, 나머지 → `~/.claude`), `lite.json` 필수 제외 경로(좌석 `CLAUDE.md` 를 제외하면 ⚠), `~/.claude-team/run` 권한 700, 좌석 bin, 셸 rc 의 `claude-team` 별칭에 `--append-system-prompt-file` 이 남았으면 ⚠, 전역 「추가」 조항, Paseo `claude-team` provider(없음·`claude-seat.sh` 없음·`--append-system-prompt-file` 있음, 래퍼가 있으면 래퍼 파일·`CLAUDE_SEAT_BIN`·`CLAUDE_SEAT_LITE` 중 하나라도 없거나 쓸 수 없으면 ⚠, 읽기 전용). 해당 없으면 "건너뜀". 설치 절차 = 모듈의 `INSTALL.md`(공개 스냅샷 미포함).
   - **5g. 전역 deny 대조** — 라이브 `permissions.deny` 와 킷 템플릿 deny 를 대조(⚠ — 라이브에만 있음 / 템플릿에만 있는데 `settings-deny-kit-only.txt` 에 미등록 / 등록인데 템플릿에 없음(등록이 낡음), deny 가 문자열 배열이 아니면 판정 불가 ⚠ · 등록 항목이 라이브·템플릿에 다 있으면 ✓ 정보 — 킷 기본값 그대로).
6. **JVM 빌드 관문(선택)** — `MAVEN_REPO`(machine.env 반영) 오프라인 레포 존재 여부(없으면 ⚠, 6절 참조).
7. **Playwright 의존(선택)** — 시각검증 스킬의 `node_modules` 설치 여부(미설치 ⚠, 7절 참조).
8. **Java LSP(jdtls, 선택)** — jdtls 심 설치·PATH 순서(⚠).
9. **상시 로드 규약 크기·`.bak` 잔존** — 전역 `CLAUDE.md` 크기 상한, 라이브 `.bak` 파일 수(⚠ 비차단).

**✗(실패)** 는 조치 필수, **⚠(경고)** 는 스택/선택 항목이라 해당 없으면 무시 가능.

## 6. [선택] JVM 빌드 관문 — maven 오프라인 레포

**킷에는 maven 레포가 없다**(용량). eGov/Maven 프로젝트를 빌드하려면 이게 **오프라인 빌드의 실질 최대 관문**이다.

- 이유: 기본 `~/.m2`의 egov POM은 의존성 0개 스텁이라 bare `mvn`은 반드시 실패. 정상 저장소(`__HOME__/maven_repo/maven/repository`)가 있어야 harness가 `-Dmaven.repo.local=`로 고정 컴파일한다(`global/skills/harness/SKILL.md` 참조).
- 확보 방법 둘 중 하나:
  - **백업 드라이브에서 복사** — 이전 머신의 `~/maven_repo/maven/repository`를 그대로 복사(가장 확실).
  - **mvn 재구성** — 온라인에서 프로젝트를 한 번 정상 빌드해 로컬 저장소를 채운 뒤 그 경로를 `MAVEN_REPO`로.
- 채운 뒤 `MAVEN_REPO`를 `machine.env`에 맞추고 `./doctor.sh`로 존재 확인. JVM 프로젝트를 안 다루면 이 절 전체 건너뛰어도 된다.

## 7. [선택] 킷 범위 밖 항목 (간단 안내)

`settings.json.template`은 이식 가능한 공통(권한·훅 등록 `hooks`·`theme`·팀 에이전트 플래그 `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`·`teammateMode`·`enabledMcpjsonServers` 플레이스홀더)을 담는다.
> ⚠️ **적용 시점 주의:** `bootstrap-machine.sh`는 **settings.json 이 없으면 템플릿을 통째로 설치**(→ theme·팀 플래그·MCP 전부 적용), **이미 있으면 `hooks.Stop` 을 킷 것으로 통째 교체**(라이브에만 있는 Stop 원소는 사라진다 — 백업 .bak-<시각>)하고 `destructive-cmd-ask` 등록 보장·빠진 킷 훅 등록 추가·deny 가 없을 때만 킷 deny 주입(4절) 외의 키(theme·env·MCP·기존 권한)는 **기존값 보존**(덮어쓰지 않음). 즉 위 신규 키는 **새(빈) 머신에서만 자동 반영**되고, 기존 settings.json 이 있는 머신엔 수동으로 추가한다.

아래는 머신·플러그인·시크릿 고유라 킷에서 제외 — 필요하면 수동 구성:

- **Playwright 시각검증 의존** — `playwright-verify` 스킬은 설치되지만 `node_modules`는 킷에 없다(gitignore). 시각검증을 쓰려면 브라우저·의존을 한 번 설치:
  ```bash
  cd ~/.claude/skills/playwright-verify && npm ci && npx playwright install chromium
  ```
  안 쓰면 생략(검증은 수동/다른 수단으로).
- **플러그인 클러스터 3키 — `statusLine`·`enabledPlugins`·`extraKnownMarketplaces`**: 라이브 settings.json의 이 3키는 **절대경로가 박혀 있어 그대로 복사하면 새 머신에서 깨진다**(statusLine=nvm node 경로+claude-hud dist 캐시경로, extraKnownMarketplaces=claude-hud github 소스). 그래서 **값 복사가 아니라 플러그인 설치로 재현**한다 — 설치하면 Claude Code가 이 3키를 머신에 맞는 경로로 **자동 기록**한다:
  - `claude-hud`(statusline) — 마켓플레이스 설치 후 `claude-hud:setup` 스킬로 `statusLine.command` 자동 등록. doctor 5절이 node 경로 유효성 검사.
  - `jdtls-lsp`(Java LSP) — §11. `swift-lsp`는 라이브에서 `false`(비활성)라 재현 대상 아님.
- **MCP DB 서버** — 회사 dev/운영 DB MCP는 접속정보·시크릿이라 킷에 없음. 템플릿 `enabledMcpjsonServers`엔 `__PROJECT__-dev-db` 플레이스홀더만 있으니 새 환경에서 실제 서버명으로 교체. 운영 DB MCP 는 `enabledMcpjsonServers` 에 넣지 않고(세션 시작 때 승인 질문), **서버명을 `-db` 로 끝나게(개발 DB 는 `-dev-db`·`-devserver-db` — 훅의 개발 접미사 명시 목록) 짓는다** — `destructive-cmd-ask.sh` 가 이름 규칙(소문자화해 `-db` 로 끝나고 개발 접미사가 아니면 ask)으로 확인창을 띄우고, settings matcher `Bash|mcp__.*-[Dd][Bb]__.*` 는 bootstrap 이 보장한다(서버명 교체 작업 없음, 실명은 킷에 넣지 않는다 — doctor [5e] 가 반출 검사). 라이브 `permissions.ask` 에 운영 서버명을 따로 적는 것은 선택(보조 층)이다(접속정보는 각 프로젝트 `.mcp.json`을 `bootstrap-project`로 배선, 비번은 env-var/`machine.env`).
- **전역 MCP(context7)** — 시크릿 없는 공용 문서조회 MCP. 새 머신에서 한 번 등록: `claude mcp add context7 -- npx -y @upstash/context7-mcp`.
- **`settings.local.json`(머신 로컬 override)** — 킷 `global/settings.local.json.example` 참고해 `~/.claude/settings.local.json`으로 복사(프로젝트별 임시 허용 등, 커밋 안 됨).

## 8. 완료 알림 (은퇴)

2026-11-19 은퇴 — 킷은 완료 알림을 내지 않는다. 이전에 설치한 머신은 `~/.claude/settings.json` 의 `hooks.Stop` 에서 `notify-done` 등록을 먼저 빼고(jq 로 그 원소만 삭제 — `bootstrap-machine.sh` 재실행은 라이브에만 있는 Stop 원소까지 지운다) 그다음 `~/.claude/hooks/notify-done.sh`·`notify-done.test.sh` 를 지운다. 완료 알림이 필요하면 Claude Code 내장 알림(`preferredNotifChannel`)이나 Paseo 앱 푸시를 쓴다.

## 9. 새 프로젝트에 적용

레포마다 스택이 다르므로, `/bootstrap-project` **전에** 스택을 판정한다.

```bash
./analyze-stack.sh <repo_경로>     # 생략 시 현재 디렉터리
```

출력 = 빌드툴/언어·버전/모듈구조/프레임워크/테스트 리포트 + 프로파일·룰 권고. 프로파일별 대응:

- **egov-maven** (Maven + eGovFrame 감지) → 킷 스캐폴드 그대로. `/bootstrap-project`로 `CLAUDE.md`·harness·훅·`conventions.enabled` 이식.
- **maven-generic** (Maven, eGov 아님) → 스캐폴드 쓰되 eGov 전용 조항(egovframework mapper 경로·eGov Boot Starter) 트리밍.
- **gradle** → harness의 Maven 컴파일 게이트 미적용. `./gradlew build`·`test`로 검증 대체, harness.md 섹션 재작성.
- **non-JVM** → `METHOD.md`의 스택무관 코어(단일출처 CLAUDE.md·폐쇄루프·승격사다리)만 이식, 게이트는 그 스택 린터로 대체 설계.

**룰 취사**(analyze-stack가 판정해줌):

- 룰 H(Java 9+ 금지) = Java ≤8 프로젝트만 켜기(Java 17이면 `conventions.enabled`에서 제외).
- 룰 A/E/F(SELECT*·CDATA·물리DELETE) = MyBatis일 때만.
- 룰 B(매퍼 id 동작접두어)·D(퍼블 공통JS)·G(FQN) = 팀 컨벤션에 맞으면 유지, 아니면 레포별 옵트인에서 제외.

판정 확인 후 `/bootstrap-project` 스킬로 해당 레포에 구성 이식. 커밋 게이트는 settings 가 아니라 층 A git 훅(`.claude/scripts/install-git-hooks.sh`)에 있다 — 스킬 1단계 순서(층 A 설치 → `--check` rc 0 → 그다음 settings)를 지킨다(층 A 없이 깔린 settings 에선 `git-hooks-installed-guard.sh` 가 에이전트 커밋을 막는다).

## 10. 킷에 없는 것 (반출 금지 회사 자산)

이식성·기밀 때문에 킷에서 **의도적으로 제외**. 새 환경에선 각자 다시 확보:

- **memory** — 회사·프로젝트 고유 학습(도메인 결정·함정·진행상태). 새 프로젝트에서 폐쇄루프로 새로 쌓임.
- **DB 접속정보 / MCP 시크릿** — dev/운영 DB 접속·토큰.
- **maven 오프라인 레포** — 용량·회사 의존(6절 참조, 별도 확보).
- **도메인 표준값** — 회사 코드체계(사용자유형·학교급 등). 새 회사 도메인으로 대체.
- **회사 회귀 스위트** — 프로젝트별 E2E 케이스.
- **standard-db-naming 원본 사전** — 원본 엑셀(`assets/*.xlsx`)은 프로젝트 고유 자료라 킷에 없다(gitignore). 공공데이터 공통표준용어 등을 `assets/` 에 두고 `scripts/build_dictionary_db.py` 로 sqlite 사전을 만든다(열 구성 = 스킬 `SKILL.md`).

## 11. [선택] Java LSP(jdtls) — 코드 인텔리전스

대형 JVM 멀티모듈에서 grep 대신 컴파일러 수준 탐색(goToDefinition·findReferences·incomingCalls 등)을 쓰기 위한 셋업. LSP 도구는 세션에서 ToolSearch `select:LSP`로 로드한다.

**구성 3층:**

```bash
brew install jdtls                                        # 1) 바이너리 (Java 21+ 필요)
claude plugin install jdtls-lsp@claude-plugins-official   # 2) 공식 플러그인 — .java에 jdtls 배선
# 3) 래퍼 심 ~/.local/bin/jdtls — bootstrap-machine.sh가 자동 설치(global/bin/jdtls)
```

**심이 해결하는 함정 2개**(둘 다 실측으로 잡은 것):

1. **JAVA_HOME 충돌** — 셸 기본 JAVA_HOME이 프로젝트 빌드용 Java 8이면 jdtls가 "requires at least Java 21"로 즉사. 심이 그 프로세스만 Java 21로 지정(빌드 환경 무영향).
2. **Lombok 미처리** — javaagent 없으면 `@Getter`/`@Builder`/`@RequiredArgsConstructor` 바인딩이 깨져 **findReferences가 self만 반환**(goToDefinition·심볼 인덱스는 바인딩 불완전해도 동작해서 반쯤 되는 것처럼 보임 — 함정). 심이 로컬 maven 레포에서 lombok jar 최신판을 자동 탐색해 `--jvm-arg=-javaagent:`로 주입.

**전제:** `~/.local/bin`이 PATH에서 homebrew보다 **앞**이어야 플러그인이 심을 집는다(doctor [8]이 검진).

**운영 노트:**
- 플러그인 `lspServers`는 **세션 시작 시 로드** — 설치/심 변경 직후엔 "No LSP server available for file type: .java". `/clear`로는 재로드 안 됨, **CLI 완전 재시작** 필요.
- 인터페이스 메서드의 전체 지형 = **findReferences + goToImplementation 조합**(jdtls 관례상 findReferences는 오버라이드 구현 선언을 참조로 세지 않음). 구현체 기준 `incomingCalls`는 호출 메서드·위치까지 정확.

---

**문제 시 `./doctor.sh` 먼저.**
