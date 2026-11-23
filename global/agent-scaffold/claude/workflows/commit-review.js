/**
 * commit-review — 커밋 전 A티어 자체 리뷰 (다각 finder → 적대적 verify)
 *
 * 호출 (⚠️이 빌드는 `.claude/workflows/` 를 이름으로 탐색하지 않는다 — `name:'commit-review'` 는 not found):
 *   Workflow({
 *     scriptPath: '<레포>/.claude/workflows/commit-review.js',
 *     args: {
 *       intent: '이번 변경 의도 1~3줄',
 *       stagedFiles: ['a/B.java', 'c/d_sql.xml'],   // ← `git diff --cached --name-only` 출력 줄 그대로(레포 상대경로)
 *     }
 *   })
 *   ⚠️stagedFiles 를 빼면 대조 모집단이 finder 자기보고뿐이라, finder 가 목록과 reviewedFiles 에서 같은 파일을
 *      함께 빠뜨린 경우를 못 잡는다 — 셸을 가진 호출자가 넣는다.
 *   ⚠️args 는 실측상 JSON 문자열로 도착하는 경우가 있어 스크립트가 파싱해 복구한다(아래 정규화 블록).
 *      복구가 돌면 log 에 경고가 찍히니, 찍혔는데 lenses 가 무시된 것 같으면 그 블록부터 의심하라.
 *
 * args (전부 선택, 문자열을 넘기면 intent 로 취급):
 *   intent  string  이번 변경의 의도(사용자 요청 원문 요약). **넣는 것을 강력히 권장** —
 *                   없으면 finder 가 "무엇이 의도된 동작인지" 몰라 스코프 밖 지적이 늘어난다.
 *   facts   string  실측으로 확정된 전제(선택). finder 는 첫 항목에서 이것을 **반증**한다.
 *   repo    string  레포 루트(기본 '.'). 서브에이전트 cwd 가 프로젝트 루트면 생략.
 *   lenses  string[] 사용할 관점 키 부분집합(기본 = LENSES 전부): behavior|markup|a11y|regression|attack
 *                   콤마/공백 문자열도 받는다(배열로 정규화). ⚠️**LENSES 의 key 밖 키는 인정되지 않는다** —
 *                   넘기면 무시되고 `lensStatus` 에 `unknown-lens` 로 남아 `reviewComplete` 가 false 가 된다
 *                   (2026-09-07 무음 소실 사고의 수리. 새 관점이 필요하면 LENSES 에 추가하거나 axes 로 지시하라).
 *   axes    string   이 레포의 판정축·규약 추가 지시(스택별로 다른 부분만).
 *   specRef string   설계서 경로(레포 상대) 또는 D목록 원문(선택). 있으면 behavior 관점 8번이 (a)요구 누락·부분 구현
 *                   (b)요청하지 않은 동작을 지적마다 설계서 줄 인용과 함께 본다. 없으면 8번은 "no spec" 으로 건너뛴다
 *                   (코드·intent 에서 요구를 역추론하지 않는다). lenses 에서 behavior 를 빼면 대조가 돌지 않는다(로그 경고).
 *   model   string   전 단계 모델 오버라이드. **미지정 = 메인 세션 모델 상속(권장 기본값)**.
 *   finderModel / verifyModel  string  단계별 오버라이드(있으면 model 보다 우선).
 *   effort  string   추론 강도('low'|'medium'|'high'|'xhigh'|'max'). 미지정 = 세션 상속.
 *   finderEffort / verifyEffort  string  단계별 오버라이드.
 *   mergeLineWindow  number  같은 파일에서 병합할 라인 근접 폭(기본 15). 0 이면 라인 근접 병합 끄기.
 *   mergeTitleSim    number  제목 토큰 overlap 계수 병합 임계(0~1, 기본 0.3). 1 초과면 제목 병합 끄기.
 *   verifyBatchMax   number  verify 에이전트 1개가 맡을 최대 지적 수(기본 6).
 *   stagedFiles      string[] `git diff --cached --name-only` 결과(호출 예시대로 넣는다). 줄바꿈 구분 문자열도 받는다
 *                   (콤마는 파일명에 쓸 수 있는 글자라 구분자로 보지 않는다).
 *                   finder 가 보고한 스테이징 목록과 합집합으로 `reviewedFiles` 누락 대조의 모집단이 된다
 *                   (호출자 목록이 finder 보고보다 좁아도 넓은 쪽으로 대조한다 — 덮어야 할 범위가 줄지 않는 방향).
 *
 *   ⚠️**모델을 낮추기 전에 읽어라 — 이 워크플로가 도는 시점은 이미 A티어로 판정된 변경뿐이다.**
 *   (표현만 바뀌는 B티어는 애초에 이 워크플로를 부르지 않고 인라인 셀프리뷰로 끝낸다.)
 *   약화의 위험이 양쪽 다 **결함 유출**로 이어진다는 점이 중요하다:
 *     - finder 약화 → 지적 자체가 안 나옴 → 결함이 그대로 커밋된다.
 *     - verify 약화 → 진짜 지적을 **거짓 기각** → 역시 결함이 그대로 커밋된다(verify 는 기본값이 기각이라
 *       약한 모델일수록 "애매하니 기각" 으로 쏠린다 = 안전한 방향으로 실패하지 않는다).
 *   ⇒ 그래서 **자동 하향은 넣지 않았다.** 낮추려면 호출자가 그 회차에 한해 명시적으로 넘긴다.
 *   낮춰도 되는 경우의 예: 판정이 애매해 A 로 올렸지만 실질은 문구·주석·설정값 한 줄인 diff,
 *   같은 diff 를 이미 메인 모델로 한 번 리뷰한 뒤의 **델타 재리뷰**, 관점 하나만 재실행하는 재시도.
 *   ⚠️낮췄으면 **로그와 반환값(modelPolicy)에 남고, 사용자에게도 말해야 한다**(침묵 강등 금지 —
 *   리스크 티어링의 'B 로 판정했으면 사용자에게 말한다' 와 같은 축).
 *
 * ⚠️**반환값 읽는 법 — `reviewComplete` 가 true 일 때만 게이트 통과로 읽어라.**
 *   반환 객체의 키는 파일 끝 return 블록이 정본이다(게이트 판정 = reviewComplete, 미완결 사유 = lensStatus·uncoveredFiles·unverified)
 *   (fixChecklist = CONFIRMED 수리 체크리스트 줄 — 병합된 지적은 대표 줄 아래에 병합 위치마다 들여쓴 줄이 붙는다.
 *    uncoveredFiles = status ok 인 어느 관점도 읽지 않은 스테이징 파일 — 비어 있지 않으면 reviewComplete=false 이고,
 *    그 파일을 읽는 관점으로 재실행한다. lensStatus[].unreviewedFiles = 그 관점이 안 읽은 파일(정보용, 게이트 아님)).
 *   `confirmed: []` 하나만 보고 "지적 0건"이라 판정하면 **리뷰가 아예 안 돈 경우와 구분되지 않는다.**
 *   2026-08-13 실사고: finder 4개가 전부 `null` 로 회수돼 `{confirmed:[],rejected:[]}` 가 나왔고,
 *   에이전트 트랜스크립트를 직접 파보고서야 실제로는 `{"findings":[]}` 였음을 확인했다.
 *   그때는 "지적 0건"이 맞았지만, **틀렸어도 똑같은 값이 나왔을 것**이다 = 게이트가 무검문으로 열린다.
 *
 * 설계 의도(바꾸기 전에 읽을 것):
 *   1) 모든 지적에 `changedLine` 을 **필수 필드**로 요구한다. "diff 밖은 보고 금지"를 산문으로
 *      아무리 써도 계속 새어 나오는데, 필수 필드로 만들면 스코프 밖 지적이 **구조적으로** 생성 불가가
 *      되고 그것을 반박하는 verify 비용까지 함께 사라진다.
 *   2) 각 finder 의 **첫 항목은 언제나 "전제 반증"**이다. 틀린 전제는 실행자와 검증자가 함께 밟기
 *      때문에 "이 diff 의 결함을 찾아라"만 시키면 구조적 사각이 된다.
 *   3) verify 는 **기본값이 기각**이다. 그러지 않으면 그럴듯하지만 틀린 지적이 살아남는다.
 *   4) verify 앞에 **전 관점 지적을 병합**하고 고유 지적당 판정 1회만 한다.
 *      (2026-08-27 재설계 — 8/13~8/27 리뷰 24회 실측에서 CONFIRMED ~195건 중 고유 ~109건,
 *      즉 verify 의 44% 가 같은 결함의 재검증이었다. 병합은 전 관점 결과가 필요하므로 finder 뒤
 *      배리어는 의도적 선택이다 — 전역 규약의 "비싼 후속 작업 전 dedup = 정당한 배리어" 축.)
 *      ⚠️2026-08-28 실측: 병합 키가 **`(file, 라인)` 정확일치**여서 **절감이 0 이었다.** 관점마다
 *      같은 결함을 다른 라인으로 인용한다(`:1291` vs `:1010 부근`) — 원시 8건에 verify 8개가 돌았고
 *      `mergedCount` 가 전부 1 이었다. ⇒ 키를 **라인 근접(±window) 또는 제목 유사도**로 완화했다.
 *   6) verify 는 **지적 단위가 아니라 파일 단위 배치**로 돈다(2026-08-28). 같은 파일의 지적 N 건을
 *      에이전트 하나가 **각각 독립 판정 블록**으로 처리한다 — 위 실측에서 지적 8건이 파일 2개에 몰려
 *      같은 파일을 8번 다시 읽었다(≈685k). 파일 읽기를 1회만 지불하는 것이 목적이다.
 *      ⚠️**배치의 대가 = 한 에이전트가 죽으면 그 파일의 지적이 통째로 증발한다**(지적 단위였을 때는
 *      1건 손실이었다). 그래서 미판정 id 를 회수해 재시도하고, 그래도 안 오면 `unverified` 로 남겨
 *      **`reviewComplete=false`** 로 게이트를 막는다. 미판정을 기각으로 접으면 설계의도 3)의
 *      "거짓 기각 = 결함 유출"을 스스로 만드는 셈이다.
 *      ⚠️판정끼리의 오염(한 건을 기각한 뒤 나머지도 기각하는 후광)은 프롬프트의 독립판정 지시와
 *      id 별 reason 필수로 막는다 — **다음 회차에서 CONFIRMED 수가 줄지 않는지로 검증할 것.**
 *   5) finder 스키마의 `reviewedFiles` 는 **"0건"을 정보량 있는 값으로 만들기 위한 필수 필드**다.
 *      빈 결과(null)와 "파일 4개를 읽고 지적 0건"이 값으로 구분돼야 게이트가 무검문으로 열리지 않는다.
 *      **이 필드와 아래 상태 판정 블록을 지우지 마라 — 지우면 2026-08-13 실사고가 그대로 재발한다.**
 *      완결 판정 = **status ok 인 관점들의 `reviewedFiles` 합집합 ⊇ 스테이징 목록**(args.stagedFiles ∪ 각 finder 가
 *      보고한 `stagedFiles`). 관점마다 프롬프트 범위가 달라(markup·a11y 가 .java 를 안 읽는 것은 결함이 아니다) 관점별 누락은
 *      `unreviewedFiles` 로 정보만 남기고, 합집합에서도 빠진 파일이 `uncoveredFiles` 로 남으면 `reviewComplete=false`.
 *      스테이징 파일을 하나도 읽지 않은 관점은 `empty-scan`, 스테이징 목록을 아무도 못 댔으면 판정 불가로 `reviewComplete=false`.
 *
 * 운영 규약(2026-09-17 규약 다이어트로 CLAUDE.md 에서 이관 — 이 워크플로를 부를 때의 계약):
 *   · **verify 는 지적을 병합해 고유당 1회 판정하고, 실행은 파일 단위 배치**다(위 4)·6)). 병합 키는
 *     `(file, 라인)` 정확일치가 아니라 **라인 근접·제목 유사**(서로 다른 관점 사이만). 배치는 에이전트 1개가
 *     죽으면 그 파일 지적 전부를 삼키므로 **미판정은 기각이 아니라 게이트 차단**(`unverified` → `reviewComplete=false`).
 *     **verify 모델 하향·델타 재리뷰 생략 금지**(델타 템플릿 = `.claude/workflows/delta-review.md`).
 *   · **검증은 병렬로 돌린다** — 렌더/E2E 와 이 리뷰는 둘 다 읽기 전용이라 동시에 돌려도 안전하다.
 *     같은 세션에서 이미 확인한 화면은 재검증하지 않는다.
 *   · **finder 스키마의 "그 지적이 걸리는 변경 라인"(`changedLine`)과 `reviewedFiles` 는 필수 필드로 유지한다** —
 *     스코프 밖 지적을 산문이 아니라 **구조로** 막는 장치다(위 설계의도 1)·5)).
 *   · **과잉설계 리뷰 관점을 이 워크플로의 상시 관점으로 추가하지 마라**(토큰) — 인정 키 = LENSES 의 key
 *     (모집단 = `grep -n "key: '" .claude/workflows/commit-review.js`), 과잉설계가 의심되는 커밋에서만 빌트인 `/simplify` 를 따로 쓴다.
 *   · 새 점검 축은 관점(=finder 에이전트)을 늘리지 말고 기존 관점의 항목으로 접는다. 2026-10-09 공식
 *     pr-review-toolkit 의 silent-failure-hunter·pr-test-analyzer 를 `regression` 8·9 로 이렇게 흡수했다.
 *     2026-11-04 공식 code-review·pr-review-toolkit·security-guidance 의 지침을 verify 반박 체크 2·6번, regression 8번, attack 1·2번에 같은 방식으로 흡수했다(새 관점 추가 없음).
 *     2026-11-12 포니테일 v5.3.3 review(마커 = 결정, 한계 초과 시만 지적)를 반박 체크 7번에 흡수했다(새 관점 추가 없음).
 *     2026-11-17 mattpocock/skills code-review 의 Spec 축(요구 누락·부분 / 요청 외 동작, 설계서 줄 인용, spec 없으면 건너뜀)을 behavior 8번 + 인자 specRef 로 흡수했다(새 관점 추가 없음).
 *     **예외 = `attack`(2026-10-10 사용자 승인, 상시 결함 사냥꾼)** — 결함만 찾는 공격자 시점은 기존 관점의
 *     항목으로 접으면 "의도대로 동작하나"를 보는 시점에 묻혀 희석되므로 별도 finder 로 둔다. 효과(그 관점만 잡은
 *     CONFIRMED 수·비용) 실측 근거 = ~/.claude/rules-rationale/defect-hunter-standing.md.
 */

