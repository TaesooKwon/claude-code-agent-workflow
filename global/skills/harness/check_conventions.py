#!/usr/bin/env python3
"""프로젝트 컨벤션 정적 검사(텍스트 룰) — harness 빌드 게이트용.

CLAUDE.md 규약 중 컴파일·계약검사로는 안 잡히던 "글로만 있던 규칙"을 자동강제로 끌어올린다.
룰 목록(전부 텍스트/정규식·git diff 수준). 살아 있는 룰 문자의 모집단 조회 =
`grep -n '^  [A-Z]\. ' 이_파일` — 개수를 세어 적지 않는다(룰을 하나 더하면 조용히 거짓이 된다):

  A. SELECT * 금지            (매퍼 XML)
  B. 매퍼 statement id 동작접두어  (insert/save/update/edit/remove/select/get/list/find 금지 → create/modify/delete/read)
  C. AG Grid 구버전 체크박스 방식  (rowSelection:'multiple' / headerCheckboxSelection / checkboxSelection)
  D. 퍼블 공통 JS 수정 금지        (common.js · js/common/** 변경 차단 — git diff 기반)
  E. CDATA 강제               (매퍼 XML — SQL 텍스트의 엔티티 비교연산자 &lt;=/&gt;=/&lt;&gt;/단독 &lt;·&gt; 금지 → <![CDATA[ ... ]]>.
                               CDATA 내부·태그 속성값(test="a &lt; b" 등) 내부는 제외)
  F. 물리 DELETE 경고          (매퍼 XML — DELETE FROM 검출. th_ 접두 테이블·hard-delete-ok 마커 예외. **경고 전용·비차단**)
  G. FQN 인라인 금지           (.java — 타입 위치·정적호출 수신자에 정규화경로 인라인 금지 → import로 짧은 타입명.
                               `new java.util.ArrayList<com.example...>` 류. import/package 라인·fqn-ok 마커 예외)
  H. Java 9+ 문법 금지          (.java — 이 레포 Java 8 ONLY. var·record·List/Map/Set.of·copyOf·ofEntries·
                               .toList()·텍스트블록. 문자열/주석 리터럴은 스트립 후 매칭해 오탐 차단)
  K. 매퍼↔실스키마 대조         (매퍼 XML — SQL의 테이블명·명시적 컬럼(INSERT 목록/UPDATE SET/별칭.컬럼)이
                               레포 스냅샷(.claude/schema-snapshot.json)에 없으면 경고. **경고 전용·비차단**.
                               스냅샷 없는 레포는 자동 스킵. 갱신=export_schema_snapshot.py)
  L. 뷰·프래그먼트 참조 정합   (템플릿·컨트롤러 — th:replace/insert 의 정적 `~{경로 :: 프래그먼트}` 가
                               가리키는 .html·프래그먼트 정의 존재 여부 + @Controller 매핑 핸들러의
                               return "뷰경로" 에 대응하는 템플릿 존재 여부. 표현식이 낀 동적 참조·
                               @ResponseBody·redirect:/forward: 는 침묵 스킵. 예외 마커 = 줄 끝 lint-view-ok.
                               **--changed-only 와 무관하게 전역 스캔** — 프래그먼트를 지우면 그것을
                               가리키는 참조는 '변경 안 된 파일'에 남아 라인 필터로는 안 잡히기 때문.
                               뷰 루트는 spring.thymeleaf.prefix 를 읽어 자동 탐지, 없으면 관례 폴백,
                               템플릿 디렉터리가 없는 레포/모듈은 자동 스킵)
  M. 비동기 래퍼 실패 sentinel 가드 (.js·템플릿 인라인 script — `App.requestFetch(url, opt, handler, ...)` 의
                               성공 핸들러가 래퍼의 실패 sentinel(false)을 성공 본문으로 흘리지 않는지.
                               핸들러 본문에서 **콜백 파라미터를 처음 읽는 문장**이 falsy 가드가 아니면 위반.
                               파라미터 없는 핸들러도 위반(가드할 자리가 없다). 3번째 인자가 함수 리터럴이
                               아니거나, 파라미터가 구조분해({a}·[a])거나, 본문이 비면 침묵 스킵.
                               ⚠️ --changed-only 에서는 **가드 줄만 지운 diff 를 못 잡는다**(삭제 헝크는
                               추가 줄이 0 → 라인 필터가 전부 거른다) — 가드를 걷었으면 전수로 재확인.
                               예외 마커 = 호출 줄 lint-fetch-ok. **경고 전용·비차단**)
  N. 네이티브 다이얼로그 금지    (개발 소유 JS `js/develop/**`·템플릿 인라인 script 의 alert(/confirm(/prompt(
                               → 프로젝트 공통 다이얼로그. 같은 파일이 그 이름을 직접 정의하면(래퍼 구현부
                               자신) 그 이름만 스킵. 예외 마커 = 줄 끝 lint-dialog-ok. **경고 전용·비차단**)
  O. 템플릿 정적자원 절대경로 금지 (Thymeleaf 템플릿 루트의 .html — src/href 의 평문 `/resources...` 는
                               컨텍스트패스가 빠져 404 → `@{/resources/...}`. 퍼블 원본(static/html)처럼
                               템플릿 루트 밖은 대상 아님. 렌더되는 마크업만 본다 — HTML 주석·<script>
                               본문은 블랭킹하고, data-src·xlink:href 처럼 하이픈·콜론이 앞선 속성은
                               src/href 로 치지 않는다. 예외 마커 = 줄 끝 lint-abs-path-ok)
  P. 동작 접두어 강제           (.java — @…Mapping URL 세그먼트 + Controller/Service/ServiceImpl 의 메서드명에
                               insert/save/update/edit/remove/select/get/list/find 접두 금지 →
                               create/modify/delete/read. 룰 B 와 같은 camelCase 경계(뒤가 대문자·숫자·밑줄)로만
                               매칭. 예외 마커 = 줄 끝 lint-verb-ok. **경고 전용·비차단**)
  Q. Toast 가드                 (개발 소유 JS `js/develop/**`·템플릿 인라인 script 의 toast.show( 호출 —
                               같은 줄 또는 앞 3줄에 `window.toast &&` / `if (window.toast)` 가드가 없으면 경고.
                               common.js 가 module 이라 top-level 시점엔 window.toast 가 없을 수 있다.
                               예외 마커 = 줄 끝 lint-toast-ok. **경고 전용·비차단**)
  R. camelCase(kebab 금지)      (템플릿 루트 .html 파일명의 `-` + @…Mapping URL 세그먼트의 kebab
                               (`[a-z0-9]+-[a-z0-9]`). 예외 마커 = 줄 끝 lint-kebab-ok(매핑 줄만).
                               **경고 전용·비차단**)
  S. 트랜잭션 없는 다중 쓰기      (@Service *Impl.java 의 public 메서드가 @Transactional 없이 쓰기 호출 2회 이상 —
                               self-invocation 본문 합산. 구현 = 같은 디렉터리 rule_tx.py. 예외 마커 =
                               메서드 선언부 위 lint-tx-ok. **경고 전용·비차단**)
  V. select* 안의 쓰기          (*Impl.java 의 public select* 메서드 본문에 쓰기 호출이 1회라도 있으면 — 판정 기준·
                               self-invocation 합산은 룰 S 와 같다. select* 는 read-only 트랜잭션(복제 시 슬레이브)이라
                               그 안의 쓰기(REQUIRED 로 부른 다른 서비스 쓰기 포함)는 실패한다 → masterSelect* 개명 또는
                               쓰기 메서드 분리. 구현 = 같은 디렉터리 rule_tx.py. 예외 마커 = 메서드 선언부 위
                               lint-select-write-ok. **옵트인 마커와 별개로 발동** — 레포 basename __SELECT_WRITE_ALWAYS_REPO__ 는 항상,
                               그 밖은 context-transaction.xml 에 select* read-only 규칙·masterSelect 가 있을 때만
                               (마커 없는 레포에선 룰 V 만 돈다). **경고 전용·비차단**)
  T. LIKE 검색어 escape 강제     (매퍼 XML — LIKE 피연산자의 #{x} 는 값이 `__LIKE_ESCAPE_UTIL__@escape(` 인 <bind> 이름이어야
                               한다(%·_·\\ 가 와일드카드로 새는 것 차단). <sql> 조각이면 같은 파일에서 그 조각을
                               include 하는 statement 전부가 bind 해야 한다. LIKE 피연산자의 ${} 도 위반.
                               거꾸로 escape bind 값을 LIKE 밖(정확일치·FN_APP_ENC·encFit)에 쓰는 것도 위반.
                               예외 마커 = LIKE 줄의 주석 lint-like-ok. 레포 옵트인 = .claude/lint-like-escape.enabled)
  U. 템플릿 전송 주석 금지       (템플릿 루트 .html — `<!--/*` 가 아닌 `<!--` 와 인라인 <script>·<style> 본문의
                               JS·CSS 주석은 응답에 그대로 실린다 → `<!--/* */-->`. IE 조건부 주석·Thymeleaf
                               텍스트 문법(`/*[…`)은 제외. 구현 = 같은 디렉터리 rule_html_comment.py.
                               예외 마커 = 그 줄의 lint-comment-ok. 레포 옵트인 = .claude/lint-template-comment.enabled)
  ※ I·J 는 보안코딩 룰(디버그잔존·빈catch)용으로 예약 — 2026-07-09 원복(보류)됐고 재개 시 그 이름으로 복원
    (복원 경로 = claude-agent-kit 이력 009130c, memory security-audit-prep).

--changed-only 면 변경/스테이징/신규 파일만 검사(harness 기본). 위반=exit 1(빌드 FAIL).
룰 F·K·M·N·P·Q·R·S·V 는 [WARN] 출력 전용 — exit 코드에 영향 없음(차단은 A~E·G·H·O·L·T·U).
오탐 회피: 룰 B는 URL 레벨(list.do 등 관용 충돌)이 아니라 매퍼 id로만, 룰 C/A는 vendor/min/old 제외.
"""

from __future__ import print_function

import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rule_tx import check_java_tx_multiwrite, filter_by_lines as tx_filter_by_lines  # noqa: E402 — 룰 S
from rule_tx import check_java_select_write, select_write_enabled  # noqa: E402 — 룰 V
from rule_html_comment import check_template_comment, RULE_MARKER as COMMENT_RULE_MARKER  # noqa: E402 — 룰 U


PRUNE_DIRS = set([
    "target", "build", "out", "bin", ".git", ".idea", ".gradle",
    "node_modules", "generated-sources", "generated", "dist", "resources-old",
])

# 룰 B: 신규·수정 API 금지 동작접두어(= create/modify/delete/read 로 대체). delete/create/modify/read 는 허용.
BANNED_VERBS = ["insert", "save", "update", "edit", "remove", "select", "get", "list", "find"]
# 매퍼 id="readJobList" 처럼 접두어 뒤가 camelCase 경계(대문자/숫자/밑줄/따옴표끝)일 때만 매칭 → "selectable" 류 오탐 회피.
# 따옴표는 큰·작은 양쪽 — XML 에서 id='selectFoo' 도 동등하게 유효한데 큰따옴표만 보던 탓에
# 따옴표만 바꾸면 명명 게이트를 우회할 수 있었다(2026-08-05 감사).
MAPPER_ID_BANNED_RE = re.compile(
    r'\bid\s*=\s*["\'](' + "|".join(BANNED_VERBS) + r')(?=[A-Z0-9_"\'])')
# 별칭 star(SELECT R.*, SELECT A.*, B.X)도 '컬럼 미명시'라 동일하게 금지한다.
# bare 'SELECT *' 만 보던 탓에 실 레포 위반의 다수(별칭형 11건)가 게이트를 통과했다(2026-08-05 감사).
SELECT_STAR_RE = re.compile(r'(?i)\bselect\s+(?:distinct\s+)?(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)?\*')
XML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)

