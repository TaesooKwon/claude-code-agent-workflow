---
name: bootstrap-project
description: 신규(또는 기존) eGov/Spring Boot 2.7 + Maven 멀티모듈 레포에 Claude Code 에이전트 구성(CLAUDE.md 규약·.claude/settings·훅·harness 런북·git 격리·폐쇄형 학습 루프)을 부트스트랩한다. EXAMPLE_REPO에서 정립한 구성을 동일 스택 새 프로젝트로 이식할 때 사용. 사용자가 `/bootstrap-project` 로 직접 호출한다(자동 호출 꺼짐).
disable-model-invocation: true
---

# bootstrap-project — 에이전트 구성 이식 스킬

`~/.claude/agent-scaffold/`의 템플릿을 **현재 작업 중인 레포**에 설치한다.
원칙(전역 CLAUDE.md): **플로우(하네스+이력루프)는 공유, 설정값은 격리, 의례 조항은 트리밍, 동일 스택 한정.**

## 0. 착수 판단 — 전파 여부 먼저

**eGov/Maven 레거시 레포에 착수할 때는 다른 프로젝트의 워크플로 전파 여부를 먼저 검토한다** — 플로우(하네스+이력루프)는 공유, 설정값은 격리, 의례 조항은 트리밍, **동일 스택 한정**. 무엇을 어느 층에 두는지는 전역 규약 §규약 배치·전파의 **배치 3규칙**(①스택 불문 방법론 → 전역 단일정본 ②동일 스택 공유 자산 → 각 프로젝트 md 중복 기재 ③도메인값·접속정보·포트 → 프로젝트 격리)을 따른다. 형제 레포 대조 절차·함정 = [[rule-propagation-crossrepo]].

## 전제 확인 (먼저)
1. 현재 디렉터리가 대상 레포 루트인지, git 레포인지 확인(`git rev-parse --show-toplevel`).
2. 스택이 eGov/Spring Boot 2.7 + Maven 멀티모듈인지 확인(`pom.xml` 존재·`<modules>`). **다른 스택이면 중단하고 사용자에게 알린다**(이 스캐폴드는 동일 스택 전용).
3. 이미 `CLAUDE.md`가 있으면 **덮어쓰지 말고** 사용자에게 병합 여부를 묻는다.

## 값 수집 (플레이스홀더)
가능한 값은 `pom.xml`·디렉터리에서 **자동 추론**하고, 못 채우는 것만 사용자에게 묻는다(AskUserQuestion, 한국어).