export const meta = {
  name: 'commit-review',
  description: '스테이징된 diff 를 다각 관점으로 리뷰하고 각 지적을 적대적으로 검증한다(커밋 전 A티어 게이트)',
  whenToUse: '사용자가 커밋을 요청했고 판정축상 A티어(실행 의미가 바뀌는 변경)일 때. 표현만 바뀌는 B티어는 인라인 셀프리뷰로 충분하다.',
  phases: [
    { title: '리뷰', detail: '관점별 finder — 스코프=스테이징 diff' },
    { title: '검증', detail: '지적 병합(라인 근접·제목 유사) 후 파일 단위 배치로 적대적 verify (기본값=기각)' },
  ],
}

// args 정규화 — **이 복구 로직은 필수다(장식 아님).**
// 2026-08-10 실측: 동일한 호출 형식으로 두 번 돌렸는데 args 가 **두 번 다 JSON 문자열로 도착**했다.
// 복구 없던 1회차는 `lenses:["behavior"]` 가 통째로 무시돼 관점 4개가 전부 돌았고(에이전트 4개),
// 파싱 복구를 넣은 2회차는 의도대로 1개만 돌았다. 옛 폴백(`typeof args==='string' → {intent:args}`)은
// 그 실수를 **조용히 삼켜** JSON 원문을 intent 에 통째로 넣었다 — 침묵 실패라 더 나빴다.
// ⇒ 문자열로 와도 파싱해 복구하고, 복구했다는 사실을 log 로 남긴다.
let A = args || {}
if (typeof A === 'string') {
  const s = A.trim()
  if (s.charAt(0) === '{') {
    try {
      A = JSON.parse(s)
      log('⚠️ args 가 JSON 문자열로 전달됐다 — 파싱해 복구했다. 다음부터는 객체를 그대로 넘겨라(문자열 인코딩 금지).')
    } catch (e) {
      A = { intent: s }
      log('⚠️ args 가 JSON 처럼 보이는 문자열인데 파싱에 실패해 intent 로만 취급한다.')
    }
  } else {
    A = { intent: s }
  }
}
const REPO = A.repo || '.'
// 경로 정규화(normPath)가 벗길 레포 접두 — args.repo 가 절대경로일 때만 둔다.
const REPO_PREFIX = (function () {
  const r = String(REPO).trim().replace(/\\/g, '/').replace(/\/+$/, '')
  return r.charAt(0) === '/' && r.length > 1 ? r + '/' : null
})()
const INTENT = A.intent || '(호출자가 변경 의도를 넘기지 않았다. diff 자체에서 의도를 추론하되, 추론이 갈리는 지점은 지적하지 말고 openQuestion 성격으로만 다뤄라.)'
const FACTS = A.facts || '(호출자가 별도 전제를 제시하지 않았다. 그렇더라도 diff 가 암묵적으로 깔고 있는 전제를 스스로 찾아 반증하라.)'
const AXES = A.axes || ''
const SPEC_REF = A.specRef ? String(A.specRef).trim() : ''

