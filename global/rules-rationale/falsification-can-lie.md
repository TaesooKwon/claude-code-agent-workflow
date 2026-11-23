---
name: falsification-can-lie
description: "전역 '반증검사 부칙' 조항의 근거 — 빨간불이 안 뜨는 것이 거짓 초록/미실행인 경우의 판별 항목, 동어반복 단언."
metadata:
  node_type: memory
  type: feedback
  title: 반증검사 자체가 거짓을 말한다
---

**규칙(전역 규약 §비동기·검증):** 반증검사 자체가 거짓을 말한다 — 몇 건이 왜 깨져야 하는지 먼저 적고 대조하고, `Tests run: N>0` 을 단언한다(미실행 ≠ 통과). 기대값은 코드와 같은 계산으로 만들지 말고 리터럴·설계서에서 가져온다.

레포별 변이 사례·함정 목록은 각 프로젝트 회상층(예시 레포 = `falsification-can-lie-mutation-not-applied`)이다.


## 경위(2026-09-17 이동)

**비동기검증:20 축약(원문 전문):** "**부칙 — 반증검사 자체가 거짓을 말할 수 있다**('빨간불 안 뜸' = 거짓 초록 또는 미실행): ⓐ**변이 적용 건수를 `assert`**(비가시 문자는 이스케이프로) ⓑ메시지 단언은 전문 일치·구조적(부분문자열이 다른 실패 경로에 걸린다) ⓒ몇 건이 왜 깨져야 하는지 먼저 적고 대조 ⓓ**`Tests run: N>0` 단언** — 컴파일 실패·미실행은 '미반증'이지 통과가 아니다(변이는 컴파일되는 형태로)." → ⓓ의 마커 시점 기계화(리포트 신선도 포함)는 승격 대기.

## 동어반복 단언(2026-11-17 추가)

원문: "the assertion recomputes the expected value the way the code does … so it passes by construction and can never disagree with the code. Expected values must come from an independent source of truth: a known-good literal, a worked example, the spec." (출처 mattpocock/skills `skills/engineering/tdd/SKILL.md:31` @5863806, MIT). 기대값을 고의로 어긋나게 하는 빨간불 확인은 이 결함을 못 잡는다 — 바꾼 기대값은 코드 계산과 달라지므로 동어반복 단언도 빨개진다(추론, 재현 없음). 같은 원본의 "DB 를 조회해 검증하지 말라"(`tests.md:47-60`)는 저장값 재조회 조항과 충돌해 채택하지 않았다.
