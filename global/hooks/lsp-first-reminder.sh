#!/usr/bin/env bash
# PreToolUse(Bash) 소프트 리마인더 — "Java 심볼 탐색은 LSP 우선(grep보다)" 규칙(CLAUDE.md 🔌MCP)의 보강.
# grep/rg 가 **.java 로만** 스코프되고 "검색 패턴 인자"가 **심볼 모양**일 때만 비차단 리마인더(additionalContext)를
# 주입한다. 차단하지 않는다(방법론 넛지, 안전critical 아님).
#   - 판정 단위 = 명령 전체가 아니라 grep/rg 호출 "세그먼트"(;·&&·||·| 로 분할한 조각) 하나하나.
#   - 발동(한 세그먼트 안에서 AND):
#       ①grep/egrep/fgrep/rg/ripgrep 호출
#       ②Java **전용** 스코프 — --include=*.java·-g/--glob *.java·-t java·대상 경로가 .java/자바 소스 디렉터리이고,
#         **비Java 스코프가 하나도 섞이지 않았을 때**(--include=*.xml 병기·resources/·templates/·static/·.xml·.js·.md·
#         .html·.properties 경로가 하나라도 있으면 텍스트 검색으로 보고 침묵)
#       ③"검색 패턴 인자"(-e 값 또는 첫 비옵션 인자)가 **심볼 모양** — 앵커(^·$·\b)·후행 `\(`/`(` 를 벗긴 나머지가
#         `[A-Za-z_][A-Za-z0-9_.]*` 이고 camel/Pascal 험프를 가지거나, `class|interface|implements|extends|new` +
#         PascalCase 정의 검색. 대안(|)은 갈래 전부가 심볼일 때만. 공백·문자클래스·수량자가 든 정규식 = 텍스트 패턴 → 침묵.
#   - 미발동: XML/properties/템플릿/JS grep, 혼합 스코프 grep, 한글·비ASCII 검색어, 파일경로만 PascalCase 인 경우,
#            밑줄 DB식별자(tn_mbr_info) 검색, 문장·정규식 검색 등.
#   - 2026-09-03 조건 축소: 이전 판정(Java 스코프 + 험프)은 XML·JS·md 가 섞인 grep 에도 50회+ 발화했고 유효 0 이었다.
# 안전: jq/python3 부재·JSON 파싱 실패·셸 파싱 실패 → 조용히 exit 0. 절대 deny/ask 하지 않음(fail-open).
set -u

input=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# 판정은 python3(shlex)로 — 셸 인용/옵션-값 구조를 지켜야 "패턴 인자"와 "경로 인자"를 가를 수 있다.
# 매치 시 exit 0, 아니면 exit 1(=리마인더 없음).
# ponytail: shlex 로 못 푸는 셸 구성($( ) 치환·복잡한 리다이렉션)은 침묵 처리(오탐보다 미탐 선택) /
#           업그레이드 경로 = 필요해지면 bash -n 수준 파서 도입
LSP_HOOK_CMD="$cmd" python3 - <<'PY' || exit 0
import os, re, shlex, sys

cmd = os.environ.get("LSP_HOOK_CMD", "")

try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lex.whitespace_split = True  # commenters 는 기본값(#) 유지 — 후행 셸 주석의 .java 스침을 배제
    tokens = list(lex)
except ValueError:
    sys.exit(1)  # 인용 불균형 등 파싱 실패 → 침묵

GREPS = {"grep", "egrep", "fgrep", "rg", "ripgrep", "ggrep"}
# 값을 하나 더 먹는 옵션(다음 토큰이 패턴 아님)
VALUE_OPTS = {
    "-e", "--regexp", "-f", "--file", "--include", "--exclude", "--exclude-dir",
    "--exclude-from", "-m", "--max-count", "-A", "-B", "-C", "--after-context",
    "--before-context", "--context", "-g", "--glob", "--iglob", "-t", "--type",
    "-T", "--type-not", "--color", "--colour", "-d", "--directories",
    "--binary-files", "--sort", "-j", "--threads", "-M", "--max-columns",
}
GLOB_OPTS = {"--include", "-g", "--glob", "--iglob"}
TYPE_OPTS = {"-t", "--type"}
HUMP = re.compile(r"[a-z][A-Z][a-z]|[A-Z][a-z]+[A-Z]")
SYMBOL = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*")
DEFN = re.compile(r"^(class|interface|enum|implements|extends|new)\s+[A-Z][A-Za-z0-9_]*$")
NONJAVA_EXT = (".xml", ".js", ".mjs", ".ts", ".md", ".html", ".properties", ".yml", ".yaml", ".json", ".sql", ".css", ".scss", ".txt")
NONJAVA_DIR = ("resources/", "templates/", "static/", "docs/", "html/")


