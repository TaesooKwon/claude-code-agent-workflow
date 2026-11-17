#!/usr/bin/env node
'use strict';
/*
 * jsharness 러너 — 화면 JS(js/develop/**) 로직의 결정적 단위검증(브라우저 없음, DB 없음).
 *
 *   node .claude/jsharness/run.js                 # specs/*.spec.js 전부
 *   node .claude/jsharness/run.js specs/x.spec.js # 지정 스펙만
 *
 * 스펙 계약: module.exports = async function (h, ctx) { ... }  — h = lib/harness.js, ctx = { repoRoot, check }
 *   check(name, cond, detail) 로 단언을 쌓고, 러너가 PASS/FAIL 을 찍는다. 예외는 그 스펙의 FAIL 로 접는다.
 * 규약(프로젝트 CLAUDE.md 🧪): js/develop/** 로직 변경 시 스펙 1개 + 반증(변이로 빨간불) 1회.
 *   "Tests run: N" 이 0 이면 스펙이 안 돈 것이다 — 러너가 0건을 실패로 취급한다(반증 부칙 ⓓ).
 */
const fs = require('fs');
const path = require('path');
const h = require('./lib/harness.js');

const HERE = __dirname;
const repoRoot = path.resolve(HERE, '..', '..');
let specs = process.argv.slice(2).map((p) => path.resolve(process.cwd(), p));
if (specs.length === 0) {
    const dir = path.join(HERE, 'specs');
    specs = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.spec.js')).sort().map((f) => path.join(dir, f)) : [];
}

(async () => {
    let total = 0, fail = 0;
    for (const spec of specs) {
        const c = h.checker();
        const name = path.relative(repoRoot, spec);
        try {
            await require(spec)(h, { repoRoot, check: c.check });
        } catch (e) {
            c.check('(스펙 실행 예외) ' + (e && e.message), false, e && e.stack);
        }
        console.log('== ' + name);
        c.results.forEach((r) => { total++; if (!r.ok) fail++; console.log((r.ok ? '  PASS ' : '  FAIL ') + r.name + (r.ok ? '' : '  << ' + r.detail)); });
    }
    console.log('');
    console.log('Tests run: ' + total + ', Failures: ' + fail + ', Specs: ' + specs.length);
    if (total === 0) { console.log('FAIL — 단언 0건(스펙이 안 돌았다 — 통과가 아니다)'); process.exit(2); }
    process.exit(fail === 0 ? 0 : 1);
})();