// 병합·배치 파라미터. 기본값은 실측 표본이 없어 보수적으로 잡았다(과병합보다 과분할이 안전한 쪽이다).
// 라인 근접만으로는 2026-08-28 실측 케이스(같은 결함을 :1291 과 :1010 로 인용 = 281행 차)를 못 잡는다 —
// 실효 레버는 제목 유사도 쪽이고, 라인 근접은 "같은 블록을 다른 줄로 지목"하는 흔한 경우를 덮는다.
const MERGE_LINE_WINDOW = Number.isFinite(Number(A.mergeLineWindow)) ? Number(A.mergeLineWindow) : 15
const MERGE_TITLE_SIM = Number.isFinite(Number(A.mergeTitleSim)) ? Number(A.mergeTitleSim) : 0.3
const VERIFY_BATCH_MAX = Number(A.verifyBatchMax) > 0 ? Number(A.verifyBatchMax) : 6

// 모델·추론강도 — 미지정이면 옵션 자체를 넘기지 않아 메인 세션 모델/세션 effort 를 상속한다(현행 동작 유지).
// undefined 키를 넘겨도 무해하지만, "명시적으로 안 넘긴다"를 코드로 드러내려고 조건부로 조립한다.
const FINDER_MODEL = A.finderModel || A.model || null
const VERIFY_MODEL = A.verifyModel || A.model || null
const FINDER_EFFORT = A.finderEffort || A.effort || null
const VERIFY_EFFORT = A.verifyEffort || A.effort || null
function tune(base, model, effort) {
  const o = Object.assign({}, base)
  if (model) o.model = model
  if (effort) o.effort = effort
  return o
}
const MODEL_POLICY = {
  finder: { model: FINDER_MODEL || '(세션 상속)', effort: FINDER_EFFORT || '(세션 상속)' },
  verify: { model: VERIFY_MODEL || '(세션 상속)', effort: VERIFY_EFFORT || '(세션 상속)' },
}
// 침묵 강등 금지 — 낮췄으면 로그에 남긴다(반환값 modelPolicy 로도 회수된다).
if (FINDER_MODEL || VERIFY_MODEL || FINDER_EFFORT || VERIFY_EFFORT) {
  log(`⚠️ 모델·추론강도 오버라이드: finder=${MODEL_POLICY.finder.model}/${MODEL_POLICY.finder.effort} · verify=${MODEL_POLICY.verify.model}/${MODEL_POLICY.verify.effort} — 이 사실을 사용자에게 보고하라.`)
}

const CONTEXT = `
[리뷰 대상] \`cd ${REPO} && git diff --cached\` 로 나오는 **스테이징된 diff 만**.
  ⚠️ 스테이징되지 않은 dirty 파일은 리뷰 대상이 아니다. 언급도 하지 마라.
  ⚠️ 프로젝트 규약(CLAUDE.md)은 네 컨텍스트에 이미 로드돼 있다. 그 규약 위반은 결함으로 취급하라.

[이번 변경의 의도]
${INTENT}

[실측으로 확정된 전제 — 근거로 삼되, **첫 항목에서 이것 자체를 반증하는 것이 네 임무다**]
${FACTS}
${AXES ? '\n[이 레포의 판정축·추가 규약]\n' + AXES : ''}${SPEC_REF ? '\n[설계서(specRef) — behavior 8 대조 기준]\n' + SPEC_REF + '\n' : ''}
[읽기 전용] 편집·커밋·앱 기동·스테이징 변경 금지. 조사만 한다.
`

