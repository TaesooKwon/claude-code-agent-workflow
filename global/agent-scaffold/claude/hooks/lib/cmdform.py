#!/usr/bin/env python3
# 공용 판정기 — Bash 명령 문자열이 허용 형태인지 판정한다(킷 가드 v2: 금지 목록 → 허용 목록).
# 사용(셸 훅이 부른다 — 표준 라이브러리만 쓰고 -I 로 사용자 site·PYTHON* 환경변수 영향을 끊는다):
#   python3 -I cmdform.py commit <cwd>   < cmd   → NONE | ALLOW | DENY\t<사유>   (커밋 게이트 PreToolUse 경로)
#   python3 -I cmdform.py db             < cmd   → ALLOW | DENY\t<사유>          (운영 DB 가드)
# 원칙: 허용 형태로 확정될 때만 ALLOW. 해석 불가(Ambig)면 관련 낱말이 보일 때 DENY.
# 실패 계약: 예외·시간 초과(내부 상한 LIMIT_SEC)·인자 오류 = 표준출력 DENY + rc≠0. 호출부는 rc≠0 과
#   위 세 형태 밖의 출력을 모두 deny 로 받는다(fail-closed).
# 허용 문법·규칙의 정본 = 아래 judge_commit / judge_db 와 그 주석.
# ponytail: 렉서가 모르는 문법(zsh 전용 ${(f)…}·case 패턴·(( )) 명령)은 Ambig — commit·DB 낱말이 보일 때만 deny(그 밖엔 통과·
#   CLI 층에 위임) / 업그레이드 = 문법 추가 시 케이스 동반
# ponytail: 함수 정의 판정(has_funcdef)은 인용을 걷은 사본에 대한 정규식이라 히어독 본문 안 `f()` 문구도 함수로 본다(오차단 방향)
#   / 업그레이드 = 렉서 토큰 기준 판정
import os, re, sys, signal, subprocess

LIMIT_SEC = 5   # 판정 1회 상한(초) — 넘으면 DENY. 셸 쪽 `timeout` 이 없는 기계에서도 이 상한이 걸린다.

class Ambig(Exception):
    pass

class Word:
    __slots__ = ('text', 'raw', 'quoted', 'subst', 'expand', 'ansi', 'nested')
    def __init__(self):
        self.text = ''; self.raw = ''; self.quoted = False; self.subst = False
        self.expand = False; self.ansi = False; self.nested = []

class Cmd:
    __slots__ = ('words', 'redirs', 'heredocs', 'sep', 'depth', 'insubst', 'nested')
    def __init__(self, sep, depth, insubst):
        self.words = []; self.redirs = []; self.heredocs = []; self.sep = sep
        self.depth = depth; self.insubst = insubst; self.nested = []

META = set(' \t\n;&|()<>')
NAME_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')

def _ansi_decode(s):
    try:
        return bytes(s, 'latin1', 'backslashreplace').decode('unicode_escape')
    except Exception:
        raise Ambig('ansi')

