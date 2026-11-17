"""룰 S(경고 전용): 트랜잭션 없이 여러 번 쓰는 서비스 메서드 · 룰 V(경고 전용): select* 안의 쓰기(파일 아래쪽 절).

check_conventions.py 가 이미 커서 따로 둔 모듈이다(같은 디렉터리에서 import).

판정 = `@Service` 가 붙은 *Impl.java 의 public 메서드 중 @Transactional 이 없는데 쓰기 호출이 2회 이상인 것.
  · 쓰기 호출 = 수신자 이름이 Mapper·Dao·Service 로 끝나고(this. 제외) 메서드명이 쓰기 동사로 시작하는 호출.
  · 같은 클래스 메서드를 수신자 없이 부르면(self-invocation — 프록시를 안 거친다) 그 본문의 쓰기도 합산한다.
제외 = 메서드·클래스의 @Transactional · 본문의 TransactionTemplate 사용 · 예외 마커 lint-tx-ok
      (메서드 선언부 위 주석·어노테이션 구간 또는 선언 줄에 둔다 — 문장별 autocommit 이 의도인 곳).

// ponytail: 루프 안 단일 쓰기(일괄 처리)·읽고 검사한 뒤 쓰기(경합)·인터페이스 기본 메서드는 못 본다
//           / 필요해지면 루프 본문 쓰기를 ×2 로 세는 규칙을 더한다.
"""
import os
import re

TX_OK_MARKER = "lint-tx-ok"

_BLANK_RE = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', re.S)
_METHOD_RE = re.compile(
    r'^[ \t]*(public|protected|private)\s+(?:static\s+|final\s+|synchronized\s+)*'
    r'(?:<[^>{};]*>\s*)?[\w$<>\[\],.?\s]+?\s+(\w+)\s*\(', re.M)
_WRITE_CALL_RE = re.compile(
    r'(?<![\w$])(\w*(?:Mapper|Dao|DAO|Service))\s*\.\s*'
    r'((?:create|modify|delete|insert|update|restore|save|merge|upsert)\w*)\s*\(')
_SELF_CALL_RE = re.compile(r'(?<![\w$.])(?:this\s*\.\s*)?(\w+)\s*\(')
_STMT_WORDS = {"if", "for", "while", "switch", "catch", "return", "new", "throw", "synchronized", "super", "this"}


def _blank(match):
    # 줄 수 보존 — 개행만 남기고 공백으로.
    return re.sub(r'[^\n]', ' ', match.group(0))