const LENSES = [
  {
    key: 'behavior',
    title: '기능 정확성·상태 동기화',
    prompt: `1. 이 변경이 **의도한 동작을 실제로 하는가**? 코드 경로를 끝까지 따라가라. 요청된 기능이 특정 조건에서만 동작한다면 그 조건을 명시하라.
2. **상태가 바뀔 수 있는 경로를 전수로 열거**한 뒤(사용자 입력 / 프로그램적 대입 / 비동기 응답 / 초기 렌더 / 복원·되돌리기), 경로마다 갱신 로직이 실제로 도달하는지 확인하라. **누락된 경로가 결함이다.**
3. 같은 판정을 **두 곳 이상에서 각자 계산**하고 있지 않은가? 술어가 갈리면 한쪽이 거짓말을 한다(예: UI 가드는 통과인데 검증은 거부). 동치성을 구체 입력으로 따져라.
4. 동일 역할의 요소가 여러 개면(데스크톱/모바일, 목록/상세) **전부** 처리됐는가? 파일 수가 아니라 **요소 수**로 세라.
5. 선언·초기화 **순서**: 참조 시점에 대상이 이미 할당돼 있는가? 호이스팅으로 undefined 를 참조하는 경로가 있는가?
6. 비동기가 있다면 **재진입(in-flight) 가드**가 있는가? 성공·실패 **양쪽**에서 해제되는가(한쪽만 풀면 영구 잠금)?
7. 기존 기능 회귀: 이 변경이 건드린 공유 지점을 쓰는 다른 경로가 깨지지 않는가?
8. **설계서 대조(Spec)**: ${SPEC_REF
    ? `설계서 = ${SPEC_REF} (경로면 읽고, 목록 원문이면 그대로 쓴다). (a) 설계서가 요구했는데 이번 diff 에서 **누락·부분 구현**된 요구 (b) 설계서가 요구하지 않은 동작을 이번 diff 가 **더한** 것. 지적마다 failureScenario 첫머리에 **설계서 줄을 인용**하라(\`경로:줄 "원문"\` 또는 D목록 항목 원문) — 인용할 줄이 없으면 지적이 아니다. changedLine = (a)는 그 요구가 들어갔어야 할 이번 diff 의 라인(그 기능의 진입·분기), (b)는 그 추가 동작 라인. 이번 diff 가 그 기능을 전혀 건드리지 않았으면 이 커밋의 범위 밖이라 보고하지 않는다.`
    : 'no spec — 호출자가 specRef 를 넘기지 않았다. 이 항목은 건너뛴다. 코드·intent 에서 요구사항을 역추론해 누락·범위 밖 지적을 만들지 마라.'}`,
  },
  {
    key: 'markup',
    title: '마크업·템플릿·프레임워크 규약',
    prompt: `1. 템플릿 엔진 파싱: 속성값·인라인 스크립트의 이스케이프가 올바른가? **이중 이스케이프나 미이스케이프가 있으면 그 자리가 런타임에 깨진다** — diff 원문 바이트로 확인하라(렌더된 표현을 믿지 마라).
2. 텍스트 바인딩이 **자식 요소를 덮어쓰는** 자리에 자식 노드를 넣지 않았는가?
3. 새로 쓴 클래스·컴포넌트가 **실제 스타일시트에 존재**하는가? 오타·존재하지 않는 클래스가 있으면 결함이다. 반대로, 붙인 상태(비활성·선택 등)에 **대응 규칙이 아예 없는** 클래스는 아닌가(있을 거라 가정하지 말고 grep 으로 실재를 확인하라).
4. 디자인 가이드·기존 실사용 예와 **구조 순서**가 맞는가?
5. 프로젝트 규약 위반: 새 스타일시트 파일 생성, 공통 자산 직접 수정, 임의 마크업, 금지된 API 사용.
6. HTML 유효성: 중복 id, 닫히지 않은 태그, 잘못된 중첩, 폼 안에서 기본 type 인 버튼(암묵 submit).`,
  },
  {
    key: 'a11y',
    title: '접근성',
    prompt: `1. \`aria-*\` 가 가리키는 id 가 **같은 문서에 정확히 하나** 존재하는가? 조건부 렌더 때문에 한쪽만 렌더돼 **깨진 IDREF** 가 되는 경우가 있는가? 참조하는 쪽과 참조되는 쪽의 렌더 조건을 대조하라.
2. 숨김 처리된 조상 아래에 보조기술용 텍스트를 두지 않았는가? **\`display:none\` 조상 아래면 스크린리더도 못 읽는다.** 반응형에서 숨겨지는 컨테이너를 특히 확인하라.
3. 비활성·숨김이 **키보드 사용자의 도달 경로를 통째로 끊는** 순간이 있는가? 그 상태가 시각적으로도 구분되는가(구분되지 않으면 "눌리지 않는 버튼"이 된다)?
4. 요소를 옮기거나 교체하면서 **접근가능 이름을 잃지 않았는가**? 탭 순서가 시각 순서와 어긋나지 않는가?
5. 값 변경만으로 컨텍스트가 바뀌는 컨트롤(자동 제출·자동 이동)을 **새로** 만들었다면 사전 고지가 있는가(WCAG 3.2.2 On Input / 기법 G13)?
6. 라이브 리전을 썼다면 **같은 값 재대입으로 이중 낭독**이 나지 않는가? 안 썼다면 그 결정이 실제 정보 손실을 만드는가(단순히 "쓰는 게 좋다"는 취향 의견은 지적이 아니다).`,
  },
  {
    key: 'regression',
    title: '회귀·부작용·엣지케이스',
    prompt: `1. **경계값**: 대상이 0개·null·빈 목록·로드 실패인 경우 동작은? \`total > 0 && x === total\` 류 판정이 0 에서 어떻게 되는가?
2. **영구 고착 위험**: 어떤 오류 경로(예외·조기 return)로 갱신이 다시 안 불려 상태가 잠긴 채 남는 시나리오가 있는가?
3. **권한·비로그인·미생성** 등 조기 반환 경로에서 이 변경이 참조하는 모델 속성이 없어 렌더가 깨지지 않는가?
4. URL·경로 생성이 **컨텍스트 패스·프리픽스**를 올바르게 포함하는가?
5. 조건부 렌더가 **상호배타적**인가? 안내·표식이 해당되지 않는 행에까지 새어 나가지 않는가(거짓 안내)?
6. 변경된/남겨진 **주석이 새 동작과 모순**되지 않는가? 세 축을 따로 보라:
   ⓐ이 diff 가 **더한 것**(새 호출처·적재처·분기·상태값)을 옛 문장이 부정하지 않는가 — 삭제는 컴파일이 돕지만 **추가는 아무도 안 돕는다**(옛 문장은 문법적으로 멀쩡한 채 거짓이 된다). 작성자가 **이번에 손댄 주석**일수록 의심하라(자기가 만든 변화라 다시 안 읽는다).
   ⓑ주석이 **코드 밖 사실**(실행 순서·호출처 수·다른 파일이나 라이브러리의 동작)을 단언하는데 근거가 없지 않은가 — 그 자리에서 셀 수 있는 것은 세어 대조하라.
   ⓒ배타·계수 단언("X만"·"유일한"·"셋이다"·"여기 하나뿐")이 실측과 맞는가.
   ⓓ**복제된 주석**: 같은 함수·블록이 여러 파일에 복제됐다면, 주석이 **원본 파일에서만 참인 사실**을 그대로 옮겨 오지 않았는가(예: "이 화면의 검색 셀렉트" 가 복제된 화면에는 없다). 본문은 같아도 "왜 이 자리에 필요한가"는 자리마다 다르다 — **주석 속 명사(화면명·클래스명·필드명)를 그 파일에서 grep 해 실재를 확인하라**.
   ⓔ같은 diff 의 **테스트가 그 주석을 반증**하고 있지 않은가 — 이 레포에서 두 번 났다(주석은 "X 가 된다"인데 테스트는 "X 가 안 된다"를 단언).
7. 이 변경이 **공유 자산·다른 화면**에 영향을 주는가(공통 fragment, 전역 셀렉터·id 충돌)?
8. **삼켜지는 실패**: 이 diff 가 더한 오류 처리 자리(catch·실패 콜백·실패 sentinel 분기·기본값 대체·옵셔널 체이닝·널 병합)마다 물어라 — 실패가 **사용자 피드백도 로그도 없이** 사라지는가? catch 가 **의도한 예외보다 넓어** 무관한 오류까지 덮는가(덮일 수 있는 예외를 구체로 들어라)? 실패 시 기본값·대체 동작이 **오류를 정상처럼 보이게** 하는가(빈 목록 = "0건" 오인 등)? 트랜잭션 안에서 잡고 넘겨 **롤백이 안 되는** 경로가 있는가? "로그만 찍고 계속"이 이 자리에 맞는지 근거를 대라. 운영 경로에 목·스텁·하드코딩 대체값이 남아 실패를 성공처럼 꾸미는가? 재시도가 모두 실패해도 사용자·로그에 알리지 않고 끝나는가?
9. **테스트 공백**: 이 diff 가 더한 분기·계산·검증(특히 거부·실패 쪽)에 대해 같은 diff 의 테스트가 **그 분기를 실제로 실행**하는가? 데이터 손실·권한·정합성에 걸리는 분기가 미검증이면 지적하라 — changedLine 은 **검증되지 않은 그 분기 라인**이다. 구현 세부에만 묶여 동작이 깨져도 통과할 단언도 같은 축이다. 커버리지 숫자 취향(모든 줄 테스트)은 지적이 아니다.`,
  },
  {
    key: 'attack',
    title: '공격자 관점 결함 사냥(인가·입력·세션·경합·손실)',
    prompt: `너는 이 diff 를 **깨뜨리려는 공격자이자 운 나쁜 사용자**다. 잘 된 점은 보지 마라 — 결함만 찾는다.
**failureScenario 는 반드시 "누가(역할·로그인 여부) → 어떤 요청·조작(메서드·URL·파라미터 값·순서) → 어떤 잘못된 결과(누구의 데이터가 어떻게)" 형식**이어야 한다. 공격 경로를 구체로 못 쓰는 "강화하면 좋다" 류 일반 권고는 지적이 아니다.
1. **인가**: 이 diff 가 더하거나 바꾼 엔드포인트·서비스 메서드마다 **서버가** 호출자의 역할·소유·스코프를 확인하는가? 버튼·메뉴를 화면에서 숨기기만 하고 서버는 받는 경우가 결함이다. 식별번호를 남의 것으로 바꿔 보내면(IDOR) · 스코프(조직·기관·사이트 등 데이터 범위) 밖 대상을 넣으면 · 비슷하지만 다른 역할(상·하위 관리자 유형)로 부르면 어떻게 되는가? '이미 검증됨'·'안전함'을 주장하는 주석을 믿지 말고 실제 검사 코드를 찾아라. 같은 파일·컨트롤러의 **형제 핸들러**가 하는 인가·스코프 검사를 이 핸들러도 하는지 대조하라. 리소스 ID 를 받는 diff 내 엔드포인트는 전부 확인하라(첫 결함을 찾은 뒤에도 계속 탐색).
2. **트러스트 경계 입력**: 클라이언트가 보낸 값(hidden 필드·식별번호·유형/상태 코드·정렬키·개수·URL·리다이렉트 대상)을 서버가 **허용목록 검증 없이** 믿는가? 서버가 정해야 할 필드(소유자·감사 컬럼·상태·사이트)를 요청 본문이 덮어쓸 수 있는가(mass assignment)? 열린 리다이렉트·경로 조작이 가능한가? X-Forwarded-For·X-Real-IP 등 **클라이언트가 위조 가능한 헤더**로 권한·IP 판정을 하는가? 허용목록 대조가 부분문자열·앵커 없는 정규식·startsWith 로 우회되는가?
3. **인증·세션·토큰**: 로그인·권한 상승 직후 세션 ID 를 재발급하는가(세션 고정)? 일회성 토큰이면 **만료·1회 소비·발급 대상 귀속**이 서버에서 원자적으로 강제되는가(재사용·탈취·다른 계정에 사용)? 상태를 바꾸는 요청이 GET 이거나 CSRF 예외 경로에 있는가? 로그아웃·권한 회수 뒤에도 남는 신원·캐시가 있는가?
4. **경합**: 같은 요청을 **동시에 2번**(더블클릭·재전송·두 탭) 또는 **두 사용자가 동시에** 보내면? check-then-act 사이 끼어들기 · 0행 UPDATE 를 성공으로 처리 · 채번·정원·1회 소비 중복을 구체 순서로 따져라.
5. **데이터 손실·무결성**: 물리 삭제 · 다른 사람 변경을 덮어쓰는 저장(lost update) · 중간에 실패하면 반쯤 반영된 상태로 남는 경로 · 트랜잭션 경계 밖 부수효과(외부 호출·파일)가 있는가?
6. **정보 노출**: 응답·오류 메시지·로그에 개인정보·시크릿·내부 식별자·스택이 실리는가? 오류 문구 차이로 계정·리소스 존재를 열거할 수 있는가?
7. **운영 가드**: 로컬·개발 전용이어야 할 경로가 운영에서 켜질 수 있는가(토글 기본값·프로파일 누락·루프백 검사 부재)? 감사 기록이 필요한 특권 행위가 기록 없이 지나가는가(정책상 의도된 제외면 지적 아님 — diff 의 주석·intent·facts 로 확인)?`,
  },
]