# 룰 C: AG Grid 구버전 방식 신호.
AGGRID_OLD_RES = [
    ("rowSelection:'multiple'(구버전 문자열)", re.compile(r"rowSelection\s*:\s*['\"]multiple['\"]")),
    ("headerCheckboxSelection:true(columnDefs 체크박스 직접선언)", re.compile(r"headerCheckboxSelection\s*:\s*true")),
    ("checkboxSelection:true(columnDefs 체크박스 직접선언)", re.compile(r"checkboxSelection\s*:\s*true")),
]
# JS 단순 라인주석 제거(// ...) — 블록주석은 보수적으로 미제거.
JS_LINE_COMMENT_RE = re.compile(r"//.*")

# 룰 D: 퍼블팀 관리 공통 JS(수정 금지). 경로 정규화(소문자·슬래시) 후 정규식 매칭.
# 고정 문자열 목록이던 이전 방식은 퍼블팀이 js/ → js/design/ 으로 옮긴 순간(커밋 3b17f058)
# 매칭 0건이 되어 **아무 파일도 보호하지 않는 죽은 게이트**가 됐고, 아무 신호도 없었다(2026-08-05 감사).
# → 중간 디렉터리를 허용하는 패턴으로 바꾸고, 아래 drift 자가점검으로 '보호 대상 0건'을 경고한다.
PUBLISH_JS_PROTECTED_RES = [
    re.compile(r"/static/resources/js/(?:[a-z0-9_-]+/)?common\.js$"),
    re.compile(r"/static/resources/js/(?:[a-z0-9_-]+/)?common/"),
]

# 룰 E: CDATA 강제 — 매퍼 XML의 "SQL 텍스트"(태그·주석·CDATA 밖)에서 엔티티 이스케이프
# 비교연산자를 금지한다. 태그 내부(= 속성값, 예: <if test="a &lt; b">)는 XML 문법상
# &lt; 가 유일한 방법이므로 절대 위반 아님 → XML_NONTEXT_RE 로 통째 제외.
XML_NONTEXT_RE = re.compile(
    r"<!--.*?-->"                                             # 주석
    r"|<!\[CDATA\[.*?\]\]>"                                   # CDATA 구간
    r"|<[^>\"']*(?:\"[^\"]*\"[^>\"']*|'[^']*'[^>\"']*)*>",    # 태그(따옴표 속성값 안의 >·엔티티까지 포함해 스킵)
    re.S)
ENTITY_CMP_RE = re.compile(
    r"&lt;\s*=?\s*&gt;"        # &lt;&gt; · &lt;=&gt;(null-safe)
    r"|&lt;="                  # &lt;=
    r"|&gt;="                  # &gt;=
    # 단독 &lt;·&gt; — 앞뒤 공백을 요구하던 탓에 붙여 쓴 `a&lt;b` 를 놓쳤다(2026-08-05 감사).
    # 피연산자 경계(식별자·바인드변수·숫자·닫는 괄호) 사이면 공백 없이도 비교로 본다.
    r"|(?<=[\w)}'\"\s])&lt;(?=[\s\w(#$'\"])"
    r"|(?<=[\w)}'\"\s])&gt;(?=[\s\w(#$'\"])")

# 룰 T: LIKE 검색어 escape 강제. 매퍼마다 손으로 bind 를 기억해 넣던 탓에 escape 누락이 회차마다 다시 나왔다
# (2026-10-14 장부 I102). statement 단위로 bind 를 모으고, <sql> 조각은 같은 파일의
# include 처로 해소한다. 판정은 주석 블랭킹 뷰에서, 예외 마커는 원문 줄에서 본다.
LIKE_STMT_RE = re.compile(r"<(select|insert|update|delete|sql)\b([^>]*)>(.*?)</\1\s*>", re.S)
LIKE_ID_ATTR_RE = re.compile(r"\bid\s*=\s*[\"']([^\"']+)[\"']")
LIKE_BIND_RE = re.compile(r"<bind\b([^>]*)/?>")
LIKE_BIND_NAME_RE = re.compile(r"\bname\s*=\s*[\"']([^\"']+)[\"']")
LIKE_BIND_VALUE_RE = re.compile(r"\bvalue\s*=\s*\"([^\"]*)\"|\bvalue\s*=\s*'([^']*)'")
LIKE_INCLUDE_RE = re.compile(r"<include\s+refid\s*=\s*[\"']([^\"']+)[\"']")
LIKE_OP_RE = re.compile(r"(?i)\bLIKE\b")
LIKE_PARAM_RE = re.compile(r"#\{\s*([A-Za-z_][\w.]*)")
# ponytail: 킷 사본은 LIKE escape 유틸 클래스명을 __LIKE_ESCAPE_UTIL__ 자리표시로 둔다(레포 고유명 비반출) — 설치 후 실클래스명으로 바꾸지 않으면 룰 T 는
#           마커를 켜도 모든 LIKE 를 위반으로 본다 / 업그레이드 = 클래스명을 마커 파일 내용·환경변수로 받아 라이브·킷 로직 동일화.
LIKE_ESCAPE_FN_RE = re.compile(r"__LIKE_ESCAPE_UTIL__@escape\(")
LIKE_OK_MARKER = "lint-like-ok"
LIKE_ENCFIT_RE = re.compile(r"@encFit\(\s*([A-Za-z_][\w.]*)")
LIKE_RULE_MARKER = "lint-like-escape.enabled"
# 피연산자 끝 = 줄 끝·다음 태그·다음 논리연산자(같은 줄의 다음 LIKE 피연산자를 끌어오지 않게).
LIKE_TAIL_END_RE = re.compile(r"[\n<]|\b(?:AND|OR)\b", re.I)

# 룰 F: 물리 DELETE 경고(비차단). th_ 접두(로그·이력) 테이블·hard-delete-ok 마커는 예외.
DELETE_FROM_RE = re.compile(r"(?i)\bDELETE\s+FROM\b[\s`\"]*([A-Za-z0-9_.$#{}]*)")
HARD_DELETE_OK_MARKER = "hard-delete-ok"

# 룰 G: FQN 인라인 금지(.java). "패키지 세그먼트 2개 이상(소문자시작) + 대문자 클래스"인 정규화경로가
# 타입 위치(생성자 new / 제네릭 <> 안팎) 또는 정적 호출 수신자에 오면 위반 → import로 짧은 타입명 사용.
# ≥2 소문자세그먼트 요구로 내부클래스(Outer.Inner)·정적필드(Enum.VALUE) 오탐 회피.
FQN_SEG = r"(?:[a-z][a-zA-Z0-9]*\.){2,}[A-Z][A-Za-z0-9_]*"
FQN_NEW_RE = re.compile(r"\bnew\s+(" + FQN_SEG + r")\s*[<(]")           # new java.util.ArrayList<... / new com.example.X(
FQN_TYPE_RE = re.compile(r"(?:^|[\s<(,])(" + FQN_SEG + r")\s*[<>]")     # 제네릭 타입 위치: List<kr...>, java.util.Map<...
# 정적 메서드 호출 수신자: java.util.Objects.equals(...) / com.example.X.builder().
# 메서드명 소문자 시작 요구(자바 관례) → 중첩타입 참조(pkg.Outer.Inner)는 걸리지 않는다.
# 앞 문자 가드로 식별자 중간·점 뒤 매칭 차단. 문자열 리터럴 제거본에 매칭(문자열 속 FQN 오탐 차단).
FQN_CALL_RE = re.compile(r"(?:^|[^\w.\"'])(" + FQN_SEG + r")\s*\.\s*[a-z]\w*\s*\(")
# 선언 위치의 FQN — 필드/지역변수 선언, 파라미터 타입, 클래스 리터럴.
# 이전엔 new·제네릭·정적호출 3형태만 봐서 **가장 평범한 선언형**(제네릭 아닌 DTO·Entity 타입)이
# 전부 통과했다 — 규약이 금지한 형태의 절반 이상이 미강제였다(2026-08-05 감사).
# 후행 경계에 `:` 를 포함하는 이유 = **확장 for 문 헤더**(`for (pkg.Sub.Type x : list)`).
# `[=;,)]` 만 보던 종전 정규식은 그 자리를 통째로 놓쳤다 — 제네릭이 붙으면 FQN_TYPE_RE 가
# 우연히 잡아 사각이 가려졌고, 제네릭 없는 형태만 조용히 통과했다(2026-09-02 예시 레포 실측 1건).
# `타입 + 공백 + 소문자식별자 + :` 는 자바에서 확장 for 외에 나오지 않아 삼항연산자와 충돌하지 않는다.
FQN_DECL_RE = re.compile(
    r"(?:^\s*|[(,]\s*|\b(?:final|private|public|protected|static|return|throws)\s+)"
    r"(" + FQN_SEG + r")\s+[a-z]\w*\s*(?=[=;,):])")
FQN_CLASSLIT_RE = re.compile(r"(?:^|[^\w.\"'])(" + FQN_SEG + r")\s*\.\s*class\b")
JAVA_LINE_COMMENT_RE = re.compile(r"//.*")
FQN_OK_MARKER = "fqn-ok"

# 룰 H: Java 9+ 문법 금지(이 레포 Java 8 ONLY). CLAUDE.md 최상단 강조규칙의 게이트화.
# 오탐 회피: 매칭 전 문자열/char 리터럴을 통째 비운다(SQL·메시지 문자열 속 var/record/of 오탐 차단).
# 텍스트블록(\"\"\")만은 리터럴 스트립이 삼중따옴표를 잘라먹으므로 스트립 전 code 에서 별도 검출.
JAVA_STR_RE = re.compile(r'"(?:\\.|[^"\\])*"' + r"|'(?:\\.|[^'\\])*'")
JAVA9_RES = [
    # (라벨, 정규식, 대체 힌트)
    ("var(지역변수 타입추론)", re.compile(r"(?<![.\w])var\s+[a-zA-Z_]\w*\s*[:=]"),
     "명시적 타입 선언(List<X> x = ...)"),
    ("record 선언", re.compile(r"(?<![.\w])record\s+[A-Z]\w*\s*\("),
     "일반 클래스 + 생성자/게터"),
    ("List/Map/Set.of·copyOf·ofEntries(불변컬렉션 팩토리)",
     re.compile(r"\b(?:List|Map|Set)\.(?:of|copyOf|ofEntries)\s*\("),
     "new ArrayList<>()+add 또는 Collections.unmodifiable*"),
]
# Stream.toList()(Java16)는 별도 처리 — 같은 라인에 `.stream(` 신호가 있을 때만 위반.
# 이유: 바레 `.toList()`는 org.json `JSONArray.toList()`(Java8 유효) 등 비-Stream 수신자에서도 나와
# 오탐이 크다((예시레포B) 실측 103건 전부 JSONArray). Collectors.toList()는 음성 룩비하인드로 이중 제외.
TOLIST_RE = re.compile(r"(?<!Collectors)\.toList\s*\(\s*\)")
# 텍스트 블록(Java 15): Java 8 소스엔 유효히 존재 불가 → 비주석 code 에 \"\"\" 있으면 위반.
JAVA_TEXTBLOCK = '"""'

# ── 룰 M·N 공용: JS 뷰(주석·문자열 블랭킹) ────────────────────────────────
# 주석·문자열 리터럴을 **동일 길이 공백**으로 지운다(오프셋 보존 — 룰 E·K 와 같은 방식).
# 제거하면 이후 모든 라인번호가 밀려 --changed-only 라인 필터가 엉뚱한 줄을 가리킨다.
# ⚠️ 정규식 리터럴(/.../)은 인식하지 않는다 — 그 안의 따옴표·괄호가 균형을 깨면 그 호출만
#    조용히 스킵된다(fail-open: 오탐이 아니라 미탐으로 떨어진다).
#    실측(2026-09-18): `var re = /it's/; alert('x');` 한 줄이면 정규식 안 `'` 가 문자열 시작으로
#    오인돼 그 뒤 호출이 통째로 미탐. 줄을 나누면 정상 검출(단일따옴표 패턴이 개행을 안 넘음).
#    ⚠️ **룰 M 을 차단으로 승격하기 전 선행 조건** = JS 토크나이저 도입 또는 정규식 리터럴 인식.
#    경고 동안은 미탐이지만, 차단이 되면 이 사각이 "가드 없는 호출을 통과시키는" 구멍이 된다.
# ponytail: 정규식 리터럴 미인식 / 업그레이드 경로 = JS 토크나이저 도입 시 이 함수만 교체
JS_BLANK_RE = re.compile(
    r"//[^\n]*"                       # 라인 주석
    r"|/\*.*?\*/"                     # 블록 주석
    r"|'(?:\\.|[^'\\\n])*'"           # 작은따옴표 문자열
    r'|"(?:\\.|[^"\\\n])*"'           # 큰따옴표 문자열
    r"|`(?:\\.|[^`\\])*`",            # 템플릿 리터럴
    re.S)

