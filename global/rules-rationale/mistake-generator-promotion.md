---
name: mistake-generator-promotion
description: "전역 '실수가 이어지면 생성기를 찾아 규약화하라' 조항의 근거 — 발동 조건과 5단 절차 원문(2026-08-07 사용자 상시 지시)."
metadata:
  node_type: memory
  type: feedback
  title: 생성기 승격 절차 근거
---

**규칙(전역 규약 §상태주장):** 같은 실수가 2~3회 이어지면 개별 수리를 멈추고 생성기를 찾아 규약·훅으로 승격, 진단을 보고 후 승인받는다. 방어하지 않는다.

레포별 승격 후보 대기열은 각 프로젝트 회상층(예시 레포 = `promotion-candidates`)이다 — 여기엔 절차만 둔다.


## 경위(2026-09-17 이동)

**상태주장:7 축약(원문 전문):** "**실수가 이어지면 개별 수리로 끝내지 말고 생성기를 찾아 규약화하라**(사용자 상시 지시 2026-08-07). 발동 = 같은 세션·주에 사용자 정정 2~3회 누적, 또는 사용자가 결함을 먼저 잡는 일이 반복. 절차 = ①그 세션의 실수를 이력에서 전수 나열(형태를 본다) ②공통 생성기 하나 ③기존 검증이 왜 못 잡았나(검사하지 않는 층) ④규약·훅·게이트·계약 필수항목으로 승격(배치 3규칙대로) ⑤진단·해결책·반영 위치 보고 후 승인. **방어하지 마라.**"

## ③④ 보강(2026-11-17 추가)

- ③: 이미 있는데 연결 안 됐거나 조용히 깨진 검사가 있으면 그것이 발견이다 — 새로 만들기 전에 기존 훅·harness·테스트가 이 실수를 볼 수 있었는지부터 확인한다. 원문: "a check that already exists but sits unwired or silently broken is the finding, not a reinvention."
- ④: 기계적 위반(고정된 문법 패턴·금지 API·import 모양·파일 위치)은 규칙 문장보다 결정적 검사가 먼저다 — 산문 규약은 기계가 못 가리는 판단 문제에만. 원문: "a **mechanical** one … gets a deterministic check, full stop … Default to building the check over writing the rule."
- 출처: mattpocock/skills `skills/engineering/retro/SKILL.md:18-19` @5863806 (MIT). 같은 원본의 "CLAUDE.md 는 내비게이션 포인터만"(`:41`)은 배치 3규칙과 충돌해 채택하지 않았다.