const FIND_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['stagedFiles', 'reviewedFiles', 'findings'],
  properties: {
    stagedFiles: {
      type: 'array',
      items: { type: 'string' },
      description: '**필수** — `git diff --cached --name-only` 출력 줄 전부를 그대로(레포 상대경로). 읽었는지와 무관하게 스테이징 목록 자체다. reviewedFiles 누락 대조의 기준이 된다.',
    },
    reviewedFiles: {
      type: 'array',
      items: { type: 'string' },
      description: '**필수** — `git diff --cached --name-only` 로 확인해 네가 실제로 읽은 스테이징 파일의 레포 상대경로 전부. 추측으로 채우지 마라. 삭제 파일은 그 경로의 삭제 hunk 를, 이름만 바뀐 파일은 rename 헤더를 읽었으면 읽은 것이다(경로 표기는 --name-only 출력 그대로). 이 배열에 스테이징 파일이 하나도 없으면 리뷰가 성립하지 않은 것으로 처리된다(지적 0건과 구분하기 위한 필드).',
    },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'file', 'changedLine', 'severity', 'failureScenario', 'fix'],
        properties: {
          title: { type: 'string' },
          file: { type: 'string', description: '레포 상대경로' },
          changedLine: {
            type: 'string',
            description: '**필수** — 이 지적이 걸리는 이번 스테이징 diff 의 라인(파일:라인 + 그 라인의 실제 코드). 이번 diff 밖 기존 성질이면 보고 자체가 금지된다. 채울 수 없으면 그 지적은 버려라.',
          },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          failureScenario: { type: 'string', description: '구체 입력·조작 → 잘못된 결과. "~할 수도 있다" 류 추상적 우려는 금지' },
          fix: { type: 'string', description: '최소 수정안(프로젝트 규약이 허용하는 경로로)' },
        },
      },
    },
  },
}

// verify 는 파일 단위 배치라 **묶음 id 별로 하나씩** 판정을 돌려받는다.
// id 를 필수로 둔 이유 = 반환이 뒤섞이거나 일부가 빠졌을 때 "어느 지적이 미판정인지"를 값으로 알기 위함이다.
// (빠진 것을 기각으로 접으면 진짜 지적이 조용히 사라진다 — 헤더 설계의도 6) 참조.)
const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdicts'],
  properties: {
    verdicts: {
      type: 'array',
      description: '**입력으로 준 묶음 id 전부**에 대해 각각 하나씩. 하나도 빠뜨리지 마라.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'isReal', 'reason'],
        properties: {
          id: { type: 'string', description: '입력 묶음의 id 를 그대로 반복하라(임의 생성 금지).' },
          isReal: { type: 'boolean' },
          reason: { type: 'string' },
        },
      },
    },
  },
}

// lenses 정규화 — 문자열로 와도 배열로 복구한다(args 자체가 JSON 문자열로 도착하는 사례가 위에 실측돼 있다).
// ⚠️정규화 없이 문자열에 `indexOf` 를 쓰면 **부분문자열 일치**로 우연히 걸린다(키가 다른 토큰에 포함된 경우).
function normalizeLenses(v) {
  if (!v) return []
  const arr = Array.isArray(v) ? v : String(v).split(/[\s,]+/)
  return arr.map((x) => String(x).trim()).filter((x) => x.length)
}
const KNOWN_LENS_KEYS = LENSES.map((l) => l.key)
const requestedLenses = normalizeLenses(A.lenses)
// ⚠️**인정되지 않는 관점 키가 조용히 사라지면 안 된다.** 2026-09-07 실사고: `security`·`concurrency` 를
// 함께 넘겼는데 화이트리스트 밖이라 이 filter 에서 통째로 소실됐고, 아래 droppedLenses 차집합은
// `picked` 기준이라 **애초에 picked 에 못 들어온 키를 원리적으로 못 잡는다** → 게이트 3조건(reviewComplete·
// lensStatus·unverified)이 전부 초록인 채로 요청한 관점의 절반만 돌았다. 그래서 여기서 걸러 남긴다.
const unknownLenses = requestedLenses.filter((k) => KNOWN_LENS_KEYS.indexOf(k) === -1)
const picked = requestedLenses.length
  ? LENSES.filter((l) => requestedLenses.indexOf(l.key) !== -1)
  : LENSES

if (unknownLenses.length) {
  log(`🔴 인정되지 않는 관점 키 ${unknownLenses.length}개를 무시했다: ${unknownLenses.join(', ')} — 인정 키는 ${KNOWN_LENS_KEYS.join('|')} 뿐이다. lensStatus 에 unknown-lens 로 남기므로 reviewComplete 는 false 가 된다.`)
}
if (!picked.length) {
  log('🔴 요청한 관점이 하나도 인정되지 않아 돌릴 관점이 0개다 — 지적 0건은 "결함 없음"이 아니라 미실행이다.')
}
if (SPEC_REF && !picked.some((l) => l.key === 'behavior')) {
  log('⚠️ specRef 를 넘겼지만 behavior 관점이 빠져 설계서 대조(behavior 8번)가 돌지 않는다 — 대조가 필요하면 lenses 에 behavior 를 넣어라.')
}
log(`리뷰 관점 ${picked.length}개: ${picked.map((l) => l.key).join(', ')}`)

/**
 * 관점별 finder 1회 실행. 반환이 null 이면(에이전트 사망·스킵·스키마 회수 실패) 호출부가 재시도한다.
 */
function runFinder(l, attempt) {
  return agent(`${CONTEXT}
[관점] ${l.title}

0. **첫 항목: 전제 반증.** 위 [실측으로 확정된 전제]와 이 diff 가 암묵적으로 깔고 있는 가정이 실제 코드·설정·공통 자산과 맞는지 먼저 확인하라. 틀린 게 있으면 그것이 최우선 지적이다.
${l.prompt}

[절차] 먼저 \`cd ${REPO} && git diff --cached\` 로 실제 diff 전문을 읽어라. 필요하면 파일 전문·스타일시트·공통 자산·\`git show HEAD:<파일>\`(변경 전 대조)도 확인하라.
[규율] 지적이 없으면 findings 를 빈 배열로 반환하라. **억지로 만들지 마라.** 취향·스타일 제안은 지적이 아니다.
[필수] \`reviewedFiles\` 에 네가 실제로 읽은 스테이징 파일 경로를 **빠짐없이** 채워라. 지적이 0건이어도 이 배열은 비워선 안 된다 — 호출자는 이 값으로 "리뷰가 돌았는데 깨끗한 것"과 "리뷰가 못 돈 것"을 구분한다.
[필수] \`stagedFiles\` 에 \`cd ${REPO} && git diff --cached --name-only\` 출력을 그대로 넣어라. diff 를 읽은 스테이징 파일은 이 관점의 판정 대상이 아니어도 reviewedFiles 에 넣어라(관점별 누락은 정보로 남는다) — 어느 관점도 읽지 않은 스테이징 파일이 남으면 리뷰 전체가 미완결로 처리된다.`,
    tune({ label: attempt > 1 ? `review:${l.key}(재시도)` : `review:${l.key}`, phase: '리뷰', schema: FIND_SCHEMA }, FINDER_MODEL, FINDER_EFFORT))
}

// ── 1단계: finder 전 관점 병렬 실행 ─────────────────────────────────────────
const found = await parallel(picked.map((l) => async () => {
  let r = await runFinder(l, 1)
  if (!r) {
    log(`⚠️ ${l.key} finder 가 결과를 반환하지 못했다(null) — 1회 재시도한다.`)
    r = await runFinder(l, 2)
  }
  return { l: l, r: r }
}))

// 상태 판정 — "지적 0건"과 "리뷰 미수행"을 값으로 가른다. (2026-08-13 실사고 대응, 지우지 말 것)
const lensResults = []
found.filter(Boolean).forEach((it) => {
  const l = it.l
  const r = it.r
  if (!r || !Array.isArray(r.reviewedFiles)) {
    log(`🔴 ${l.key} 관점: 결과 회수 실패(재시도 후에도 null). 이 관점은 검증되지 않았다.`)
    lensResults.push({ key: l.key, status: 'failed', reviewedFiles: [], findings: [] })
    return
  }
  // finder 자기보고는 신뢰 밖 입력이라 표기를 정규화한 뒤 판정한다(공백뿐인 원소만 온 경우도 0개로 친다).
  const reviewed = normPathList(r.reviewedFiles)
  // 지적 원소도 신뢰 밖 입력 — 객체만 병합으로 넘기고(null 이면 병합의 String(x.file) 에서 예외), 버린 수는 로그로 남긴다.
  const lensFindings = Array.isArray(r.findings) ? r.findings.filter((x) => x && typeof x === 'object') : []
  const droppedFindings = Array.isArray(r.findings) ? r.findings.length - lensFindings.length : 0
  if (droppedFindings > 0) log(`🟡 ${l.key} 관점: 객체가 아닌 지적 원소 ${droppedFindings}개를 제외했다.`)
  if (!reviewed.length) {
    log(`🔴 ${l.key} 관점: 읽은 스테이징 파일 0개 — 공허 통과로 간주한다.`)
    lensResults.push({ key: l.key, status: 'empty-scan', reviewedFiles: [], findings: lensFindings })
    return
  }
  lensResults.push({ key: l.key, status: 'ok', reviewedFiles: reviewed, stagedFiles: normPathList(r.stagedFiles), findings: lensFindings })
})