def is_operator(tok):
    return tok != "" and all(c in ";|&()<>\n" for c in tok)


def scope_kind(name, val):
    """옵션 값이 가리키는 스코프: 'java' / 'other' / None(판정 불가)."""
    if name in TYPE_OPTS:
        return "java" if val == "java" else "other"
    if ".java" in val:
        return "java"
    return "other" if val else None


def path_kind(p):
    q = p.rstrip("/")
    if q.endswith(".java") or "src/main/java" in q or "src/test/java" in q or q.endswith("/java"):
        return "java"
    if q.endswith(NONJAVA_EXT) or any(d in q + "/" for d in NONJAVA_DIR):
        return "other"
    return None  # 모듈 루트·src 등 상위 디렉터리 = 혼합 → 단독으로는 Java 스코프가 아님


def one_symbol(p):
    p = p.strip()
    if DEFN.match(p):
        return True
    p = re.sub(r"^(\^|\\b|\\<)+", "", p)
    p = re.sub(r"(\\\(|\(|\\b|\\>|\$)+$", "", p)
    if not p or not SYMBOL.fullmatch(p):
        return False  # 공백·문자클래스·수량자 = 텍스트/정규식 검색
    return bool(HUMP.search(p))


def symbol_shaped(pattern):
    try:
        pattern.encode("ascii")
    except UnicodeEncodeError:
        return False  # 한글 등 비ASCII 검색어 = 심볼 탐색 아님
    p = pattern.strip()
    if p.startswith("(") and p.endswith(")"):
        p = p[1:-1]
    # 대안(|)은 갈래 전부가 심볼일 때만 심볼 검색으로 본다(`MbrInfo|mbrInfo` = 발화, `readLsn|room id` = 침묵)
    parts = re.split(r"(?<!\\)\|", p)
    return all(one_symbol(x) for x in parts)


def segments(toks):
    out, seg = [], []
    for t in toks:
        if is_operator(t):
            if seg:
                out.append(seg)
            seg = []
        else:
            seg.append(t)
    if seg:
        out.append(seg)
    return out


def hits(seg):
    if not seg or os.path.basename(seg[0]) not in GREPS:
        return False
    args = seg[1:]
    pattern = None
    kinds = set()
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional.extend(args[i + 1:])
            break
        if a.startswith("-") and a != "-":
            name, eq, val = a.partition("=")
            if eq:
                if name in GLOB_OPTS or name in TYPE_OPTS:
                    kinds.add(scope_kind(name, val))
                if name in ("-e", "--regexp") and pattern is None:
                    pattern = val
                i += 1
                continue
            if name in VALUE_OPTS:
                val = args[i + 1] if i + 1 < len(args) else ""
                if name in GLOB_OPTS or name in TYPE_OPTS:
                    kinds.add(scope_kind(name, val))
                if name in ("-e", "--regexp") and pattern is None:
                    pattern = val
                i += 2
                continue
            if re.fullmatch(r"-t[A-Za-z]+", a):  # rg -tjava / -txml
                kinds.add("java" if a[2:] == "java" else "other")
            i += 1
            continue
        positional.append(a)
        i += 1

    if pattern is None:
        if not positional:
            return False
        pattern = positional[0]
        paths = positional[1:]
    else:
        paths = positional

    for p in paths:
        kinds.add(path_kind(p))
    kinds.discard(None)
    # Java 전용 스코프일 때만(비Java 스코프가 하나라도 섞이면 텍스트 검색으로 본다)
    if kinds != {"java"}:
        return False
    return symbol_shaped(pattern)


sys.exit(0 if any(hits(s) for s in segments(tokens)) else 1)
PY

reason="[LSP 우선 리마인더] Java 심볼(클래스/메서드/필드)의 정의·참조·구현체·호출계층·영향도 탐색은 grep 대신 LSP를 쓰세요(CLAUDE.md 🔌MCP 규약).
  - 참조 찾기: LSP findReferences (인터페이스 전체 지형은 findReferences + goToImplementation 조합)
  - 정의 이동: goToDefinition / 심볼 검색: workspaceSymbol
grep 은 XML 매퍼·템플릿·설정 등 '텍스트 패턴' 검색에만. (이 리마인더는 차단이 아니며, 실제로 텍스트 검색이었다면 무시하고 진행하세요.)"

jq -n --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$r}}'
exit 0
