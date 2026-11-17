// 화면 JS(js/develop/**)를 실제 파일 그대로 vm 에서 실행하기 위한 최소 DOM 스텁(jsharness 공용, 2026-09-03 승격).
// 목적 = 테스트가 소스의 사본이 아니라 '그 파일'을 태우게 하는 것 — 사본을 검사하면 게이트가 자기 자신만 본다.
// 한계(정직 고지) = 셀렉터는 마지막 복합 셀렉터(.cls 여럿 + [attr="v"])만 해석(태그명 셀렉터 미지원) · 레이아웃 없음.
//   실브라우저 의존(포커스 링·CSS 표시·레이아웃)은 Playwright 몫이고, 이 스텁은 <b>상태·요청·DOM 조립 로직</b>의 반증용이다.
'use strict';
function makeEl(tag) {
    const e = {
        tagName: String(tag || 'div').toUpperCase(),
        id: '', className: '', value: '', disabled: false, checked: false, type: '',
        title: '', _children: [], _attrs: {}, parentNode: null,
        style: {}, dataset: {}, scrollTop: 0, scrollHeight: 0, clientHeight: 0,
        classList: {
            _s: new Set(),
            add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
            contains(c) { return this._s.has(c); },
            // force 를 주면 그 값대로, 안 주면 뒤집는다(DOM 과 같게 최종 포함 여부를 돌려준다)
            toggle(c, force) {
                const on = force === undefined ? !this._s.has(c) : !!force;
                if (on) this._s.add(c); else this._s.delete(c);
                return on;
            }
        },
        _listeners: {},
        setAttribute(k, v) { this._attrs[k] = String(v); },
        getAttribute(k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
        removeAttribute(k) { delete this._attrs[k]; },
        appendChild(c) {
            if (c && c._isFragment) { c._children.forEach((x) => { this._children.push(x); x.parentNode = this; }); c._children = []; return c; }
            this._children.push(c); if (c) c.parentNode = this; return c;
        },
        insertBefore(c, ref) {
            const kids = (c && c._isFragment) ? c._children.slice() : [c];
            if (c && c._isFragment) c._children = [];
            let i = this._children.indexOf(ref); if (i < 0) i = 0;
            this._children.splice(i, 0, ...kids); kids.forEach((x) => { if (x) x.parentNode = this; });
            return c;
        },
        removeChild(c) { const i = this._children.indexOf(c); if (i >= 0) this._children.splice(i, 1); return c; },
        remove() { if (this.parentNode && this.parentNode.removeChild) this.parentNode.removeChild(this); },
        // <dialog> 흉내 — 열림/닫힘 상태만 남긴다(레이아웃·inert·backdrop 은 Playwright 몫).
        showModal() { this.open = true; }, close() { this.open = false; (this._listeners.close || []).forEach((fn) => fn({})); },
        replaceChild(n, o) { const i = this._children.indexOf(o); if (i >= 0) { this._children[i] = n; n.parentNode = this; o.parentNode = null; } return o; },
        replaceChildren(...kids) { this._children = []; kids.forEach((k) => this.appendChild(k)); },
        contains(n) { if (n === this) return true; return this._children.some((c) => c && c.contains && c.contains(n)); },
        querySelector(sel) { return this._find(sel)[0] || null; },
        querySelectorAll(sel) { return this._find(sel); },
        // 마지막 복합 셀렉터만 해석한다: .cls 여럿 + [attr="value"] 여럿 (실브라우저의 속성 필터를
        // 무시하면 aria-expanded="true" 같은 조건이 통째로 사라져 <b>테스트가 거짓 실패</b>한다).
        // 클래스도 속성도 없는 셀렉터(태그명뿐)는 매칭하지 않는다 — 스텁이 태그 셀렉터를 모른다.
        _matchesSel(sel) {
            const parts = String(sel).split(/[\s,]+/).filter(Boolean);
            let last = parts[parts.length - 1] || '';
            // :not(.cls) 는 먼저 떼어 제외 목록으로 쓴다 — 안 그러면 그 안의 클래스가 '필수 클래스'로 읽혀
            // 셀렉터 의미가 정반대가 된다(.a:not(.b) 가 'a 이면서 b' 로 매칭된다).
            const excluded = [];
            last = last.replace(/:not\(([^)]*)\)/g, (m, inner) => {
                (inner.match(/\.[A-Za-z0-9_-]+/g) || []).forEach((c) => excluded.push(c.slice(1)));
                return '';
            });
            const classes = (last.match(/\.[A-Za-z0-9_-]+/g) || []).map((c) => c.slice(1));
            if (excluded.length) {
                const own = String(this.className).split(/\s+/);
                if (excluded.some((x) => own.includes(x))) return false;
            }
            const attrs = [];
            const re = /\[([A-Za-z0-9_-]+)(?:=\"([^\"]*)\")?\]/g;
            let m;
            while ((m = re.exec(last)) !== null) attrs.push([m[1], m[2]]);
            if (!classes.length && !attrs.length) return false;
            const cl = String(this.className).split(/\s+/);
            if (!classes.every((x) => cl.includes(x))) return false;
            return attrs.every(([k, v]) => {
                const got = this.getAttribute ? this.getAttribute(k) : null;
                return v === undefined ? got !== null : got === v;
            });
        },
        _find(sel) {
            const out = [];
            const walk = (n) => { n._children.forEach((c) => { if (!c) return; if (c._matchesSel && c._matchesSel(sel)) out.push(c); walk(c); }); };
            walk(this); return out;
        },
        addEventListener(t, fn) { (this._listeners[t] = this._listeners[t] || []).push(fn); },
        removeEventListener() {},
        focus() { global.document.activeElement = this; },
        // 자신부터 부모 체인을 올라가며 첫 일치를 돌려준다(_matchesSel 과 같은 셀렉터 한계를 그대로 쓴다)
        closest(sel) {
            let node = this;
            while (node) {
                if (node._matchesSel && node._matchesSel(sel)) return node;
                node = node.parentNode;
            }
            return null;
        },
        get firstChild() { return this._children[0] || null; },
        get firstElementChild() { return this._children[0] || null; }
    };
    Object.defineProperty(e, 'textContent', {
        get() { return e._text !== undefined ? e._text : ''; },
        set(v) { e._text = String(v); if (String(v) === '') e._children = []; }
    });
    Object.defineProperty(e, 'innerHTML', {
        get() { return e._html || ''; },
        set(v) {
            e._html = String(v); e.value = String(v);
            // <template> 은 innerHTML 을 파싱해 content 로 내준다. 스텁은 HTML 을 파싱하지 않으므로
            // 루트 태그 하나와 그 안의 class 들만 훑어 <b>골격만</b> 만든다 — 자식 구조·순서는 재현하지 않는다.
            // ({{JS_NS}}.alert/confirm 이 template.content.firstChild 로 다이얼로그를 꺼내는 경로용)
            if (e.tagName !== 'TEMPLATE') return;
            const rootTag = (String(v).match(/^\s*<([a-zA-Z][a-zA-Z0-9]*)/) || [null, 'div'])[1];
            const root = makeEl(rootTag);
            const seen = new Set();
            (String(v).match(/class="([^"]*)"/g) || []).forEach((chunk) => {
                chunk.replace(/^class="|"$/g, '').split(/\s+/).filter(Boolean).forEach((cls) => {
                    if (seen.has(cls)) return;
                    seen.add(cls);
                    const child = makeEl('div');
                    child.className = cls;
                    root.appendChild(child);
                });
            });
            const frag = makeEl('#fragment'); frag._isFragment = true; frag.appendChild(root);
            e._content = frag;
        }
    });
    Object.defineProperty(e, 'content', { get() { return e._content || null; } });
    return e;
}
function makeDom() {
    const byId = {};
    const document = {
        hidden: false, activeElement: null, _listeners: {}, body: makeEl('body'),
        getElementById(id) { if (!byId[id]) { byId[id] = makeEl('div'); byId[id].id = id; } return byId[id]; },
        createElement(t) { return makeEl(t); },
        // 텍스트 노드도 요소로 흉내 낸다 — appendChild 로 붙기만 하면 되고, 내용은 textContent 로 읽힌다.
        createTextNode(t) { const n = makeEl('#text'); n.textContent = String(t); return n; },
        createDocumentFragment() { const f = makeEl('#fragment'); f._isFragment = true; return f; },
        querySelector() { return null; },
        querySelectorAll() { return []; },
        addEventListener(t, fn) { (this._listeners[t] = this._listeners[t] || []).push(fn); },
        fire(t, ev) { (this._listeners[t] || []).forEach((fn) => fn(ev)); }
    };
    return { document, byId };
}
module.exports = { makeEl, makeDom };