// 스테이징 목록 대조 — reviewedFiles 가 비어 있지 않다는 것만으로는 "전부 읽었다"가 아니다.
// 모집단 = args.stagedFiles ∪ 정상 반환 finder 들이 보고한 stagedFiles. 정규화 = 앞뒤 공백·역슬래시·./ 접두·
// 절대경로 args.repo 접두(그 레포 안 경로를 상대경로로). 그 밖의 표기 차는 맞추지 않는다 → 덮이지 않은 쪽으로 남아 차단된다.
// 목록이 비면 대조 자체가 불가능하므로 통과가 아니라 미완결로 친다(판정 불가 = 차단).
// # ponytail: 워크플로 런타임엔 셸이 없어 모집단이 호출자·finder 보고에 기댄다 / 런타임이 git 조회를 열면 그 값으로 교체
// (REPO_PREFIX 는 위 상태 판정 블록이 이 함수를 먼저 부르므로 REPO 선언부 옆에 둔다 — const 는 선언 전 참조가 TDZ 오류다.)
function normPath(p) {
  let s = String(p == null ? '' : p).trim().replace(/\\/g, '/')
  if (REPO_PREFIX && s.indexOf(REPO_PREFIX) === 0) s = s.slice(REPO_PREFIX.length)
  return s.replace(/^(\.\/)+/, '')
}
function normPathList(v) {
  if (!v) return []
  const arr = Array.isArray(v) ? v : String(v).split(/[\r\n]+/)
  return arr.map(normPath).filter((x) => x.length)
}
const stagedSet = Object.create(null)
normPathList(A.stagedFiles).forEach((p) => { stagedSet[p] = 1 })
lensResults.forEach((r) => { (r.stagedFiles || []).forEach((p) => { stagedSet[p] = 1 }) })
const stagedFiles = Object.keys(stagedSet).sort()
const stagedUnknown = stagedFiles.length === 0
if (stagedUnknown) {
  log('🔴 스테이징 목록을 확보하지 못했다(args.stagedFiles 없음 · finder 보고 없음) — reviewedFiles 누락을 대조할 수 없어 리뷰를 미완결로 처리한다.')
}
// 완결 판정 = status ok 인 관점들의 reviewedFiles 합집합 ⊇ stagedFiles.
//   관점별 누락(unreviewedFiles)은 정보로만 남긴다 — 관점 프롬프트가 원래 일부 파일 종류를 안 보므로(markup·a11y ↔ .java)
//   관점 단위로 막으면 혼합 커밋이 늘 미완결이 되고, 재실행으로도 안 풀려 --skip-reason 쪽으로 게이트가 약해진다.
//   단, 스테이징 파일을 하나도 읽지 않은 관점은 그 관점의 리뷰가 성립하지 않은 것이라 empty-scan 으로 친다.
//   삭제·rename 경로도 다른 경로와 똑같이 어느 ok 관점의 reviewedFiles 에 있어야 덮인 것으로 친다(자동 커버 없음 —
//   이 런타임은 셸이 없어 삭제 여부를 스스로 못 가리고, finder 는 삭제 hunk·rename 헤더를 읽고 그 경로를 보고할 수 있다).
const coveredSet = Object.create(null)
lensResults.forEach((r) => {
  r.unreviewedFiles = []
  if (r.status !== 'ok') return
  const seen = Object.create(null)
  r.reviewedFiles.forEach((p) => { seen[p] = 1 })
  r.unreviewedFiles = stagedFiles.filter((p) => !seen[p])
  if (stagedFiles.length && r.unreviewedFiles.length === stagedFiles.length) {
    r.status = 'empty-scan'
    log(`🔴 ${r.key} 관점: reviewedFiles 에 스테이징 파일이 하나도 없다 — 공허 통과로 간주한다.`)
    return
  }
  stagedFiles.forEach((p) => { if (seen[p]) coveredSet[p] = 1 })
  if (r.unreviewedFiles.length) {
    log(`ℹ️ ${r.key} 관점: 이 관점이 읽지 않은 스테이징 파일 ${r.unreviewedFiles.length}개(다른 관점이 덮으면 게이트 무관) — ${r.unreviewedFiles.join(', ')}`)
  }
})
const uncoveredFiles = stagedFiles.filter((p) => !coveredSet[p])
if (uncoveredFiles.length) {
  log(`🔴 어느 관점도 읽지 않은 스테이징 파일 ${uncoveredFiles.length}개 — ${uncoveredFiles.join(', ')} · 그 파일을 읽는 관점으로 재실행하라.`)
}

// ── 2단계: 지적 병합 — 같은 결함을 관점 수만큼 판정하지 않는다 ────────────────
// 병합 조건(같은 파일 안에서만): ①라인 근접(±MERGE_LINE_WINDOW) ②제목 토큰 자카드 ≥ MERGE_TITLE_SIM
//   ③둘 다 라인을 못 뽑았고 changedLine 원문이 같음.
// ⚠️정확일치 키(구버전)는 2026-08-28 실측에서 절감 0 이었다 — 관점마다 인용 라인이 달랐기 때문이다.
// "서로 다른 결함 2개"가 합쳐질 위험은 지적 전문을 verify 프롬프트에 전부 싣고
// "하나라도 실재하면 isReal=true" 로 두어 방어한다(진짜 지적이 병합 때문에 사라지지 않는 쪽으로 실패시킨다).
function lineOf(x) {
  const s = String(x.changedLine || '')
  const m = /:(\d{1,6})\b/.exec(s) || /\b(\d{1,6})\b/.exec(s)
  return m ? parseInt(m[1], 10) : null
}
function titleTokens(x) {
  return String(x.title || '')
    .toLowerCase()
    .replace(/[^0-9a-z가-힣]+/g, ' ')
    .split(' ')
    .filter((t) => t.length >= 2)
}
// 자카드가 아니라 **overlap coefficient**(교집합 / 짧은 쪽 크기)다.
// 제목은 3~5토큰으로 짧아서 자카드로는 핵심 명사를 공유해도 값이 0.2 아래로 떨어진다
// (실측 케이스 "대상학년 토글 미동기화" vs "대상학년 체크박스 상태 어긋남" = 자카드 0.17, overlap 0.33).
function overlap(a, b) {
  if (!a.length || !b.length) return 0
  const sa = {}
  a.forEach((t) => { sa[t] = 1 })
  const seen = Object.create(null)
  let inter = 0
  b.forEach((t) => {
    if (sa[t] && !seen[t]) { inter++; seen[t] = 1 }
  })
  const uniqA = Object.keys(sa).length
  const uniqB = b.filter((t, i) => b.indexOf(t) === i).length
  return inter / Math.min(uniqA, uniqB)
}
function sameDefect(a, b) {
  const la = lineOf(a)
  const lb = lineOf(b)
  if (MERGE_LINE_WINDOW > 0 && la !== null && lb !== null && Math.abs(la - lb) <= MERGE_LINE_WINDOW) return true
  if (MERGE_TITLE_SIM <= 1 && overlap(titleTokens(a), titleTokens(b)) >= MERGE_TITLE_SIM) return true
  if (la === null && lb === null) {
    return String(a.changedLine || '').trim() === String(b.changedLine || '').trim()
  }
  return false
}
const byFileGroups = new Map()
// 회수된 지적은 관점 status 와 무관하게 병합·verify 대상에 넣는다 — 게이트를 막는 관점(empty-scan 등)의 지적이라도
// 버리면 결함이 조용히 사라진다(게이트 차단은 아래 reviewComplete 가 따로 한다). 회수 실패 관점은 findings 가 빈 배열이다.
lensResults.forEach((r) => {
  r.findings.forEach((x) => {
    const file = String(x.file)
    if (!byFileGroups.has(file)) byFileGroups.set(file, [])
    const bucket = byFileGroups.get(file)
    // ⚠️병합은 **서로 다른 관점 사이에서만** 한다. 병합의 목적이 "관점 간 중복 제거"이고,
    // 같은 관점이 같은 파일에 2건을 냈다면 그 에이전트는 둘을 다른 결함으로 본 것이다
    // (구버전은 정확일치라 이 구분이 없었다 — 키를 느슨하게 푸는 만큼 이 축으로 과병합을 막는다).
    let hit = null
    for (let i = 0; i < bucket.length && !hit; i++) {
      if (bucket[i].lenses.indexOf(r.key) !== -1) continue
      if (bucket[i].findings.some((y) => sameDefect(x, y))) hit = bucket[i]
    }
    if (!hit) {
      hit = { file: file, lenses: [], findings: [] }
      bucket.push(hit)
    }
    if (hit.lenses.indexOf(r.key) === -1) hit.lenses.push(r.key)
    hit.findings.push(x)
  })
})
const rawCount = lensResults.reduce((n, r) => n + r.findings.length, 0)
const uniq = []
byFileGroups.forEach((bucket) => bucket.forEach((g) => {
  g.id = 'G' + (uniq.length + 1)
  uniq.push(g)
}))
log(`지적 ${rawCount}건 → 고유 ${uniq.length}건 (중복 ${rawCount - uniq.length}건 병합 — 판정은 고유 지적당 1회)`)

