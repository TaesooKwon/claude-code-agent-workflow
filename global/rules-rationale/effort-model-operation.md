---
name: effort-model-operation
description: "effort·모델 운용 — 작업 단계별 effort(구현 medium · 기존 코드 버그 수리·검증·리뷰 high · 기계적 일괄 편집 low), 막히면 모델보다 effort 먼저, 같은 문제 2회째 high → 3회째 전 xhigh/Fable. effort 는 사용자 명령(/effort)이라 에이전트는 권고만."
metadata:
  title: "effort·모델 운용"
  node_type: memory
  type: feedback
---

**규칙(권고 — effort·모델 전환은 사용자 명령 `/effort`·`/model` 이다. 에이전트는 단계 진입 때 한 줄로 권고하고 스스로 바꾸지 않는다):**
- **단계별 effort:** 설계 인터뷰·일반 구현 = medium(Opus 5.5 기본) / **기존 코드 버그 수리·검증·리뷰·경합·인가·보안 = high** / 이름 바꾸기·같은 패턴 N곳 같은 기계적 편집 = low(모델은 Opus 유지) / 사람 없이 끝까지 가는 어려운 문제 = max. 끝나면 원래 단계로 내린다.
- **막히면 모델보다 effort 먼저:** 수정이 한 층에서 멈추는 것(호출부·다른 층을 안 봄)이 신호다. 단, effort 를 올리기 전에 "그 결함을 잡는 검사를 모델이 돌릴 수 있나"부터 본다(검사 1턴이 effort 상향보다 싸다).
- **에스컬레이션 사다리(같은 버그):** 1회째 수리 실패 → 2회째는 high 로 → 그래도 실패하면 멈춤 보고(레포에 루프 상한 규약이 있으면 그 보고)의 선택지에 **xhigh 또는 Fable 전환**을 넣는다.
- **모델 전환은 끊기는 지점에서:** 새 모델은 캐시가 비어 있다 → `/compact`(보존할 것을 지시) 뒤 또는 짧은 계획을 들고 새 세션.
- **작은 모델(Sonnet·Haiku)은 조회·요약용**(검색·로그 판독·"어디 정의돼 있나"). 코드 편집은 Opus.
- **프롬프트에 "think hard" 류 금지**(effort 로 조절). 2026-10-11 실측: 전역·레포 규약·rules-lite·전 SKILL.md·워크플로에 0건.

**Why:** claude.dev 「Spending your effort」(2026-09-25) — "higher effort is best for tasks with lots of hidden edge cases", 경험칙 "High: … fixing a bug in a brownfield codebase", Terminal-Bench 3.0 에서 low → high 로 엣지케이스 실패가 줄고 Security 64% → 87%(Fable 5.1). 「What a task costs on Opus 5.5」 — "Raise effort before you change models", high 가 더 쓰는 thinking 은 작업당 대략 재시도 루프 1회 값이라 재시도를 하나라도 줄이면 본전, "If Opus 5.5 on xhigh hits the same problem twice, switch"(Fable), "Move down to Sonnet or Haiku for lookups, not for writing code", **구독·API 키에선 effort 를 세션 중에 바꿔도 캐시가 유지된다**(Bedrock·Vertex·게이트웨이는 아님). 우리 설정 = `~/.claude/settings.json` modelSettings 의 Opus 5.5 medium 고정 — 단계별 전환 관례가 없었다(2026-10-11 사용자 "권장안으로 해줘").

**How to apply:** 훅 `effort-stage-reminder.sh`(PreToolUse `Skill|Workflow`)가 검증·리뷰 진입(harness·regress·playwright-verify 스킬, commit-review·delta 워크플로) 때 세션당 1회 사다리를 상기한다 → 에이전트는 진행 중인 작업이 high 축이면 사용자에게 `/effort high` 를 한 줄로 권고. 수치·근거 원문 = 레포 `docs/agent_claude-dev-survey-20261010.md`. 관련 [[delegation-token-economy]].