# 룰 M: 공통 비동기 래퍼의 실패 sentinel 가드.
# 래퍼 계약 = requestFetch(url, requestOption, handler, errorHandler) — 401/403/500 을 래퍼가
# 스스로 안내하고 **handler 에 false 를 넘긴다**. 성공 핸들러가 그 false 를 성공 본문으로
# 흘리면 "없는 데이터"를 렌더하거나 TypeError 로 죽고, 안내가 두 번 뜬다.
# 판정축 = "콜백 파라미터를 처음 **읽는** 문장이 falsy 가드인가". '첫 문장' 이 아니다 —
# 재진입 잠금 해제(processing = false)와 last-wins 시퀀스 토큰 가드(if(seq !== cur) return)는
# sentinel 가드보다 **앞에 와야 옳다**(해제를 뒤로 미루면 실패 시 잠금이 영구히 남는다).
APP_FETCH_RE = re.compile(r"\bApp\.requestFetch\s*\(")
FETCH_OK_MARKER = "lint-fetch-ok"
# 핸들러 머리: function(resp){ · (resp) => { · resp => { — 파라미터가 없으면 그룹이 전부 None.
# 첫 파라미터는 식별자 외에 **구조분해**(`{data}`·`[a, b]`)도 받는다. 구조분해를 파라미터 형태에서
# 빼면 그룹이 전부 None 이 되어 '파라미터 없음' 위반으로 오탐한다(2026-09-18 실측 각 1건) —
# 구조분해로 매칭한 뒤 check_js_fetch_guard 가 침묵 스킵한다(fail-open).
# ponytail: 정규식 리터럴로 판정 / 업그레이드 경로 = JS 토크나이저 도입 시 이 판정을 AST 로 교체.
#   알려진 오탐(전수 아님 — 차단 승격 전 반드시 걷어낼 것, 2026-09-18 픽스처 실측 각 1건):
#   ⓐ `if(typeof resp === 'boolean' && resp === false) return;` 처럼 typeof 를 낀 가드
#   ⓑ 조건을 여러 줄로 쪼갠 `if(\n resp === false\n) return;`(_sentinel_guard_re 가 한 줄만 본다)
#   ⓒ 가드보다 앞선 클로저가 파라미터를 캡처하는 경우(캡처를 '먼저 읽음' 으로 계산)
_JS_PARAM_HEAD = r"(?:[A-Za-z_$][\w$]*|\{[^}]*\}|\[[^\]]*\])"
JS_HANDLER_HEAD_RE = re.compile(
    r"^\s*(?:function\s*[\w$]*\s*\(\s*(" + _JS_PARAM_HEAD + r")?[^)]*\)"
    r"|\(\s*(" + _JS_PARAM_HEAD + r")?[^)]*\)\s*=>"
    r"|([A-Za-z_$][\w$]*)\s*=>)\s*\{")

# 룰 N: 네이티브 다이얼로그 금지(프로젝트 공통 다이얼로그로). 앞 문자 가드에 `-` 를 포함하는
# 이유 = 마크업 문자열의 `modal-confirm(` 류가 식별자 호출로 오인되는 것을 막기 위해서다.
NATIVE_DIALOG_RE = re.compile(r"(?<![.\w$\-])(alert|confirm|prompt)\s*\(")
DIALOG_OK_MARKER = "lint-dialog-ok"
DEV_JS_DIR = "/js/develop/"

# 룰 O: 템플릿의 평문 절대경로 정적자원. 컨텍스트패스(/cms·/front)가 빠져 404 가 된다 → @{}.
# 앞 경계는 `\b` 가 아니라 음성 룩비하인드다 — `\b` 는 하이픈·콜론 뒤에서도 성립해
# `data-src`·`xlink:href` 를 src/href 로 오인한다(2026-09-18 실측 각 1건). 룰 O 는 **차단**이라
# SVG 스프라이트(`xlink:href`)·lazy-load(`data-src`) 가 퍼블에서 한 번 유입되면 빌드가 멈춘다.
ABS_RESOURCE_RE = re.compile(
    r"""(?<![-:\w])(src|href)\s*=\s*(["'])(/resources/[^"']*)\2""")
ABS_PATH_OK_MARKER = "lint-abs-path-ok"

# 룰 P: 동작 접두어(룰 B 의 자바쪽 짝). 경계는 룰 B 와 동일 — 접두어 뒤가 대문자·숫자·밑줄일
# 때만 매칭해 selectable·getter 관용어 오탐을 피한다.
VERB_OK_MARKER = "lint-verb-ok"
BANNED_VERB_PREFIX_RE = re.compile(r"^(?:" + "|".join(BANNED_VERBS) + r")(?=[A-Z0-9_])")
MAPPING_ANNO_RE = re.compile(r"@(?:Get|Post|Put|Delete|Patch|Request)Mapping\b")
JAVA_STRLIT_VALUE_RE = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')
PUBLIC_METHOD_RE = re.compile(
    r"^\s*public\s+(?:(?:static|final|synchronized|abstract|native|default)\s+)*"
    r"[\w$][\w$<>,\[\]\.\s?]*\s+([a-z][\w$]*)\s*\(")
# 인터페이스 선언(implicit public) — 본문 없는 선언만 본다(끝이 `;`, `=` 없음).
IFACE_METHOD_RE = re.compile(
    r"^\s+(?:(?:default|static)\s+)?[\w$][\w$<>,\[\]\.\s?]*\s+([a-z][\w$]*)\s*\(")
# 선두 토큰이 문(statement) 키워드면 메서드 선언이 아니다(return selectFoo(x); 오탐 차단).
JAVA_STMT_KEYWORDS = set([
    "return", "new", "throw", "else", "case", "do", "while", "for", "if",
    "switch", "synchronized", "assert", "try", "catch", "finally", "yield",
])
P_TARGET_SUFFIXES = ("Controller.java", "Service.java", "ServiceImpl.java")

# 룰 Q: Toast 가드. 호출은 문자열·주석 블랭킹 뷰에서 찾고, 가드는 원문 줄(같은 줄 + 앞 3줄)에서 찾는다.
TOAST_CALL_RE = re.compile(r"(?<![\w$])(?:window\s*\.\s*)?toast\s*\.\s*show\s*\(")
TOAST_GUARD_RE = re.compile(r"window\.toast\s*&&|if\s*\(\s*window\.toast\s*\)")
TOAST_GUARD_LOOKBACK = 3
TOAST_OK_MARKER = "lint-toast-ok"

# 룰 R: camelCase(kebab 금지) — 템플릿 파일명과 @…Mapping URL 세그먼트.
KEBAB_SEGMENT_RE = re.compile(r"[a-z0-9]+-[a-z0-9]")
# 매핑 애너테이션 안이라도 URL 이 아닌 속성 값(produces="text/event-stream" 등)은 대상이 아니다.
MAPPING_NON_PATH_ATTR_RE = re.compile(
    r"\b(?:produces|consumes|headers|params|name)\s*=\s*\{?\s*(?:\"[^\"]*\"\s*,\s*)*$")
KEBAB_OK_MARKER = "lint-kebab-ok"


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except TypeError:  # py2
        with open(path, "r") as handle:
            return handle.read()


def iter_repo_files(root, suffix):
    for current_root, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in PRUNE_DIRS]
        for name in files:
            if name.endswith(suffix):
                yield os.path.join(current_root, name)


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))?")


def git_changed_line_map(project_root):
    """변경 파일 → 새 코드 라인번호 집합. 값이 None 이면 신규파일(전 라인 대상).

    레거시 파일을 부분 수정했을 때 '그 파일의 기존 위반 전부'가 아니라
    실제로 추가·수정한 라인의 위반만 잡도록 git diff 헝크(새 측)로 좁힌다.
    """
    try:
        git_root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], cwd=project_root).decode("utf-8", "replace").strip()
    except (OSError, subprocess.CalledProcessError):
        git_root = project_root

    line_map = {}

    def absorb_diff(extra_args):
        try:
            # ⚠️ strict utf-8 로 디코드하면 안 된다. git 이 텍스트로 판단했지만 실제로는 비-UTF8 바이트를
            # 품은 파일(퍼블 납품 CSS/JS·SVG·서브셋 폰트 등)이 diff 에 섞이면 UnicodeDecodeError 로
            # 체커가 통째로 죽고, 그러면 게이트가 "위반 0건 + exit 1" 이라는 판독 불가 상태가 된다
            # (2026-08-06 퍼블 1,342파일 반입 커밋에서 실측: 97MB 지점에서 크래시).
            # 여기서 필요한 것은 '+++ 파일명' 과 '@@ 헝크' 헤더뿐이라 손실 디코딩으로 충분하다.
            output = subprocess.check_output(
                ["git", "diff", "--unified=0", "--no-color"] + extra_args,
                cwd=project_root).decode("utf-8", "replace")
        except (OSError, subprocess.CalledProcessError):
            return
        current = None
        for line in output.splitlines():
            if line.startswith("+++ "):
                path = line[4:].strip()
                if path == "/dev/null":
                    current = None
                    continue
                if path.startswith("b/"):
                    path = path[2:]
                current = os.path.abspath(os.path.join(git_root, path))
                if line_map.get(current) is None and current not in line_map:
                    line_map[current] = set()
            elif current is not None and line_map.get(current) is not None:
                match = HUNK_RE.match(line)
                if match:
                    start = int(match.group(1))
                    count = 1 if match.group(2) is None else int(match.group(2))
                    for ln in range(start, start + count):
                        line_map[current].add(ln)

    absorb_diff([])           # 워킹트리(unstaged)
    absorb_diff(["--cached"])  # 스테이징(staged)

    try:  # 신규(untracked) = 전 라인 대상
        output = subprocess.check_output(
            ["git", "ls-files", "--others", "--exclude-standard"], cwd=project_root).decode("utf-8", "replace")
        for line in output.splitlines():
            if line.strip():
                line_map[os.path.abspath(os.path.join(git_root, line.strip()))] = None
    except (OSError, subprocess.CalledProcessError):
        pass

    # 스테이징된 '추가'(A)도 신규로 분류한다. 위 --cached diff 는 추가 파일을 전 라인 헝크로
    # 뱉어 set 이 잡히는데, 그러면 `git add` 하는 순간 신규 파일이 '수정'으로 둔갑해
    # 룰 D 같은 add/modify 구분 룰이 커밋 직전에만 오발화한다(신규 반입 시 실측).
    # ※ 여기 --diff-filter=A 는 '이번 diff 안에서 add 냐 modify 냐'를 가르는 용도다.
    #   전역 규약이 금지하는 것은 파일 '작업 귀속(소유권) 판정'에 이걸 쓰는 것으로, 용도가 다르다.
    try:
        output = subprocess.check_output(
            ["git", "diff", "--cached", "--diff-filter=A", "--name-only"], cwd=project_root).decode("utf-8", "replace")
        for line in output.splitlines():
            if line.strip():
                line_map[os.path.abspath(os.path.join(git_root, line.strip()))] = None
    except (OSError, subprocess.CalledProcessError):
        pass

    return line_map


def is_mapper_xml(path):
    low = path.lower()
    return low.endswith(".xml") and (os.sep + "mapper" + os.sep) in low