// ⓒ 병합 0건 경고 — "병합 기능은 있는데 아무것도 안 줄었다"가 조용히 지나가지 않게 한다.
// 2026-08-28 실측이 정확히 이 상태였고, 로그만 찍혀서 결과만 본 호출자는 병합이 동작한 줄 알았다.
const mergeWarning = (picked.length >= 2 && rawCount >= 2 && uniq.length === rawCount)
  ? `⚠️ 관점 ${picked.length}개가 지적 ${rawCount}건을 냈는데 병합이 0건이다. 관점들이 같은 결함을 서로 다른 라인·문구로 지목했을 수 있다(2026-08-28 실측 재발 패턴). CONFIRMED 목록에서 실질 중복을 직접 확인하고, 반복되면 mergeTitleSim 을 낮춰라.`
  : null
if (mergeWarning) log(mergeWarning)

// ── 3단계: 파일 단위 배치로 적대적 verify ──────────────────────────────────
// 지적 단위로 돌리면 같은 파일을 지적 수만큼 다시 읽는다(2026-08-28 실측: 파일 2개를 8번 = ≈685k).
// 파일당 1에이전트가 그 파일의 지적을 **각각 독립 판정 블록**으로 처리해 파일 읽기를 1회만 지불한다.
// 파일 하나에 지적이 몰리면 한 컨텍스트가 과부하되고 판정끼리 오염되기 쉬우므로 VERIFY_BATCH_MAX 로 쪼갠다.
const batches = []
const filesWithFindings = []
byFileGroups.forEach((bucket, file) => {
  if (!bucket.length) return
  filesWithFindings.push(file)
  for (let i = 0; i < bucket.length; i += VERIFY_BATCH_MAX) {
    batches.push({ file: file, part: Math.floor(i / VERIFY_BATCH_MAX) + 1, groups: bucket.slice(i, i + VERIFY_BATCH_MAX) })
  }
})
if (uniq.length) {
  log(`검증: verify 에이전트 ${batches.length}개 (대상 파일 ${filesWithFindings.length}개 · 고유 지적 ${uniq.length}건)`)
}

function runVerifyBatch(file, groups, part, attempt) {
  const payload = groups.map((g) => ({ id: g.id, lenses: g.lenses, findings: g.findings }))
  const partLabel = part > 1 ? `#${part}` : ''
  return agent(`${CONTEXT}
[역할] 아래 리뷰 지적들을 **반박**하라. 기본값은 "지적이 틀렸다(isReal=false)" 이며, 실제 코드로 재현 경로를 확인했을 때만 isReal=true 로 올려라.

[대상 파일] ${file} — 이 파일에 걸린 지적 묶음 ${groups.length}건이다. 파일 전문·diff 는 **한 번만 읽고** 모든 묶음 판정에 재사용하라.

⚠️[독립 판정] 각 묶음은 **서로 독립**이다. 한 묶음을 기각했다고 다른 묶음까지 기각하지 말고, 하나가 실재한다고
다른 묶음이 실재하는 것도 아니다. 묶음마다 근거를 **따로** 확인하고 reason 을 각각 써라.
묶음 id 를 **하나도 빠뜨리지 말고** 전부 판정해 반환하라(빠뜨리면 그 지적은 미판정으로 남아 리뷰가 미완결 처리된다).

[각 묶음 = 같은 결함으로 병합된 지적들] 한 묶음 안에서는 **하나라도 실재하면 isReal=true** 로 하고,
reason 에 어느 서술이 정확한지 명시하라. 서술끼리 어긋나면 실제 코드가 판정 기준이다.
${JSON.stringify(payload)}

[반박 체크 — 묶음 전체가 걸릴 때만 isReal=false]
1. 지적이 인용한 파일:라인을 **직접 Read** 해 실제로 그런 코드인지 확인하라(리뷰어의 인용을 믿지 마라). 인용이 틀렸으면 기각.
   ⚠️단, **인용 라인이 어긋났을 뿐 지적하는 결함이 그 파일에 실재하면 기각하지 마라**(관점마다 인용 라인이 다르게 잡힌다).
2. 이번 스테이징 변경 **때문에** 생긴 것인가, 변경 전에도 있던 성질인가? \`git diff --cached\` 와 \`git show HEAD:<파일>\` 을 대조하라. 후자면 기각.
   ⚠️단, 이번 + 줄이 **기존의 위험 싱크**(SQL 문자열 결합 \`\${}\`·eval·셸·innerHTML 등)로 신뢰불가 입력의 **새 경로**를 열었다면 싱크가 예전부터 있었어도 기각하지 마라 — 공격 표면이 이번 변경으로 넓어졌다.
   ⚠️단, **behavior 8(설계서 대조)** 지적은 인용한 설계서 줄이 [설계서(specRef)] 블록에 실재하고 이번 diff 가 그 기능을 건드렸으면 "변경 전에도 없던 것"이라는 이유로 기각하지 마라 — 누락은 원래 변경 전에도 없다.
3. 실패 시나리오가 실제로 성립하는가? 성립 조건을 명시하고 그 조건이 발생 가능한지 코드·데이터로 확인하라. 발생 불가면 기각.
4. 우리가 수정할 수 없는 외부·공통 자산의 성질이면 기각(reason 에 명시). 단 **우리 코드 쪽에서 우회·보정이 가능하면 기각하지 마라.**
5. 취향·스타일 의견이면 기각. 결함만 남긴다.
6. harness lint 룰이 이미 차단·경고하는 형태이거나 \`lint-*-ok\` 로 명시 예외 처리된 자리면 기각. 규약 위반 지적은 위반된 CLAUDE.md 원문 문장을 인용하지 못하면 기각.
7. 지적이 \`ponytail: <한계> / <업그레이드 경로>\` 마커가 붙은 자리의 **그 한계 자체**(의도한 코너컷)를 문제 삼으면 기각 — 마커는 결정이지 결함이 아니다.
   ⚠️단, ⓐ예상 부하·입력이 그 한계를 이미 넘는 경로가 코드·데이터로 보이거나 ⓑ마커가 약속한 동작(예: "상한에 닿으면 알린다")이 실재하지 않거나 ⓒ자른 것이 하한선(입력검증·데이터 손실 방지 에러처리·보안·접근성·명시 요청 기능)이면 기각하지 마라 — 마커는 하한선을 면제하지 못한다.
[규율] 통과시키는 쪽이 아니라 **떨어뜨리는 쪽이 기본값**이다. 애매하면 기각하라.`,
    tune({
      label: `verify:${String(file).split('/').pop()}${partLabel}${attempt > 1 ? '(재시도)' : ''}`,
      phase: '검증',
      schema: VERDICT_SCHEMA,
    }, VERIFY_MODEL, VERIFY_EFFORT))
}

// 배치 실행. 반환에서 **입력으로 준 id 만** 취한다(에이전트가 만들어낸 id 는 버린다).
// 미판정이 남으면 그 묶음만 1회 재시도하고, 그래도 안 오면 unverified 로 남긴다(기각으로 접지 않는다).
const verdictMaps = await parallel(batches.map((b) => async () => {
  const got = new Map()
  const collect = (r) => {
    if (!r || !Array.isArray(r.verdicts)) return
    r.verdicts.forEach((v) => {
      if (!v || typeof v.id !== 'string') return
      if (!b.groups.some((g) => g.id === v.id)) return
      if (got.has(v.id)) return
      got.set(v.id, { isReal: !!v.isReal, reason: v.reason })
    })
  }
  collect(await runVerifyBatch(b.file, b.groups, b.part, 1))
  const missing = b.groups.filter((g) => !got.has(g.id))
  if (missing.length) {
    log(`⚠️ verify 배치 ${b.file}${b.part > 1 ? '#' + b.part : ''}: 지적 ${missing.length}건이 미판정으로 돌아왔다 — 그 건만 재시도한다.`)
    collect(await runVerifyBatch(b.file, missing, b.part, 2))
  }
  // ⚠️Map 을 그대로 돌려주면 안 된다 — parallel() 경계를 넘으며 결과가 직렬화돼
  // Map 이 plain object 로 납작해지고, 받는 쪽 m.forEach 가 undefined 가 되어
  // 전체 워크플로가 TypeError 로 죽는다(2026-08-31 실측: 리뷰 6에이전트가 전부 정상 완료한 뒤
  // 집계 단계에서만 터져 832k 토큰어치 판정이 통째로 버려질 뻔했다). 직렬화에 안전한 배열로 넘긴다.
  return Array.from(got.entries())
}))
const verdictById = new Map()
// 위 이유로 배열이 정상 경로지만, 런타임이 Map 을 보존하거나 객체로 납작하게 만드는 경우까지
// 모두 받아 낸다 — 여기서 형태 하나를 놓치면 판정 전체가 조용히 미판정으로 떨어진다.
verdictMaps.filter(Boolean).forEach((m) => {
  const entries = Array.isArray(m) ? m
    : (m instanceof Map) ? Array.from(m.entries())
    : (typeof m === 'object') ? Object.entries(m) : []
  entries.forEach((pair) => {
    if (!Array.isArray(pair) || pair.length < 2 || !pair[1]) return
    verdictById.set(pair[0], pair[1])
  })
})

