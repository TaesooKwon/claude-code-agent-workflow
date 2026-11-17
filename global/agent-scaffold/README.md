# agent-scaffold — Claude Code 에이전트 구성 이식 템플릿

EXAMPLE_REPO에서 정립한 에이전트 구성(규약·훅·런북·격리·폐쇄형 학습 루프)을 **동일 스택**
(eGov/Spring Boot 2.7 + Maven 멀티모듈 + MyBatis + Thymeleaf) 신규 프로젝트로 옮기기 위한 정적 템플릿.

## 쓰는 법
새 레포 루트에서 `/bootstrap-project` 스킬을 호출하면 이 템플릿을 복사·치환·설치한다.
스킬 정의: `~/.claude/skills/bootstrap-project/SKILL.md`.

## 구성
- `CLAUDE.md.tmpl` — 규약 정본 골격(플로우 조항 공유, 설정값은 `{{...}}` 플레이스홀더, 프로젝트 고유값은 `<<< >>>` 채움 구간)
- `claude/settings.json` — permissions.deny 안전망 + 이 디렉터리 훅의 이벤트별 등록(PreToolUse·PostToolUse·PostToolUseFailure·SessionStart — 등록 모집단은 파일 자체가 정본). 커밋 내용 게이트는 여기 없고 층 A(아래 `claude/hooks/git/`)가 부른다 — 층 A 설치(`--check` rc 0)보다 이 파일을 먼저 깔면 PreToolUse 의 `git-hooks-installed-guard.sh` 가 그 레포의 에이전트 커밋을 막는다(설치하면 풀린다) — bootstrap-project 1단계 순서를 따른다. ⚠️`permissions.allow` 에 `"Bash"` 전면 허용이 기본값이다 — 차단은 훅과 deny 가 맡는 설계이며, 원치 않으면 설치 시 좁힌다.
- `claude/conventions.enabled` — harness 컨벤션 게이트 옵트인 마커(차단 룰 A~E·G·H·L·O / 경고 룰 F·K·M·N·P — 룰 목록 정본은 파일 주석과 전역 `check_conventions.py`)
- `claude/hooks/mirror-history.sh` — history·memory 개인 백업 미러
- `claude/hooks/git/` + `claude/scripts/install-git-hooks.sh` — **층 A(커밋 내용 게이트의 권위 층)**: `.git/hooks/{pre-commit,pre-merge-commit,pre-push}` 에 얇은 스텁을 깔고(설치 = `bash .claude/scripts/install-git-hooks.sh`, 점검 = `--check`), 스텁이 이 디렉터리의 디스패처를 부른다. 에이전트 세션(`CLAUDECODE=1`)에서 돌고, pre-commit 디스패처가 커밋 게이트(sql-staging·secret·test-count·mvn-test-result·code-review-marker)를 합성 PreToolUse 입력(`GATE_LAYER=git`)으로 불러 **실제 커밋될 내용**(경로 지정 커밋·`add && commit`·`-a`·`GIT_INDEX_FILE` 포함)을 판정한다 — 도구·lib·게이트 부재와 게이트 비정상 종료는 차단. 병합 커밋엔 내용 게이트(secret·sql)를 돌리고, pre-push 는 푸시를 막는다(`ALLOW_GIT_PUSH=1` = 실제 환경변수일 때). 사용자 터미널(CLAUDECODE 미설정)은 무영향. 설치 스크립트는 `core.hooksPath` 설정·남의 훅·깨진 링크가 있으면 아무것도 쓰지 않고 중단한다. 짝 테스트 `claude/hooks/git/git-hooks.test.sh`(임시 레포에서 실제 commit/merge/push). 한계 = 디스패처 머리말 `ponytail:` 줄(cherry-pick·revert·rebase --continue·am·저수준 커밋 생성 명령은 pre-commit 을 안 거친다 · 층 A 미설치 다른 레포 대상 커밋엔 게이트가 없다).
- `claude/hooks/git-hooks-check.sh` — SessionStart: 층 A 스텁 미설치·실행 비트 없음·`core.hooksPath` 무효화·설치 스크립트 부재를 세션 머리에 알린다(차단 아님). 새 clone·`.git/hooks` 초기화·스크립트 누락 뒤 게이트 없이 커밋되는 상태를 드러내는 장치.
- `claude/hooks/git-hook-bypass-guard.sh` — PreToolUse(Bash): 층 A 를 건너뛰거나 끄는 낱말(`--no-verify`·`commit -n`·`core.hooksPath`·`-c alias.`·`env -i`·`CLAUDECODE` 조작·`.git/hooks` 조작)을 막는다(우회 변수 없음 — 필요하면 사용자가 자기 터미널에서). 문자열 판정이라 조기 경보이고 권위는 층 A(한계 = 그 파일 머리말 `ponytail:` 줄). 짝 테스트 `git-hook-bypass-guard.test.sh`.
- `claude/hooks/git-hooks-installed-guard.sh` — PreToolUse(Bash): `git commit` 이 보이면 이 프로젝트에서 `install-git-hooks.sh --check` 를 돌려 rc 0 이 아니면(스크립트 부재 포함) deny — 층 A 미설치·무효 프로젝트의 커밋을 게이트 없이 통과시키지 않는 fail-closed 보조 장치(우회 변수 없음). 대상 레포를 명령 문자열로 추정하지 않아 층 A 가 없는 동안은 다른 레포 대상 커밋도 막고, 설치돼 있으면 아무것도 하지 않는다(그때 층 A 미설치 다른 레포 대상 커밋은 게이트 없이 지나간다 — 디스패처 `ponytail:` 줄). 커밋 내용은 보지 않는다(권위 = 층 A). 한계 = 그 파일 머리말 `ponytail:` 줄. 짝 테스트 `git-hooks-installed-guard.test.sh`.
- `claude/hooks/sql-staging-guard.sh` — 커밋 게이트(층 A 디스패처가 부른다 — settings 의 PreToolUse 에 등록한 레포에서는 명령이 허용 형태(단독 커밋 — `lib/git-cmd.sh` `git_commit_call_form`)일 때만 실검사로 넘어간다): 새 경로가 생기는(A·C·R) `.sql` 스테이징 차단(tracked 덤프 수정 M은 통과). 안내 = `git restore --staged -- <새·옛 경로·.sql 삭제>`(HEAD 없으면 `git rm --cached`)
- `claude/hooks/git-add-all-guard.sh` — PreToolUse(Bash): 병행 세션이 인덱스를 공유하는 레포에서 일괄 스테이징(`add -A/--all/-u/.`·`commit -a`) 차단, 명시 경로만 통과(예외 `ALLOW_GIT_ADD_ALL=1`). 짝 = `claude/scripts/wt-prereview.sh`(리뷰용 worktree 스테이징)
- `claude/hooks/secret-commit-guard.sh` — 커밋 게이트(층 A 디스패처가 부른다 — settings 의 PreToolUse 에 등록한 레포에서는 명령이 허용 형태(단독 커밋 — `lib/git-cmd.sh` `git_commit_call_form`)일 때만 실검사로 넘어간다): 커밋될 diff 추가라인 시크릿 스캔 차단(기본 = 제외 없음·전 파일 스캔. 팀이 tracked 로 관리하는 접속정보 파일만 설치 시 EXCLUDE_PATH_REGEX 에 추가)
- `claude/hooks/prod-db-guard.sh` — PreToolUse(Bash): 직접 DB 접속 차단 — 인라인 python(-c·히어독·파이프·같은 호출에서 쓰고 실행)의 DB 접속은 **호스트와 무관하게** 차단(정본 = DB MCP·DDL 스킬 스크립트 *파일* 실행), DB CLI 는 허용 호스트 단독 호출만 통과, 단독 ssh·autossh 터널 생성(-L·LocalForward·-N)도 차단(부트스트랩 시 dev 호스트를 **`ALLOWED_DB_HOSTS_ANYPORT_REGEX`** 에 추가 — 포트 게이트 축 `ALLOWED_DB_HOSTS_REGEX` 에 넣으면 비표준 포트 dev 접속이 막힌다). 짝 테스트 `prod-db-guard.test.sh`·`lib/cmdform.test.sh`.
- `claude/hooks/lib/cmdform.py` — 허용 형태 판정기(python3 표준 라이브러리, `python3 -I` 로 부른다): prod-db-guard 와 커밋 게이트의 PreToolUse 경로가 쓴다. 판정기·python3·jq 부재·시간 초과·예외는 관련 낱말이 보이면 차단(fail-closed). **형제 레포 갱신 순서 = `lib/`(git-cmd.sh·cmdform.py)를 먼저 두고 게이트·prod-db-guard 를 그다음 한 번에 바꾼다** — 옛 게이트 + 새 lib 는 종전 동작, 새 게이트 + 옛 lib 는 커밋이 막히는 쪽(fail-closed)으로만 어긋난다. 짝 테스트 `lib/cmdform.test.sh`·`commit-gate-form.test.sh`.
- `claude/hooks/code-review-marker-reminder.sh` / `claude/hooks/mark-review.sh` — 커밋 전 리뷰 게이트(층 A 디스패처가 부른다 — settings 의 PreToolUse 에 등록한 레포에서는 명령이 허용 형태(단독 커밋 — `lib/git-cmd.sh` `git_commit_call_form`)일 때만 실검사로 넘어간다 — 그 경로의 대상 = cwd, 지문 = 정규형 `git commit`)와 그 통과 마커. **마커는 인자가 있어야 찍힌다**(`--result <리뷰 결과 JSON>` 또는 `--skip-reason "<사유>"`, 인자 없는 호출은 fail-closed) — `--result` 의 통과 조건 정본 = `mark-review.sh` 머리 주석(허용 목록).
- `claude/hooks/roundtrip-verify-reminder.sh` / `claude/hooks/mark-roundtrip.sh` — PreToolUse(Bash): 다층 관통 diff 에 **실물 왕복 1회**를 상기(경고형)하고, 왕복 후 마커를 찍으면 조용해진다. ⚠️설치 시 `FILE_REGEX`·`CONTENT_REGEX` 를 대상 레포 실측으로 채워야 발동한다(미치환 = 조용한 무기능).
- `claude/hooks/stale-app-verify-guard.sh` — PreToolUse(Bash): **소스 최신 mtime > 앱 기동 시각**이거나 **모듈 소스 > 그 모듈 classes(미컴파일)**이면 검증 명령을 차단(`ALLOW_STALE_APP=1` 우회). '클래스가 더 새로움'은 mvn 이 매번 갱신해 근거로 쓰지 않는다. 짝 테스트 `stale-app-verify-guard.test.sh`.
- `claude/hooks/mvn-test-record.sh` / `claude/hooks/mvn-test-result-gate.sh` — PostToolUse·PostToolUseFailure 로 `mvn test` 결과를 기록하고(기록 형식·판정 정본 = 두 훅 머리 주석 — 부분 실행·잘린 출력·백그라운드 실행은 커밋 근거가 아니다), 커밋 게이트(층 A 디스패처가 부른다)로 **커밋 근거가 되는 SUCCESS 가 없거나 그 실행 시작 뒤 빌드 입력이 바뀐 커밋을 차단**(`ALLOW_UNTESTED_COMMIT=1` 우회). 짝 테스트 `mvn-test-result-gate.test.sh`.
- `claude/hooks/profile-key-diff-guard.sh` — Pre/PostToolUse: 모듈별 `-local`·`-dev`·`-prod.sample` 프로파일의 **키 차집합**을 경고(`ALLOW_PROFILE_KEY_DIFF=1` 우회, base 는 기본 제외). 짝 테스트 `profile-key-diff-guard.test.sh`.
- `claude/hooks/text-constant-3layer-reminder.sh` — PreToolUse(Bash): diff 가 **바꾼 사용자 문구**의 옛 값이 소비 층 3개(레포 소스 / 전역 회귀 스위트 / 설계 문서)에 남아 있는지 후보를 뽑아준다(판정은 사람). 짝 테스트 `text-constant-3layer-reminder.test.sh`.
- `claude/hooks/comment-selfcheck-reminder.sh` / `claude/scripts/comment-selfcheck.sh` — 커밋 전 **주석이 코드 밖 사실·개수·배타 단언**을 하고 있지 않은지 후보를 뽑아 확인 사실을 리뷰 기록에 남기게 한다(`--repair` = 리뷰 수리분에서 새로 쓴 주석 문장 표시).
- `claude/hooks/test-count-guard.sh` — 커밋 게이트(층 A 디스패처가 부른다 — settings 의 PreToolUse 에 등록한 레포에서는 명령이 허용 형태(단독 커밋 — `lib/git-cmd.sh` `git_commit_call_form`)일 때만 실검사로 넘어간다): 테스트 수 감소 커밋 차단(`ALLOW_TEST_COUNT_DROP=1` — 층 A 에선 실제 환경변수일 때).
- `claude/scripts/ponytail-debt.sh` — `// ponytail:` 로 표기한 의도적 코너컷 장부 조회.
- `claude/scripts/token_usage.py` — 세션 트랜스크립트(JSONL) 토큰 집계(`requestId` 중복 제거). 설치 시 `SLUG` 를 대상 레포 인코딩 경로로 치환.
- `claude/scripts/session-grep.py` — 지난 세션 원문(JSONL) 키워드 검색. 로컬 전용·네트워크 없음, 스니펫의 비밀값 마스킹은 끌 수 없다(의심 지시어 뒤 줄 끝까지 가림 · 테스트 `session-grep.test.py`). 기본 대상 = 현재 레포(git toplevel)의 세션 폴더 — 치환 불필요, 다른 폴더는 `--dir`.
- 훅 테스트(`*.test.sh`)는 훅을 고칠 때 **반증 1회**를 붙이기 위한 것이다 — 설치 후 `bash .claude/hooks/<훅>.test.sh` 로 양성·음성이 같이 도는지 확인한다(플레이스홀더 미치환 상태에서는 실패한다).
- `claude/hooks/pull-smoke-reminder.sh` — PostToolUse(Bash): `git pull`로 팀 커밋 유입 시 "작업 착수 전 harness 스모크 1회" 리마인더를 additionalContext로 주입(차단 아님·fail-open, 팀 문서 변경 시 규약 대조 안내 포함)
- `claude/scripts/wt-prereview.sh` / `claude/scripts/wt-collect.sh` — 병행 세션용 리뷰 worktree 준비(`--include-staged`·`--with-scaffold`)와 수리분 회수(시작 지문 대비 충돌 보호·cmp 보고)
- `claude/workflows/commit-review.js` — 커밋 전 다각 리뷰 워크플로(반환 `fixChecklist` = CONFIRMED 1:1 수리 체크리스트) / `claude/workflows/delta-review.md` — 소형 A·델타 재리뷰용 단일 에이전트 프롬프트 템플릿
- `claude/jsharness/` — 화면 JS 로직의 결정적 단위검증(vm + 최소 DOM 스텁, 브라우저·DB 없음). lib·run.js 만 이식, 스펙은 레포 고유
- `claude/scripts/export_schema_snapshot.py` — dev DB 스키마 스냅샷 추출 템플릿(harness 룰 K 대조 기준·CRUD 스캐폴드 입력·로컬 컬럼 확인; 설치 시 `{{MODULE_ADMIN}}` 치환 + `DEV_HOST_ALLOWLIST`에 프로젝트 dev 호스트 추가 + `chmod +x` 후 1회 실행해 `.claude/schema-snapshot.json` 생성)
- `claude/skills/new-screen/` — 신규 화면 착수 체크리스트 + CRUD 스캐폴드 생성기(스키마 스냅샷 → Core 8파일 +`--admin` BO 5파일). **회사·프로젝트 고유값은 스크럽됨** — 설치 시 `scaffold_crud.py` 상단 REEXTRACT 구간 + `templates/*.tmpl`의 `{{...}}` 플레이스홀더(`{{MODULE_CORE}}`·`{{PKG_CORE}}`·`{{PKG_PATH_*}}`·`{{UUID_UTIL_FQN}}`/`{{UUID_UTIL_NAME}}`·`{{JS_NS}}`·`{{BASE_CONTROLLER_FQN}}`·`{{BASE_SEARCH_VO_FQN}}`·`{{SITE_HELPER_FQN}}`)를 대상 레포 실측으로 채운다(미치환 시 `_guard_reextract()`가 기동 차단). 정본 참조 도메인·감사 명명표준(eGov standard-db-naming 기본)도 레포에 맞게 확정.
- ~~`claude/agents/e2e-verify.md.tmpl`~~ — **설치 안 함(2026-07-07 유저레벨 단일화).** e2e-verify는 유저레벨 범용 서브에이전트 `~/.claude/agents/e2e-verify.md` 하나로 전 레포 자동 적용(설정은 `playwright-verify` 스킬 self-discover). per-repo 사본 금지(shadow·드리프트). 이 `.tmpl`은 제거됨(2026-07-07).
- `docs/harness.md.tmpl` — 빌드·검증 런북
- `docs/agent_history.md` — 빈 작업로그 스켈레톤
- `docs/obsidian-memory-viz.md` — memory 디렉터리를 Obsidian 볼트로 열어 그래프 시각화(`metadata.title` 라벨) 셋업 가이드
- `obsidian/` — memory `.obsidian/`로 복사할 Front Matter Title 플러그인 설정 시드(무설정 그래프 라벨; 플러그인만 사용자가 설치)
- `git-exclude-block.txt` — `.git/info/exclude`에 주입할 AI 스캐폴딩 격리 블록
- `claude/tier.conf` — 전역 `commit-tier-calc.sh` 의 프로젝트 확장 축(`extra_a_globs`). 없으면 화면 JS 로직만 바뀐 커밋이 B티어로 나온다. 설치 시 개발 소유 JS 경로로 확정.

