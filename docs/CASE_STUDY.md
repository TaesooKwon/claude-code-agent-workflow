# Case Study — AI 코딩 에이전트를 "규약 → 훅 → 게이트"로 통제하기

> 공공기관 웹 서비스 SI 실무(eGovFrame/Spring + Maven 멀티모듈, Java 8, MyBatis)에서
> Claude Code 를 주 개발 도구로 쓰며 6개월간(2026-06 ~ 11) 만든 개인 워크플로우 킷의 요약이다.
> 세부 근거는 [`METHOD.md`](../METHOD.md), 구현은 레포 전체.

## 1. 문제

AI 에이전트는 빠르지만, 레거시 프로젝트에서는 다음이 반복됐다.

- **규칙을 알려줘도 어긴다.** `CLAUDE.md` 에 "SELECT * 금지", "Java 9+ 문법 금지"를 적어도 다음 세션에서 또 나온다.
- **"확인했다"는 보고를 그대로 믿을 수 없다.** 리뷰 지적을 고친 뒤 재스테이징을 빠뜨리면 리뷰 전 코드가 커밋되고, 테스트가 0건 실행돼도 "빨간불 없음"이 통과로 읽힌다 — 에이전트의 자기 보고로는 이런 실패를 구분할 수 없다.
- **검증 비용이 통제되지 않는다.** 모든 변경에 같은 무게의 리뷰·E2E 를 돌리면 토큰과 시간이 크게 들지만 소득이 없는 경우가 많았다.
- **규약이 자라며 매 세션 고정비가 된다.** 자동 로드되는 규약·메모리 인덱스가 컨텍스트를 잠식했다.

## 2. 설계 원칙