def _match_brace(text, open_idx):
    depth = 0
    for i in range(open_idx, len(text)):
        ch = text[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1


def _parse_methods(raw, view):
    """메서드 목록: dict(name, public, head, body, sig_line, start_line, end_line)."""
    methods = []
    prev_end = 0
    for m in _METHOD_RE.finditer(view):
        if m.start() < prev_end:
            continue  # 앞 메서드 본문 안(익명 클래스 등)
        name = m.group(2)
        if name in _STMT_WORDS:
            continue
        # 시그니처의 ')' 뒤 첫 '{' 또는 ';'(추상) 까지.
        depth, i = 0, m.end() - 1
        while i < len(view):
            if view[i] == '(':
                depth += 1
            elif view[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        j = i + 1
        while j < len(view) and view[j] not in '{;':
            j += 1
        if j >= len(view) or view[j] == ';':
            continue
        close = _match_brace(view, j)
        if close < 0:
            continue
        methods.append({
            "name": name,
            "public": m.group(1) == "public",
            "head_raw": raw[prev_end:m.end()],      # 직전 멤버 끝 ~ 선언 줄: 어노테이션·주석·마커 자리
            "head_view": view[prev_end:m.end()],
            "body": view[j + 1:close],
            "sig_line": view.count('\n', 0, m.start()) + 1,
            "end_line": view.count('\n', 0, close) + 1,
        })
        prev_end = close + 1
    return methods


_IF_HEAD_RE = re.compile(r'\bif\s*\((?:.|\n)*\)\s*$')
_ELSE_GAP_RE = re.compile(r'^\s*else\s*(?:if\s*\((?:.|\n)*\)\s*)?$')


def _linear(text, by_name, visiting):
    count = len(_WRITE_CALL_RE.findall(text))
    for call in _SELF_CALL_RE.finditer(text):
        callee = by_name.get(call.group(1))
        if callee is not None:
            count += _writes(callee, by_name, visiting)
    return count


def _count_block(text, by_name, visiting):
    """중괄호 블록 단위로 센다 — if/else if/else 사슬은 서로 배타라 가지 중 최댓값만."""
    blocks, depth, start = [], 0, -1
    for i, ch in enumerate(text):
        if ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                blocks.append((start, i))
    total, cursor, chain = 0, 0, None   # chain = 진행 중인 if 사슬의 가지별 쓰기 수
    for b_start, b_end in blocks:
        gap = text[cursor:b_start]
        inner = _count_block(text[b_start + 1:b_end], by_name, visiting)
        if chain is not None and _ELSE_GAP_RE.match(gap):
            total += _linear(gap, by_name, visiting)
            chain.append(inner)
        else:
            if chain is not None:
                total += max(chain)
            total += _linear(gap, by_name, visiting)
            chain = [inner] if _IF_HEAD_RE.search(gap) else None
            if chain is None:
                total += inner
        cursor = b_end + 1
    if chain is not None:
        total += max(chain)
    return total + _linear(text[cursor:], by_name, visiting)


def _writes(method, by_name, visiting):
    if method["name"] in visiting or "TransactionTemplate" in method["body"] \
            or "transactionTemplate" in method["body"]:
        return 0  # 순환 · 자기 트랜잭션을 여는 메서드(그 안의 쓰기는 이미 원자적)
    return _count_block(method["body"], by_name, visiting | {method["name"]})


def check_java_tx_multiwrite(path, raw):
    """(line, message, line_range) 목록 — line_range 는 메서드 전체 줄(changed-only 필터용)."""
    norm = path.replace("\\", "/")
    if not norm.endswith("Impl.java") or "/src/main/" not in norm or "@Service" not in raw:
        return []
    view = _BLANK_RE.sub(_blank, raw)
    class_m = re.search(r'\bclass\s+\w+', view)
    if class_m is None:
        return []
    class_head = view[:class_m.start()]
    if "@Transactional" in class_head or TX_OK_MARKER in raw[:class_m.start()]:
        return []
    methods = _parse_methods(raw, view)
    by_name = {}
    for meth in methods:
        by_name.setdefault(meth["name"], meth)  # 오버로드는 첫 정의로 근사
    found = []
    for meth in methods:
        if not meth["public"]:
            continue
        if "@Transactional" in meth["head_view"] or TX_OK_MARKER in meth["head_raw"]:
            continue
        if "TransactionTemplate" in meth["body"] or "transactionTemplate" in meth["body"]:
            continue
        n = _writes(meth, by_name, frozenset())
        if n >= 2:
            line = meth["sig_line"]
            found.append((line,
                          "[S:트랜잭션] %s:%d — '%s' 가 @Transactional 없이 쓰기 %d회(중간 실패 시 부분 반영) → "
                          "@Transactional(rollbackFor = Exception.class) · 문장별 autocommit 이 의도면 %s 마커"
                          % (path, line, meth["name"], n, TX_OK_MARKER),
                          range(line, meth["end_line"] + 1)))
    return found


def filter_by_lines(found, allowed):
    """allowed: 'ALL' | None(신규 파일) | set(변경 줄). 메서드 안 어느 줄이든 바뀌었으면 보고한다."""
    if allowed == "ALL" or allowed is None:
        return [msg for _, msg, _ in found]
    return [msg for _, msg, rng in found if any(ln in allowed for ln in rng)]


# ── 룰 V(경고 전용): read-only 트랜잭션(select*) 안의 쓰기 ─────────────────────────
# context-transaction.xml 의 `tx:method name="select*" read-only="true"` 아래에서는 select* 가 읽기 전용
# 트랜잭션(복제 URL 이 켜지면 슬레이브)으로 열리고, 전파 REQUIRED 라 그 안에서 부른 다른 서비스의 쓰기까지
# 같은 read-only 를 물려받아 실패한다. 판정 = *Impl.java 의 public select* 메서드 본문에 쓰기 호출이 1회라도
# 있으면(룰 S 와 같은 _WRITE_CALL_RE · self-invocation 본문 합산). masterSelect* 는 select 로 시작하지 않아 제외.
# 예외 마커 lint-select-write-ok — 위치 규칙은 lint-tx-ok 와 같다(메서드 선언부 위 구간·선언 줄, 또는 클래스 머리).
# ponytail: 매퍼 XML 의 <select id> 안 UPDATE·DB 함수의 쓰기·람다/익명 클래스 안 호출 구분·
#           수신자 이름이 Mapper/Dao/Service 로 안 끝나는 쓰기는 못 본다 / 필요하면 매퍼 XML statement 종류를 대조한다.
SELECT_WRITE_OK_MARKER = "lint-select-write-ok"
# ponytail: 킷 사본은 '항상 발동' 레포 basename 을 __SELECT_WRITE_ALWAYS_REPO__ 자리표시로 둔다(형제 레포 실명 비반출) — 치환하지 않으면
#           어떤 basename 과도 맞지 않아 XML 탐지만 돈다(안전 쪽) / 업그레이드 = basename 목록을 환경변수·설정 파일로 받아 라이브·킷 로직 동일화.
_SELECT_NAME_RE = re.compile(r'^select(?=[A-Z0-9_]|$)')
# 판정 = <method …> 태그 하나(접두사 tx: 등은 선택) 안에 name="select*" 와 read-only="true" 가 함께 있는가(속성 순서 무관).
# ponytail: 정규식 태그 분리라 속성값 안의 '>'·주석·CDATA 를 구분하지 못한다 / 업그레이드 = xml.etree 로 method 요소 순회(파싱 실패 시 이 정규식으로 폴백).
_TX_METHOD_TAG_RE = re.compile(r'<(?:[\w.-]+:)?method\b[^>]*>', re.I)
_SELECT_STAR_NAME_RE = re.compile(r'\bname\s*=\s*["\']select\*["\']', re.I)
_READ_ONLY_TRUE_RE = re.compile(r'\bread-only\s*=\s*["\']true["\']', re.I)


def _has_readonly_select(text):
    return any(_SELECT_STAR_NAME_RE.search(tag.group(0)) and _READ_ONLY_TRUE_RE.search(tag.group(0))
               for tag in _TX_METHOD_TAG_RE.finditer(text))


_TX_XML_NAME = "context-transaction.xml"
_TX_XML_PRUNE = set(["target", "build", "out", "bin", ".git", ".idea", "node_modules"])


def select_write_enabled(project_root):
    """룰 V 발동 여부. basename 이 __SELECT_WRITE_ALWAYS_REPO__ 인 레포는 항상(XML 규칙이 없는 브랜치에서도 같은 명명 규칙을 쓰는 레포),
    그 밖의 레포는 context-transaction.xml 에 select* read-only 규칙이나 masterSelect 가 있을 때만."""
    root = os.path.abspath(project_root)
    if os.path.basename(root) == "__SELECT_WRITE_ALWAYS_REPO__":
        return True
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in _TX_XML_PRUNE]
        if _TX_XML_NAME not in files:
            continue
        try:
            with open(os.path.join(current, _TX_XML_NAME), "rb") as handle:
                text = handle.read().decode("utf-8", "replace")
        except (IOError, OSError):
            continue
        if _has_readonly_select(text) or "masterSelect" in text:
            return True
    return False


def _collect_writes(method, by_name, visiting):
    """쓰기 호출 표기 목록. self-invocation 은 'callee→recv.meth' 로 표기한다(프록시를 안 거쳐 같은 트랜잭션)."""
    body = method["body"]
    calls = ["%s.%s" % (m.group(1), m.group(2)) for m in _WRITE_CALL_RE.finditer(body)]
    for call in _SELF_CALL_RE.finditer(body):
        name = call.group(1)
        callee = by_name.get(name)
        if callee is None or name in visiting:
            continue
        for inner in _collect_writes(callee, by_name, visiting | {name}):
            calls.append("%s→%s" % (name, inner))
    return calls


def check_java_select_write(path, raw):
    """(line, message, line_range) 목록 — filter_by_lines 로 변경 줄 스코프를 건다."""
    norm = path.replace("\\", "/")
    if not norm.endswith("Impl.java") or "/src/main/" not in norm:
        return []
    view = _BLANK_RE.sub(_blank, raw)
    class_m = re.search(r'\bclass\s+\w+', view)
    if class_m is None or SELECT_WRITE_OK_MARKER in raw[:class_m.start()]:
        return []
    methods = _parse_methods(raw, view)
    by_name = {}
    for meth in methods:
        by_name.setdefault(meth["name"], meth)  # 오버로드는 첫 정의로 근사(룰 S 와 같다)
    found = []
    for meth in methods:
        if not meth["public"] or not _SELECT_NAME_RE.match(meth["name"]):
            continue  # 프록시가 가로채는 것은 public 뿐 — private select* 는 호출자 쪽 본문에서 합산된다
        if SELECT_WRITE_OK_MARKER in meth["head_raw"]:
            continue
        calls = _collect_writes(meth, by_name, frozenset([meth["name"]]))
        if not calls:
            continue
        shown = ", ".join(calls[:3]) + (" 외 %d건" % (len(calls) - 3) if len(calls) > 3 else "")
        line = meth["sig_line"]
        found.append((line,
                      "[V:읽기전용쓰기] %s:%d — '%s' (select* = read-only 트랜잭션) 안 쓰기 호출: %s → "
                      "masterSelect* 로 개명하거나 쓰기를 insert/update/delete 메서드로 분리 · 의도면 %s 마커"
                      % (path, line, meth["name"], shown, SELECT_WRITE_OK_MARKER),
                      range(line, meth["end_line"] + 1)))
    return found