// changedLine 원문에서 라인 번호 힌트("448: …" 또는 "Foo.java:448 …")를 뽑는다. 없으면 null.
function lineHint(changedLine) {
  const s = String(changedLine || '')
  const m = /^\s*(\d{1,6})\s*:/.exec(s) || /[A-Za-z_)\]]:(\d{1,6})(?=\D|$)/.exec(s)
  return m ? m[1] : null
}

const confirmed = uniq
  .filter((g) => { const v = verdictById.get(g.id); return v && v.isReal })
  .map((g) => Object.assign(
    {
      lens: g.lenses[0],
      lenses: g.lenses,
      mergedCount: g.findings.length,
      // 병합된 나머지 지적도 회수한다 — 대표 지적만 남기면 다른 관점이 제안한 수정안이 조용히 사라진다.
      mergedFindings: g.findings.slice(1).map((x) => ({ title: x.title, file: x.file, changedLine: x.changedLine, fix: x.fix })),
    },
    g.findings[0],
    { verifyReason: verdictById.get(g.id).reason }
  ))
const rejected = uniq
  .filter((g) => { const v = verdictById.get(g.id); return v && !v.isReal })
  .map((g) => ({ lenses: g.lenses, title: g.findings[0].title, file: g.file, why: verdictById.get(g.id).reason }))
// 미판정 = 배치 에이전트가 죽었거나 id 를 빠뜨린 지적. **기각도 확정도 아니다** — 게이트를 막는다.
const unverified = uniq
  .filter((g) => !verdictById.has(g.id))
  .map((g) => ({ lenses: g.lenses, title: g.findings[0].title, file: g.file, changedLine: g.findings[0].changedLine }))
if (unverified.length) {
  log(`🔴 미판정 ${unverified.length}건 — verify 가 판정을 돌려주지 않았다(재시도 후에도). 기각으로 읽지 마라.`)
}

// 게이트 판정 — 관점이 하나라도 탈락(반환 null·예외)하거나 status 가 ok 가 아니거나, 어느 ok 관점도 읽지 않은
// 스테이징 파일(uncoveredFiles)이 남거나, 미판정 지적이 있거나, 스테이징 목록을 못 얻었으면 리뷰는 미완결이다.
// status 값의 정본 = 이 파일의 lensResults·lensStatus 대입부(모집단 = grep -nE "status(: | = )'" .claude/workflows/commit-review.js).
// lensStatus.findings = 그 관점이 낸 원시 지적 수(병합 전). 검증 결과는 confirmed/rejected 로 회수한다.
const lensStatus = lensResults.map((r) => ({
  lens: r.key,
  status: r.status,
  reviewedFiles: r.reviewedFiles,
  unreviewedFiles: r.unreviewedFiles || [],
  findings: r.findings.length,
}))
// ⚠️ parallel 의 thunk 가 throw 하면 그 원소가 null 로 떨어져 어느 관점이 죽었는지 안 남는다.
// 여기서 차집합으로 되살려야 "어느 관점이 죽었는지"가 보인다.
const okKeys = lensResults.map((r) => r.key)
const droppedLenses = picked.map((l) => l.key).filter((k) => okKeys.indexOf(k) === -1)
droppedLenses.forEach((k) => {
  lensStatus.push({ lens: k, status: 'dropped', reviewedFiles: [], findings: 0 })
})
// 화이트리스트 밖이라 picked 단계에서 소실된 키. 위 차집합은 picked 기준이라 이것을 못 잡는다.
unknownLenses.forEach((k) => {
  lensStatus.push({ lens: k, status: 'unknown-lens', reviewedFiles: [], findings: 0 })
})
const droppedCount = droppedLenses.length
if (droppedCount > 0) {
  log(`🔴 관점 ${droppedCount}개가 파이프라인에서 탈락했다(반환 null 또는 예외): ${droppedLenses.join(', ')}`)
}
const failedLenses = lensStatus.filter((s) => s.status !== 'ok').map((s) => s.lens)
// 미판정 지적이 하나라도 남으면 미완결이다 — 파일 단위 배치는 에이전트 하나가 죽으면 그 파일의 지적이
// 통째로 사라지므로, 이 조건이 없으면 "지적이 원래 없었다"와 구분되지 않는다(설계의도 6)).
const reviewComplete = droppedCount === 0 && failedLenses.length === 0 && unverified.length === 0 && !stagedUnknown && uncoveredFiles.length === 0

log(`CONFIRMED ${confirmed.length}건 / 기각 ${rejected.length}건${unverified.length ? ` / 미판정 ${unverified.length}건` : ''}`)

if (reviewComplete) {
  log(`✅ 리뷰 완결 — 관점 ${lensStatus.length}개 전부 정상 반환, 고유 지적 ${uniq.length}건 전부 판정됨.`)
} else {
  const why = []
  if (failedLenses.length || droppedCount) why.push(`실패 관점: ${failedLenses.join(', ') || '(파이프라인 탈락)'}`)
  if (unverified.length) why.push(`미판정 지적 ${unverified.length}건`)
  if (stagedUnknown) why.push('스테이징 목록 미확보')
  if (uncoveredFiles.length) why.push(`어느 관점도 안 읽은 스테이징 파일 ${uncoveredFiles.length}개(uncoveredFiles — 그 파일을 읽는 관점으로 재실행)`)
  log(`🔴 리뷰 미완결 — ${why.join(' · ')}. **이 결과를 "지적 0건"으로 읽지 마라.** 재실행하거나 에이전트 트랜스크립트를 직접 확인할 것.`)
}

return {
  reviewComplete: reviewComplete,
  lensStatus: lensStatus,
  confirmed: confirmed,
  rejected: rejected,
  // 대조에 쓴 스테이징 목록(정규화 후). 비어 있으면 reviewComplete 는 false 다.
  stagedFiles: stagedFiles,
  // status ok 인 어느 관점의 reviewedFiles 에도 없는 스테이징 파일. 비어 있지 않으면 reviewComplete 는 false 다.
  uncoveredFiles: uncoveredFiles,
  // CONFIRMED 를 **제목·파일·라인 수리 체크리스트**로 — 회수 즉시 그대로 옮겨 적는다(2026-09-03).
  // 지적을 요약해 다시 쓰면 항목이 빠진다(실측: 수리 누락 → 델타 재리뷰에서 재상정). 수리·델타 재리뷰 후 체크.
  // 라인 = finder 의 line 필드가 없으면 changedLine 의 "NNN: …" / "…java:NNN" 접두에서 뽑는다
  //   (3세션 검증 2·3회차 실측: 스키마에 line 이 없어 체크리스트가 전부 `:?` 로 비어 왔다).
  // 병합된 지적은 대표 줄 아래에 위치마다 들여쓴 줄을 붙인다 — 대표 위치만 고치면 다른 관점이 지목한 자리가 남는다.
  fixChecklist: confirmed.reduce((out, f) => {
    out.push(`- [ ] [${f.severity || '?'}] ${f.title || f.summary || '(제목 없음)'} — ${f.file || '?'}:${f.line || lineHint(f.changedLine) || '?'}`)
    ;(f.mergedFindings || []).forEach((m) => {
      out.push(`  - [ ] (병합) ${m.title || '(제목 없음)'} — ${m.file || f.file || '?'}:${lineHint(m.changedLine) || '?'}`)
    })
    return out
  }, []),
  // 판정을 못 받은 지적. 비어 있지 않으면 reviewComplete 는 false 다(기각과 혼동 금지).
  unverified: unverified,
  // 병합·배치 실측치 — 개선이 실제로 먹었는지는 이 값으로 확인한다(mergedCount 가 1뿐이면 절감 0).
  mergeStats: {
    rawFindings: rawCount,
    uniqueFindings: uniq.length,
    mergedAway: rawCount - uniq.length,
    verifyAgents: batches.length,
    filesWithFindings: filesWithFindings.length,
    warning: mergeWarning,
  },
  // 어떤 모델·추론강도로 돌았는지 회수한다. '(세션 상속)' 이 아닌 값이 있으면 **사용자에게 보고할 것**.
  modelPolicy: MODEL_POLICY,
}
