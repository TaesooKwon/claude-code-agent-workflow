---
name: playwright-verify
description: >-
  DEFAULT tool for visual/UI verification of JS-rendered, auth-gated admin screens
  in the agent-target eGov/Maven repos under __PROJECTS_DIR__ (harness skill allowlist) — Playwright
  headless/headed (login → navigate → screenshot → assert). Use this (NOT
  claude-in-chrome, which is blocked/costly here) whenever confirming ag-Grid rows,
  modals, iframes, or any rendered content curl cannot see (curl runs no JS).
  Self-discovers per-project config (port, context-path, login URL, creds); never
  hardcodes across repos. Screenshots save into the CURRENT repo's docs/verify-shots/
  (git-excluded).
---

# Playwright Visual Verify — JS 렌더·인증 게이트 화면 시각검증 (시각검증 기본 도구)

**시각(렌더) 검증의 기본 도구**다 — claude-in-chrome(브라우저 MCP)은 쓰지 않는다(이 환경
차단·고비용·서브에이전트 공회전 전례). curl로는 못 보는 **JS 렌더 결과(ag-Grid 행·모달·
iframe·동적 콘텐츠)** 를 Playwright 헤드리스/헤디드로 로그인→네비게이트→스크린샷→assert 한다.
**메커니즘은 공유, 설정값(포트/컨텍스트패스/로그인/계정/셀렉터)은 각 레포에서 self-discover**
(전파 원칙 [[propagate-agent-workflow]]).

## 언제 쓰나
- **시각·렌더 검증이면 기본으로 이 스킬**(claude-in-chrome 위임 시도 금지 — denied→하위에이전트 중첩 공회전).
- 목록이 ag-Grid/JS로 렌더돼 curl 응답엔 `id="grid"` 컨테이너만 있고 행은 안 보일 때.
- 모달(상세/iframe/Q&A) 렌더·클릭까지 확인해야 할 때.
- 사용자가 "같이 따라보고" 싶으면 headed(`headless:false`+`slowMo`)로 창을 띄워 관전.
- 단, **데이터·라우팅·템플릿 키워드 수준 검증은 curl이 더 싸다** — 먼저 curl로 거르고
  (200/302·본문 키워드), 렌더·클릭 같은 시각만 Playwright로.

## 0) Playwright 준비 (캐시 재사용)
```bash
mkdir -p /tmp/pw-verify && cd /tmp/pw-verify
[ -f package.json ] || npm init -y >/dev/null
npm i playwright@latest >/dev/null 2>&1
npx playwright install chromium   # 캐시 있으면 스킵, 없으면 ~90MB 1회 다운
```
브라우저는 `~/Library/Caches/ms-playwright`에 캐시된다(여러 레포 공용). 스크립트는 이
node_modules가 있는 디렉터리에서 `node verify.mjs`로 실행한다.

## 1) 레포별 설정 self-discover (절대 추측 금지 — 포트/컨텍스트패스 함정)
⚠️ **포트·컨텍스트패스를 추측하면 전부 404가 난다**(실측 함정: EXAMPLE_REPO 어드민은
8081이 아니라 **8080 + context-path `/example-admin`**, 프론트가 8081/`/example-front`였음).
구동 web 모듈의 `application.properties`에서 **반드시 실측**한다:
```bash
grep -nE "server\.port|server\.servlet\.context-path" <WEB_MODULE>/src/main/resources/application.properties
```
- **BASE** = `http://localhost:<server.port><context-path>` (예: `http://localhost:8080/example-admin`).
- **로그인 페이지** = LoginController의 `@GetMapping(... login.do)` (예: `/auth/login.do`).
  미인증 접근이 unauthorized로 가는 앱이면 보호 URL로 가지 말고 **로그인 페이지로 직접** 이동.
- **로그인 폼 필드/버튼** = 로그인 템플릿에서 확인(예: `#userId`/`#userPswd` + `#loginForm button[type=submit]`).
  로그인이 ajax면 클릭 후 리다이렉트까지 `waitForTimeout`(2~3초).