| 플레이스홀더 | 의미 | 추론 방법 |
|---|---|---|
| `{{PROJECT_NAME}}` | 레포 이름 | 루트 디렉터리명 |
| `{{ROOT}}` | 절대경로 | `git rev-parse --show-toplevel` |
| `{{DB_MCP}}` | DB MCP 이름 | `.mcp.json`의 mcpServers 키(없으면 질문) |
| `{{ENCODED_CWD}}` | memory 디렉터리용 인코딩 경로 | 대상 레포 절대경로의 비영숫자 문자를 전부 `-`로 치환(예: `__PROJECTS_DIR__/EXAMPLE_REPO` → `-Users-<user>-projects-<repo>`). 검증: `ls ~/.claude/projects/`에서 실제 디렉터리명 확인 |
| `{{MODULE_CORE}}` `{{MODULE_ADMIN}}` `{{MODULE_FRONT}}` | 모듈 디렉터리명 | 루트 `pom.xml` `<modules>` + 각 모듈 role 추정(core=라이브러리, admin/front=boot). 3모듈 아니면 질문 |
| `{{PKG_BASE}}` | 자바 패키지 base | 소스 트리 `src/main/java` 최심 공통 패키지(예 `com.example.app`) |
| `{{PKG_PATH}}` | 위를 `/`로 | `{{PKG_BASE}}`의 `.`→`/` |
| `{{MAVEN_REPO}}` | 로컬 저장소 고정 경로 | 기본 `__HOME__/maven_repo/maven/repository`(EXAMPLE_REPO와 동일 머신) |
| `{{ADMIN_URL}}` `{{FRONT_URL}}` `{{LOGIN_PATH}}` | 검증용 URL | `application.properties`의 context-path·port에서 조립(없으면 질문) |
| `{{ADMIN_PORT}}` `{{FRONT_PORT}}` | **에이전트 검증 전용 포트**(사용자 IDE 인스턴스와 분리) | 사용자 포트 + 10000 관례(예 8080→18080). `run-<repo>` 스킬과 같은 값이어야 한다 |
| `{{PORT_ENV_PREFIX}}` | 회귀 스위트가 포트를 받는 환경변수 접두 | 예 `APP` → `APP_ADMIN_PORT`/`APP_FRONT_PORT`. 스위트를 만들 때 정한다 |
| `{{RUN_SKILL}}` `{{REGRESS_SKILL}}` | 앱 기동·전량 회귀 프로젝트 스킬명 | 관례 `run-<repo>`·`regress-<repo>`(아직 없으면 그 이름으로 예약) |
| `{{ROUNDTRIP_FILE_REGEX}}` `{{ROUNDTRIP_CONTENT_REGEX}}` `{{ROUNDTRIP_CONTRACT}}` `{{ROUNDTRIP_SUITE}}` | 왕복 검증 리마인더의 대상 파일·diff 내용 정규식, 왕복 계약 한 줄, 스위트 경로 | **그 레포에서 다층 관통 사고가 실제로 난 파일군**으로 좁게 채운다(넓게 잡으면 오탐→우회 습관). 아직 사고 이력이 없으면 훅 등록을 빼두고 첫 사고 때 채운다 |
| `{{JS_NS}}` | 프론트 공통 JS 네임스페이스 | `new-screen` 템플릿과 `jsharness`(lib 주석) 양쪽에서 쓰인다 |
| `{{ENCODED_CWD}}` (재사용) | `mirror-history.sh`·`token_usage.py` 의 memory/트랜스크립트 앵커 | 위 참조 |

**DB MCP가 아예 없는 레포 분기:** `.mcp.json`에 DB MCP가 없으면(사용자도 없다고 확인) `{{DB_MCP}}` 치환 대신 ①`settings.json`의 `mcp__{{DB_MCP}}__mysql_query` 줄을 삭제하고 ②CLAUDE.md/harness.md의 DB MCP 관련 조항을 트리밍 대상으로 처리한다. DB MCP가 있는 경우에도 도구명(`mysql_query`)이 다를 수 있으니 `.mcp.json` 실측으로 확인 후 치환한다.

