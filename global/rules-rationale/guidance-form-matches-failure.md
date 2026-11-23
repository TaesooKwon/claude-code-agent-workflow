---
name: guidance-form-matches-failure
description: 전역 「규약 배치·전파」 "지침 문구는 실패 형태에 맞춘다" 조항의 근거 — superpowers writing-skills 대조(2026-11-05)·mattpocock writing-for-agents 가지치기(2026-11-17) 흡수분.
---

# 지침 문구는 실패 형태에 맞춘다

## 규칙(전역 정본은 한 줄)
문구를 쓰기 전에 그 문구가 막으려는 실패를 분류하고 형태를 고른다.

| 실패 형태 | 맞는 형태 | 틀린 형태 |
|---|---|---|
| 알면서 어김(압박 아래 규칙 위반) | 금지 + 걸리는 증상(합리화 신호) | "가급적 ~" 같은 약한 권고 |
| 따르긴 하는데 결과물 모양이 틀림(장황·결론 묻힘·명세 재서술) | 구성 레시피 — 결과물이 무엇인지, 부분과 순서 | 금지 목록("~하지 마라") |
| 이미 만드는 산출물에서 필수 요소 누락 | 템플릿의 필수 칸(구조) | 템플릿 근처의 산문 상기 |
| 조건에 따라 달라져야 하는 동작 | 관측 가능한 조건문("X 가 있으면 Y") | 무조건 규칙 + 예외 조항 |

- **뉘앙스 조항 금지:** "중요하면 예외" 같은 단서는 협상을 다시 연다. 진짜 예외는 관측 가능한 조건문으로 따로 쓴다.
- **예외 조항은 범위를 못 가둔다:** "코드 블록에는 적용 안 함"이라고 써도 억제가 번진다. 예외가 필요하면 규칙이 그 자리에 닿지 않게 구조를 바꾼다.
- **스킬 `description`:** 무엇+언제는 쓰되 단계 순서·횟수는 요약하지 않는다. 에이전트가 본문 대신 요약을 따른다.

## 근거(출처 = obra/superpowers `skills/writing-skills/SKILL.md`, 마켓플레이스 고정 커밋 bb92a777)
- :461-476 "Match the Form to the Failure" 표와 규칙 — 원문 주장: 디스패치 프롬프트 문구 비교에서 금지형이 레시피형보다 원치 않는 내용을 확연히 더 냈고 무지침 대조군보다도 나빴다, 이긴 레시피에 뉘앙스 조항 하나를 붙이자 일관 → 들쭉날쭉. **실험 수치는 원문 주장이며 우리 쪽 재현 없음(미검증).**
- :150-158 description 실험 — "code review between tasks" 라고 요약하자 에이전트가 본문의 2단계 리뷰 중 1번만 수행, 트리거 조건만 남기자 2단계를 따름.
- 범위 축소 이유: 원문은 "description = 언제만"을 요구하지만 같은 묶음의 `anthropic-best-practices.md`:185-187 은 "what it does and when to use" — 우리는 Anthropic 권고를 따르고 **순서·횟수 요약만** 금지한다.
- 대조 = 좌석 조사(교차 더블체크) → 원문 :150-158·:461-476·:580-583 직접 대조(2026-11-05).

## 가지치기(2026-11-17 추가 — 출처 mattpocock/skills `skills/productivity/writing-for-agents/SKILL.md:49,79,82`·`.out-of-scope/new-skills.md:9` @5863806, MIT)
- **무동작 문장은 문장째 삭제:** 모델이 이미 기본으로 지키는 지시는 부하만 쓴다. 원문 "an instruction the model already obeys by default pays load to say nothing … delete the whole sentence rather than trim words from it." 판정은 모델 기준이라 논쟁이 아니라 실행으로 정한다.
- **환경을 다시 적은 문서 = 캐시:** 파일·명령 하나로 찾는 사실(설정값·스크립트 목록·디렉터리 구조)은 적지 않는다 — 낡는다. 적는 것은 찾아서는 안 나오는 것(불문율·선택의 이유·설정이 말해 주지 않는 함정). 원문 "Cache what the agent cannot find by looking".
- **완료 기준이 모호하면 조기 완료:** "이해될 때까지" 같은 경계는 다음 단계로 넘어가는 당김을 못 버틴다 — 경계를 먼저 날카롭게(관측 가능한 조건) 한다. 원문 "A vague bound … invites **premature completion** … sharpen the bound first".
- **새 스킬 신설 기준:** 기존 스킬 조합이나 기존 스킬에 절을 추가해서 되는 동작이면 새 스킬을 만들지 않는다. 원문 "if you can compose the behaviour from existing skills, it doesn't get a new skill."

## 적용 메모
- 우리 규약은 "금지 + 예외" 형태가 많다(11-05 실측) — 소급 재작성하지 않는다. 그 조항을 고칠 일이 생겼을 때 이 표로 형태를 다시 고른다.
- description 에 단계를 나열하는 기존 스킬(표본: memory-hygiene·new-screen) — 소급 재작성하지 않는다. 다음에 그 스킬을 고칠 때 판정.
- 채택하지 않은 것: writing-skills 의 "스킬마다 서브에이전트 압박 시나리오 3+·5회 반복·안 하면 삭제"(위임 비용 충돌 — [[delegation-token-economy]]), "무지침 대조군에서 실패가 안 보이면 쓰지 말라"(:582 — 우리 승격 조건 2~3회 반복과 같은 축이라 생략, 11-05 결정).