- **계정** = 로그인은 각 레포 스위트의 로그인 헬퍼로 — 헬퍼가 비밀번호를 키체인 등에서 직접 읽어 `page.fill` 에 넘기게 해 값이 에이전트 맥락에 오지 않게 한다. **비밀번호 조회·출력·복사 금지.** 헬퍼가 없는 레포는 사용자에게. 민감값은 로그/문서에 원문 노출 금지.
- **셀렉터** = ag-Grid 행 `.ag-row`, 모달 `dialog[data-modal="..."]`, 상세버튼 등 해당 화면 기준.

## 2) 스크린샷 저장 위치 — 각 레포 안에
스크린샷은 `/tmp`가 아니라 **현재 작업 레포의 `docs/verify-shots/`** 에 저장한다(프로젝트별
디렉터리). 이 디렉터리는 로컬 산출물이므로 각 레포 `.git/info/exclude`에 추가([SKILL-05]):
```bash
mkdir -p <REPO>/docs/verify-shots
grep -qxF 'docs/verify-shots/' <REPO>/.git/info/exclude 2>/dev/null || echo 'docs/verify-shots/' >> <REPO>/.git/info/exclude
```
스크립트의 `SHOTS` 상수를 그 절대경로로 지정한다.

## 3) 스크립트 템플릿
`template/verify.mjs` 참조 — 상단 CONFIG(BASE/LOGIN_PATH/creds/STEPS/SHOTS)만 레포별로
채우면 된다. 로그인→허브/목록(ag-Grid 행수 assert)→상세 모달(iframe/Q&A assert)→스크린샷,
마지막에 PASS/FAIL 표를 stdout으로 출력. headed 관전은 `headless:false, slowMo:700`.

## 4) 결과 보고
- stdout PASS/FAIL 표 + 행수/assert 값.
- 핵심 스크린샷을 `Read`로 대화에 인라인 표시(사용자가 시각 확인).
- 실패 시: 스크린샷의 실제 화면(404/로그인페이지/truncated)을 읽고 원인 분리
  (포트/컨텍스트패스 오인 → properties 재실측 / 로그인 실패 → 폼·계정 / 렌더 500 → 서버로그).

## 5) 누적 회귀 스위트 (일회성 스크립트 짜고 버리기 금지)
검증 스크립트를 짜고 지우면 **회귀가 누적 감지 안 된다**(과거 고친 게 다시 깨져도 모름). 그래서 검증 가치가 있는 흐름은 **`@playwright/test` 누적 스위트에 케이스로 남긴다**: `~/.claude/skills/playwright-verify/suites/<repo>/`(레포별, 로컬 전용·footprint 0).
- 실행: `cd ~/.claude/skills/playwright-verify/suites/EXAMPLE_REPO && npx playwright test`(앱 구동 전제). 케이스 추가법·함정은 그 안 `README.md`.
  - ⚠️ **포트 오버라이드(에이전트 기동 시 필수)**: 스위트 기본값은 사용자 인스턴스 포트(사용자가 직접 띄운 앱)를 향한다. `run-<repo>`/`regress-<repo>`로 **에이전트 전용 포트**(사용자 포트와 분리, 예: 사용자 8080/8081 → 에이전트 18080/18081)에 앱을 띄웠으면 그 포트를 env로 명시해야 사용자 인스턴스를 오검증(쓰기 포함)하거나 미기동 오탐하는 사고를 막는다: `<ADMIN_PORT_ENV>=18080 <FRONT_PORT_ENV>=18081 npx playwright test`. (또는 이 오버라이드를 자체 강제하는 `regress-<repo>` 경유가 기본 경로.)
- 원칙: **자기정리(idempotent)**(시작 상태 맞추고 끝에 원복)·`expect` 단언.
- ⚠️ **퍼블 낙관적 토글 함정**: 클릭 시 class(`is-active`/`fill`)가 낙관적으로 즉시 바뀌므로 class만 기다리면 영속화(`*Bookmark.json`) 전에 진행돼 누락 → `waitForResponse`로 서버 응답 대기.
- 일회성 raw 스크립트는 탐색/디버깅 때만, 검증이 끝나면 **스위트 케이스로 승격**하고 임시 스크립트는 정리.