## 설치 절차
1. **파일 복사 + 치환.** 아래를 대상 레포로 복사하되 위 플레이스홀더를 실제 값으로 치환한다. **기존 파일 보호(전 복사 대상):** 각 대상 파일이 이미 존재하면 덮어쓰지 말고 diff 제시 후 병합/스킵을 사용자에게 확인한다(CLAUDE.md뿐 아니라 settings.json·hooks·harness.md·conventions.enabled·agent_history.md 전부).
   - `agent-scaffold/CLAUDE.md.tmpl` → 레포 `CLAUDE.md`
   - `agent-scaffold/claude/conventions.enabled` → `.claude/conventions.enabled` (컨벤션 게이트 옵트인; 원치 않으면 생략)
   - `agent-scaffold/claude/tier.conf` → `.claude/tier.conf` — 전역 `commit-tier-calc.sh` 의 프로젝트 확장 축. `extra_a_globs` 를 이 레포의 **개발 소유 JS 경로**로 확정(없으면 화면 JS 로직 커밋이 B티어로 강등된다).
   - **DDL 적용 절차:** 킷은 `dev-ddl-apply` 류 스킬을 배포하지 않는다. CLAUDE.md 의 DDL `<<< >>>` 구간과 `prod-db-guard.sh` 차단 안내('DDL 적용 스킬')를 이 레포에 실제로 있는 절차로 맞춘다.
   - **`agent-scaffold/claude/hooks/` 디렉터리 전체** → `.claude/hooks/` (`lib/` 포함 통째 복사 후 `chmod +x .claude/hooks/*.sh`). ⚠️ **개별 나열이 아니라 디렉터리째 복사가 원칙:** `settings.json`이 이 디렉터리의 훅을 **PreToolUse·PostToolUse·PostToolUseFailure·SessionStart 이벤트별로** 참조하고 층 A 스텁이 `hooks/git/` 디스패처를 부르므로(등록 모집단 조회 = `python3 -c "import json;d=json.load(open('.claude/settings.json'));print([h['command'] for ev in d['hooks'] for m in d['hooks'][ev] for h in m['hooks']])"`) 하나라도 빠지면 그 트리거마다 `bash: No such file or directory`가 난다. 신규 훅이 추가돼도 목록이 다시 어긋나지 않게 **디렉터리째** 복사한다. `lib/`(공용 라이브러리 `git-cmd.sh`·`review-diff.sh`·허용 형태 판정기 `cmdform.py`)도 이 안에 함께 복사됨 — 커밋 게이트·prod-db·pull-smoke 가드가 쓴다. 커밋 게이트의 PreToolUse 경로와 prod-db 는 lib·판정기(python3 필요)가 없으면 관련 낱말이 보이는 호출을 막는다(fail-closed), 층 A 디스패처는 `lib/git-cmd.sh`·`lib/review-diff.sh` 가 없으면 커밋을 막는다. 기존 레포를 갱신할 땐 `lib/` 를 먼저 두고 훅을 그다음에 바꾼다.
   - **복사 후 후처리(아래 3개 파일만, 나머지는 repo-agnostic·무치환):**
     - `secret-commit-guard.sh`: 상단 `EXCLUDE_PATH_REGEX` 의 **기본값은 빈 값(=전 파일 스캔)**이다. 팀이 tracked 로 관리하는 접속정보 파일(정본 DB 덤프 디렉터리·추적 프로파일 등)만 예외로 추가한다 — 넓게 넣을수록 실제 자격증명이 무검문 통과한다.
     - `prod-db-guard.sh`: 상단 `ALLOWED_DB_HOSTS_REGEX`에 이 프로젝트 dev DB 호스트 추가(미추가 시 localhost 외 전부 차단 — 과차단이지 구멍은 아님).
     - `module-isolation-reminder.sh`: **`{{MODULE_CORE}}`·`{{MODULE_ADMIN}}`·`{{MODULE_FRONT}}` 플레이스홀더를 이 레포 실제 모듈명으로 치환**(미치환 시 web 모듈 경로 매칭 실패 → 격리 리마인더가 조용히 무기능. step 1 말미 `grep -r '{{' .claude/`에서 잔여 검출).
     - **모듈·경로·포트 일괄 치환(훅 전반):** `stale-app-verify-guard.sh`·`compact-state-reinject.sh`·`mvn-test-record.sh`·`mvn-test-result-gate.sh`·`profile-key-diff-guard.sh`·`text-constant-3layer-reminder.sh`·`ponytail-debt.sh`·`token_usage.py`·`jsharness/lib/*`·`hooks/git/git-hooks.test.sh` 와 각 `*.test.sh` 가 `{{MODULE_*}}`·`{{MAVEN_REPO}}`·`{{ADMIN_PORT}}`/`{{FRONT_PORT}}`·`{{PORT_ENV_PREFIX}}`·`{{RUN_SKILL}}`/`{{REGRESS_SKILL}}`·`{{PROJECT_NAME}}`·`{{ENCODED_CWD}}`·`{{ROOT}}`·`{{PKG_PATH}}`·`{{JS_NS}}` 를 쓴다. **치환 후 `grep -rn '{{' .claude/` 0건**을 확인한다(미치환 훅은 매칭 실패로 조용히 무기능이 된다).
     - `roundtrip-verify-reminder.sh`: 대상 정규식 2개와 안내 문구를 **이 레포에서 실제로 다층 사고가 난 파일군**으로 채우거나, 이력이 없으면 `settings.json` 에서 이 훅 등록을 빼둔다(넓은 패턴은 오탐→우회 습관으로 훅을 죽인다).
     - `mvn-test-result-gate.sh`·`profile-key-diff-guard.sh`·`stale-app-verify-guard.sh`·`text-constant-3layer-reminder.sh`: 치환 후 짝 `*.test.sh` 를 1회 돌려 **양성·음성이 같이 도는지** 확인한다(통과만 확인하지 말 것).
     - `application*.properties` 프로파일 분리를 쓰지 않는 레포면 `profile-key-diff-guard.sh` 등록을 빼고 CLAUDE.md 의 프로파일 조항도 함께 삭제한다.
   - `agent-scaffold/claude/scripts/export_schema_snapshot.py` → `.claude/scripts/export_schema_snapshot.py` (`chmod +x`) — 복사 시 `{{MODULE_ADMIN}}` 치환 + 스크립트 상단 `DEV_HOST_ALLOWLIST`에 프로젝트 dev DB 호스트 추가, 설치 후 1회 실행해 `.claude/schema-snapshot.json` 스냅샷 생성(harness 룰 K 대조 기준·CRUD 스캐폴드 입력·로컬 컬럼 확인).
   - `agent-scaffold/claude/skills/new-screen/` → `.claude/skills/new-screen/` (선택 — CRUD 스캐폴드 생성기를 쓸 경우). 복사 후 **REEXTRACT 채움 필수**: `scaffold_crud.py` 상단 CONFIG(`MODULE_CORE`·`MODULE_ADMIN`·`PKG_PATH_*`·`UUID_UTIL_NAME`·`JS_NS`)와 `templates/*.tmpl`의 `{{...}}`(`{{PKG_CORE}}`·`{{PKG_ADMIN}}`·`{{UUID_UTIL_FQN}}`·`{{JS_NS}}`·`{{BASE_CONTROLLER_FQN}}`·`{{BASE_SEARCH_VO_FQN}}`·`{{SITE_HELPER_FQN}}`)를 대상 레포 실측(모듈 디렉터리·소스 레이아웃·공통 유틸·프론트 JS 네임스페이스)으로 치환. 잔여 확인 `grep -rn '{{' .claude/skills/new-screen` 0건, 미치환 시 생성기가 `_guard_reextract()`로 기동 차단. 감사 명명표준이 eGov standard-db-naming과 다르면 `AUDIT_COLS`+감사 리터럴도 조정.
   - **e2e-verify 는 설치하지 않는다** — 유저레벨 범용 서브에이전트(`~/.claude/agents/e2e-verify.md`) 하나가 모든 형제 레포에 적용되고, 포트·컨텍스트패스·로그인·계정은 전역 `playwright-verify` 스킬이 레포별로 self-discover 한다. per-repo 사본은 유저레벨판을 가리고 하드코딩 드리프트를 들이므로 만들지 않는다. 새 레포도 바로 `subagent_type:"e2e-verify"` 로 쓴다(웹 UI 없는 레포면 부르지 않는다).
   - `agent-scaffold/docs/harness.md.tmpl` → `docs/harness.md`
   - `agent-scaffold/docs/agent_history.md` → `docs/agent_history.md` (빈 스켈레톤; 기존 있으면 유지)
   - `agent-scaffold/docs/obsidian-memory-viz.md` → `docs/obsidian-memory-viz.md` — 치환 불필요(repo-agnostic). CLAUDE.md/SKILL step 6가 이 상대경로를 참조하므로 함께 복사해야 dangling 참조가 안 된다(Obsidian 시각화 안 쓰는 프로젝트면 생략 가능하나, 생략 시 CLAUDE.md의 참조 링크도 함께 정리).
   - 치환은 `sed`보다 Read→Edit로 안전하게(플레이스홀더 소수). `{{...}}`가 하나도 안 남았는지 `grep -r '{{' CLAUDE.md docs/ .claude/`로 확인.
   - `agent-scaffold/claude/scripts/install-git-hooks.sh` → `.claude/scripts/install-git-hooks.sh` — 무치환. 훅 디렉터리만 복사하면 이 파일이 빠진다(SessionStart `git-hooks-check.sh` 가 '설치 스크립트 부재'로 경고).
   - **층 A git 훅 설치 — 신규·기존 레포 모두, settings.json 보다 먼저:** 대상 레포 루트에서 `bash .claude/scripts/install-git-hooks.sh` → `bash .claude/scripts/install-git-hooks.sh --check` rc 0 → `bash .claude/hooks/git/git-hooks.test.sh` 초록(임시 레포에서 실제 commit/merge/push — 실레포 `.git` 무접촉, 치환 전엔 실패한다 — 빨강이면 실패 항목을 사용자에게 보여 판정받는다). 커밋 내용 게이트(sql-staging·secret·test-count·mvn-test-result·code-review-marker)는 settings 의 PreToolUse 가 아니라 `.git/hooks` 스텁 → `.claude/hooks/git/pre-commit` 디스패처가 부른다. 설치가 중단되면(`core.hooksPath` 설정·남의 훅·깨진 링크) 덮어쓰지 말고 그 사유를 사용자에게 보여 정리한다 — **정리되어 `--check` 가 rc 0 이 되기 전엔 아래 settings.json 단계로 넘어가지 않는다**(기존 레포는 기존 settings 의 PreToolUse 게이트 등록을 그대로 둔다). 이미 설치된 레포에서 다시 돌려도 멱등이다.
   - `agent-scaffold/claude/settings.json` → `.claude/settings.json` — **1단계의 마지막 복사(위 층 A `--check` rc 0 뒤).** 이 템플릿은 커밋 게이트(sql-staging·secret·test-count·mvn-test-result·code-review-marker)를 PreToolUse 에 등록하지 않는다 — 층 A 없이 깔리면 PreToolUse 의 `git-hooks-installed-guard.sh` 가 그 레포의 에이전트 커밋을 막는다(설치·`--check` rc 0 뒤 풀린다). 기존 레포(이미 settings 가 있음)는 diff 를 보여 수동 병합한다 — ①`git-hook-bypass-guard.sh`·`git-hooks-installed-guard.sh`(PreToolUse Bash)·`git-hooks-check.sh`(SessionStart) 추가 ②새 이벤트 `PostToolUseFailure`(Bash) 블록 추가 ③PreToolUse 의 커밋 게이트 등록(위 이름들) 제거(①②와 층 A `--check` rc 0 을 확인한 뒤). 기존 프로젝트 settings 에 새 이벤트를 넣어 주는 자동 경로는 없다(머신 부트스트랩·doctor 는 전역 settings 를, `kit-drift-check.sh` 는 레포 hooks 최상위·`lib/` 와 workflows 를 다룬다 — 층 A(`hooks/git/`·`scripts/install-git-hooks.sh`)는 대조 밖이라 킷 갱신 때 수동 대조(ponytail: 층 A 드리프트 미감시 / 업그레이드 = kit-drift-check 모집단에 `git/`·`scripts/` 키 추가) — 프로젝트 settings 는 병합·대조 대상이 아니다. 확인 = 각 스크립트의 settings 처리부) — 그래서 이 병합을 건너뛰면 실패 종료 기록·층 A 점검이 조용히 빠진다. 위 후처리 중 settings 를 고치라는 항목(DB MCP 없는 레포 분기·`roundtrip-verify-reminder.sh`·`profile-key-diff-guard.sh` 등록 빼기)은 이 복사 때 함께 반영한다. 병합 뒤 등록 모집단 조회(위 hooks 항목의 python 한 줄)로 이벤트별 등록을 확인한다.
