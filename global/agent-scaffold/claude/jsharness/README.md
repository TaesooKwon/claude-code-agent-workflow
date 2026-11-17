# jsharness — 화면 JS 로직의 결정적 단위검증(브라우저·DB 없음)

`js/develop/**` 의 **상태·요청·DOM 조립 로직**을 실제 파일 그대로 `vm` 에서 태워 단언한다. 화면 JS 리뷰 수리(HIGH 급 결함이 JS 였던 회차)를
반증하려고 스크래치패드에 만든 하네스를 승격한 것. Playwright(시각·경합·실브라우저)와 층이 다르다 — 이건 **수 초에 도는 회귀 게이트**다.

```bash
node .claude/jsharness/run.js                      # specs/*.spec.js 전부
node .claude/jsharness/run.js .claude/jsharness/specs/<화면>.spec.js
```

- `lib/domstub.js` — 최소 DOM(마지막 복합 셀렉터만 해석, `closest` 는 null, 레이아웃 없음). 한계는 파일 머리 주석.
- `lib/harness.js` — `load(src, {globals, window, ctxRoot})`·`clickEvent`·`submitEvent`·`checker`·`sleep`. 팀 래퍼 `{{JS_NS}}.requestFetch` 는 `reqCalls` 에 쌓이고 `handler(응답)` 로 응답을 주입한다. 순수 `fetch` 는 `fetchCalls` + `resolveFetch(body)`.
- `specs/*.spec.js` — `module.exports = async (h, {repoRoot, check}) => {...}`. 스펙 하나 = 화면 하나.

**규약(프로젝트 CLAUDE.md 🧪)** — `js/develop/**` 로직 변경 시 스펙 1개를 두거나 갱신하고, 커밋 전에 **변이로 빨간불 1회** 확인한다
(변이는 실행되는 형태로 — 예: 조건 뒤집기·상수 변경. 러너는 단언 0건을 실패로 취급한다). 러너 출력의 `Tests run: N` 을 보고에 적는다.

git 격리(`.claude/`)라 커밋되지 않는다 — 이식 킷 스캐폴드(`claude/jsharness/`)에 lib·run.js 만 있고 스펙은 레포 고유.
