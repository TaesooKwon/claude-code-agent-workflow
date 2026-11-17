'use strict';
/*
 * jsharness 공용 라이브러리 — 화면 JS 실물을 vm 샌드박스에서 태우고, 요청·DOM 상태를 단언한다.
 *   load(srcPath, opts)  → { document, byId, fetchCalls, reqCalls, sandbox, resolveFetch }   opts.prepare(document, byId) = 실행 전 DOM 준비 훅
 *   clickEvent(sel, attrs) → 위임 클릭 이벤트 흉내(target.closest 가 sel 에만 반응)
 *   checker()            → { check(name, cond, detail), results }
 * 스택 전제 = 팀 공통 래퍼 `{{JS_NS}}.requestFetch(url, opt, handler, err)`(콜백형) + 폴링은 순수 fetch.
 * 다른 화면이 다른 전역을 쓰면 opts.globals 로 덮어쓴다(샌드박스에 그대로 병합).
 */
const fs = require('fs');
const vm = require('vm');
const { makeDom } = require('./domstub.js');

function load(srcPath, opts) {
    opts = opts || {};
    const { document, byId } = makeDom();
    const fetchCalls = [];
    const reqCalls = [];
    let resolveFetch = null;
    const window = Object.assign({
        setTimeout: (fn) => { try { fn(); } catch (e) {} return 0; },
        setInterval: () => 1,
        clearInterval: () => {},
        requestAnimationFrame: (fn) => { try { fn(); } catch (e) {} return 0; },
        modal: { open: () => {}, close: () => {} },
        toast: { show: () => {} },
        location: { href: '', reload: () => {} }
    }, opts.window || {});
    const sandbox = Object.assign({
        document, window, console: { error() {}, debug() {}, log() {}, warn() {} },
        CTX_ROOT: opts.ctxRoot || '/cms',
        CODE: { RCV_SUCCESS: 200 },
        cms_csrf: { token: 't' },
        FormData: class { constructor() { this._d = []; } append(k, v) { this._d.push([k, v]); } },
        App: {
            requestFetch: (url, opt, handler, err) => { reqCalls.push({ url, opt, handler, err }); },
            alert: () => {}, confirm: () => {}, alertThen: (m, cb) => { if (cb) cb(); }
        },
        fetch: (url, opt) => {
            fetchCalls.push({ url, opt });
            return new Promise((res) => { resolveFetch = res; });
        },
        encodeURIComponent, decodeURIComponent, setTimeout: window.setTimeout, clearTimeout: () => {}
    }, opts.globals || {});
    sandbox.global = sandbox;
    sandbox.window.document = document;
    global.document = document;
    // 스크립트가 시작 시 읽는 앵커 요소(data-* 속성)를 미리 심는다 — 앵커(예: `#xxxApi`)가 없으면 즉시 return 하는 화면용
    if (typeof opts.prepare === 'function') opts.prepare(document, byId);
    vm.createContext(sandbox);
    vm.runInContext(fs.readFileSync(srcPath, 'utf8'), sandbox, { filename: srcPath });
    if (opts.domReady !== false) document.fire('DOMContentLoaded', {});
    return {
        document, byId, fetchCalls, reqCalls, sandbox,
        // 소스의 top-level `const`/`let` 을 집는다 — 그 바인딩은 컨텍스트의 전역 렉시컬 스코프에 살아
        // sandbox 의 <b>속성으로는 보이지 않는다</b>(예: 공통 JS 의 `const {{JS_NS}} = ...()` 최상위 바인딩).
        // 같은 컨텍스트에서 한 번 더 평가하면 그 스코프를 그대로 읽는다.
        evalIn: (expr) => vm.runInContext(expr, sandbox),
        // 마지막 fetch 를 응답으로 매듭짓는다(in-flight 가드 해제용). body 는 json() 이 돌려줄 객체.
        resolveFetch: (body, init) => resolveFetch(Object.assign({
            ok: true, status: 200, headers: { get: () => null }, json: () => Promise.resolve(body)
        }, init || {}))
    };
}

function clickEvent(sel, attrs) {
    attrs = attrs || {};
    const stub = { getAttribute: (k) => (attrs[k] === undefined ? null : attrs[k]), closest: () => null, disabled: false, dataset: attrs };
    return { preventDefault() {}, stopPropagation() {}, target: { closest: (s) => (s === sel ? stub : null) } };
}

function submitEvent(formSel) {
    return { preventDefault() {}, target: { closest: (s) => (s === formSel ? {} : null) } };
}

function checker() {
    const results = [];
    return {
        results,
        check(name, cond, detail) { results.push({ name, ok: !!cond, detail: detail || '' }); }
    };
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

module.exports = { load, clickEvent, submitEvent, checker, sleep };