def is_lintable_js(path):
    low = path.replace("\\", "/").lower()
    if not low.endswith(".js") or low.endswith(".min.js"):
        return False
    # 룰 C(AG-Grid 구버전 체크박스)는 admin 모듈에 국한되지 않는 구조적 안티패턴이므로
    # 특정 admin 모듈명 하드코딩을 제거 — 레포마다 admin 모듈명이 달라도 동작. vendor/공통/min만 제외.
    # (과소적용<과다스캔; --changed-only 가 실제 편집 파일로 범위를 좁혀 성능부담 없음)
    if "/vendor/" in low or "/lib/" in low or "/common/" in low:
        return False
    return True


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def check_mapper_xml(path, like_rule=False):
    """(line, message) 목록 반환."""
    found = []
    raw = read_text(path)
    # 주석은 '제거'가 아니라 '동일 길이 공백 블랭킹'(오프셋 보존) — 제거하면 이후 모든 위반의
    # 라인번호가 주석 길이만큼 밀려, --changed-only 라인 필터가 엉뚱한 레거시 위반을
    # '변경된 줄'로 오탐한다(XML 주석을 추가하기만 해도 재현). 룰 K와 동일 방식으로 통일.
    text = XML_COMMENT_RE.sub(_blank, raw)
    for match in SELECT_STAR_RE.finditer(text):
        found.append((line_of(text, match.start()),
                      "[A:SELECT*] %s:%d — 'SELECT *' 금지(필요 컬럼 명시)" % (path, line_of(text, match.start()))))
    for match in MAPPER_ID_BANNED_RE.finditer(text):
        ln = line_of(text, match.start())
        found.append((ln, "[B:명명] %s:%d — 매퍼 id 접두어 '%s' 금지(create/modify/delete/read 사용)" % (
            path, ln, match.group(1))))
    found.extend(check_mapper_xml_cdata(path, raw))
    if like_rule:
        found.extend(check_mapper_xml_like_escape(path, raw, text))
    return found


def _like_escaped_binds(body):
    """statement 본문의 <bind> 중 값이 escape 함수를 거치는 이름 집합."""
    names = set()
    for bind in LIKE_BIND_RE.finditer(body):
        attrs = bind.group(1)
        name = LIKE_BIND_NAME_RE.search(attrs)
        value = LIKE_BIND_VALUE_RE.search(attrs)
        if name and value and LIKE_ESCAPE_FN_RE.search(value.group(1) or value.group(2) or ""):
            names.add(name.group(1))
    return names


def check_mapper_xml_like_escape(path, raw, text):
    """룰 T: LIKE 피연산자의 #{x} 가 escape 된 bind 이름인지 본다(차단).

    피연산자 = LIKE 뒤(앞 공백·줄바꿈 건너뜀)부터 그 줄 끝·다음 태그('<')·다음 AND/OR 전까지.
    // ponytail: 조각의 include 처는 같은 파일만 해소한다(다른 매퍼가 namespace 로 include 하면 못 본다) /
    //   bind 를 조각 안에 두면 include 처와 무관하게 통과 — 다른 파일 include 가 늘면 전 매퍼 id 색인으로 확장.
    """
    stmts = []
    for m in LIKE_STMT_RE.finditer(text):
        sid = LIKE_ID_ATTR_RE.search(m.group(2))
        stmts.append((m.group(1).lower(), sid.group(1) if sid else "", m.start(3), m.group(3)))
    by_id = dict((sid, (kind, body)) for kind, sid, _, body in stmts)

    def includers(frag_id, seen):
        out = []
        for kind, sid, _, body in stmts:
            refs = [r.split(".")[-1] for r in LIKE_INCLUDE_RE.findall(body)]
            if frag_id in refs and sid not in seen:
                if kind == "sql":
                    out.extend(includers(sid, seen | set([sid])))
                else:
                    out.append((sid, body))
        return out

    raw_lines = raw.splitlines()
    found = []
    for kind, sid, offset, body in stmts:
        own = _like_escaped_binds(body)
        visible = set(own)
        if kind == "sql":
            for _, ubody in includers(sid, set([sid])):
                visible |= _like_escaped_binds(ubody)
        like_spans = []
        for op in LIKE_OP_RE.finditer(body):
            rest = body[op.end():]
            lead = len(rest) - len(rest.lstrip())
            tail = LIKE_TAIL_END_RE.split(rest[lead:], 1)[0]
            start = op.end() + lead
            like_spans.append((start, start + len(tail)))
            ln = line_of(text, offset + op.start())
            if 0 < ln <= len(raw_lines) and LIKE_OK_MARKER in raw_lines[ln - 1]:
                continue
            if "${" in tail:
                found.append((ln, "[T:LIKE] %s:%d — LIKE 피연산자에 ${} 금지(#{} + escape bind 로)" % (path, ln)))
            for param in LIKE_PARAM_RE.findall(tail):
                if param in own:
                    continue
                if kind != "sql":
                    missing = [sid]
                else:
                    users = includers(sid, set([sid]))
                    missing = [u for u, ubody in users if param not in _like_escaped_binds(ubody)]
                    if not users:
                        missing = ["(같은 파일 include 처 없음)"]
                if missing:
                    found.append((ln, "[T:LIKE] %s:%d — LIKE 검색어 #{%s} 가 escape 를 거치지 않음(%s) — "
                                      "<bind name=\"%sKw\" value=\"@...__LIKE_ESCAPE_UTIL__@escape(%s)\"/> 로 감싼다"
                                      "(의도된 와일드카드면 그 줄 주석에 %s)" % (
                                          path, ln, param, ", ".join(missing), param.split(".")[-1],
                                          param, LIKE_OK_MARKER)))
        # escape 값은 LIKE 전용 — 정확일치(=)·암호화 함수 인자·encFit 에 들어가면 _ · 역슬래시가 든 값이 일치하지 않는다.
        for use in list(LIKE_PARAM_RE.finditer(body)) + list(LIKE_ENCFIT_RE.finditer(body)):
            name = use.group(1)
            if name not in visible or any(a <= use.start() < b for a, b in like_spans):
                continue
            ln = line_of(text, offset + use.start())
            if 0 < ln <= len(raw_lines) and LIKE_OK_MARKER in raw_lines[ln - 1]:
                continue
            found.append((ln, "[T:LIKE] %s:%d — escape 값 %s 를 LIKE 밖(정확일치·함수 인자)에 씀 — 원문 속성을 넘긴다" % (
                path, ln, name)))
    return found


def check_mapper_xml_cdata(path, raw):
    """룰 E: 태그(속성값)·주석·CDATA "밖" SQL 텍스트의 엔티티 비교연산자만 위반 처리.

    파일을 선형 스캔해 비텍스트 구간(XML_NONTEXT_RE)을 제거한 갭(=SQL 텍스트)에서만
    매칭한다. 라인번호는 raw 기준이라 --changed-only 라인 필터와 정확히 일치.
    """
    found = []
    pos = 0
    segments = []
    for nontext in XML_NONTEXT_RE.finditer(raw):
        segments.append((pos, raw[pos:nontext.start()]))
        pos = nontext.end()
    segments.append((pos, raw[pos:]))
    for offset, segment in segments:
        for match in ENTITY_CMP_RE.finditer(segment):
            ln = line_of(raw, offset + match.start())
            found.append((ln, "[E:CDATA] %s:%d — SQL 텍스트에 엔티티 비교연산자 '%s' 금지(<![CDATA[ ... ]]> 로 감싼다)" % (
                path, ln, match.group(0))))
    return found


def check_mapper_xml_delete_warn(path):
    """룰 F(경고 전용·비차단): 물리 DELETE 검출. (line, message) 목록 반환.

    예외 = 같은 라인 대상 테이블이 th_ 접두(로그·이력), 또는 라인/직전 라인에
    hard-delete-ok 주석 마커.
    """
    found = []
    raw = read_text(path)
    # 주석은 오프셋 보존 블랭킹 — 주석 속 'DELETE FROM' 예시 문구가 경고로 잡히는 오탐 차단.
    text = XML_COMMENT_RE.sub(_blank, raw)
    lines = text.splitlines()
    # ⚠️ 마커 탐색은 **원문**(raw)에서 한다. XML 에서 마커를 쓸 자리는 주석뿐인데(SQL 텍스트에 넣으면
    #    쿼리가 깨진다) 블랭킹된 text 에서 찾으면 마커가 영원히 안 보여, 메시지가 안내하는
    #    "hard-delete-ok 주석 마커" 탈출구가 원리적으로 동작하지 않았다(2026-08-05 실측).
    raw_lines = raw.splitlines()
    # 라인 단위로 찾던 이전 방식은 실제 코드에서 흔한 줄바꿈 포맷(DELETE 다음 줄 FROM ...)을 놓쳤다
    # — 포맷만 바꾸면 감시망을 벗어났다(2026-08-05 감사). 파일 전체에서 개행 포함으로 매칭한다.
    for match in DELETE_FROM_RE.finditer(text):
        table = match.group(1).strip("`\"").lower()
        if table.split(".")[-1].startswith("th_"):
            continue
        ln = line_of(text, match.start())
        idx = ln - 1
        line = raw_lines[idx] if 0 <= idx < len(raw_lines) else ""
        prev = raw_lines[idx - 1] if idx > 0 else ""
        if HARD_DELETE_OK_MARKER in line or HARD_DELETE_OK_MARKER in prev:
            continue
        found.append((ln, "[F:물리DELETE] %s:%d — 물리 DELETE 감지(소프트 딜리트 DEL_YN='Y' 원칙; 의도적이면 hard-delete-ok 주석 마커)" % (
            path, ln)))
    return found


# ── 룰 K: 매퍼↔실스키마 대조(경고 전용·비차단) ─────────────────────────────
# 원칙: "확실히 판정 가능한 것만 본다"(오탐≈0). 동적 이름(#{}·${})·미해석 별칭·프래그먼트
# 경유 참조는 전부 침묵 스킵. 라인번호 정확성을 위해 제거 대신 **동일 길이 공백 블랭킹**을
# 써서 오프셋을 보존한다(--changed-only 라인 필터와 정합).
SNAPSHOT_RELPATH = os.path.join(".claude", "schema-snapshot.json")
STMT_RE = re.compile(r"<(select|insert|update|delete)\b[^>]*>(.*?)</\1>", re.S | re.I)
SQL_KEYWORDS = set("""
    where left right inner outer cross join on and or not set values select from as
    group order by having limit union all distinct when then else end case exists
    between like in is null dual straight_join use force ignore
    for skip locked nowait wait duplicate key
""".split())
TABLE_REF_RE = re.compile(r"(?i)\b(?:from|join|into|update|delete\s+from)\s+([`A-Za-z0-9_.$]+)")
ALIAS_RE = re.compile(r"(?i)\b(?:from|join)\s+([`A-Za-z0-9_]+)\s+(?:as\s+)?([A-Za-z_][A-Za-z0-9_]*)")
QUALIFIED_COL_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\b")
INSERT_COLS_RE = re.compile(r"(?i)\binsert\s+into\s+([`A-Za-z0-9_.]+)\s*\(([^()]*)\)")
UPDATE_SET_RE = re.compile(r"(?i)\bupdate\s+([`A-Za-z0-9_.]+)(?:\s+([A-Za-z_][A-Za-z0-9_]*))?\s+set\b")
SET_PART_COL_RE = re.compile(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)")
# 태그 블랭킹은 따옴표 인지형(룰 E와 동일 접근) — test="a > 0" 속성의 raw '>' 에서 조기종료 방지.
TAG_RE = re.compile(r"<[^>\"']*(?:\"[^\"]*\"[^>\"']*|'[^']*'[^>\"']*)*>")
CDATA_RE = re.compile(r"<!\[CDATA\[.*?\]\]>", re.S)
# TABLE_REF 의 update 분기가 upsert/잠금절의 UPDATE 를 테이블 참조로 오인하지 않게 선블랭킹.
UPSERT_LOCK_RE = re.compile(r"(?i)\bon\s+duplicate\s+key\s+update\b|\bfor\s+update\b(?:\s+skip\s+locked|\s+nowait)?")


def load_schema_snapshot(project_root):
    """스냅샷 로드. 없거나 깨졌으면 None(룰 K 전체 스킵 — fail-open)."""
    path = os.path.join(project_root, SNAPSHOT_RELPATH)
    if not os.path.exists(path):
        return None
    try:
        import json
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
        tables = data.get("tables")
        if not isinstance(tables, dict) or not tables:
            return None
        return dict((t, set(info.get("columns", {}).keys())) for t, info in tables.items())
    except Exception:
        return None


def _blank(match):
    return re.sub(r"[^\n]", " ", match.group(0))


