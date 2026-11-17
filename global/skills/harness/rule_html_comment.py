"""룰 U(차단): 템플릿에서 브라우저로 나가는 개발 주석.

check_conventions.py 가 이미 커서 따로 둔 모듈이다(같은 디렉터리에서 import).
레포 옵트인 = .claude/lint-template-comment.enabled — 응답에 주석을 싣지 않기로 정한 레포만 막는다.

Thymeleaf 는 일반 HTML 주석 `<!-- -->` 과 인라인 <script>·<style> 본문의 JS·CSS 주석을 렌더 결과에
그대로 남긴다. 그래서 개발 주석은 파서 주석 `<!--/* */-->` 으로만 쓴다(렌더 때 제거된다).
판정(템플릿 루트 안 .html):
  U1. <script>·<style> 본문 밖의 `<!--` 가 `<!--/*` 로 시작하지 않으면 위반. IE 조건부 주석
      `<!--[if …]>`·`<![endif]-->` 는 동작 마크업이라 제외.
  U2. <script> 본문의 `//`·`/* */` 주석과 <style> 본문의 `/* */` 주석은 위반. Thymeleaf 텍스트 문법
      (`/*[[…]]*/`·`/*[(…)]*/`·`/*[- … -]*/`·`/*[# …]*/`·`/*[/]*/`)은 `/*[` 로 시작하므로 제외.
예외 마커 = 그 줄의 lint-comment-ok.

// ponytail: JS 정규식 리터럴 안의 `//`·`/*` 는 주석으로 오판할 수 있다 / 오탐이 나면 그 줄에 마커를 단다.
"""
import re

COMMENT_OK_MARKER = "lint-comment-ok"
RULE_MARKER = "lint-template-comment.enabled"

_BLOCK_RE = re.compile(r"<(script|style)\b[^>]*>(.*?)</\1\s*>", re.S | re.I)
_HTML_COMMENT_RE = re.compile(r"<!--")
_ANY_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
# 문자열·템플릿 리터럴을 먼저 소비해 그 안의 `//`·`/*` 를 주석으로 보지 않는다.
_JS_TOKEN_RE = re.compile(
    r"(//[^\n]*)"
    r"|(/\*.*?\*/)"
    r"|'(?:\\.|[^'\\\n])*'"
    r'|"(?:\\.|[^"\\\n])*"'
    r"|`(?:\\.|[^`\\])*`",
    re.S)
_CSS_TOKEN_RE = re.compile(
    r"(/\*.*?\*/)"
    r"|'(?:\\.|[^'\\\n])*'"
    r'|"(?:\\.|[^"\\\n])*"',
    re.S)


def _line_of(text, index):
    return text.count("\n", 0, index) + 1


def check_template_comment(path, raw):
    """(line, message) 목록."""
    found = []
    lines = raw.splitlines()

    def marked(ln):
        return 0 < ln <= len(lines) and COMMENT_OK_MARKER in lines[ln - 1]

    # 주석 본문에 적힌 `<script>` 글자를 태그로 보지 않도록 주석 구간을 가린 뷰에서 블록을 찾는다.
    view = _ANY_COMMENT_RE.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), raw)
    blocks = [(m.group(1).lower(), m.start(2), m.end(2)) for m in _BLOCK_RE.finditer(view)]

    def in_block(idx):
        return any(start <= idx < end for _, start, end in blocks)

    for m in _HTML_COMMENT_RE.finditer(raw):
        if in_block(m.start()):
            continue
        rest = raw[m.end():m.end() + 2]
        if rest.startswith("/*") or rest.startswith("["):
            continue
        ln = _line_of(raw, m.start())
        if marked(ln):
            continue
        found.append((ln, "[U:전송주석] %s:%d — `<!--` 주석은 응답 HTML 에 그대로 실린다 → `<!--/* … */-->`"
                          "(예외 = %s 마커)" % (path, ln, COMMENT_OK_MARKER)))

    for kind, start, end in blocks:
        body = raw[start:end]
        token_re = _JS_TOKEN_RE if kind == "script" else _CSS_TOKEN_RE
        for t in token_re.finditer(body):
            comment = t.group(1) if kind == "style" else (t.group(1) or t.group(2))
            if not comment or comment.startswith("/*["):
                continue
            ln = _line_of(raw, start + t.start())
            if marked(ln):
                continue
            found.append((ln, "[U:전송주석] %s:%d — 인라인 <%s> 본문의 주석은 응답에 그대로 실린다"
                              " → 블록 밖 `<!--/* … */-->` 로 옮긴다(예외 = %s 마커)"
                              % (path, ln, kind, COMMENT_OK_MARKER)))
    return found