2. **git 격리.** `agent-scaffold/git-exclude-block.txt` 내용을 대상 레포 `.git/info/exclude`에 **append**(중복 방지: 이미 `Local-only AI scaffolding` 마커 있으면 건너뜀). **append 전 기존 파일이 개행으로 끝나는지 확인**: 마지막 줄에 개행이 없으면 블록 첫 줄(주석 `# ── Local-only …`)이 직전 규칙에 붙어 **직전 규칙+마커가 동시에 손상**(멱등 마커까지 깨져 재실행 시 중복 주입)된다. 안전하게 `[ -s exclude ] && [ -n "$(tail -c1 exclude)" ] && echo >> exclude` 로 개행을 먼저 확보한 뒤 `cat block >> exclude`(또는 Read→끝에 개행 보장 후 Write). 이걸로 팀 레포 커밋에서 AI 스캐폴딩이 빠진다. **`<<<DB_DOC_DIR>>>/*.sql` 자리표시 필수 처리:** 프로젝트의 SQL 초안 디렉터리(예: `01.Documents/05.DATABASE`)로 치환하거나, 해당 디렉터리가 없으면 그 줄+주석을 삭제한다(미치환 잔존 시 glob 무매칭 → SQL 격리 무증상 미작동). 잔여 확인: `grep -E '\{\{|<<<' .git/info/exclude` 0건.
3. **개인 백업 레포 초기화(선택·권장).** `~/.claude/history-backups/{{PROJECT_NAME}}/`에 `git init`(미러 훅이 여기로 커밋). origin은 사용자가 원할 때만.
4. **standard-db-naming 스킬(선택).** DB 표준명명이 필요하면 킷 원본 `~/.claude/skills/standard-db-naming/`(스크립트만 포함 — 원본 xlsx 사전은 `assets/` 에 직접 두고, sqlite 는 빌드 산출물)을 그대로 쓸지, 레포 전용 사전으로 바꿀지 사용자에게 확인. 그대로 쓰면 복사하지 않는다(같은 이름 사본은 전역판에 가려 로드되지 않는다). 바꿀 거면 대상 레포 `.claude/skills/<repo>-db-naming/` 으로 복사하고 frontmatter `name` 도 같은 이름으로 바꾼다 — 디렉터리명까지 달라야 목록에 따로 뜬다. 복사 후 최초 사용 시 `python3 scripts/build_dictionary_db.py assets standard_dictionary.sqlite`로 로컬 sqlite를 1회 생성(순수 stdlib, pip 불필요).
5. **memory는 이식하지 않는다.** memory(`~/.claude/projects/<encoded-cwd>/memory/`)는 프로젝트 고유 학습이라 빈 상태로 시작한다. 세션이 진행되며 자동 축적된다. EXAMPLE_REPO의 범용 교훈(`skills-*`·함정 노트) 중 스택 공통인 것만 사용자 요청 시 선별 복사.
6. **Obsidian 메모리 시각화 설정(선택).** memory 디렉터리를 Obsidian 볼트로 열어 메모리 그래프를 볼 수 있게, `agent-scaffold/obsidian/`의 설정(`community-plugins.json`·`plugins/obsidian-front-matter-title-plugin/data.json`)을 대상 프로젝트 memory 디렉터리(`~/.claude/projects/{{ENCODED_CWD}}/memory/`)의 `.obsidian/`로 복사한다(이미 `.obsidian`이 있으면 덮어쓰지 말고 `data.json`의 `templates.common.main`만 `metadata.title`로 맞춘다). 사용자에게 "Obsidian에서 그 memory 디렉터리를 볼트로 열고 → 커뮤니티 플러그인 **Front Matter Title** 설치 → 리로드하면 그래프 노드가 표시명(`metadata.title`)으로 뜬다"고 안내. 신규 프로젝트 memory는 비어 있어 노드가 없다가 세션 진행하며 채워진다(메모리 작성 규약이 frontmatter `title` 포함을 강제 → `metadata.title` 정규화). 상세=`docs/obsidian-memory-viz.md`.

## 마무리
- 트리밍 안내: CLAUDE.md 템플릿의 `<<< ... >>>` 구간(도메인 표준값·trunk 커밋 조항·Design.md 유무·standard-db-naming 채택)을 이 프로젝트에 맞게 채우거나 삭제하라고 사용자에게 알린다.
- 설치 요약: 생성/수정 파일 목록 + 층 A `--check` 결과 + 남은 `<<<>>>` 채움 항목 + 검증 명령(`harness` 스킬 또는 `mvn -Dmaven.repo.local=... clean compile`) 안내.
- 설치 자체는 커밋하지 않는다(격리 대상).
- **기반 점검 안내:** 첫 화면 착수 전에 `foundation-check` 스킬(요청 결말·오류 응답·문자 처리·인증/세션·트랜잭션·저장값·파일)을 돌리라고 사용자에게 알린다 — 인계 초기소스·팀 공통 모듈이 이미 있으면 지금 돌린다.