### 5-1) 스위트가 느려지면 — 로그인 캐시 + 세션 그룹 병렬
스위트는 보통 "dev DB 공유하니 `workers:1` 통짜 직렬"로 시작하는데, 케이스가 쌓이면 이게 병목이 된다.
**도구를 갈아끼우기 전에 어디서 시간이 새는지 먼저 재라** — 앱 부팅(수 초)이나 Playwright 자체보다
**spec 마다 반복하는 로그인**과 **통짜 직렬**이 원인인 경우가 많다.
실측 개편 사례: 직렬·spec마다 재로그인 **238초 → 78초(3.05배)**, 3회 연속 전량 PASS.

**① 로그인은 계정당 1회 (storageState)**
- `lib/global-setup.js`가 계정별로 한 번만 실제 로그인 → `.auth/<계정id>.json` 에 storageState 저장.
  로그인 직후 **착지 URL**도 `.auth/landing.json` 에 같이 남긴다.
- `playwright.config.js`의 프로젝트가 `use.storageState` 로 복원하고 `metadata: { accountId }` 를 단다.
- 로그인 헬퍼가 `test.info().project.metadata.accountId` 를 보고 요청 계정과 같으면 **폼 왕복을 건너뛰고
  착지 URL로만 이동**한다 → **spec 을 한 줄도 안 고치고** 로그인 비용이 사라진다.
  (헬퍼 호출 직후 goto 없이 헤더를 읽는 spec 이 있으므로 착지 이동 자체를 생략하면 안 된다.)
- 쿠키 path 주의: 같은 host 라도 컨텍스트패스가 다르면(예: 관리자 `/ctx-a` vs 사용자 `/ctx-b`) 세션 쿠키가 안 겹치지만,
  **같은 컨텍스트패스의 계정끼리는 서로 덮어쓴다** → 계정별 파일로 분리한다.
- `.auth/` 는 세션 쿠키다. 반드시 gitignore.

**② 병렬 단위는 파일이 아니라 "세션·데이터 주체"**
- spec 파일 단위 병렬은 대개 깨진다 — 같은 계정·같은 행을 건드리는 spec 끼리 간섭하기 때문
  (감사로그 행 수 세기, 같은 사용자 마이페이지 목록, 앞 spec 의 제출 결과를 뒤 spec 이 읽기 등).
- **계정/권한 주체별로 프로젝트를 나누고**(예: `bo` / `fo-A` / `fo-B` / `anon`) **그룹 안은 직렬,
  그룹 사이만 병렬**. 벽시계 = 합이 아니라 최대 그룹.
- Playwright 는 **프로젝트별 worker 수를 지정할 수 없다**(`workers` 는 전역). 따라서 러너 스크립트가
  `--project=<name>` 프로세스를 그룹 수만큼 띄우는 방식으로 구현한다.
- 프로세스가 여럿이면 globalSetup 이 동시에 돌아 `.auth/*.json` 을 서로 덮어쓴다 → 러너가
  **로그인 캐시를 먼저 1회 만들고**(전용 스크립트) 뒤따르는 프로세스는 환경변수로 globalSetup 을
  건너뛰게 한다(캐시 존재 + TTL 확인).
- 프로세스마다 `--output` 을 갈라 test-results 충돌을 피하고, 간섭 의심 시 단일 프로세스로 되돌리는
  환경변수 탈출구(`<PREFIX>_NO_PARALLEL=1`)를 남긴다.

**③ 상태를 되돌리는 코드는 `test.afterAll` 에**
원복을 별도 `test()` 로 두면 **앞 테스트가 실패한 실행에서 돌지 않아 dev DB 가 오염된다**(실측 사고).
afterAll 은 성패와 무관하게 실행된다. 자체 컨텍스트가 필요하면
`browser.newContext({ storageState: <프로젝트 storageState> })` 로 인증을 물려주고,
정리 전에 현재 값을 읽어 이미 원상태면 건너뛰는 가드를 둔다.