## 이식하지 않는 것 (프로젝트 격리)
- `memory/` (프로젝트 도메인 학습 — 빈 상태로 시작)
- 도메인 표준값(공통코드·유형코드) — 실 DB 선검증 후 CLAUDE.md `<<< >>>` 구간에 채움
- `skills/standard-db-naming/` — 필요 시 스킬이 선택 복사
- 프로젝트 전용 스킬·도구 — `run-<repo>`·`regress-<repo>`(포트·스위트 고유), `dev-ddl-apply`(DB 호스트 고유 — 없으면 CLAUDE.md 의 DDL 안내를 조정), `ux-guide-apply`(그 레포 UX 가이드), `scripts/erd/`(그 레포 스키마 전용), `jsharness/specs/*`(화면 고유 — lib·run.js 만 이식)

## 계층 구분
- **전역(이미 공유):** `~/.claude/skills/{harness,playwright-verify}`, `~/.claude/hooks/*`, `~/.claude/CLAUDE.md` → 새 레포에서 자동 적용, 이식 불필요.
  - 완료 알림: 전역 Stop 훅 `~/.claude/hooks/notify-done.sh`(맥 배너+소리 + 폰 ntfy 푸시)가 **모든 레포에서 자동 발화**(프로젝트명=cwd basename 자동). CLAUDE.md.tmpl의 "완료 알림 상태줄" 규약이 알림 본문을 `[프로젝트명] <문장>`으로 채운다. 새 **머신**을 셋업할 때만 이 전역 훅 + `~/.claude/settings.json` Stop 등록 + 개인 ntfy 토픽(`NTFY_TOPIC`)을 함께 옮기면 된다(레포 부트스트랩 범위 밖).
- **레포별(이 템플릿):** 위 구성 파일들.
- **프로젝트 고유(격리):** memory·도메인값·DB 스킬.
