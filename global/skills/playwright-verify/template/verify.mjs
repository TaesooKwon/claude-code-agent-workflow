/*
 * playwright-verify 템플릿 — JS 렌더·인증 게이트 화면 시각검증
 * 사용법: 상단 CONFIG 를 레포별 self-discover 값으로 채우고, STEPS 를 화면에 맞게 편집.
 *   node verify.mjs            (헤드리스)
 *   HEADED=1 node verify.mjs   (창 띄워 관전; slowMo 적용)
 * 실행은 playwright 가 설치된 디렉터리(npm i 한 곳)에서. CONFIG.SHOTS 는 "각 레포 docs/verify-shots" 절대경로.
 */
import { createRequire } from 'module';
import { mkdirSync } from 'fs';
// playwright 는 공유 스킬 디렉터리에 1회 설치(레포별 node_modules 불필요) → 어디서 실행하든 그 설치를 사용
const require = createRequire('__HOME__/.claude/skills/playwright-verify/');
const { chromium } = require('playwright');

// ===== CONFIG (레포별로 채움 — application.properties/LoginController 로 self-discover. 비밀번호는 env CMS_PASS 로만 —
//        스위트에 키체인을 읽는 로그인 헬퍼가 있으면 이 템플릿 대신 그 헬퍼를 쓴다(조회·복사 금지)) =====
const CONFIG = {
  // BASE = http://localhost:<server.port><context-path>  (추측 금지! properties 실측)
  BASE: 'http://localhost:8080/example-admin',
  LOGIN_PATH: '/auth/login.do',            // LoginController @GetMapping
  ID_SEL: '#userId',
  PW_SEL: '#userPswd',
  SUBMIT_SEL: '#loginForm button[type="submit"]',
  USER: process.env.CMS_USER || 'admin',       // 민감값은 가급적 env 로 주입
  PASS: process.env.CMS_PASS || '',            // 비우면 env CMS_PASS 필요
  SHOTS: '/ABSOLUTE/PATH/TO/<REPO>/docs/verify-shots',
  HEADED: !!process.env.HEADED,
};
// ===== STEPS (화면에 맞게 편집) =====
// 각 step: { name, run: async(page,rec) => {} }  / rec(name, ok, note) 로 결과 기록
const STEPS = [
  { name: '예시: 목록 ag-Grid 행 렌더', run: async (page, rec) => {
      await page.goto(`${CONFIG.BASE}/<도메인>/<화면>/index.do`, { waitUntil: 'networkidle' });
      await page.waitForSelector('.ag-row', { timeout: 10000 }).catch(() => {});
      const rows = await page.locator('.ag-row').count();
      await page.screenshot({ path: `${CONFIG.SHOTS}/list.png` });
      rec('목록 ag-Grid 행', rows > 0, `${rows}행`);
  }},
  { name: '예시: 상세 모달', run: async (page, rec) => {
      await page.locator('.btn-detail').first().click();
      await page.waitForTimeout(1200);
      const ok = (await page.locator('dialog[data-modal] iframe, dialog[data-modal] .intv-detail').count()) > 0;
      await page.screenshot({ path: `${CONFIG.SHOTS}/detail.png` });
      rec('상세 모달 렌더', ok);
  }},
];

mkdirSync(CONFIG.SHOTS, { recursive: true });
const results = [];
const log = (...a) => console.log('[VERIFY]', ...a);
const rec = (name, ok, note = '') => { results.push([name, ok, note]); log(`${ok ? 'PASS' : 'FAIL'} - ${name} ${note}`); };

const browser = await chromium.launch({ headless: !CONFIG.HEADED, slowMo: CONFIG.HEADED ? 700 : 0 });
const page = await (await browser.newContext({ viewport: { width: 1600, height: 1000 } })).newPage();
try {
  // 로그인
  await page.goto(`${CONFIG.BASE}${CONFIG.LOGIN_PATH}`, { waitUntil: 'domcontentloaded' });
  log('로그인 페이지:', page.url(), '| title:', await page.title());
  await page.fill(CONFIG.ID_SEL, CONFIG.USER);
  await page.fill(CONFIG.PW_SEL, CONFIG.PASS || process.env.CMS_PASS || '');
  await page.click(CONFIG.SUBMIT_SEL);
  await page.waitForTimeout(3000); // ajax 로그인 + 리다이렉트
  log('로그인 후:', page.url(), '| title:', await page.title());

  for (const step of STEPS) {
    try { await step.run(page, rec); }
    catch (e) { rec(step.name, false, 'ERROR ' + e.message); await page.screenshot({ path: `${CONFIG.SHOTS}/err-${step.name.replace(/\W+/g, '_')}.png` }).catch(() => {}); }
  }
} catch (e) {
  log('FATAL', e.message);
  await page.screenshot({ path: `${CONFIG.SHOTS}/fatal.png` }).catch(() => {});
} finally {
  await browser.close();
  console.log('\n=== RESULT ===');
  results.forEach((r) => console.log(`${r[1] ? 'PASS' : 'FAIL'}\t${r[0]}\t${r[2] || ''}`));
  console.log(`\n스크린샷: ${CONFIG.SHOTS}/`);
}