class Lexer:
    def __init__(self, s):
        self.s = s; self.n = len(s)

    def _find_close_paren(self, i):
        # $( … ) 의 짝 ) 위치 — 하위 렉싱으로 찾는다(따옴표·중첩 인식)
        sub = Lexer(self.s)
        cmds, j = sub.lex(i, end_paren=True, insubst=True)
        return cmds, j

    def _read_dq(self, i, w):
        # i = 여는 " 다음. 반환 = 닫는 " 다음 위치
        s = self.s
        while i < self.n:
            c = s[i]
            if c == '"':
                return i + 1
            if c == '\\' and i + 1 < self.n:
                d = s[i + 1]
                if d == '\n':
                    i += 2; continue
                if d in '$`"\\':
                    w.text += d; i += 2; continue
                w.text += c; i += 1; continue
            if c == '$' and s.startswith('$((', i):
                j = s.find('))', i + 3)
                if j < 0: raise Ambig('arith')
                w.expand = True; w.text += s[i:j + 2]; i = j + 2; continue
            if c == '$' and s.startswith('$(', i):
                cmds, j = self._find_close_paren(i + 2)
                w.subst = True; w.nested.extend(cmds); w.text += '\x00S\x00'; i = j; continue
            if c == '`':
                j = self._bq_end(i + 1)
                inner = s[i + 1:j].replace('\\`', '`')
                w.subst = True; w.nested.extend(Lexer(inner).lex(0, insubst=True)[0]); w.text += '\x00S\x00'; i = j + 1; continue
            if c == '$' and s.startswith('${', i):
                j = s.find('}', i)
                if j < 0: raise Ambig('brace')
                w.expand = True; w.text += s[i:j + 1]; i = j + 1; continue
            if c == '$':
                m = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9?#@*$!-])').match(s, i)
                if m:
                    w.expand = True; w.text += m.group(0); i = m.end(); continue
            w.text += c; i += 1
        raise Ambig('dq-unclosed')

    def _bq_end(self, i):
        while i < self.n:
            if self.s[i] == '\\': i += 2; continue
            if self.s[i] == '`': return i
            i += 1
        raise Ambig('bq-unclosed')

    def _read_word(self, i):
        # 셸 낱말 하나 — i 는 메타문자가 아닌 위치. 반환 (Word, 다음 위치)
        s = self.s; w = Word(); start = i
        while i < self.n:
            c = s[i]
            if c in META:
                break
            if c == '\\':
                if i + 1 < self.n:
                    if s[i + 1] == '\n': i += 2; continue
                    w.text += s[i + 1]; w.quoted = True; i += 2; continue
                i += 1; continue
            if c == "'":
                j = s.find("'", i + 1)
                if j < 0: raise Ambig('sq-unclosed')
                w.text += s[i + 1:j]; w.quoted = True; i = j + 1; continue
            if c == '$' and s.startswith("$'", i):
                j = i + 2
                while j < self.n and s[j] != "'":
                    j += 2 if s[j] == '\\' else 1
                if j >= self.n: raise Ambig('ansi-unclosed')
                body = s[i + 2:j]
                w.text += _ansi_decode(body); w.quoted = True; w.ansi = True; i = j + 1; continue
            if c == '$' and s.startswith('$"', i):
                i += 1; continue  # $"…" = 지역화 큰따옴표 — 큰따옴표로 본다
            if c == '"':
                w.quoted = True; i = self._read_dq(i + 1, w); continue
            if c == '$' and s.startswith('$((', i):
                j = s.find('))', i + 3)
                if j < 0: raise Ambig('arith')
                w.expand = True; w.text += s[i:j + 2]; i = j + 2; continue
            if c == '$' and s.startswith('$(', i):
                cmds, j = self._find_close_paren(i + 2)
                w.subst = True; w.nested.extend(cmds); w.text += '\x00S\x00'; i = j; continue
            if c == '`':
                j = self._bq_end(i + 1)
                inner = s[i + 1:j].replace('\\`', '`')
                w.subst = True; w.nested.extend(Lexer(inner).lex(0, insubst=True)[0]); w.text += '\x00S\x00'; i = j + 1; continue
            if c == '$' and s.startswith('${', i):
                j = s.find('}', i)
                if j < 0: raise Ambig('brace')
                w.expand = True; w.text += s[i:j + 1]; i = j + 1; continue
            if c == '$':
                m = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*|[0-9?#@*$!-])').match(s, i)
                if m:
                    w.expand = True; w.text += m.group(0); i = m.end(); continue
            w.text += c; i += 1
        w.raw = s[start:i]
        return w, i

    def _heredoc_delim(self, i):
        # << 뒤 구분자 낱말 원문을 읽어 종류를 가린다. 순수형만 인정(N2) — 섞이면 Ambig.
        s = self.s
        while i < self.n and s[i] in ' \t': i += 1
        w, j = self._read_word(i)
        raw = w.raw
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', raw): kind = 'plain'
        elif re.fullmatch(r"'[A-Za-z_][A-Za-z0-9_]*'", raw): kind = 'sq'
        elif re.fullmatch(r'"[A-Za-z_][A-Za-z0-9_]*"', raw): kind = 'dq'
        elif re.fullmatch(r'\\[A-Za-z_][A-Za-z0-9_]*', raw): kind = 'bs'
        else: raise Ambig('heredoc-delim:' + raw)
        return {'delim': w.text, 'kind': kind, 'body': None}, j

    def lex(self, i=0, end_paren=False, insubst=False):
        s = self.s; cmds = []; depth = 0
        cur = Cmd('start', 0, insubst); pend = []; redir = None
        def finish(sep):
            nonlocal cur
            if cur.words or cur.redirs or cur.heredocs:
                cmds.append(cur)
            cur = Cmd(sep, depth, insubst)
        while i < self.n:
            c = s[i]
            if c in ' \t':
                i += 1; continue
            if c == '\\' and s.startswith('\\\n', i):
                i += 2; continue
            if c == '#':   # 루프 머리 = 낱말 시작 자리 → 주석
                while i < self.n and s[i] != '\n': i += 1
                continue
            if c == '\n':
                if redir: raise Ambig('redir-target')
                i += 1
                for (owner, hd) in pend:
                    body = []; found = False
                    while i <= self.n:
                        k = s.find('\n', i)
                        line = s[i:] if k < 0 else s[i:k]
                        nxt = self.n + 1 if k < 0 else k + 1
                        cmp = line.lstrip('\t') if hd['strip'] else line
                        i = nxt
                        if cmp == hd['delim']:
                            found = True; break
                        body.append(line)
                        if k < 0: break
                    if not found: raise Ambig('heredoc-unterminated:' + hd['delim'])
                    hd['body'] = '\n'.join(body)
                pend = []
                finish('\n'); continue
            if end_paren and c == ')' and depth == 0:
                finish(')')
                if pend: raise Ambig('heredoc-in-subst-unterminated')
                return cmds, i + 1
            if c in ';&|()<>' or (c.isdigit() and re.match(r'\d+[<>]', s[i:])):
                if c.isdigit():
                    m = re.match(r'\d+', s[i:]); fd = m.group(0); i += len(fd); c = s[i]
                else:
                    fd = ''
                if s.startswith('&&', i): finish('&&'); i += 2; continue
                if s.startswith('||', i): finish('||'); i += 2; continue
                if s.startswith(';;', i): finish(';'); i += 2; continue
                if s.startswith('|&', i): finish('|&'); i += 2; continue
                if c == ';': finish(';'); i += 1; continue
                if c == '|': finish('|'); i += 1; continue
                if s.startswith('&>>', i): redir = fd + '&>>'; i += 3; continue
                if s.startswith('&>', i): redir = fd + '&>'; i += 2; continue
                if c == '&': finish('&'); i += 1; continue
                if c == '(':
                    if s.startswith('((', i): raise Ambig('arith-cmd')
                    finish(cur.sep if not cur.words else ';'); depth += 1; cur.depth = depth; i += 1; continue
                if c == ')':
                    finish(';'); depth -= 1
                    if depth < 0: raise Ambig('paren')
                    cur.depth = depth; i += 1; continue
                if s.startswith('<<<', i): redir = fd + '<<<'; i += 3; continue
                if s.startswith('<<', i):
                    dash = s.startswith('<<-', i); i += 3 if dash else 2
                    hd, i = self._heredoc_delim(i); hd['strip'] = dash; hd['fd'] = fd
                    cur.heredocs.append(hd); pend.append((cur, hd)); continue
                if s.startswith('<(', i) or s.startswith('>(', i):
                    cmds2, j = self._find_close_paren(i + 2)
                    w = Word(); w.subst = True; w.nested = cmds2; w.text = '\x00P\x00'; w.raw = s[i:j]
                    cur.words.append(w); i = j; continue
                for op in ('>>', '>|', '>&', '<&', '<>', '>', '<'):
                    if s.startswith(op, i):
                        redir = fd + op; i += len(op); break
                continue
            w, i = self._read_word(i)
            if redir is not None:
                cur.redirs.append((redir, w)); redir = None; continue
            if not cur.words and w.raw in ('{', '}'):
                if w.raw == '{': depth += 1
                else: depth -= 1
                cur.depth = depth; continue
            cur.words.append(w)
        if redir: raise Ambig('redir-target')
        if pend: raise Ambig('heredoc-no-newline')
        if end_paren: raise Ambig('subst-unclosed')
        if depth != 0: raise Ambig('group-unclosed')
        finish('end')
        return cmds, i

def flatten(cmds, out=None):
    out = [] if out is None else out
    for c in cmds:
        out.append(c)
        for w in c.words:
            flatten(w.nested, out)
        for (_, w) in c.redirs:
            flatten(w.nested, out)
    return out

ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
KEYWORDS = {'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!', 'time', 'fi', 'done', 'esac'}
def exe_idx(c):
    # 선행 대입·셸 예약어(do python3 …)를 건너뛴 첫 실행어 위치
    k = 0
    while k < len(c.words) and (ASSIGN_RE.match(c.words[k].raw) or (not c.words[k].quoted and c.words[k].text in KEYWORDS)):
        k += 1
    if k < len(c.words) and not c.words[k].quoted and c.words[k].text in ('for', 'case', 'select', 'function'):
        return None   # for x in … / case … in — 낱말은 실행어가 아니다
    return k if k < len(c.words) else None

def base(t):
    return t.rsplit('/', 1)[-1]

WRAP = {'env', 'command', 'exec', 'time', 'nice', 'timeout', 'nohup', 'sudo', 'stdbuf', 'xargs', 'builtin'}
def resolve_exe(c):
    """투명 래퍼를 벗긴 실행어(소문자 basename). 확정 못 하면 '?'. 없으면 None."""
    k = exe_idx(c)
    if k is None: return None, None
    ws = c.words
    while k < len(ws):
        w = ws[k]
        if w.subst or w.expand: return '?', k
        b = base(w.text).lower()
        if b not in WRAP: return b, k
        k += 1
        # 래퍼 옵션 — 값 확정 가능한 꼴만 벗긴다. 모르면 '?'
        while k < len(ws):
            t = ws[k].text
            if b == 'env' and ASSIGN_RE.match(t): k += 1; continue
            if b == 'timeout' and re.fullmatch(r'[0-9.]+[smhd]?', t): k += 1; break
            if t in ('-n', '-u', '-I', '-a', '-k', '-s', '-g') and b in ('nice', 'sudo', 'xargs', 'exec', 'timeout', 'env'):
                k += 2; continue
            if t.startswith('-'):
                if b in ('sudo', 'xargs', 'env', 'stdbuf', 'command', 'exec', 'time', 'timeout', 'nice'): k += 1; continue
                return '?', k
            break
    return None, None

SHELLS = {'sh', 'bash', 'zsh', 'dash', 'ksh', 'fish'}
def shell_c_nested(c):
    """sh -c STRING / eval ARGS → 하위 명령(실행될 문자열을 렉싱)."""
    b, k = resolve_exe(c)
    if b in SHELLS:
        for j in range(k + 1, len(c.words)):
            t = c.words[j].text
            if re.fullmatch(r'-[A-Za-z]*c[A-Za-z]*', t) and j + 1 < len(c.words):
                return Lexer(c.words[j + 1].text).lex(0, insubst=True)[0]
        # 표준입력 스크립트(`bash <<EOF` · `sh -s <<EOF`) — 히어독 본문이 곧 실행될 명령이다(터널·CLI 판정 대상).
        #   본문은 live_texts 에 원문으로도 남으므로, 렉싱이 안 되면 하위 명령만 포기한다(낱말 판정은 그대로).
        if c.heredocs and all(w.text.startswith('-') for w in c.words[k + 1:]):
            out = []
            for hd in c.heredocs:
                try:
                    out.extend(Lexer(hd['body'] or '').lex(0, insubst=True)[0])
                except Ambig:
                    pass
            return out
    if b == 'eval':
        return Lexer(' '.join(w.text for w in c.words[k + 1:])).lex(0, insubst=True)[0]
    return []

DOC_EXT = re.compile(r'\.(md|txt|json|sql|xml|yaml|yml|properties|html|css|csv|log|conf|diff|patch)$', re.I)
SINK = {'cat', 'tee', 'grep', 'jq', 'sort', 'head', 'tail', 'wc', 'diff', 'tr', 'cut'}
DATA_SAFE = {'grep', 'egrep', 'fgrep', 'rg', 'echo', 'printf', 'cat', 'head', 'tail', 'wc', 'ls', 'cut', 'sort', 'uniq', 'tr', 'jq', 'column', 'which', 'type', 'man'}
RO_GIT = {'log', 'status', 'diff', 'show', 'rev-parse', 'shortlog'}

def pipelines(cmds):
    out = []; cur = []
    for c in cmds:
        if cur and c.sep in ('|', '|&'):
            cur.append(c)
        else:
            if cur: out.append(cur)
            cur = [c]
    if cur: out.append(cur)
    return out

def is_ro_git(c):
    b, k = resolve_exe(c)
    if b != 'git' or k != exe_idx(c): return False
    ws = c.words
    if k + 1 >= len(ws): return False
    sub = ws[k + 1]
    if sub.quoted or sub.subst or sub.expand: return False
    if sub.text == 'branch':
        return all(w.text in ('--show-current', '-v', '-vv', '--list', '-a') for w in ws[k + 2:])
    if sub.text not in RO_GIT: return False
    for w in ws[k + 2:]:
        if w.text.startswith(('--output', '--ext-diff', '--exec')): return False
    return True

def heredoc_inert(c, hd, pipe):
    """lib git_strip_heredoc 과 같은 축 — 데이터 싱크가 문서·데이터 대상으로 쓸 때만 본문을 데이터로 본다."""
    b, k = resolve_exe(c)
    if b not in SINK or k != exe_idx(c): return False
    if len(pipe) > 1 and pipe[-1] is not c: return False
    if c.depth or c.insubst: return False
    if hd['kind'] == 'plain' and re.search(r'\$\(|`', hd['body'] or ''): return False
    for (op, w) in c.redirs:
        if op.endswith('>') or op.endswith('>>') or op.endswith('>|'):
            if w.subst or w.expand: return False
            if not (w.text == '/dev/null' or DOC_EXT.search(w.text)): return False
        if op.endswith('>&') and w.text not in ('1', '2'): return False
    if b == 'tee':
        for w in c.words[k + 1:]:
            if w.text.startswith('-'): continue
            if not DOC_EXT.search(w.text): return False
    return True

RUNNERS = {'bash', 'sh', 'zsh', 'node'}
def is_file_runner(c):
    # 스크립트 파일 실행(bash x.sh · node x.mjs · python3 x.py) — 인자는 그 스크립트의 데이터다(스크립트 본문은 원래 못 본다)
    b, k = resolve_exe(c)
    if k is None or k != exe_idx(c) or c.heredocs: return False
    if not (b in RUNNERS or (b and PY_EXE.fullmatch(b))): return False
    if k + 1 >= len(c.words): return False
    w = c.words[k + 1]
    return not w.subst and not w.text.startswith('-')

def out_redirs_doc_only(c):
    """출력 리다이렉트 대상이 전부 /dev/null·문서 확장자(DOC_EXT)·표준 출력/오류 복제인가 — heredoc_inert 와 같은 축(F1).
    `printf '…pymysql…' > x.py && python3 x.py` 처럼 데이터 실행어가 실행될 만한 파일로 쓰면 그 텍스트는 데이터가 아니다."""
    for (op, w) in c.redirs:
        o = op.lstrip('0123456789')
        if o in ('>&', '<&'):
            if w.text in ('1', '2') and not w.subst and not w.expand: continue
            return False
        if o in ('<', '<<<'): continue
        if w.subst or w.expand: return False
        if not (w.text == '/dev/null' or DOC_EXT.search(w.text)): return False
    return True

def pipe_inert(pipe):
    for c in pipe:
        if c.insubst: return False
        for w in c.words:
            if w.subst: return False
        if is_ro_git(c): continue
        if is_file_runner(c): continue
        b, k = resolve_exe(c)
        if k != exe_idx(c): return False   # 래퍼 경유는 데이터로 보지 않는다
        if b not in DATA_SAFE: return False
        if not out_redirs_doc_only(c): return False   # F1 — 실행될 만한 파일로 쓰는 텍스트는 살아 있다
        for hd in c.heredocs:
            if not heredoc_inert(c, hd, pipe): return False
    return True

def live_texts(cmds, skip_heredoc_of=None):
    """(cmd, 텍스트) — 데이터로 확정된 파이프라인·본문을 뺀 나머지."""
    allc = flatten(cmds)
    top_pipes = pipelines([c for c in cmds])
    inert = set()
    for p in top_pipes:
        if pipe_inert(p):
            for c in p: inert.add(id(c))
    out = []
    for c in allc:
        extra = []
        for n in shell_c_nested(c):
            extra.extend(flatten([n]))
        for n in extra:
            out.append((n, ' '.join(w.text for w in n.words)))
        pipe = next((p for p in top_pipes if c in p), [c])
        for hd in c.heredocs:
            if skip_heredoc_of is not None and (c, hd) in skip_heredoc_of: continue
            if not heredoc_inert(c, hd, pipe):
                out.append((c, hd['body'] or ''))
        if id(c) in inert: continue
        out.append((c, ' '.join(w.text for w in c.words) + ' ' + ' '.join(w.text for (_, w) in c.redirs)))
    return out

# ───────────────────────── 커밋 게이트(PTU) ─────────────────────────
COMMIT_RE = re.compile(r'(?<![A-Za-z0-9_-])commit(?![A-Za-z0-9_])')   # 빠른 경로(넓게)
TOK_SPLIT = re.compile(r"[\s;&|()<>'\"`=,\[\]{}]+")
def commit_hit(text):
    # 낱말 단위 — commit · commit-tree 토큰만(파일명 commit-review.js 는 아님). '=' 로도 자른다(alias.ci=commit · X=commit)
    return any(t in ('commit', 'commit-tree') for t in TOK_SPLIT.split(text))
FILTERS = {'tail', 'head', 'grep', 'cat', 'wc', 'cut', 'sort', 'uniq', 'tr'}
RO_EXE = {'echo', 'printf', 'true', 'pwd'} | FILTERS
OK_REDIR_TGT = {'/dev/null'}

def redir_ok(c, allow_heredoc=False, allow_in=False):
    for (op, w) in c.redirs:
        o = op.lstrip('0123456789')
        if o in ('>&', '<&') and w.text in ('1', '2') and not w.subst: continue
        if o in ('>', '>>', '&>') and w.text in OK_REDIR_TGT: continue
        if allow_in and o == '<' and not w.subst: continue
        return False
    if c.heredocs and not allow_heredoc: return False
    return True

def toplevel(path):
    env = {k: v for k, v in os.environ.items() if k not in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE')}
    try:
        r = subprocess.run(['git', '-C', path, 'rev-parse', '--show-toplevel'], capture_output=True, text=True, env=env, timeout=5)
    except Exception:
        return None
    if r.returncode != 0: return None
    return os.path.realpath(r.stdout.strip())

def resolve_cd(w, cwd):
    if w.subst: return None
    t = w.text
    home = os.environ.get('HOME', '')
    if t == '~' or t.startswith('~/'): t = home + t[1:]
    for name in ('HOME', 'CLAUDE_PROJECT_DIR', 'PWD'):
        v = os.environ.get(name, '') if name != 'PWD' else cwd
        t = t.replace('${%s}' % name, v).replace('$%s' % name, v) if v else t
    if '$' in t or '\x00' in t: return None
    return os.path.join(cwd, t)

SHORT_OK = re.compile(r'-([qsv]*)([mF]?)(.*)')
def check_commit_cmd(c):
    """허용 형태의 git commit 이면 (True, 메시지 히어독 집합) 아니면 (False, 사유)."""
    ws = c.words; k = 0
    while k < len(ws) and ASSIGN_RE.match(ws[k].raw):
        if not re.fullmatch(r'ALLOW_[A-Z_]+=1', ws[k].raw): return False, 'prefix-assign:' + ws[k].raw
        k += 1
    if k + 1 >= len(ws) or ws[k].raw != 'git' or ws[k + 1].raw != 'commit':
        return False, 'not-plain-git-commit'
    i = k + 2; need_stdin = False; msg_hd = set()
    def msg_word_ok(w):
        if not w.subst: return True
        # 허용: "$(cat <<'X' … X\n)" 만 — 하위 명령이 cat 하나, 인용 구분자 히어독 하나
        if not (w.raw.startswith('"$(') and w.raw.endswith(')"')): return False
        if len(w.nested) != 1: return False
        n = w.nested[0]
        if [x.text for x in n.words] != ['cat'] or n.redirs or len(n.heredocs) != 1: return False
        return n.heredocs[0]['kind'] in ('sq', 'dq', 'bs')
    while i < len(ws):
        w = ws[i]; t = w.text
        if t in ('-q', '--quiet', '-s', '--signoff', '--amend', '--no-edit', '-v', '--verbose'):
            i += 1; continue
        val = None; kind = None
        if t in ('-m', '--message'):
            kind = 'm'; val = ws[i + 1] if i + 1 < len(ws) else None; i += 2
        elif t.startswith('--message='):
            kind = 'm'; val = w; i += 1
        elif t in ('-F', '--file'):
            kind = 'F'; val = ws[i + 1] if i + 1 < len(ws) else None; i += 2
        elif t.startswith('--file='):
            kind = 'F'; val = w; i += 1
            if t == '--file=-': need_stdin = True
        elif t.startswith('-') and not t.startswith('--'):
            m = SHORT_OK.fullmatch(t)
            if not m or (not m.group(2) and m.group(3)) or t == '-':
                return False, 'commit-option:' + t
            kind = m.group(2) or None
            if kind and m.group(3):
                val = w; i += 1
                if kind == 'F' and m.group(3) == '-': need_stdin = True
            elif kind:
                val = ws[i + 1] if i + 1 < len(ws) else None; i += 2
            else:
                i += 1; continue
        else:
            return False, 'commit-arg:' + t   # 경로 인자·-a·-i·-o·--all·-n·-C 등 전부
        if val is None: return False, 'commit-option-value'
        if kind == 'm' and not msg_word_ok(val): return False, 'msg-subst'
        if kind == 'F':
            if val.subst: return False, 'file-subst'
            if val is not w and val.text == '-': need_stdin = True
    if not redir_ok(c, allow_heredoc=True, allow_in=True): return False, 'commit-redirect'
    if len(c.heredocs) > 1: return False, 'multi-heredoc'
    for hd in c.heredocs:
        if hd['kind'] == 'plain' and re.search(r'\$\(|`', hd['body'] or ''):
            return False, 'msg-heredoc-expands'
        msg_hd.add((c, hd['delim']))
    return True, msg_hd

FUNC_RE = re.compile(r'(^|[;&|\s({])(function\s+[A-Za-z_][A-Za-z0-9_-]*|[A-Za-z_][A-Za-z0-9_-]*\s*\(\s*\))')
def has_funcdef(cmd):
    m = re.sub(r"'[^']*'", "''", cmd); m = re.sub(r'"(\\.|[^"\\])*"', '""', m)
    return bool(FUNC_RE.search(m))

def judge_commit(cmd, cwd):
    raw2 = re.sub(r'\\\n', '', cmd).replace("'", '').replace('"', '').replace('\\', '')
    if not COMMIT_RE.search(raw2) and "$'" not in cmd:
        return 'NONE', ''
    try:
        cmds, _ = Lexer(cmd).lex(0)
    except Ambig as e:
        return 'DENY', 'ambiguous:' + str(e)
    if has_funcdef(cmd) and commit_hit(raw2):
        return 'DENY', 'function-def-with-commit-word'   # 함수 본문이 인자를 실행할 수 있다 — commit 낱말이 보이면 판정 불가
    # 메시지 히어독(커밋 자신의 본문)은 판정에서 뺀다 — 단 커밋 명령이 허용 형태일 때만(아래에서 재확인)
    cand = None
    for c in cmds:
        ws = c.words; k = 0
        while k < len(ws) and ASSIGN_RE.match(ws[k].raw): k += 1
        if k + 1 < len(ws) and ws[k].raw == 'git' and ws[k + 1].raw == 'commit':
            if cand is not None: return 'DENY', 'two-commits'
            cand = c
    lt = live_texts(cmds)
    engaged = []
    for (c, text) in lt:
        if commit_hit(text):
            if c is cand:
                continue
            # 커밋 자신의 메시지 하위명령($(cat <<…))·메시지 히어독 본문은 커밋 형태 검사에서 다룬다
            if cand is not None and any(c in flatten(w.nested) for w in cand.words):
                continue
            if cand is not None and c is cand: continue
            engaged.append(c)
    if cand is None and not engaged:
        return 'NONE', ''
    if cand is None:
        return 'DENY', 'commit-word-outside-allowed-form'
    # 메시지 히어독 본문의 commit 낱말은 위 live_texts 에서 cand 소유라 건너뛰었다. 그 밖 engaged 는 거부.
    if engaged:
        return 'DENY', 'commit-word-elsewhere'
    ok, why = check_commit_cmd(cand)
    if not ok: return 'DENY', why
    # 호출 전체 모양: [cd 자기레포 SEP] (RO 파이프 SEP)* [PRE |] COMMIT [| FILTER]* (SEP RO 파이프)*
    for c in cmds:
        if c.depth: return 'DENY', 'group-or-subshell'
    pipes = pipelines(cmds)
    for idx, p in enumerate(pipes):
        if idx and p[0].sep not in ('&&', ';', '\n'): return 'DENY', 'separator:' + p[0].sep
        if cand in p:
            pos = p.index(cand)
            if pos > 1: return 'DENY', 'pre-pipe-long'
            if pos == 1:
                pre = p[0]; b, k = resolve_exe(pre)
                if b not in ('printf', 'echo') or k != exe_idx(pre) or k != 0 or any(w.subst for w in pre.words) or not redir_ok(pre):
                    return 'DENY', 'pre-pipe'
            for f in p[pos + 1:]:
                b, k = resolve_exe(f)
                if b not in FILTERS or k != 0 or any(w.subst for w in f.words) or not redir_ok(f):
                    return 'DENY', 'post-filter'
            continue
        for c in p:
            if c.words and c.words[0].text == 'cd' and len(p) == 1 and idx == 0 and len(c.words) == 2:
                tgt = resolve_cd(c.words[1], cwd)
                if tgt is None or not redir_ok(c): return 'DENY', 'cd-unresolved'
                a, b2 = toplevel(tgt), toplevel(cwd)
                if not a or a != b2: return 'DENY', 'cd-other-repo'
                continue
            if exe_idx(c) != 0: return 'DENY', 'assign-segment'
            if any(w.subst for w in c.words): return 'DENY', 'subst-in-companion'
            if not redir_ok(c): return 'DENY', 'companion-redirect'
            if is_ro_git(c): continue
            b, k = resolve_exe(c)
            if k != 0 or b not in RO_EXE: return 'DENY', 'companion:' + str(b)
    return 'ALLOW', ''

# ───────────────────────── 운영 DB 가드(①②③ + ④ 옵션 허용목록) ─────────────────────────
PY_EXE = re.compile(r'(python|pypy)[0-9.]*')
CONN_WORDS = re.compile(r'pymysql|mysql\.?connector|mysqldb|mysqlclient|import\s+mariadb|from\s+mariadb|mariadb\.connect|aiomysql|asyncmy|sqlalchemy|create_engine|sshtunnel|(^|[^:A-Za-z0-9_])(mysql|mariadb)(\+[a-z0-9_]+)?://', re.I)
DB_CLI_WORD = re.compile(r'(?<![A-Za-z0-9_.-])((mysql|mariadb)[a-z0-9_-]*|mycli)(?![A-Za-z0-9_.])')
PROC_RE = re.compile(r'subprocess|os\.system|os\.popen|os\.exec|os\.spawn|pty\.spawn|commands\.get')
DB_CLI_EXE = re.compile(r'(mysql|mariadb)[a-z0-9_-]*|mycli')
SAFE_READERS = {'grep', 'egrep', 'fgrep', 'rg', 'git', 'echo', 'printf', 'ls', 'cat', 'head', 'tail', 'less', 'brew', 'which', 'type', 'man', 'pgrep', 'ps', 'mvn', 'wc'}
COMPANION_OK = SAFE_READERS | {'cd', 'sleep', 'true', 'false', 'test', '[', 'pwd', 'sort', 'uniq', 'cut', 'tr', 'column', 'tee', 'jq', 'date'}
LONG_OK = {'--host', '--port', '--user', '--password', '--database', '--execute', '--protocol', '--batch', '--silent',
           '--skip-column-names', '--column-names', '--table', '--vertical', '--default-character-set', '--raw',
           '--help', '--version', '--verbose', '--force', '--show-warnings', '--comments', '--ssl-mode', '--compress',
           '--connect-timeout', '--no-data', '--single-transaction', '--routines', '--triggers', '--events',
           '--no-create-info', '--skip-lock-tables', '--result-file', '--where', '--uri', '--sql', '--json'}
SHORT_FLAG = set('BNstvErfACV?')       # 값 없는 짧은 옵션
SHORT_VAL = set('hPuDep')             # 값 받는 짧은 옵션(묶음 맨 앞에서만)
# 값 없이 쓰는 긴 옵션 — --password 는 값을 붙여 쓸 때(--password=…)만 값이 있다(맨 --password 는 프롬프트, 다음 낱말을 먹지 않는다).
LONG_NOVAL = {'--batch', '--silent', '--skip-column-names', '--column-names', '--table', '--vertical', '--raw', '--help',
              '--version', '--verbose', '--force', '--show-warnings', '--comments', '--compress', '--no-data',
              '--single-transaction', '--routines', '--triggers', '--events', '--no-create-info', '--skip-lock-tables',
              '--sql', '--json', '--password'}

def _next_val(ws, i):
    """i 자리 옵션이 다음 낱말을 값으로 먹으면 2, 아니면 1 — 다음 낱말이 '-' 로 시작하면 값으로 먹지 않는다(그 낱말도 옵션으로
    판정된다 — `--password --ssh=…`·`-h --ssh-host …` 가 뒤 옵션을 숨기던 결함의 fail-closed 수리)."""
    return 2 if i + 1 < len(ws) and not ws[i + 1].text.startswith('-') else 1

def db_cli_opts_ok(c, k):
    ws = c.words; proto_tcp = any(re.fullmatch(r'--protocol=tcp', w.text, re.I) for w in ws)
    i = k + 1
    while i < len(ws):
        t = ws[i].text
        if t.startswith('--'):
            name = t.split('=', 1)[0]
            if name.startswith('--ssh'): return False, 'ssh-option:' + name
            if name in ('--socket',):
                if proto_tcp: i += 1 if '=' in t else _next_val(ws, i); continue
                return False, 'socket'
            if name not in LONG_OK: return False, 'long-option-not-allowed:' + name
            i += 1 if ('=' in t or name in LONG_NOVAL) else _next_val(ws, i)
            continue
        if t.startswith('-') and len(t) > 1:
            body = t[1:]
            if body[0] == 'S':
                if proto_tcp: i += 1 if len(body) > 1 else _next_val(ws, i); continue
                return False, 'socket'
            if body[0] in SHORT_VAL:
                i += 1 if len(body) > 1 else (1 if body[0] == 'p' else _next_val(ws, i)); continue
            if all(ch in SHORT_FLAG for ch in body): i += 1; continue
            return False, 'short-bundle:' + t
        i += 1
    return True, ''

# DB 낱말이 살아 있는 호출에서 허용하는 실행어 — 읽기·텍스트 처리·DB 동행 허용 목록(COMPANION_OK·DATA_SAFE 에서 온다).
#   그 안의 도구 옵션으로 실행하는 경로(git -c alias !·mvn exec·less !)는 판정하지 않는다(prod-db-guard.sh ponytail).
#   pip·pip3 는 패키지 조회(`pip3 show pymysql`)용으로 넣는다 — 인자 텍스트를 코드로 실행하지 않는다.
#   로컬 경로 설치(pip install <경로>)의 setup.py 실행은 판정하지 않는다(쓰고-실행 판정 밖).
DB_SAFE_EXE = (COMPANION_OK | DATA_SAFE | {'pip', 'pip3'}) - {'xargs'}

def written_texts(allc):
    """파일로 쓰는 텍스트 — 출력 리다이렉트 대상이 /dev/null·표준 출력/오류 복제가 아닌 명령이나 tee 가 든 파이프라인의
    모든 낱말과 히어독 본문(파이프 앞단이 쓰일 내용을 낸다)."""
    def writes(c):
        if resolve_exe(c)[0] == 'tee': return True
        for (op, w) in c.redirs:
            o = op.lstrip('0123456789')
            if o in ('<', '<<<'): continue
            if o in ('>&', '<&') and w.text in ('1', '2'): continue
            if w.text != '/dev/null': return True
        return False
    out = []
    for p in pipelines(allc):
        if any(writes(c) for c in p):
            for c in p:
                out.append(' '.join(w.text for w in c.words))
                out.extend(hd['body'] or '' for hd in c.heredocs)
    return out

def written_targets(allc):
    """출력 리다이렉트·tee 가 쓰는 파일 낱말(원문 그대로 — 변수 경로는 같은 모양끼리만 맞는다)."""
    out = set()
    for c in allc:
        for (op, w) in c.redirs:
            o = op.lstrip('0123456789')
            if o in ('<', '<<<') or w.text == '/dev/null' or (o in ('>&', '<&') and w.text in ('1', '2')): continue
            out.add(w.text)
        b, k = resolve_exe(c)
        if b == 'tee':
            out.update(w.text for w in c.words[k + 1:] if not w.text.startswith('-'))
    return out

def exec_targets(runners):
    """러너가 실행하는 파일 낱말 — 첫 비옵션 인자와 표준입력 리다이렉트 대상."""
    out = set()
    for c in runners:
        k = runner_idx(c)
        for w in c.words[k + 1:]:
            if not w.text.startswith('-'): out.add(w.text); break
        out.update(w.text for (op, w) in c.redirs if op.lstrip('0123456789') == '<')
    return out

SCRIPT_RUNNERS = RUNNERS | SHELLS | {'source', '.'}
def runner_idx(c):
    """스크립트 러너(셸·node·source)의 낱말 위치 — 첫 실행어가 러너면 그 자리, 안전 목록 밖 실행어(런처 `uv run bash …`·
    `docker exec c sh …`)면 낱말 중 첫 러너 자리. 없으면 None."""
    b, k = resolve_exe(c)
    if k is None or b is None: return None
    if b in SCRIPT_RUNNERS: return k
    if b in DB_SAFE_EXE: return None
    return next((j for j in range(k + 1, len(c.words)) if not c.words[j].subst and not c.words[j].quoted
                 and base(c.words[j].text).lower() in SCRIPT_RUNNERS), None)

TUNNEL_WORD = re.compile(r'(?<![A-Za-z0-9_.-])(auto)?ssh(?![A-Za-z0-9_.-])')
TUNNEL_HINT = re.compile(r'(?<![A-Za-z0-9_])-[A-Za-z]*[LN]|localforward', re.I)
SSH_VAL = set('BbcDEeFIiJLlmOopQRSWw')   # 값을 받는 ssh 짧은 옵션(묶음에서는 그 뒤 글자가 값)
LOCALFWD = re.compile(r'\s*localforward\b', re.I)

def ssh_tunnel(c):
    """ssh·autossh 호출이 로컬 포워딩(-L·-o LocalForward)이나 원격 명령 없는 연결(-N — ssh config 의 LocalForward 터널)이면 사유.
    판정 범위 = 명령줄에 보이는 옵션뿐(config 에 LocalForward 를 둔 `ssh -f host sleep 60` 은 못 본다 — 아래 ponytail)."""
    b, k = resolve_exe(c)
    if k is None: return ''
    if b not in ('ssh', 'autossh'):
        # 런처 경유(`uv run ssh`·`docker exec c ssh`·`find -exec ssh`) — 첫 실행어가 안전 목록 밖이면 낱말 중 ssh·autossh 부터 본다.
        if b in DB_SAFE_EXE: return ''
        j = next((j for j in range(k + 1, len(c.words)) if not c.words[j].subst and not c.words[j].quoted
                  and base(c.words[j].text).lower() in ('ssh', 'autossh')), None)
        if j is None: return ''
        b, k = base(c.words[j].text).lower(), j
    ws = c.words; i = k + 1; host = False
    vals = SSH_VAL | ({'M'} if b == 'autossh' else set())   # autossh -M <감시 포트>
    while i < len(ws):
        t = ws[i].text
        if t == '--' or not t.startswith('-') or t == '-':
            # OpenSSH 는 호스트 뒤에서 옵션을 한 번 더 읽는다(`ssh host -L …`) — 호스트 다음 첫 비옵션부터가 원격 명령이다.
            if host or t == '--': break
            host = True; i += 1; continue
        body = t[1:]; j = 0
        while j < len(body):
            ch = body[j]
            if ch == 'N': return 'ssh-tunnel:-N'
            if ch in vals:
                val = body[j + 1:]
                if not val and _next_val(ws, i) == 2:   # '-' 로 시작하는 다음 낱말은 값으로 먹지 않는다(그 낱말도 옵션 판정)
                    val = ws[i + 1].text
                    i += 1
                if ch == 'L': return 'ssh-tunnel:-L'
                if ch == 'o' and LOCALFWD.match(val): return 'ssh-tunnel:LocalForward'
                break
            j += 1
        i += 1
    return ''
# ponytail: ssh config 의 LocalForward 를 -N 없이 여는 호출(`ssh -f host sleep 60`)·socat·kubectl port-forward·ncat 단독 터널은
#   못 막는다 — 다음 호출의 localhost 표준 포트 접속을 가리지 못한다 / 업그레이드 = 네트워크 층 차단(운영 DB 송신 자체 차단)

def judge_db(cmd):
    raw2 = re.sub(r'\\\n', '', cmd).replace("'", '').replace('"', '').replace('\\', '')
    hot = CONN_WORDS.search(raw2) or DB_CLI_WORD.search(raw2.lower()) or TUNNEL_WORD.search(raw2) or "$'" in cmd
    if not hot:
        return 'ALLOW', ''
    try:
        cmds, _ = Lexer(cmd).lex(0)
    except Ambig as e:
        # 해석 불가 — DB 낱말(커넥터·CLI 이름)이나 터널 모양(ssh + -L·-N·LocalForward)이 보일 때만 차단(N2).
        # 안 보이면 CLI 층 판정으로 넘긴다.
        if CONN_WORDS.search(raw2) or DB_CLI_WORD.search(raw2.lower()) \
                or (TUNNEL_WORD.search(raw2) and TUNNEL_HINT.search(raw2)):
            return 'DENY', 'ambiguous:' + str(e)
        return 'ALLOW', ''
    if has_funcdef(cmd) and CONN_WORDS.search(raw2):
        return 'DENY', 'function-def-with-db-words'
    lt = live_texts(cmds)
    allc = []
    seen = set()
    for c0 in flatten(cmds):
        for c in [c0] + [n for x in shell_c_nested(c0) for n in flatten([x])]:
            if id(c) not in seen: seen.add(id(c)); allc.append(c)
    # ⑤ 단독 터널 생성(ssh·autossh 의 -L·LocalForward·-N) — 다음 호출의 localhost 접속이 운영 DB 로 갈 수 있다.
    for c in allc:
        why = ssh_tunnel(c)
        if why: return 'DENY', why
    # DB 낱말 = 커넥터 낱말, 또는 프로세스 실행 API 와 DB CLI 이름이 같은 텍스트에(N11 subprocess 로 mysql) — 경로 조각 mysql/ 오탐 회피
    db_words_live = any(CONN_WORDS.search(t) or (PROC_RE.search(t) and DB_CLI_WORD.search(t)) for (_, t) in lt)
    conn_words_live = any(CONN_WORDS.search(t) for (_, t) in lt)
    # python 실행 = 첫 실행어가 아니라 **명령 낱말 어디든** python 실행어(치환 아닌 낱말)가 있으면 — 런처 경유
    #   (`uv run python`·`poetry run python3`·`conda run -n x python`·`find -exec python3`·`docker exec c python`)도 같다.
    py = [c for c in allc if any(not w.subst and PY_EXE.fullmatch(base(w.text).lower()) for w in c.words)]
    if db_words_live and py:
        return 'DENY', 'python-with-db-words'
    # 허용 목록 원칙 — DB 낱말이 살아 있는 텍스트를 **받는** 실행어는 판정 가능한 안전 목록(DB_SAFE_EXE)·DB CLI 안이어야 한다.
    #   받는다 = 그 실행어 자신의 낱말·히어독에 있거나 같은 파이프라인 앞단에서 흘러든다. 목록 밖(런처·모르는 명령·
    #   변수/치환 실행어)이 받으면 그 낱말을 실행할 수 있다고 보고 차단한다(같은 호출의 무관한 sed·mkdir 은 보지 않는다).
    hot_ids = {id(c) for (c, t) in lt if CONN_WORDS.search(t) or (PROC_RE.search(t) and DB_CLI_WORD.search(t))}
    for pl in pipelines(allc):
        upstream = False
        for c in pl:
            b = resolve_exe(c)[0]
            own = id(c) in hot_ids
            if (own or upstream) and b is not None and (b == '?' or (b not in DB_SAFE_EXE and not DB_CLI_EXE.fullmatch(b))):
                return 'DENY', 'db-words-to-unlisted-exe:' + b
            upstream = upstream or own
    # 쓰고 실행 — 같은 호출에 python 실행·스크립트 러너(셸·node)가 있으면 파일로 쓰는 텍스트는 문서 확장자여도 데이터가 아니다
    #   (F1 의 DOC_EXT 면제는 같은 호출에 그런 실행이 없을 때만 — 실행 대상이 그 파일인지는 따지지 않는다: 이름 바꾸기·복사·
    #   변수 경로로 쉽게 갈라진다). 쓰인 텍스트에 커넥터 낱말이 있으면 차단. DB CLI 낱말은 셸 러너가 쓴 파일 자체를 실행할 때만 본다
    #   (셸 러너에 넘기는 프롬프트·문서에 mariadb 같은 낱말이 흔하다).
    runners = [c for c in allc if runner_idx(c) is not None]
    wt = written_texts(allc)
    if (py or runners) and any(CONN_WORDS.search(t) or (PROC_RE.search(t) and DB_CLI_WORD.search(t)) for t in wt):
        return 'DENY', 'write-then-exec-db-words'
    if runners and any(DB_CLI_WORD.search(t.lower()) for t in wt) and (written_targets(allc) & exec_targets(runners)):
        return 'DENY', 'write-then-exec-db-cli'
    # DB CLI 를 런처가 실행(`uv run mysql`·`docker exec c mysql`·`find -exec mysql`) — 첫 실행어가 아니어도 낱말로 본다.
    for c in allc:
        b, k = resolve_exe(c)
        if b in DB_SAFE_EXE or (b and DB_CLI_EXE.fullmatch(b)): continue
        if any(not w.subst and not w.quoted and DB_CLI_EXE.fullmatch(base(w.text).lower()) for w in c.words):
            return 'DENY', 'db-cli-via-launcher:' + str(b)
    conn_cli = []
    for c in allc:
        b, k = resolve_exe(c)
        if b and b != '?' and DB_CLI_EXE.fullmatch(b):
            rest = [w.text for w in c.words[k + 1:]]
            if rest and all(t in ('--help', '--version', '-V', '-?') for t in rest):
                continue
            conn_cli.append((c, k))
    if conn_cli:
        for c in allc:
            b, k = resolve_exe(c)
            if b is None: continue
            if b == '?' : return 'DENY', 'non-literal-exe'
            if DB_CLI_EXE.fullmatch(b): continue
            if b not in COMPANION_OK: return 'DENY', 'companion:' + b
        for (c, k) in conn_cli:
            ok, why = db_cli_opts_ok(c, k)
            if not ok: return 'DENY', why
    return 'ALLOW', ''

class _Limit(BaseException):   # 판정 함수 안의 `except Exception` 이 시간 초과를 삼키지 않게 BaseException 계열로 둔다
    pass

def _on_alarm(signum, frame):
    raise _Limit()

def main(argv, data, limit=LIMIT_SEC):
    """(출력 줄, rc). 판정 불가(인자·예외·시간 초과)는 DENY + rc≠0 — 호출부는 rc≠0 을 deny 로 받는다."""
    mode = argv[1] if len(argv) > 1 else ''
    if mode not in ('commit', 'db'):
        return 'DENY\tusage', 2
    old = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(limit)
    try:
        cmd = data.decode('utf-8')
        if mode == 'commit':
            d, why = judge_commit(cmd, argv[2] if len(argv) > 2 else os.getcwd())
        else:
            d, why = judge_db(cmd)
        return d + ('\t' + why if why else ''), 0
    except _Limit:
        return 'DENY\t판정기 시간 초과', 3
    except Exception as e:   # RecursionError·UnicodeDecodeError 포함 — 판정 불가 = 차단
        return 'DENY\t판정기 예외(%s)' % type(e).__name__, 3
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)

if __name__ == '__main__':
    out, rc = main(sys.argv, sys.stdin.buffer.read())
    print(out)
    sys.exit(rc)