def _sql_view(segment):
    """XML 조각 → 오프셋 보존 SQL 뷰. 태그·CDATA 경계·바인드변수·문자열·주석·엔티티를 공백화.

    CDATA 내용은 SQL(비교연산자 raw <·> 포함)이므로 태그 블랭킹에서 보호한다 —
    안 그러면 CDATA 안 '<'와 뒤쪽 '>'가 가짜 태그로 짝지어져 실 SQL이 통째 소실된다.
    """
    cdata_spans = [(m.start(), m.end()) for m in CDATA_RE.finditer(segment)]
    text = re.sub(r"<!\[CDATA\[|\]\]>", _blank, segment)

    def _blank_tag_outside_cdata(match):
        for start, end in cdata_spans:
            if match.start() < end and match.end() > start:  # CDATA 내용/경계와 겹침 → 보존
                return match.group(0)
        return _blank(match)

    text = TAG_RE.sub(_blank_tag_outside_cdata, text)        # MyBatis 동적 태그(내용은 유지)
    text = UPSERT_LOCK_RE.sub(_blank, text)                  # ON DUPLICATE KEY UPDATE / FOR UPDATE 관용구
    text = re.sub(r"[#$]\{[^}]*\}", _blank, text)            # 바인드/치환 변수(파라미터 경로 오탐 차단)
    text = re.sub(r"'(?:[^']|'')*'", _blank, text)           # SQL 문자열 리터럴
    text = re.sub(r"--[^\n]*", _blank, text)                 # SQL 라인 주석
    text = re.sub(r"/\*.*?\*/", _blank, text, flags=re.S)    # SQL 블록 주석
    text = re.sub(r"&[a-zA-Z]+;", _blank, text)              # 엔티티(비교연산자 등 — K 관심사 아님)
    return text


