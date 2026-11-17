---
name: agent-audit
description: 에이전트 세팅 전면감사 — 머신층(킷 doctor)·훅 동작(test-hooks)·memory(scan)·프로젝트층(훅 등록·격리·플러그인 이중발동)을 원커맨드로 점검하고, 판단성 항목은 체크리스트로 마무리. 트리거="세팅 감사", "전면 감사", "에이전트 점검", "세팅 점검".
---

# agent-audit — 에이전트 세팅 전면감사

**목적:** 수동 전면감사 3회 반복(0702·0710·0719) → 승격사다리로 절차화. 기계적 점검은 스크립트가, 판단은 아래 체크리스트로.

## 1. 기계적 점검 (원커맨드)

```bash
bash ~/.claude/skills/agent-audit/scripts/audit.sh            # 현재 프로젝트
bash ~/.claude/skills/agent-audit/scripts/audit.sh --fast     # 킷 doctor·test-hooks 스킵(프로젝트층만)
```

포함: ①머신층 = 킷 `doctor.sh`(의존·훅 등록·드리프트) ②훅 동작 = 킷 `test-hooks.sh`(판정 로직 회귀) ③memory = `memory-hygiene scan.sh`(stale·죽은링크·pending) ④프로젝트층 = settings 등록 훅 파일 실존, conventions.enabled, git exclude 격리(AI 스캐폴딩이 tracked/미격리인지), 플러그인 이중발동(전역 on + 로컬 훅 존재 + local off 부재 — 훅 비중복을 판독한 플러그인은 `plugin-hooks-ok.txt` 에 hooks.json 해시로 면제). ⑤처분 도달 대장 = 훅 파일 → settings 등록 역방향(의도적 미등록은 헤더 `# audit: unregistered-ok — 사유`) + 전역·프로젝트 규약 `[[포인터]]` 정본 실존. ⑥훅 정책 줄 = 훅마다 셔뱅 다음 줄 `# hook-policy: 강제=<차단|확인|안내|기록|보조> · 도구부재=<차단|통과|->`(형식 정본 = `scripts/hook-policy-report.sh` 머리) — 없으면 경고. 표는 `scripts/hook-policy-report.sh`. **새 훅을 만들면 이 줄을 같은 편집에서 단다.**

## 2. 판단 체크리스트 (스크립트가 못 보는 것)

- **팀 md 흡수:** `AGENTS.md`·`Design.md` 등 팀 문서 변경분이 규약과 충돌하는지(블라인드 흡수 금지).
- **크로스 에이전트 마커:** `CLAUDE.md`에 상대(제미나이) 마커(`〔+Gemini …〕`) 유입분 검토·수용/보고.
- **promotion-candidates:** 3회 도달 항목 승격 검토(스킬/훅), 처리분 라인 제거.
- **memory 처분:** scan 리포트의 stale 마커·pending을 memory-hygiene SKILL §2 기준으로 처분.
- **킷 미반영 자산:** 이번 감사에서 정착시킨 범용 자산의 킷 반영 여부(반영 시 스크럽·grep 감사 → 커밋+푸시).
- **훅 로그 건강:** `~/.claude/hooks/*.log` tail로 BLOCK/PASS가 실제 찍히는지(죽은 훅 탐지).
- **저발동 스킬·무발화 훅:** `scripts/skill-usage-report.sh [일수]`(호출 0 스킬) + `hook-obs-report.sh`(「은퇴 후보」 = block·ask·warn 0 이고 정책 강제≠기록·보조) → description 보강·은퇴 **후보로 제시만**(처분은 사용자). 월 1회는 `hook-events-retention.sh` 가 세션 시작에 상기한다. 안전 가드(운영 DB·푸시·시크릿)는 발동 0이어도 제외.

## 3. 마무리

감사 결과(정합/조치 N건)를 memory(해당 정본 파일 갱신)와 `docs/agent_history.md`에 기록. 조치가 킷 자산이면 킷 커밋+푸시까지.