| 원칙 | 내용 | 근거 |
|---|---|---|
| 승격 사다리 | 경험 → 교훈(memory) → 절차(skill) → 강제(hook/gate). 문서로 적었는데도 계속 어기면 그건 게이트가 될 규칙이다 | [METHOD §3](../METHOD.md#3-승격-사다리-promotion-ladder) |
| 승격 전 빈 층 확인 | 반복 결함이라고 바로 게이트로 가지 않는다. 검증층이 이미 잡는지, 기계 판정이 가능한지, 선언층이 있었는지 먼저 본다 | METHOD §3.2 |
| 성격 기반 티어링 | 리뷰·E2E 의 무게는 diff 크기가 아니라 **실행 의미가 바뀌었는가**로 정한다. staged diff 로 기계 판정, 애매하면 무거운 쪽 | METHOD §5 |
| 단일 출처 | 규칙은 한 곳에만. 규약엔 규칙 문장만, 근거·사례는 별도 저장소(`rules-rationale/`)로 | METHOD §1, §9 |
| 설정 격리 | 개인 에이전트 구성은 팀 레포에 섞지 않는다(`.git/info/exclude`) | METHOD §7 |

## 3. 구현

- **커밋 게이트(git 훅 + Claude Code 훅 2층).** 커밋 전에 SQL 초안·시크릿·테스트 결과·리뷰 마커를 검사하고, 리뷰 마커는 staged diff 의 **지문**과 대조해 리뷰 후 코드가 바뀌면 커밋을 막는다.
  → [`global/agent-scaffold/claude/hooks/git/`](../global/agent-scaffold/claude/hooks/git/), [`mark-review.sh`](../global/agent-scaffold/claude/hooks/mark-review.sh)
- **커밋 티어 자동 판정.** staged diff 를 로직 소스·쿼리/매퍼·인라인 스크립트·조건/반복 바인딩 4축으로 세어 A(다각 리뷰)/B(셀프리뷰)를 계산한다.
  → [`commit-tier-calc.sh`](../global/hooks/commit-tier-calc.sh), 리뷰 병합 계약 [`commit-review.js`](../global/agent-scaffold/claude/workflows/commit-review.js)
- **컨벤션 린트(harness).** MyBatis 매퍼 계약, `SELECT *`·CDATA·물리 DELETE, Java 8 전용 문법, 매퍼↔실스키마 대조, 비동기 래퍼 실패 가드 등 프로젝트 규칙을 정적 검사로 강제한다.
  → [`check_conventions.py`](../global/skills/harness/check_conventions.py), [`check_mybatis_contract.py`](../global/skills/harness/check_mybatis_contract.py)
- **위험 명령 가드.** 운영 DB 접근, 일괄 스테이징(`git add -A`), 훅 우회(`--no-verify`), 원격 push, 기존 파일 덮어쓰기를 PreToolUse 훅으로 차단·확인한다. 셸 명령을 문자열이 아니라 구문 단위로 파싱해 래핑·heredoc 우회를 막는다.
  → [`hooks/lib/cmdform.py`](../global/agent-scaffold/claude/hooks/lib/cmdform.py), [`git-push-guard.sh`](../global/hooks/git-push-guard.sh)
- **폐쇄형 학습 루프.** 세션 종료 시 교훈 기록(memory/history)이 없으면 Stop 훅이 종료를 막는다.
  → [`closed-loop-history.sh`](../global/hooks/closed-loop-history.sh)
- **이식성.** 머신 고유값은 토큰으로 비워 두고 설치 시 치환한다. 대상 레포의 스택(빌드툴·Java 버전·모듈 구조)을 판정해 룰을 켜고 끈다.
  → [`bootstrap-machine.sh`](../bootstrap-machine.sh), [`analyze-stack.sh`](../analyze-stack.sh), [`doctor.sh`](../doctor.sh)
- **훅 자체의 회귀 테스트.** 차단/통과·주입/침묵·fail-open 을 픽스처 레포에서 실제로 돌려 검증한다(168건).
  → [`test-hooks.sh`](../test-hooks.sh)

## 4. 실측 결과

| 관찰 | 수치 | 이어진 결정 |
|---|---|---|
| 상수만 바뀐 4화면(치수·색상·문구)을 개별 E2E | 위임 55만 토큰·39분, 제품 버그 0건 | 상수 변경은 회귀 스펙만 추가하고 다음 배치에 묶는다 |
| 마크업 23줄 변경에 다각 리뷰 | 15에이전트·1.08M 토큰·9.5분, 확정 지적 0 | 표현만 바뀐 변경은 셀프리뷰(B)로. 같은 무게의 리뷰가 상태·비동기 변경에선 되돌릴 수 없는 오작동을 잡았으므로 그쪽은 유지(A) |
| 자동 로드되는 규약·인덱스 합계 | 92KB ≈ 35~45k 토큰(200k 컨텍스트의 약 20%) | 규칙은 남기고 근거를 밀어내는 축소 → 프로젝트 규약 47.3 → 30.7KB(35%↓) |
| 메모리 인덱스 "한 줄 요약" 규칙 | 124줄 중 119줄 위반 | 선언으로 안 지켜져 크기 게이트로 승격. 배치 규칙이 정착한 뒤엔 실이득이 작아 게이트를 해제했다(스크립트·회귀 테스트는 보존) |
| 전역 규약이 가리키던 근거 문서 | 5건이 작성된 1개 레포 외 6개 레포에서 미존재 | 프로젝트 memory 가 아닌 전역 근거 저장소(`rules-rationale/`) 신설 |

## 5. 배운 점

- **에이전트에게 "하지 마라"를 늘리는 것보다, 어기면 깨지는 구조를 하나 세우는 게 싸다.** 단, 기계 판정이 안 되는 규칙을 억지로 훅으로 만들면 오탐만 쌓인다.
- **검증 비용은 케이스 수가 아니라 환경 재기동 횟수에 쏠린다.** 커버리지를 깎지 말고 기동을 묶어라.
- **테스트는 "통과"가 아니라 "실패할 수 있음"을 확인해야 한다.** 새 단언은 일부러 깨뜨려 빨간불을 한 번 본다.
- **규약도 코드처럼 예산이 있다.** 매 세션 로드되는 모든 줄이 고정비다.

---

이 레포는 비공개 원본의 공개용 스냅샷이며, 실무 프로젝트명·사내 식별자는 가명 처리했다.