def _split_set_clause(sql, set_start):
    """UPDATE SET 절을 최상위(괄호 깊이 0) 콤마로 분할. (part_offset, part_text) 목록.

    깊이 0의 WHERE 에서 절단 — 서브쿼리 내부 WHERE 로 조기 절단되지 않게 하고,
    CASE WHEN x = ... 같은 값 표현식 내부 비교 피연산자를 SET 컬럼으로 오인하지 않도록
    각 파트의 '선두 ident =' 만 검사 대상으로 삼는 기반을 만든다.
    """
    parts = []
    depth = 0
    part_start = set_start
    i = set_start
    end = len(sql)
    while i < end:
        ch = sql[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = depth - 1 if depth else 0
        elif depth == 0:
            if ch == ",":
                parts.append((part_start, sql[part_start:i]))
                part_start = i + 1
            elif ch in "wW" and re.match(r"(?i)where\b", sql[i:]) \
                    and (i == 0 or not (sql[i - 1].isalnum() or sql[i - 1] == "_")):
                break
        i += 1
    parts.append((part_start, sql[part_start:i]))
    return parts


def _norm_ident(name):
    name = name.strip("`\"").lower()
    return name.split(".")[-1]  # db 한정자 제거


def check_mapper_xml_schema(path, snapshot):
    """룰 K(경고 전용): (line, message) 목록 반환. snapshot = {table: set(columns)}."""
    found = []
    raw = read_text(path)
    text = XML_COMMENT_RE.sub(_blank, raw)  # 주석 블랭킹(오프셋 보존)
    seen = set()

    def warn(offset, msg):
        ln = line_of(raw, offset)
        key = (ln, msg)
        if key not in seen:
            seen.add(key)
            found.append((ln, "[K:스키마] %s:%d — %s (스냅샷 대조·경고 전용; 갱신=레포별 export_schema_snapshot.py)" % (
                path, ln, msg)))

    for stmt in STMT_RE.finditer(text):
        body_off = stmt.start(2)
        seg = stmt.group(2)
        sql = _sql_view(seg)

        # 1) 테이블 존재: 동적(블랭킹돼 빈값)·키워드·서브쿼리는 자연 스킵.
        #    FROM/JOIN 과 식별자 사이에 태그(<include/> 등)가 있었으면 별칭 오인이므로 스킵.
        stmt_tables = set()
        for m in TABLE_REF_RE.finditer(sql):
            tbl = _norm_ident(m.group(1))
            if not tbl or tbl in SQL_KEYWORDS:
                continue
            if "<" in seg[m.start():m.start(1)]:
                continue
            if tbl in snapshot:
                stmt_tables.add(tbl)
            else:
                warn(body_off + m.start(1), "테이블 '%s' 이(가) dev 스키마에 없음" % tbl)

        # 2) INSERT 컬럼 목록(명시적·무별칭이라 고신뢰).
        for m in INSERT_COLS_RE.finditer(sql):
            tbl = _norm_ident(m.group(1))
            cols_blob = m.group(2)
            if tbl not in snapshot or re.search(r"(?i)\bselect\b", cols_blob):
                continue
            col_off = m.start(2)
            for cm in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", cols_blob):
                col = cm.group(0).lower()
                if col not in snapshot[tbl]:
                    warn(body_off + col_off + cm.start(),
                         "INSERT 컬럼 '%s' 이(가) 테이블 '%s' 에 없음" % (col, tbl))

        # 3) UPDATE ... SET 무한정 컬럼(단일 테이블 기준).
        #    최상위 콤마 분할 후 각 파트의 '선두 ident =' 만 검사 — 값 표현식 내부
        #    비교 피연산자(CASE WHEN x = ...)·서브쿼리 WHERE 를 오인하지 않는다.
        for m in UPDATE_SET_RE.finditer(sql):
            tbl = _norm_ident(m.group(1))
            if tbl not in snapshot:
                continue
            for part_off, part in _split_set_clause(sql, m.end()):
                pm = SET_PART_COL_RE.match(part)
                if not pm:
                    continue
                col = pm.group(1).lower()
                if col in SQL_KEYWORDS:
                    continue
                if col not in snapshot[tbl]:
                    warn(body_off + part_off + pm.start(1),
                         "UPDATE SET 컬럼 '%s' 이(가) 테이블 '%s' 에 없음" % (col, tbl))

        # 4) 별칭.컬럼 — 같은 statement 안에서 별칭이 실테이블로 해석될 때만.
        alias_map = {}
        for m in ALIAS_RE.finditer(sql):
            tbl, alias = _norm_ident(m.group(1)), m.group(2).lower()
            if alias in SQL_KEYWORDS or tbl not in snapshot:
                continue
            if alias in alias_map and alias_map[alias] != tbl:
                alias_map[alias] = None  # 별칭 중복(UNION 등) — 판정 불가로 무효화
            else:
                alias_map.setdefault(alias, tbl)
        for m in QUALIFIED_COL_RE.finditer(sql):
            alias, col = m.group(1).lower(), m.group(2).lower()
            tbl = alias_map.get(alias)
            if not tbl or col in SQL_KEYWORDS:
                continue
            if col not in snapshot[tbl]:
                warn(body_off + m.start(2),
                     "컬럼 '%s.%s'(테이블 %s) 이(가) dev 스키마에 없음" % (alias, col, tbl))

    return found


def check_js(path):
    found = []
    raw = read_text(path)
    text = JS_LINE_COMMENT_RE.sub("", raw)
    for label, pattern in AGGRID_OLD_RES:
        for match in pattern.finditer(text):
            ln = line_of(text, match.start())
            found.append((ln, "[C:AGGrid] %s:%d — 구버전 방식 %s → 신버전 rowSelection:{mode:'multiRow',checkboxes:true,headerCheckbox:true}" % (
                path, ln, label)))
    return found


HTML_SCRIPT_RE = re.compile(r"<script\b[^>]*>(.*?)</script\s*>", re.S | re.I)


def _html_script_view(raw):
    """<script> 안만 남기고 마크업은 공백 블랭킹한 뷰(오프셋·라인번호는 파일 기준 보존).

    룰 C·M·N 이 공용한다 — 같은 옵션·같은 호출을 .js 에서 템플릿 인라인 script 로 옮기면
    통째로 우회되던 사각(2026-08-05 감사)을 세 룰 모두에서 같은 방식으로 막는다.
    """
    if "<script" not in raw.lower():
        return None
    view = ["\n" if ch == "\n" else " " for ch in raw]
    for match in HTML_SCRIPT_RE.finditer(raw):
        start, end = match.start(1), match.end(1)
        for i in range(start, end):
            view[i] = raw[i]
    return "".join(view)


def _html_markup_view(raw):
    """HTML 주석과 <script> 본문을 공백 블랭킹한 뷰(오프셋·라인번호는 파일 기준 보존).

    `_html_script_view` 의 반대 뷰다 — 룰 O 는 **렌더되는 마크업**만 봐야 한다. 둘의 근거는 다르다:
    HTML 주석 속 옛 태그는 렌더되지 않아 컨텍스트패스 404 를 낼 수 없다(정당한 제외).
    <script> 본문은 그렇지 않다 — innerHTML·insertAdjacentHTML·document.write 로 주입되는 순간
    브라우저가 그 URL 을 그대로 요청하므로 컨텍스트패스 없는 `/resources/...` 는 404 가 된다.
    그런데도 대상에서 빼는 것은 **트레이드오프**다: 문자열 조립을 정적으로 판정할 수 없고 룰 O 는
    차단이라 오탐 하나가 정상 커밋을 멈춘다. 곧 **알려진 미탐**이며, 이 블랭킹으로 실제 사라지는
    건이 있는지는 레포별로 재측정한다(`--repo <레포>` 실행의 `[O:절대경로]` 건수를 블랭킹 유무로 대조).
    주석 문법은 XML 과 같아 XML_COMMENT_RE 를 그대로 쓴다.
    """
    view = list(raw)
    for pattern, group in ((XML_COMMENT_RE, 0), (HTML_SCRIPT_RE, 1)):
        for match in pattern.finditer(raw):
            for i in range(match.start(group), match.end(group)):
                if view[i] != "\n":
                    view[i] = " "
    return "".join(view)


def check_html_inline_script(path):
    """룰 C 보강: 템플릿 인라인 <script> 안의 AG Grid 구버전 옵션도 검사한다."""
    raw = read_text(path)
    script_view = _html_script_view(raw)
    if script_view is None:
        return []
    text = JS_LINE_COMMENT_RE.sub("", script_view)
    found = []
    for label, pattern in AGGRID_OLD_RES:
        for m in pattern.finditer(text):
            ln = line_of(text, m.start())
            found.append((ln, "[C:AGGrid] %s:%d — 구버전 방식 %s → 신버전 rowSelection:{mode:'multiRow',checkboxes:true,headerCheckbox:true}" % (
                path, ln, label)))
    return found


def is_lintable_java(path):
    low = path.replace("\\", "/").lower()
    if not low.endswith(".java"):
        return False
    if "/generated" in low or low.endswith("package-info.java") or low.endswith("module-info.java"):
        return False
    return True


def check_java(path):
    """룰 G: 타입에 FQN 인라인 검출. (line, message) 목록 반환.

    라인 단위로 // 라인주석 제거 후 매칭. import/package 라인·fqn-ok 마커 라인은 제외.
    라인번호는 raw 기준이라 --changed-only 라인 필터와 정확히 일치.
    """
    found = []
    lines = read_text(path).splitlines()
    for idx, raw_line in enumerate(lines):
        stripped = raw_line.lstrip()
        if stripped.startswith("import ") or stripped.startswith("package "):
            continue
        if stripped.startswith("*") or stripped.startswith("/*") or stripped.startswith("*/"):
            continue  # 자바독/블록주석 라인 — 예시 FQN 오탐 회피
        if FQN_OK_MARKER in raw_line:
            continue
        code = JAVA_LINE_COMMENT_RE.sub("", raw_line)
        # 리터럴 스트립본 — 룰 H 와 FQN_CALL_RE 가 공용(문자열 속 FQN·키워드 오탐 차단).
        code_nostr = JAVA_STR_RE.sub('""', code)
        seen = set()
        for pattern, target in ((FQN_NEW_RE, code), (FQN_TYPE_RE, code), (FQN_CALL_RE, code_nostr),
                                (FQN_DECL_RE, code_nostr), (FQN_CLASSLIT_RE, code_nostr)):
            for match in pattern.finditer(target):
                fqn = match.group(1)
                if fqn in seen:
                    continue
                seen.add(fqn)
                found.append((idx + 1, "[G:FQN] %s:%d — 타입/정적호출에 FQN 인라인 금지 '%s'(파일 상단 import로 짧은 타입명; 단순명 충돌 등 불가피 시 fqn-ok 마커)" % (
                    path, idx + 1, fqn)))
        # 룰 H: Java 9+ 문법 금지. 리터럴 스트립 후 매칭(문자열 속 오탐 차단).
        for label, pattern, hint in JAVA9_RES:
            if pattern.search(code_nostr):
                found.append((idx + 1, "[H:Java8] %s:%d — Java 9+ 문법 %s 금지(이 레포 Java 8 ONLY) → %s" % (
                    path, idx + 1, label, hint)))
        # Stream.toList(): `.stream(` 문맥이 같은 라인에 있을 때만(JSONArray.toList 등 오탐 제외).
        if ".stream(" in code_nostr and TOLIST_RE.search(code_nostr):
            found.append((idx + 1, "[H:Java8] %s:%d — Java 9+ 문법 Stream.toList() 금지(이 레포 Java 8 ONLY) → .collect(Collectors.toList())" % (
                path, idx + 1)))
        if JAVA_TEXTBLOCK in code:
            found.append((idx + 1, "[H:Java8] %s:%d — Java 9+ 문법 텍스트블록(\"\"\") 금지(이 레포 Java 8 ONLY) → 문자열 결합/StringBuilder" % (
                path, idx + 1)))
    return found


# ── 룰 M·N: JS 본문 검사(.js 파일·템플릿 인라인 script 공용) ────────────────

def _js_balanced_end(text, open_idx, opener, closer):
    """open_idx 의 여는 괄호에 대응하는 닫는 괄호 인덱스. 못 찾으면 -1(=침묵 스킵).

    text 는 JS_BLANK_RE 로 문자열·주석이 블랭킹된 뷰여야 한다 — 아니면 문자열 속
    괄호가 균형을 깨뜨린다.
    """
    depth = 0
    for i in range(open_idx, len(text)):
        ch = text[i]
        if ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return i
    return -1


def _js_split_args(text, start, end):
    """괄호 안(start~end)을 최상위 콤마로 분할 → [(s, e), ...]."""
    spans = []
    depth = 0
    part = start
    for i in range(start, end):
        ch = text[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            spans.append((part, i))
            part = i + 1
    spans.append((part, end))
    return spans


def _sentinel_guard_re(param):
    """실패 sentinel 을 막는 **허용 형태**만 적는다(금지 목록이 아니라 허용 목록).

    셋 다 값이 false 일 때 성공 본문으로 진입하지 않는다:
    if(!x) … / if(x === false) … / if(x && …) …
    """
    p = re.escape(param)
    return re.compile(
        r"^\s*if\s*\(\s*(?:"
        r"!\s*" + p + r"\b"
        r"|" + p + r"\s*===?\s*false\b"
        r"|" + p + r"\s*&&"
        r")")


def check_js_fetch_guard(path, raw, view):
    """룰 M(경고 전용): (line, message) 목록.

    ⚠️ `--changed-only`(커밋 게이트) 에서는 **가드 줄만 지운 diff 를 못 잡는다** — 삭제 헝크는
    추가 줄이 0이라 라인 필터가 그 파일의 모든 위반을 걸러낸다(2026-09-18 픽스처 실측:
    가드 줄 삭제 후 `Scanned files: 1 / M 경고 0건`, 전수 모드로는 같은 파일에서 정상 발화).
    룰 M 이 막으려는 사고(가드 제거 회귀)가 정확히 이 형태이므로, 게이트 신뢰도를 과대평가하지
    말 것 — 가드를 걷은 커밋은 `--changed-only` 없이 전수로 한 번 돌려 확인한다.
    해소 선택지(차단 승격 판단과 함께 결정) = ⓐ 룰 L 처럼 전역 스캔으로 올리고 기존 위반을
    `lint-fetch-ok` 마커로 베이스라인 처리 ⓑ 삭제 헝크(`-` 줄)에 가드 정규식이 걸리면 그
    파일만 전수 재판정.
    """
    found = []
    raw_lines = raw.splitlines()

    def marker_on(lineno):
        return 0 < lineno <= len(raw_lines) and FETCH_OK_MARKER in raw_lines[lineno - 1]

    for call in APP_FETCH_RE.finditer(view):
        call_ln = line_of(view, call.start())
        if marker_on(call_ln):
            continue
        open_idx = call.end() - 1
        close_idx = _js_balanced_end(view, open_idx, "(", ")")
        if close_idx < 0:
            continue                       # 괄호 균형 불가 — 침묵 스킵(fail-open)
        args = _js_split_args(view, open_idx + 1, close_idx)
        if len(args) < 3:
            continue                       # 성공 핸들러 인자 자체가 없다 — 판정 대상 아님
        hstart, hend = args[2]
        head = JS_HANDLER_HEAD_RE.match(view[hstart:hend])
        if not head:
            continue                       # 함수 리터럴이 아닌 핸들러(변수 참조 등) — 침묵 스킵
        brace = hstart + head.end() - 1
        body_end = _js_balanced_end(view, brace, "{", "}")
        if body_end < 0:
            continue
        body = view[brace + 1:body_end]
        if not body.strip():
            continue                       # 본문이 빈 no-op 핸들러 — 보호할 성공 본문이 없다
        param = head.group(1) or head.group(2) or head.group(3)
        if param and param[0] in "{[":
            continue                       # 구조분해 파라미터 — sentinel 판정 불가(침묵 스킵)
        if not param:
            found.append((call_ln,
                          "[M:비동기가드] %s:%d — App.requestFetch 성공 핸들러에 파라미터가 없어 실패 "
                          "sentinel(false)을 가려낼 수 없습니다 — 401/403/500 에도 성공 본문이 그대로 "
                          "실행됩니다(handler(resp) 로 받아 선두에서 가드; 예외 = %s 마커)"
                          % (path, call_ln, FETCH_OK_MARKER)))
            continue
        hit = re.search(r"\b%s\b" % re.escape(param), body)
        if hit is None:
            found.append((call_ln,
                          "[M:비동기가드] %s:%d — App.requestFetch 성공 핸들러가 '%s' 를 한 번도 읽지 않습니다 "
                          "— 실패 sentinel(false)에도 성공 본문이 그대로 실행됩니다"
                          "(선두에 if(%s === false) return; ; 예외 = %s 마커)"
                          % (path, call_ln, param, param, FETCH_OK_MARKER)))
            continue
        # '첫 문장' 이 아니라 '파라미터를 처음 읽는 문장' 을 본다 — 재진입 잠금 해제와
        # last-wins 시퀀스 토큰 가드는 sentinel 가드보다 앞서는 것이 옳기 때문이다.
        seg_start = max([body.rfind(ch, 0, hit.start()) for ch in ";{}\n"] + [-1]) + 1
        line_end = body.find("\n", hit.start())
        stmt = body[seg_start:line_end if line_end >= 0 else len(body)]
        if _sentinel_guard_re(param).match(stmt):
            continue
        hit_ln = line_of(view, brace + 1 + hit.start())
        if marker_on(hit_ln):
            continue
        found.append((hit_ln,
                      "[M:비동기가드] %s:%d — App.requestFetch 성공 핸들러가 '%s' 를 가드 없이 먼저 읽습니다"
                      "(래퍼는 401/403/500 에 false 를 넘긴다) → 처음 읽는 자리 앞에서 "
                      "if(%s === false) return; (예외 = %s 마커)"
                      % (path, hit_ln, param, param, FETCH_OK_MARKER)))
    return found


def check_js_native_dialog(path, raw, view):
    """룰 N(경고 전용): (line, message) 목록.

    같은 파일이 그 이름을 직접 정의하면(다이얼로그 래퍼 구현부 자신) 그 이름만 스킵한다 —
    파일명을 박아 넣으면 파일이 옮겨가는 순간 조용히 죽는 게이트가 된다(룰 D 의 실패 이력).
    """
    found = []
    raw_lines = raw.splitlines()
    shadowed = set()
    for name in ("alert", "confirm", "prompt"):
        if re.search(r"\bfunction\s+%s\s*\(|\b(?:const|let|var)\s+%s\s*=" % (name, name), view):
            shadowed.add(name)
    for match in NATIVE_DIALOG_RE.finditer(view):
        name = match.group(1)
        if name in shadowed:
            continue
        ln = line_of(view, match.start())
        if 0 < ln <= len(raw_lines) and DIALOG_OK_MARKER in raw_lines[ln - 1]:
            continue
        found.append((ln, "[N:다이얼로그] %s:%d — 네이티브 %s( 금지 → 프로젝트 공통 다이얼로그"
                          "(모달 불가·beforeunload 등 불가피한 폴백이면 %s 마커)"
                      % (path, ln, name, DIALOG_OK_MARKER)))
    return found


def check_js_toast_guard(path, raw, view):
    """룰 Q(경고 전용): (line, message) 목록 — 가드 없는 toast.show( 호출."""
    found = []
    raw_lines = raw.splitlines()
    for match in TOAST_CALL_RE.finditer(view):
        ln = line_of(view, match.start())
        if 0 < ln <= len(raw_lines) and TOAST_OK_MARKER in raw_lines[ln - 1]:
            continue
        window = raw_lines[max(0, ln - 1 - TOAST_GUARD_LOOKBACK):ln]
        if any(TOAST_GUARD_RE.search(line) for line in window):
            continue
        found.append((ln, "[Q:Toast] %s:%d — toast.show( 앞 %d줄 안에 window.toast 가드 없음"
                          "(common.js 가 module 이라 top-level 시점엔 없을 수 있다 → "
                          "if(window.toast && typeof window.toast.show === 'function'); 예외 = %s 마커)"
                      % (path, ln, TOAST_GUARD_LOOKBACK, TOAST_OK_MARKER)))
    return found


def check_template_kebab_name(path):
    """룰 R(경고 전용): 템플릿 파일명의 `-`. 파일 단위라 line 1 로 보고한다."""
    name = os.path.basename(path)
    if "-" not in name:
        return []
    return [(1, "[R:camelCase] %s — 템플릿 파일명 '%s' 에 kebab(-) 금지 → camelCase" % (path, name))]


def check_java_kebab_url(path):
    """룰 R(경고 전용): (line, message) 목록 — @…Mapping URL 세그먼트의 kebab."""
    found = []
    for idx, raw_line in enumerate(read_text(path).splitlines(), 1):
        if KEBAB_OK_MARKER in raw_line:
            continue
        code = JAVA_LINE_COMMENT_RE.sub("", raw_line)
        if not MAPPING_ANNO_RE.search(code):
            continue
        for lit in JAVA_STRLIT_VALUE_RE.finditer(code):
            if MAPPING_NON_PATH_ATTR_RE.search(code[:lit.start()]):
                continue
            for segment in lit.group(1).split("/"):
                if KEBAB_SEGMENT_RE.search(segment):
                    found.append((idx, "[R:camelCase] %s:%d — URL 세그먼트 '%s' 에 kebab(-) 금지 → camelCase"
                                       "(예외 = %s 마커)" % (path, idx, segment, KEBAB_OK_MARKER)))
    return found


def check_template_abs_path(path, raw):
    """룰 O(차단): 템플릿의 평문 /resources 절대경로. (line, message) 목록.

    ⚠️ 같은 태그에 짝이 되는 th:src/th:href 가 있으면 위반이 아니다 — Thymeleaf 가 렌더 때
    평문 속성을 덮어쓰므로 404 가 나지 않고, 평문 쪽은 퍼블 정적 미리보기용 폴백이다.
    이 예외 없이 돌리면 그 관용구를 쓰는 레포에서 정상 마크업이 통째로 차단된다 — 마커를
    공유하는 형제 레포에서 이 예외를 넣기 전 잡히던 위반이 넣은 뒤 전부 사라졌다(=전부 오탐).
    해당 레포의 잔존 위반 조회 = `grep -c '\\[O:절대경로\\]' <lint 출력>`.
    """
    found = []
    lines = raw.splitlines()
    # 주석·<script> 본문은 판정 대상에서 뺀다(오프셋 보존 뷰라 라인번호·마커 조회는 raw 그대로).
    scan = _html_markup_view(raw)
    for match in ABS_RESOURCE_RE.finditer(scan):
        idx = line_of(raw, match.start())
        line = lines[idx - 1] if 0 < idx <= len(lines) else ""
        tag_start = raw.rfind("<", 0, match.start())
        tag_end = raw.find(">", match.end())
        tag = raw[tag_start if tag_start >= 0 else 0:
                  tag_end + 1 if tag_end >= 0 else len(raw)]
        if ABS_PATH_OK_MARKER in line or ABS_PATH_OK_MARKER in tag:
            continue
        attr, url = match.group(1).lower(), match.group(3)
        if re.search(r"\bth:%s\s*=" % attr, tag):
            continue
        found.append((idx, "[O:절대경로] %s:%d — 템플릿 정적자원에 평문 절대경로 '%s' 금지"
                           "(컨텍스트패스가 빠져 404) → th:%s=\"@{%s}\" (예외 = %s 마커)"
                      % (path, idx, url, attr, url, ABS_PATH_OK_MARKER)))
    return found


def check_java_verbs(path):
    """룰 P(경고 전용): (line, message) 목록 — @…Mapping URL 세그먼트 + 메서드명 동작접두어."""
    found = []
    raw = read_text(path)
    lines = raw.splitlines()
    method_scope = path.endswith(P_TARGET_SUFFIXES)
    is_iface = re.search(r"\binterface\s+[A-Za-z_$]", raw) is not None
    for idx, raw_line in enumerate(lines, 1):
        if VERB_OK_MARKER in raw_line:
            continue
        code = JAVA_LINE_COMMENT_RE.sub("", raw_line)
        stripped = code.strip()
        if not stripped or stripped.startswith(("*", "/*", "*/")):
            continue

        # ① @…Mapping 의 URL 세그먼트.
        if MAPPING_ANNO_RE.search(code):
            for literal in JAVA_STRLIT_VALUE_RE.findall(code):
                for segment in literal.split("/"):
                    verb = BANNED_VERB_PREFIX_RE.match(segment)
                    if verb:
                        found.append((idx, "[P:명명] %s:%d — URL 세그먼트 '%s' 의 동작접두어 '%s' 금지"
                                           "(create/modify/delete/read; 예외 = %s 마커)"
                                      % (path, idx, segment, verb.group(0), VERB_OK_MARKER)))

        # ② Controller/Service/ServiceImpl 의 메서드명.
        if not method_scope:
            continue
        name = None
        public_match = PUBLIC_METHOD_RE.match(code)
        if public_match:
            name = public_match.group(1)
        elif is_iface and stripped.endswith(";") and "=" not in stripped:
            # 인터페이스 선언은 public 키워드가 없다(implicit public). 본문 없는 선언만 본다.
            head = stripped.split()[0]
            iface_match = IFACE_METHOD_RE.match(code)
            if iface_match and head not in JAVA_STMT_KEYWORDS:
                name = iface_match.group(1)
        if not name:
            continue
        verb = BANNED_VERB_PREFIX_RE.match(name)
        if verb:
            found.append((idx, "[P:명명] %s:%d — 메서드명 '%s' 의 동작접두어 '%s' 금지"
                               "(create/modify/delete/read; 외부 인터페이스 구현 등 불가피하면 %s 마커)"
                          % (path, idx, name, verb.group(0), VERB_OK_MARKER)))
    return found


def found_msgs(found, allowed):
    """allowed: 'ALL'(audit 전체) | None(신규파일 전 라인) | set(변경 라인만)."""
    if allowed == "ALL" or allowed is None:
        return [msg for _, msg in found]
    return [msg for ln, msg in found if ln in allowed]


# ── 룰 L: 뷰·프래그먼트 참조 정합(리포 전역 스캔) ──────────────────────────
# 컴파일러도 MyBatis 계약검사도 "Java/템플릿 → 템플릿" 참조는 못 본다. 뷰명 오타나
# 프래그먼트 삭제는 런타임 500 으로만 드러난다(기능 제거 시 정의만 지우고 include 를
# 남기는 실패모드). 원칙은 룰 K 와 동일 — **확실히 판정 가능한 것만** 본다:
#   L1: th:replace/insert 의 정적 ~{경로 :: 프래그먼트} → 대상 .html 존재 + 프래그먼트 정의 존재
#   L2: @Controller(비 @RestController) 의 매핑 핸들러 본문 return "뷰경로" → 템플릿 존재
# 표현식(${}·#{})이 낀 동적 참조·@ResponseBody·redirect:/forward: 는 전부 침묵 스킵.
# --changed-only 와 무관하게 전역 스캔한다 — 삭제된 프래그먼트를 가리키는 참조는
# "변경되지 않은 파일"에 있어서 라인 필터로는 영원히 안 잡히기 때문이다.
VIEW_LINT_OK = "lint-view-ok"          # 줄 끝에 달면 그 줄 예외
THYMELEAF_PREFIX_RE = re.compile(r"^\s*spring\.thymeleaf\.prefix\s*=\s*(.+?)\s*$", re.M)
FRAG_REF_RE = re.compile(r'th:(?:replace|insert)\s*=\s*"([^"]*)"')
FRAG_STATIC_RE = re.compile(r'^\s*~\{\s*([^:{}$#]+?)\s*::\s*([A-Za-z0-9_]+)\s*(?:\(.*\))?\s*\}\s*$')
FRAG_DEF_RE = re.compile(r'th:fragment\s*=\s*"\s*([A-Za-z0-9_]+)')
VIEW_MAPPING_RE = re.compile(r'@(?:Get|Post|Put|Delete|Patch|Request)Mapping\b')
VIEW_RESPBODY_RE = re.compile(r'@ResponseBody\b')
VIEW_METHDECL_RE = re.compile(r'^\s*(?:public|protected|private)\s+(?:final\s+)?String\s+\w+\s*\(')
VIEW_RETURN_RE = re.compile(r'return\s+"([^"]*)"\s*;')
VIEW_NAME_RE = re.compile(r'^[A-Za-z0-9_][A-Za-z0-9_/-]*$')


def thymeleaf_roots(project_root):
    """모듈별 (java_src, templates_root). spring.thymeleaf.prefix 를 읽어 실제 뷰 루트를 잡고,
    없으면 관례 경로로 폴백. 템플릿 디렉터리가 없는 모듈은 제외(fail-open)."""
    roots = []
    for name in sorted(os.listdir(project_root)):
        module = os.path.join(project_root, name)
        res = os.path.join(module, "src", "main", "resources")
        if not os.path.isdir(res):
            continue
        prefix = None
        for props in sorted(os.listdir(res)):
            if not (props.startswith("application") and props.endswith(".properties")):
                continue
            match = THYMELEAF_PREFIX_RE.search(read_text(os.path.join(res, props)))
            if match:
                prefix = match.group(1)
                break
        rel = (prefix or "templates/").replace("classpath:", "").lstrip("/")
        troot = os.path.join(res, rel)
        if os.path.isdir(troot):
            roots.append((os.path.join(module, "src", "main", "java"), troot))
    return roots


def _fragment_names(path, cache):
    if path not in cache:
        cache[path] = set(FRAG_DEF_RE.findall(read_text(path)))
    return cache[path]


def check_view_refs(project_root):
    """룰 L: (message,) 목록 반환. 전역 스캔이라 라인 필터를 타지 않는다."""
    found = []
    for java_src, troot in thymeleaf_roots(project_root):
        views = set()
        for path in iter_repo_files(troot, ".html"):
            views.add(os.path.relpath(path, troot)[:-5].replace("\\", "/"))
        defcache = {}

        # L1 — 프래그먼트 참조
        for path in iter_repo_files(troot, ".html"):
            rel = os.path.relpath(path, project_root)
            for lineno, line in enumerate(read_text(path).splitlines(), 1):
                if VIEW_LINT_OK in line:
                    continue
                for raw in FRAG_REF_RE.findall(line):
                    match = FRAG_STATIC_RE.match(raw)
                    if not match:
                        continue  # 동적 참조 — 침묵 스킵
                    tpath, frag = match.group(1), match.group(2)
                    target = os.path.join(troot, tpath + ".html")
                    if not os.path.isfile(target):
                        found.append("[L:뷰참조] %s:%d — 대상 템플릿 없음: %s.html (%s)"
                                     % (rel, lineno, tpath, raw))
                    elif frag not in _fragment_names(target, defcache):
                        found.append("[L:뷰참조] %s:%d — 프래그먼트 미정의: %s :: %s"
                                     % (rel, lineno, tpath, frag))

        # L2 — 컨트롤러 뷰명
        if not os.path.isdir(java_src):
            continue
        for path in iter_repo_files(java_src, ".java"):
            text = read_text(path)
            if "@RestController" in text or "@Controller" not in text:
                continue
            rel = os.path.relpath(path, project_root)
            lines = text.splitlines()
            for start, end in _handler_ranges(lines):
                for idx in range(start, end + 1):
                    line = lines[idx]
                    if VIEW_LINT_OK in line:
                        continue
                    for lit in VIEW_RETURN_RE.findall(line):
                        if lit.startswith(("redirect:", "forward:")):
                            continue
                        if "/" not in lit or not VIEW_NAME_RE.match(lit):
                            continue  # MIME·상수·한글 리터럴 등 — 뷰명 아님
                        if lit not in views:
                            found.append("[L:뷰참조] %s:%d — 템플릿 없음: %s.html"
                                         % (rel, idx + 1, lit))
    return found


def _handler_ranges(lines):
    """매핑 어노테이션이 붙고 String 을 반환하는 핸들러 메서드의 (시작,끝) 인덱스.
    @ResponseBody 는 뷰가 아니므로 제외 — 이걸 안 하면 getContentType() 류
    헬퍼의 "image/jpeg" 가 통째로 오탐된다(실측 18건)."""
    ranges = []
    for idx, line in enumerate(lines):
        if not VIEW_METHDECL_RE.match(line):
            continue
        block = "\n".join(lines[max(0, idx - 12):idx])
        if "}" in block:
            block = block[block.rfind("}") + 1:]   # 직전 메서드 본문 혼입 차단
        if not VIEW_MAPPING_RE.search(block) or VIEW_RESPBODY_RE.search(block):
            continue
        depth, started, end = 0, False, idx
        for j in range(idx, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth <= 0:
                end = j
                break
        ranges.append((idx, end))
    return ranges


def check_publish_js_guard(line_map, violations):
    """룰 D — 퍼블팀 관리 공통 JS '수정' 금지.

    ⚠️ 신규 추가(untracked)는 위반이 아니다. 퍼블 최초 반입·재유입은 정의상 파일이 전부 새로
    들어오는 일이고, 그것까지 막으면 퍼블 반입 자체가 영구히 게이트에 걸린다(2026-08-06 실측:
    예시 레포 첫 퍼블 반입에서 정상 반입분 36건이 통째 위반으로 잡혀 빌드가 막혔다).
    금지 대상은 '이미 있는 퍼블 파일을 우리가 고치는 것'뿐이다.

    line_map 값 규약: None = 신규(untracked) 파일 / set = 변경된 라인번호 집합.
    tracked 파일을 지우고 같은 경로로 새로 만들어도 git 은 M 으로 보므로 이 완화로 우회되지 않는다.
    """
    for path, changed_lines in sorted(line_map.items()):
        if changed_lines is None:
            continue  # 신규 반입 — 수정이 아니다
        low = path.replace("\\", "/").lower()
        for protected in PUBLISH_JS_PROTECTED_RES:
            if protected.search(low):
                violations.append("[D:퍼블공통JS] %s — 퍼블팀 관리 공통 JS 수정 금지(custom JS에서 흡수)" % path)
                break


def check_rule_drift(project_root, warnings):
    """게이트 자가점검 — '보호 대상이 실재하는가'.

    룰이 참조하는 경로가 레포에서 사라지면(퍼블 디렉터리 이동 등) 게이트는 조용히 0건이 되고
    아무도 모른다. 감사에서 룰 D 가 정확히 그 상태였다(2026-08-05). 대상이 0건이면 경고를 낸다.
    """
    hits = 0
    for path in iter_repo_files(project_root, ".js"):
        low = path.replace("\\", "/").lower()
        if any(p.search(low) for p in PUBLISH_JS_PROTECTED_RES):
            hits += 1
            break
    if hits == 0:
        warnings.append("[드리프트] 룰 D 보호 대상(퍼블 공통 JS)이 레포에 0건 — 경로가 이동했거나 "
                        "패턴이 낡았을 수 있습니다(게이트가 아무것도 지키지 않는 상태). "
                        "PUBLISH_JS_PROTECTED_RES 를 실경로와 대조하세요.")


def scan_select_write(project_root, line_map):
    """룰 V — (스캔 파일 수, 경고 목록). line_map 규약은 main 의 changed_lines_for 와 같다(None = 전수)."""
    scanned, warnings = 0, []
    for path in iter_repo_files(project_root, ".java"):
        if not is_lintable_java(path):
            continue
        if line_map is None:
            allowed = "ALL"
        else:
            abspath = os.path.abspath(path)
            if abspath not in line_map:
                continue
            allowed = line_map[abspath]
        scanned += 1
        try:
            found = check_java_select_write(path, read_text(path))
        except Exception as exc:  # 파일 하나의 파싱 실패로 검사 전체를 멈추지 않는다
            warnings.append("[V:읽기전용쓰기] %s — 파싱 실패로 건너뜀(%s)" % (path, type(exc).__name__))
            continue
        warnings.extend(tx_filter_by_lines(found, allowed))
    return scanned, warnings


def main():
    parser = argparse.ArgumentParser(description="프로젝트 컨벤션 정적 검사(텍스트 룰).")
    parser.add_argument("--project-root", "--repo", dest="project_root", default=os.getcwd())
    parser.add_argument("--changed-only", action="store_true",
                        help="변경/스테이징/신규 파일만 검사(harness 기본).")
    parser.add_argument("--force", action="store_true",
                        help="옵트인 마커(.claude/conventions.enabled) 없이도 강제 실행.")
    args = parser.parse_args()

    project_root = os.path.abspath(args.project_root)

    # 옵트인 가드(설정값 격리): 룰셋은 레포별 규약이므로 마커가 있는 레포에서만 실행.
    # harness 는 (예시레포A) 8개 공용 → 마커 없는 형제 레포엔 남의 규칙을 적용하지 않는다.
    marker = os.path.join(project_root, ".claude", "conventions.enabled")
    select_rule = select_write_enabled(project_root)  # 룰 V 는 옵트인 마커와 별개 조건으로 발동
    if not (args.force or os.path.exists(marker)):
        print("Convention lint")
        print("Project root: %s" % project_root)
        print("Skipped — 컨벤션 옵트인 마커 없음(.claude/conventions.enabled). 이 레포는 대상 아님.")
        if not select_rule:
            return 0
        # 룰 V 만 — 경고 전용이라 exit 0 유지.
        v_scanned, v_warnings = scan_select_write(
            project_root, git_changed_line_map(project_root) if args.changed_only else None)
        print("\n룰 V(select* 안의 쓰기)만 실행 — Scanned .java files: %d%s"
              % (v_scanned, " (changed only)" if args.changed_only else ""))
        if v_scanned == 0 and args.changed_only:
            print("SKIPPED — 변경된 .java 가 없어 룰 V 를 검사하지 않았습니다. 통과가 아닙니다.")
        if v_warnings:
            print("\nWARNINGS (비차단 — 빌드 결과에 영향 없음)")
            for item in v_warnings:
                print("- [WARN] %s" % item)
        return 0

    violations = []
    warnings = []  # 룰 F·K·M·N·P·Q·R·S·V 는 경고 전용(비차단) — exit 코드에 영향 없음.
    schema_snapshot = load_schema_snapshot(project_root)  # 없으면 룰 K 스킵
    # 룰 T 는 레포별 옵트인 — escape 함수 계약(이름·역슬래시 처리)이 레포마다 달라 남의 레포를 막지 않는다.
    like_rule = os.path.exists(os.path.join(project_root, ".claude", LIKE_RULE_MARKER))
    # 룰 U 도 레포별 옵트인 — 응답에 주석을 싣지 않기로 정한 레포만 막는다(형제 레포의 퍼블 주석을 막지 않는다).
    comment_rule = os.path.exists(os.path.join(project_root, ".claude", COMMENT_RULE_MARKER))
    # 룰 M·N·O·Q·R 의 .html 대상 경계 = Thymeleaf 템플릿 루트뿐. 퍼블 원본(static/html)은 서버가
    # 렌더하지 않는 정적 미리보기라 절대경로가 정상이며, 읽기 전용이라 고칠 수도 없다.
    # ⚠️ normpath 필수 — spring.thymeleaf.prefix 는 관례상 슬래시로 끝나(classpath:/templates/)
    #    그대로 두면 경계 비교가 '.../templates//' 가 되어 **어떤 파일도 매칭되지 않는다**
    #    (픽스처 양성대조에서 룰 O 가 조용히 0건으로 나와 잡혔다).
    template_roots = [os.path.normpath(troot) for _, troot in thymeleaf_roots(project_root)]

    line_map = None
    if args.changed_only:
        line_map = git_changed_line_map(project_root)
        # 룰 D 는 git diff 기반이라 changed-only 일 때만 의미(변경 파일 경로 가드).
        # line_map 을 통째 넘긴다 — 신규(None)와 수정(set)을 구분해야 하기 때문.
        check_publish_js_guard(line_map, violations)

    def changed_lines_for(path):
        # changed-only 면 변경 라인 집합(또는 신규파일 None), 아니면 전체(audit 모드 sentinel).
        if line_map is None:
            return "ALL"
        abspath = os.path.abspath(path)
        return line_map[abspath] if abspath in line_map else "SKIP"

    scanned = 0
    for path in iter_repo_files(project_root, ".xml"):
        if not is_mapper_xml(path):
            continue
        allowed = changed_lines_for(path)
        if allowed == "SKIP":
            continue
        scanned += 1
        found = check_mapper_xml(path, like_rule)
        violations.extend(found_msgs(found, allowed))
        warnings.extend(found_msgs(check_mapper_xml_delete_warn(path), allowed))
        if schema_snapshot:
            warnings.extend(found_msgs(check_mapper_xml_schema(path, schema_snapshot), allowed))

    for path in iter_repo_files(project_root, ".js"):
        if not is_lintable_js(path):
            continue
        allowed = changed_lines_for(path)
        if allowed == "SKIP":
            continue
        scanned += 1
        found = check_js(path)
        violations.extend(found_msgs(found, allowed))
        # 룰 M·N·Q — 문자열·주석을 오프셋 보존 블랭킹한 뷰에서 판정.
        raw_js = read_text(path)
        js_view = JS_BLANK_RE.sub(_blank, raw_js)
        warnings.extend(found_msgs(check_js_fetch_guard(path, raw_js, js_view), allowed))
        if DEV_JS_DIR in path.replace("\\", "/"):
            warnings.extend(found_msgs(check_js_native_dialog(path, raw_js, js_view), allowed))
            warnings.extend(found_msgs(check_js_toast_guard(path, raw_js, js_view), allowed))

    # 룰 C 는 .js 만 보던 탓에, 같은 그리드 옵션을 템플릿 인라인 <script> 로 옮기면 통째로 우회됐다
    # (2026-08-05 감사). .html 의 <script> 블록도 같은 패턴으로 검사한다(라인번호는 파일 기준 유지).
    # 룰 M·N·Q 도 같은 사각을 공유하므로 같은 뷰에서 함께 본다. 룰 O 는 템플릿 루트 한정.
    for path in iter_repo_files(project_root, ".html"):
        allowed = changed_lines_for(path)
        if allowed == "SKIP":
            continue
        # .xml·.js·.java 루프와 같은 자리에서 스캔 모집단에 계상한다 — 빠뜨리면 .html 만 바뀐
        # 커밋에서 룰 O 가 차단까지 해놓고 아래 SKIPPED 문구가 '한 건도 검사하지 않았습니다'
        # 라고 단언한다(2026-09-18 실측: Scanned files: 0 + VIOLATIONS [O:절대경로] 동시 출력).
        scanned += 1
        found = check_html_inline_script(path)
        if found:
            violations.extend(found_msgs(found, allowed))
        # 룰 M·N·O·Q·R 의 .html 대상 = **Thymeleaf 템플릿 루트 안**뿐. 퍼블 원본(static/html)과
        # 문서 폴더의 HTML 은 우리가 고치지 않는 남의 자산이라, 거기서 경고를 내면 영원히
        # 안 없어지는 잡음이 된다(실측: 이 경계가 없을 때 룰 N 이 9건 → 17건으로 불었다).
        if not any(path.startswith(troot + os.sep) for troot in template_roots):
            continue
        raw_html = read_text(path)
        script_view = _html_script_view(raw_html)
        if script_view is not None:
            html_view = JS_BLANK_RE.sub(_blank, script_view)
            warnings.extend(found_msgs(check_js_fetch_guard(path, raw_html, html_view), allowed))
            warnings.extend(found_msgs(check_js_native_dialog(path, raw_html, html_view), allowed))
            warnings.extend(found_msgs(check_js_toast_guard(path, raw_html, html_view), allowed))
        violations.extend(found_msgs(check_template_abs_path(path, raw_html), allowed))
        if comment_rule:
            violations.extend(found_msgs(check_template_comment(path, raw_html), allowed))
        # 룰 R 파일명은 줄이 아니라 파일 속성이라 변경 줄 필터를 걸지 않는다(스코프에 든 파일이면 본다).
        warnings.extend(found_msgs(check_template_kebab_name(path), "ALL"))

    for path in iter_repo_files(project_root, ".java"):
        if not is_lintable_java(path):
            continue
        allowed = changed_lines_for(path)
        if allowed == "SKIP":
            continue
        scanned += 1
        found = check_java(path)
        violations.extend(found_msgs(found, allowed))
        warnings.extend(found_msgs(check_java_verbs(path), allowed))
        warnings.extend(found_msgs(check_java_kebab_url(path), allowed))
        warnings.extend(tx_filter_by_lines(check_java_tx_multiwrite(path, read_text(path)), allowed))

    if select_rule:
        warnings.extend(scan_select_write(project_root, line_map)[1])

    # 룰 L 은 전역 스캔(라인 필터 미적용) — 삭제된 프래그먼트를 가리키는 참조는
    # '변경되지 않은 파일'에 남아 있어 changed-only 로는 영원히 안 잡힌다.
    violations.extend(check_view_refs(project_root))

    # 게이트 자가점검 — 룰이 지키기로 한 대상이 레포에서 사라졌는지(드리프트).
    check_rule_drift(project_root, warnings)

    print("Convention lint")
    print("Project root: %s" % project_root)
    if args.changed_only:
        print("Scope: changed files only")
    print("Scanned files: %d" % scanned)
    print("Violations: %d" % len(violations))

    # '검사 대상 0건'과 '위반 0건'을 구분해 출력한다.
    # 이전에는 둘 다 'Violations: 0 / OK' 로 똑같이 초록불이라, 커밋 직후처럼 diff 가 비는 순간
    # (--changed-only 스코프 0건) 위반이 있어도 통과로 읽혔다 — 침묵이 성공처럼 보이는 구조(2026-08-05 감사).
    if scanned == 0 and args.changed_only:
        print("\nSKIPPED — 변경 파일이 없어 라인 룰(A~H·K·M~V)을 **한 건도 검사하지 않았습니다**. 통과가 아닙니다.")
        print("  · 커밋 이후에는 git diff 가 비어 스코프가 0건이 됩니다 → 커밋 **전에** 실행하거나,")
        print("    이미 커밋했다면 --changed-only 없이(전수) 다시 돌리세요.")
        print("  · 룰 L(뷰·프래그먼트 참조)만 전역 스캔이라 위에 반영돼 있습니다.")

    if warnings:
        print("\nWARNINGS (비차단 — 빌드 결과에 영향 없음)")
        for item in warnings:
            print("- [WARN] %s" % item)

    if violations:
        print("\nVIOLATIONS")
        for item in violations:
            print("- %s" % item)
        return 1

    print("OK — 컨벤션 위반 없음")
    return 0


if __name__ == "__main__":
    sys.exit(main())
