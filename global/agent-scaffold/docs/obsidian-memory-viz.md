# Obsidian으로 에이전트 메모리 시각화

Claude Code의 프로젝트 메모리(`~/.claude/projects/<encoded-cwd>/memory/`)는 frontmatter를 가진 `.md` 파일 모음이다. 이 디렉터리를 **Obsidian 볼트로 열면** 메모리 간 `[[링크]]` 관계를 그래프로 시각화할 수 있다 — "에이전트가 무엇을 알고 있는지" 한눈에 보고, 낡거나 틀린 메모리를 찾아 정비하는 **열람·정비 창**으로 쓴다. (기록은 여전히 에이전트에게 "기억해줘"로 — Obsidian은 보기용.)

## 문제: 그래프 노드가 영문 slug로 뜬다
메모리 파일명은 kebab-case slug(`always-korean-output`)라 그래프도 slug로 표시돼 직관적이지 않다.

## 해결: `metadata.title` + Front Matter Title 플러그인
각 메모리 frontmatter에 human-readable `title`(출력언어 표시명)을 두고, 플러그인이 이를 그래프 노드 라벨로 표시하게 한다.

> **표준 키 = `metadata.title`** (top-level `title` 금지)
> Claude Code harness는 새 메모리를 저장할 때 top-level `title`을 **`metadata.title`로 자동 정규화**한다. 그래서 표준을 `metadata.title`로 잡으면 앞으로 만드는 모든 메모리가 저절로 규격에 맞는다(top-level로 잡으면 정규화로 위치가 바뀌어 라벨이 깨진다).

```yaml
---
name: always-korean-output
description: ...
metadata:
  title: "출력은 항상 한국어"   # ← 그래프 노드 라벨
  type: feedback
---
```

## 셋업

### 자동 (bootstrap-project)
bootstrap-project 스킬이 `agent-scaffold/obsidian/`의 설정을 대상 프로젝트 memory 디렉터리 `.obsidian/`로 복사한다. 사용자는 Obsidian에서 그 memory 디렉터리를 볼트로 열고 **Front Matter Title 플러그인(제작자 Snezhig)만 설치**하면, 사전 시딩된 설정 덕에 무설정으로 그래프가 표시명으로 뜬다.

### 수동
1. Obsidian → 설정 → 커뮤니티 플러그인 → **Front Matter Title** 설치·활성화.
2. memory 디렉터리에 아래 두 파일을 둔다:
   - `.obsidian/community-plugins.json`
     ```json
     ["obsidian-front-matter-title-plugin"]
     ```
   - `.obsidian/plugins/obsidian-front-matter-title-plugin/data.json` — `templates.common.main`을 `metadata.title`로:
     ```json
     { "templates": { "common": { "main": "metadata.title", "fallback": "fallback_title" } },
       "features": { "explorer": { "enabled": true, "templates": { "main": "", "fallback": "" } },
                     "header":   { "enabled": true, "templates": { "main": "", "fallback": "" } },
                     "graph":    { "enabled": true, "templates": { "main": "", "fallback": "" } } } }
     ```
3. 플러그인은 `data.json`을 **부팅/설정변경 시에만** 다시 읽으므로, 디스크로 설정을 바꿨으면 **Obsidian 리로드**(`Cmd/Ctrl+R`) 또는 플러그인 껐다 켜기.

## 기존 메모리 title 백필 (기존 프로젝트만)
신규 프로젝트는 memory가 비어 있어 불필요하다(이후 메모리가 title과 함께 쌓인다). 이미 메모리가 쌓인 프로젝트는 각 파일 `metadata.title`이 없을 수 있는데, `MEMORY.md` 인덱스의 표시명을 재사용해 일괄 삽입하는 1회성 스크립트로 백필한다:

```python
# 각 memory/*.md 의 metadata 블록 첫 줄에 title 삽입 (slug->표시명 매핑은 MEMORY.md 인덱스에서)
# 참고 구현: frontmatter 파싱 → metadata: 줄 뒤에 '  title: "<표시명>"' insert (이미 있으면 skip)
```

## 규약과의 연결
- CLAUDE.md 폐쇄형 학습 루프: 메모리 작성 시 frontmatter에 `title`(표시명) 포함 → harness가 `metadata.title`로 정규화.
- 이 파일은 그 규약의 시각화 셋업 상세다.
