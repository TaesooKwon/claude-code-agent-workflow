# 병행 세션과 워킹트리·인덱스를 공유할 때 — 일괄 스테이징 금지 + 리뷰는 worktree 선실행

> 전역 `~/.claude/CLAUDE.md` 리스크 티어링 절의 조항 **정본 근거**. 규약엔 규칙 문장만, 경위·실측·절차는 여기.
> 사용자 확정 2026-09-02(예시 레포, 병행 3세션 실측).

## 문제의 형태
`git` 인덱스는 워킹트리당 하나이고 **`git commit` 은 인덱스 전체를 커밋한다.** 한 레포에서 세션 여럿이 동시에
작업하면 ①한 세션의 `git add -A/.`/`git commit -a` 가 다른 세션의 untracked·수정 파일을 자기 커밋에 휩쓸어 넣고
②내 파일을 메인 인덱스에 올려 둔 채 상대가 커밋하면 내 파일이 그쪽 커밋으로 들어간다(실사고 memory
`commit-scope-staged-files-check` — 무관 26건 혼입). ③그렇다고 상대 커밋을 기다렸다가 스테이징·리뷰를 시작하면
리뷰(10~20분)가 직렬로 붙는다.

## 처방 2가지
1. **일괄 스테이징 금지 = 훅으로 강제.** PreToolUse(Bash) `git-add-all-guard.sh` — `git add -A/--all/-u/--update/./:/`,
   `git commit -a/--all/-am` 을 deny(세그먼트 단위, `sh -c "…"` 래핑·`-C /path` 전역옵션·`/usr/bin/git` 포함 —
   서브커맨드 탐지는 공용 `lib/git-cmd.sh`). 명시 경로 `git add <파일|디렉터리>` 만 통과. 예외 = `ALLOW_GIT_ADD_ALL=1`
   접두(단독 세션 확신 시). 반증검사 25케이스(deny 13 / pass 12) 전부 기대대로 — 첫 판에서 두 결함을 잡았다:
   ⓐ `printf '%s'` 로 개행 없이 `read` 루프에 넣어 **마지막 세그먼트(=단일 명령)를 통째로 건너뛰었다** → `printf '%s\n'`
   ⓑ 래핑 명령은 옵션 뒤가 공백이 아니라 따옴표라 종결자 `[[:space:]]` 만으로는 `sh -c "git add -A"` 가 새어 나갔다.
2. **리뷰는 worktree 에서 선실행, 메인에서는 재스테이징·마커·커밋만.**
   - 리뷰 워크플로(`commit-review.js`)는 `args.repo` 로 대상 레포를 받는다(`const REPO = A.repo || '.'`).
   - 스크립트 `.claude/scripts/wt-prereview.sh <스크래치패드>/wt-<이름> <내 경로…>`: `git worktree add --detach` →
     내 신규·수정 경로 복사 → **공유 파일(상대도 고친 파일)은 인덱스 대비 내 hunk 만 `git diff -- 파일 | git apply`**
     (상대가 스테이징해 둔 상태면 인덱스 = 그쪽 버전이라 정확히 내 hunk 만 남는다; HEAD 기준 worktree 에서 줄번호
     오프셋은 `git apply` 가 흡수) → `git add -A`(worktree 안이라 안전) → 리뷰 호출 안내 출력.
   - worktree 는 **레포 밖**(스크래치패드)에 둔다 — 레포 안(`.claude/worktrees/`)이면 MyBatis 계약검사가 같은 XML 을
     두 번 읽어 `Duplicate mapper namespace` 오탐(실측).
   - ⚠️ worktree 엔 **git 이 추적하는 파일만** 있다 — gitignored 픽스처·local 설정·자격증명을 읽는 테스트는 그 안에서
     조용히 skip 되어 초록을 낼 수 있다(원문 "A worktree holds only what git tracks. Tests that read gitignored fixtures,
     local databases, or credentials can silently skip there." — mattpocock/skills `docs/engineering/implement-spec.md:68`
     @5863806, MIT). `wt-prereview.sh --with-scaffold` 가 격리 스캐폴드와 `application-local.properties` 를 복사해
     부분 대응한다 — 그 밖의 ignored 파일에 의존하는 검증은 메인 워킹트리에서 돌리고 `Tests run: N>0` 을 본다.
   - 상대 커밋 감시 = `until [ "$(git rev-parse --short HEAD)" != "<현재>" ]; do sleep 20; done` 을 `run_in_background`
     (10분 상한이라 만료 시 재장전). HEAD 가 바뀌면 메인에서 같은 경로 `git add` → `git diff --cached | grep -v '^@@'`
     를 worktree 것과 대조(hunk 헤더는 줄번호가 밀려 다르니 본문만) → `mark-review.sh` → `git commit`(별도 호출).
   - ⚠️ **리뷰 마커 파일은 레포 단위로 공유**된다 — 상대가 마커를 찍어 둔 상태에서 내가 먼저 찍으면 그쪽 게이트가
     막힌다(지문 불일치). 마커는 **내 커밋 직전, 상대 커밋 이후**에만 찍는다.
   - CONFIRMED 수리는 메인 워킹트리에서 하고 worktree 에 다시 복사(또는 worktree 재생성) 후 델타 재리뷰.
   - 정리 = `git worktree remove --force <경로>`.

## 실측(2026-09-02, 예시 레포 화면 A)
상대(화면 B 세션)가 20파일을 스테이징해 리뷰 중일 때, 내 21파일(신규 15·수정 6, 공유 파일 `SecurityConfig.java` 1)을
worktree 에 복사·스테이징해 4관점 리뷰를 선실행했다. 공유 파일은 `git diff -- 파일` 이 정확히 내 hunk 2개만 냈다.
같은 시간에 실검사형 훅 2개(리뷰 마커·일괄 스테이징 가드)가 **내 테스트 명령의 리터럴**(`git commit …`, `git add -A`)에
발동했다 — 훅 테스트 케이스는 Bash 인자가 아니라 **파일**에 두고 실행한다(명령 텍스트에 리터럴을 넣지 않는다).

## 배치
- 전역 규약(방법론) = 이 문서의 포인터. 프로젝트 규약에는 스크립트 경로·워크플로 호출 한 줄만.
- 훅·스크립트 = 이식 킷 `global/agent-scaffold/claude/{hooks,scripts}/` + `test-hooks.sh` 회귀 케이스.


## 경위(2026-09-17 이동)

**비동기검증:16 축약(원문 전문):** "**병행 세션과 인덱스를 공유할 땐** ①일괄 스테이징 금지(`git add -A/--all/-u/.`·`commit -a` — 훅 `git-add-all-guard.sh`) ②리뷰는 내 변경만 복사한 worktree 에서 선실행(`args.repo`), 상대 커밋이 HEAD 에 든 뒤 메인에서 재스테이징 → `git diff --cached | grep -v '^@@'` 대조 → 마커 → 커밋." → 스크립트 절차는 프로젝트 `.claude/scripts/wt-prereview.sh`·`wt-collect.sh`. 일괄 스테이징 차단은 현행 훅 유지(약화 금지).