### 5-2) "통과하지만 아무것도 검증하지 않는" 스펙 주의
`if (보이면) { 확인 } else { console.log('못 찾음') }` 로 짜인 스펙은 셀렉터가 썩어도 영원히 통과한다
(실측: 저장 버튼도 폼 필드도 못 찾은 채 통과하던 스펙 — 부르던 API 경로 자체가 존재하지 않았다).
교정 원칙:
1. 셀렉터·API 경로는 **컨트롤러/템플릿을 읽고 실제 응답을 찍어** 확정한다(추측 금지).
2. 화면만 보지 말고 **응답 계약**(HTTP 메서드·status·응답코드)까지 단언한다.
3. 응답을 믿지 말고 **저장값을 다시 읽어** 확인한다.
4. 필터·검색은 **양성 + 음성**(없는 값 → 0건) 양방향으로 반증한다.
5. 다 쓴 뒤 **고의로 기대값을 어긋나게 만들어 실제로 실패하는지 확인**한다. 실패하지 않으면 그 단언은 장식이다.
   (반증검사 도중 상태를 바꿨다면 원복까지 확인 — 실측에서 여기서 DB 가 오염됐다.)

### 5-3) 경합 시나리오 필수 — 두 컨텍스트 동시 조작
폴링·동시 저장·상태전이·채번·커서가 있는 기능은 **단일 흐름 스펙만으로는 검증이 안 된다**(리뷰·단위테스트도 단일 흐름만 본다).
실측(2026-09-03): 다관점 리뷰 3회가 전부 놓친 폴링 커서 결함(두 사용자가 동시에 보내면 한쪽 메시지가 화면에서 유실)을 E2E 1회가 잡았다.
1. `browser.newContext()` 2개로 **서로 다른 계정** 세션을 만들고 같은 화면을 연다(로그인 캐시는 계정별 storageState).
2. **동시 전송**: `Promise.all([ctxA.send(), ctxB.send()])` 로 같은 tick 에 보내고, 양쪽 화면에 **양쪽 메시지가 모두** 렌더되는지 단언한다.
3. **교차 갱신**: A 가 보낸 직후 B 가 폴링 주기 안에 보내는 순서(`page.waitForTimeout(폴링/2)`)도 한 번 — 커서가 "마지막 응답"만 좇으면 여기서 샌다.
4. **상태전이 경합**: 같은 행을 두 컨텍스트가 동시에 승인/취소 — 한쪽만 성공하고 다른 쪽은 **명시적 거부 응답**을 받는지(둘 다 성공하면 결함).
5. 단언은 "N건 렌더"가 아니라 **누가 보낸 무엇이 어느 화면에** 있는지 — 건수만 세면 유실과 중복이 상쇄된다.
6. **경합 수리의 증명 = 반복 재현율.** 단발 통과는 운일 수 있다 — 수정 전 재현율 k/N(k>0)을 먼저 기록하고 수정 후 0/N 을 보인다(N 기본 20, 반복마다 상태 원복 = `beforeEach`). 수정 전에도 0/N 이면 그 스펙은 경합을 못 만든다(반증 실패 — 발사 간격·순서부터 다시).

## 토큰·안전
- 기본은 읽기 검증이다. 저장·상태전이를 눌러야 하는 검증(5-3 경합 등)은 dev 에서, 원복 가능한 것만 하고
  원복은 `test.afterAll` 에 둔다(5-1 ③). 삭제 confirm 같은 비가역 클릭은 하지 않는다.
- 브라우저 검증은 `e2e-verify` 서브에이전트(백그라운드)가 기본이다 — 메인 컨텍스트를 아끼고 결과 요약만 받는다.
  서브에이전트가 브라우저 실행 권한에 막히면 재위임을 반복하지 말고 메인에서 직접 실행한다.
- 관련: [[playwright-default-visual-verify]] · [[delegate-in-background]] · 빌드는 `harness` 스킬.
