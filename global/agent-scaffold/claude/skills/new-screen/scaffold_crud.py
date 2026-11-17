#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CRUD 스캐폴드 생성기 (eGov/Spring Boot 2.7 + Maven 멀티모듈 + MyBatis 하우스 패턴).

.claude/schema-snapshot.json의 실스키마(컬럼·코멘트·PK)를 읽어 하우스 패턴
(Core 최신형 + BO 웹레이어, 상충 교정안 반영)의 CRUD 골격을 생성한다.

※ 이 파일은 이식용 스캐폴드 사본이다. 아래 "부트스트랩 재추출(REEXTRACT)" 구간의
  회사·프로젝트 고유값(모듈 디렉터리·패키지 base·소스 레이아웃·공통 유틸/JS 네임스페이스)을
  대상 레포 실측으로 채워야 동작한다(미치환 시 _guard_reextract()가 기동 차단).
  생성기 골격·치환 로직·게이트 준수 계약은 스택 공통이라 그대로 둔다.

산출(기본 Core 8):
  PaXxxSrch / PaXxx / RsXxx dto, entity Xxx, XxxMapper, XxxService, XxxServiceImpl, XxxMapper_sql.xml
--admin 시 +5:
  MngXxxController, xxxIndex.html, xxxInsert.html, xxxIndex.js, xxxReg.js

사용:
  python3 scaffold_crud.py --table tn_xxx --domain Xxx --module <module> --pkg <pkg> \
      [--admin] [--pk <컬럼>] [--uuid-prefix <축약>] [--dry-run] [--force]

계약:
  - 기존 파일은 절대 덮어쓰지 않음(충돌 목록 출력 후 중단, --force만 예외).
  - 생성 코드는 레포 게이트(MyBatis 계약·컨벤션 룰 A~H·K·Java8) 무결 통과가 계약.
  - 감사 6종 꼬리(use_yn/frst_reg_dt/frst_rgtr_idntf_no/last_mdfcn_dt/last_mdfr_idntf_no/del_yn)는
    업무컬럼과 분리해 고정부로 생성하며, 테이블에 없는 감사컬럼 라인은 생략.
    단 del_yn 없는 테이블은 소프트 딜리트 불가 → 명확히 중단(스캐폴드 대상 아님).
  - PK 타입: 문자열 PK(기본) = ServiceImpl에서 {{UUID_UTIL_NAME}}.getUUID("<접두>") 채번
    (접두어+33자 > 컬럼 char_len 이면 채번 부적합 → 중단).
    수치 PK(*_sn·decimal/int) = Long, 하우스 관례 MAX+1(read<Domain>NextSn selectKey)로 채번.
    (이 DB엔 auto_increment 컬럼이 없어 useGeneratedKeys 경로는 미지원.)
  - decimal(p,0) p>9·bigint 컬럼 = Java Long, 그 외 수치 = Integer.
  - 민감컬럼(*_pswd/*_pwd/*_salt/*_token) = 목록 응답 DTO·목록 SELECT·그리드에서 제외(입력/상세엔 유지).
"""

from __future__ import print_function

import argparse
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATE_DIR = os.path.join(SCRIPT_DIR, "templates")
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
SNAPSHOT_PATH = os.path.join(REPO_ROOT, ".claude", "schema-snapshot.json")

# ═══════════════════════════════════════════════════════════════════════════
# 부트스트라핑 재추출 구간 (REEXTRACT) — /bootstrap-project 시 대상 레포에서 채운다.
#   회사·프로젝트 고유값만 여기 모았다. 미치환({{...}} 잔존) 시 _guard_reextract()가 기동 차단.
#   채우는 법: 대상 레포의 실제 모듈 디렉터리·소스 트리·공통 유틸/JS 네임스페이스를 실측.
# ═══════════════════════════════════════════════════════════════════════════
MODULE_CORE = "{{MODULE_CORE}}"        # Core 모듈 디렉터리명 (예 App-Core)
MODULE_ADMIN = "{{MODULE_ADMIN}}"      # BO 모듈 디렉터리명 (예 App-Admin)
# 소스 트리 상대경로(모듈 루트 이하, 슬래시 구분). 말미 {module}/{pkg} 는 생성기가 붙인다.
PKG_PATH_CORE = "{{PKG_PATH_CORE}}"          # java 이하 Core 패키지 경로 예: com/example/app/core
PKG_PATH_CORE_XML = "{{PKG_PATH_CORE_XML}}"  # egovframework/mapper 이하 예: com/example/app
PKG_PATH_ADMIN = "{{PKG_PATH_ADMIN}}"        # java 이하 BO 패키지 경로 예: com/example/app/admin  (…/web 는 생성기가 붙임)
PKG_PATH_ADMIN_TPL = "{{PKG_PATH_ADMIN_TPL}}"  # templates 이하 예: com/example/app
PKG_PATH_ADMIN_JS = "{{PKG_PATH_ADMIN_JS}}"    # static/resources/js 이하 예: app
UUID_UTIL_NAME = "{{UUID_UTIL_NAME}}"  # UUID 채번 유틸 단순명 (getUUID(prefix) 제공) — 템플릿 import FQN은 {{UUID_UTIL_FQN}}
JS_NS = "{{JS_NS}}"                     # 프론트 공통 JS 네임스페이스 (예 App → App.alert/App.paging)

# 아래 감사컬럼·사이트컬럼은 eGov standard-db-naming(스택 공통) 기본값이다.
# 대상 레포가 다른 감사 명명표준을 쓰면 이 상수 + build_blocks 내 감사 리터럴을 재추출로 맞춘다.
AUDIT_COLS = ["use_yn", "frst_reg_dt", "frst_rgtr_idntf_no",
              "last_mdfcn_dt", "last_mdfr_idntf_no", "del_yn"]
SITE_COL = "site_idntf_no"             # 멀티테넌트 스코핑 컬럼(해당 없으면 빈 문자열 "")


def _split_path(rel):
    return [seg for seg in rel.split("/") if seg]


def _guard_reextract():
    """부트스트랩 미완료(플레이스홀더 잔존) 감지 시 명확히 중단."""
    pending = []
    for name in ("MODULE_CORE", "MODULE_ADMIN", "PKG_PATH_CORE", "PKG_PATH_CORE_XML",
                 "PKG_PATH_ADMIN", "PKG_PATH_ADMIN_TPL", "PKG_PATH_ADMIN_JS",
                 "UUID_UTIL_NAME", "JS_NS"):
        val = globals().get(name, "")
        if "{{" in val or "REEXTRACT" in val:
            pending.append(name)
    if pending:
        die("스캐폴드 미부트스트랩: 다음 REEXTRACT 값을 대상 레포 실측으로 채우세요 → %s "
            "(파일 상단 CONFIG + templates/*.tmpl의 {{...}} 플레이스홀더)"
            % ", ".join(pending))


NUMERIC_TYPES = ("int", "bigint", "smallint", "tinyint", "mediumint",
                 "decimal", "numeric", "float", "double")
# 민감컬럼 접미(비밀번호/솔트/토큰) — 목록 DTO·목록 SELECT·그리드 노출 제외
SENSITIVE_RE = re.compile(r"(?:^|_)(pswd|pwd|salt|token)$")

MARKER_RE = re.compile(r"<<([A-Za-z_][A-Za-z0-9_]*)>>")
IF_RE = re.compile(r"^<<IF:([A-Z_]+)>>$")
ENDIF_RE = re.compile(r"^<<ENDIF:([A-Z_]+)>>$")
BLOCK_RE = re.compile(r"^<<BLOCK:([A-Z_]+)>>$")


def die(msg):
    print("[중단] %s" % msg)
    sys.exit(2)


def snake_to_camel(name):
    parts = name.lower().split("_")
    return parts[0] + "".join(p.capitalize() for p in parts[1:] if p)


def camel_to_pascal(name):
    return name[0].upper() + name[1:] if name else name


# ── 템플릿 엔진 ─────────────────────────────────────────────────────────────
def render(template_text, subs, blocks, conds):
    """라인 기반 렌더링: <<IF:X>>/<<ENDIF:X>> 조건부, <<BLOCK:X>> 블록 삽입(빈 블록=라인 삭제),
    마지막에 <<marker>> 인라인 치환. 블록 내용에는 마커가 없어야 한다(생성기가 실값으로 계산)."""
    out = []
    stack = []
    for line in template_text.split("\n"):
        stripped = line.strip()
        m = IF_RE.match(stripped)
        if m:
            stack.append(bool(conds.get(m.group(1), False)))
            continue
        if ENDIF_RE.match(stripped):
            if not stack:
                die("템플릿 오류: 짝 없는 <<ENDIF>>")
            stack.pop()
            continue
        if stack and not all(stack):
            continue
        m = BLOCK_RE.match(stripped)
        if m:
            name = m.group(1)
            if name not in blocks:
                die("템플릿 블록 미정의: <<BLOCK:%s>>" % name)
            content = blocks[name]
            if content == "":
                continue
            indent = line[:len(line) - len(line.lstrip())]
            for bl in content.split("\n"):
                out.append((indent + bl).rstrip() if not bl.strip() else indent + bl)
            continue
        out.append(line)
    if stack:
        die("템플릿 오류: 닫히지 않은 <<IF>>")
    text = "\n".join(out)

    def sub(match):
        key = match.group(1)
        if key not in subs:
            die("치환 마커 미정의: <<%s>>" % key)
        return subs[key]

    return MARKER_RE.sub(sub, text)


def load_template(name):
    path = os.path.join(TEMPLATE_DIR, name)
    if not os.path.exists(path):
        die("템플릿 파일 없음: %s" % path)
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


# ── 스키마 로드/분류 ────────────────────────────────────────────────────────
class Col(object):
    def __init__(self, name, info):
        self.name = name.lower()
        self.upper = name.upper()
        self.camel = snake_to_camel(name)
        self.pascal = camel_to_pascal(self.camel)
        self.type = (info.get("type") or "").lower()
        self.nullable = bool(info.get("nullable"))
        self.key = (info.get("key") or "").upper()
        self.extra = (info.get("extra") or "").lower()
        default = info.get("default")
        if default is None or str(default).upper() == "NULL":
            self.default = None
        else:
            self.default = str(default).strip("'\"")
        self.comment = (info.get("comment") or "").strip() or self.camel
        base = self.type.split("(")[0].strip()
        self.is_numeric = base in NUMERIC_TYPES
        self.is_datetime = base in ("datetime", "timestamp")
        self.is_yn = self.name.endswith("_yn")
        m = re.match(r"(?:var)?char\((\d+)\)", self.type)
        self.char_len = int(m.group(1)) if m else None
        # decimal/numeric 정밀도·스케일 파싱 (scale 0 · precision>9 = Java Long 매핑 근거)
        self.precision = None
        self.scale = None
        md = re.match(r"(?:decimal|numeric)\((\d+)(?:,\s*(\d+))?\)", self.type)
        if md:
            self.precision = int(md.group(1))
            self.scale = int(md.group(2)) if md.group(2) else 0
        # Java 타입: 비수치=String / bigint·decimal(p,0) p>9 = Long(Integer 범위 초과) / 그 외 수치=Integer
        if not self.is_numeric:
            self.java_type = "String"
        elif base == "bigint":
            self.java_type = "Long"
        elif base in ("decimal", "numeric") and self.scale == 0 and self.precision and self.precision > 9:
            self.java_type = "Long"
        else:
            self.java_type = "Integer"
        # 민감컬럼(비밀번호/솔트/토큰) = 목록 노출 제외 대상
        self.is_sensitive = bool(SENSITIVE_RE.search(self.name))
        # 필수 = NOT NULL 이고 DB 기본값이 없는 컬럼(감사·PK 제외 후 판단)
        self.required = (not self.nullable) and self.default is None \
            and "current_timestamp" not in (self.extra + str(info.get("default") or "").lower())


def load_table(table):
    if not os.path.exists(SNAPSHOT_PATH):
        die("스키마 스냅샷 없음: %s (갱신 = .claude/scripts/export_schema_snapshot.py)" % SNAPSHOT_PATH)
    with open(SNAPSHOT_PATH, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    tables = data.get("tables") or {}
    key = table.lower()
    if key not in tables:
        die("스냅샷에 테이블 '%s' 없음. 스냅샷 갱신 또는 테이블명 확인." % table)
    info = tables[key]
    cols = [Col(name, colinfo) for name, colinfo in (info.get("columns") or {}).items()]
    if not cols:
        die("테이블 '%s' 컬럼 정보가 비어 있음." % table)
    return info.get("comment") or "", cols


# ── 블록 빌더 ───────────────────────────────────────────────────────────────
def build_schema_field(col, extra_annotations=None):
    lines = ['@Schema(description = "%s")' % col.comment]
    lines.extend(extra_annotations or [])
    lines.append("private %s %s;" % (col.java_type, col.camel))
    return "\n".join(lines)


def build_validation_annotations(col):
    anns = []
    if col.is_yn:
        anns.append('@Pattern(regexp = "Y|N", message = "%s은(는) Y 또는 N 이어야 합니다.")' % col.comment)
        return anns
    if col.java_type in ("Integer", "Long"):
        if col.required:
            anns.append('@NotNull(message = "%s은(는) 필수 입력 항목입니다.")' % col.comment)
        return anns
    if col.required:
        anns.append('@NotBlank(message = "%s은(는) 필수 입력 항목입니다.")' % col.comment)
    if col.char_len:
        anns.append('@Size(max = %d, message = "%s은(는) %d자 이내로 입력하세요.")'
                    % (col.char_len, col.comment, col.char_len))
    return anns


def join_fields(field_blocks):
    return "\n\n".join(b for b in field_blocks if b)


def build_select_cols(cols_spec):
    """cols_spec = [(sql_expr, alias)] → 'expr AS alias' 목록(선두 콤마 스타일)."""
    lines = []
    for i, (expr, alias) in enumerate(cols_spec):
        prefix = "" if i == 0 else ","
        lines.append("%s%s AS %s" % (prefix, expr, alias))
    return "\n".join(lines)


def build_blocks(ctx):
    pk = ctx["pk"]
    site = ctx["site"]
    business = ctx["business"]          # use_yn 제외 순수 업무컬럼
    # 민감컬럼(비밀번호/솔트/토큰)은 목록 응답/목록 SELECT/그리드에서 제외(입력·상세엔 유지)
    business_visible = [c for c in business if not c.is_sensitive]
    use_yn = ctx["use_yn"]              # Col 또는 None
    audit = ctx["audit"]                # {name: Col}
    editable = list(business) + ([use_yn] if use_yn else [])  # Pa/폼/INSERT/SET 대상
    search_cols = ([site] if site else []) + [c for c in editable if c.is_yn or c.name.endswith("_cd")]
    kor = ctx["kor"]
    blocks = {}

    # ── PaSrch 검색필드
    blocks["SRCH_FIELDS"] = join_fields([build_schema_field(c) for c in search_cols])

    # ── Pa DTO
    pa_fields = []
    if site:
        pa_fields.append(build_schema_field(site))
    needed = set()
    for c in editable:
        anns = build_validation_annotations(c)
        for a in anns:
            needed.add(a.split("(")[0][1:])
        pa_fields.append(build_schema_field(c, anns))
    blocks["PA_FIELDS"] = join_fields(pa_fields)
    blocks["PA_IMPORTS_VALIDATION"] = "\n".join(
        "import javax.validation.constraints.%s;" % n
        for n in sorted(needed))
    chain_cols = ([site] if site else []) + editable
    blocks["PA_TO_ENTITY"] = "\n".join(".%s(%s)" % (c.camel, c.camel) for c in chain_cols)
    blocks["PA_FROM_ENTITY"] = "\n".join(".%s(entity.get%s())" % (c.camel, c.pascal) for c in chain_cols)

    # ── Rs DTO
    rs_cols = ([site] if site else []) + list(business_visible) + ([use_yn] if use_yn else [])
    rs_fields = [build_schema_field(c) for c in rs_cols]
    for name, label in (("frst_reg_dt", "등록일"), ("last_mdfcn_dt", "수정일")):
        if name in audit:
            rs_fields.append('@Schema(description = "%s")\nprivate String %s;'
                             % (label, snake_to_camel(name)))
    blocks["RS_FIELDS"] = join_fields(rs_fields)

    # ── Entity
    ent = ["// %s" % pk.comment, "private %s %s;" % (ctx["pkType"], pk.camel)]
    for c in ([site] if site else []) + list(business):
        ent.append("// %s" % c.comment)
        ent.append("private %s %s;" % (c.java_type, c.camel))
    blocks["ENTITY_FIELDS"] = "\n".join(ent)
    tail = []
    for name in AUDIT_COLS:
        if name in audit:
            tail.append("// %s" % audit[name].comment)
            tail.append("private String %s;" % snake_to_camel(name))
    blocks["ENTITY_AUDIT"] = "\n".join(tail)

    # ── ServiceImpl create 본문
    if ctx["conds"]["PK_UUID"]:
        blocks["CREATE_BODY"] = "\n".join([
            'String id = %s.getUUID("%s");' % (UUID_UTIL_NAME, ctx["uuidPrefix"]),
            "%s.set%s(id);" % (ctx["domain"], pk.pascal),
            "%sMapper.create%s(%s);" % (ctx["domain"], ctx["Domain"], ctx["domain"]),
            "return id;",
        ])
    else:
        # 수치 PK: 하우스 관례 MAX+1 채번(auto_increment 부재 → useGeneratedKeys 미사용)
        blocks["CREATE_BODY"] = "\n".join([
            "%s.set%s(%sMapper.read%sNextSn());" % (ctx["domain"], pk.pascal, ctx["domain"], ctx["Domain"]),
            "%sMapper.create%s(%s);" % (ctx["domain"], ctx["Domain"], ctx["domain"]),
            "return String.valueOf(%s.get%s());" % (ctx["domain"], pk.pascal),
        ])

    # ── XML: where 조각
    conds_lines = []
    for c in search_cols:
        conds_lines.append("<if test='%s != null and %s != \"\"'>" % (c.camel, c.camel))
        conds_lines.append("    AND a.%s = #{%s}" % (c.upper, c.camel))
        conds_lines.append("</if>")
    blocks["WHERE_CONDS"] = "\n".join(conds_lines)

    # ── XML: 목록/상세 SELECT 컬럼 (AS camelCase 명시 — 상충 교정안)
    list_spec = [("a.%s" % pk.upper, pk.camel)]
    if site:
        list_spec.append(("a.%s" % site.upper, site.camel))
    for c in business_visible:
        expr = "DATE_FORMAT(a.%s, '%%Y-%%m-%%d')" % c.upper if c.is_datetime else "a.%s" % c.upper
        list_spec.append((expr, c.camel))
    if use_yn:
        list_spec.append(("a.USE_YN", "useYn"))
    for name in ("frst_reg_dt", "last_mdfcn_dt"):
        if name in audit:
            list_spec.append(("DATE_FORMAT(a.%s, '%%Y-%%m-%%d')" % name.upper(), snake_to_camel(name)))
    blocks["LIST_COLS"] = build_select_cols(list_spec)

    detail_spec = [("a.%s" % pk.upper, pk.camel)]
    if site:
        detail_spec.append(("a.%s" % site.upper, site.camel))
    for c in business:
        expr = "DATE_FORMAT(a.%s, '%%Y-%%m-%%d %%H:%%i:%%s')" % c.upper if c.is_datetime else "a.%s" % c.upper
        detail_spec.append((expr, c.camel))
    if use_yn:
        detail_spec.append(("a.USE_YN", "useYn"))
    for name in AUDIT_COLS:
        if name == "use_yn" or name not in audit:
            continue
        col = audit[name]
        expr = "DATE_FORMAT(a.%s, '%%Y-%%m-%%d %%H:%%i:%%s')" % col.upper if col.is_datetime else "a.%s" % col.upper
        detail_spec.append((expr, col.camel))
    blocks["DETAIL_COLS"] = build_select_cols(detail_spec)

    if site:
        blocks["DETAIL_SITE_COND"] = "\n".join([
            "<if test='siteIdntfNo != null and siteIdntfNo != \"\"'>",
            "    AND a.SITE_IDNTF_NO = #{siteIdntfNo}",
            "</if>",
        ])
    else:
        blocks["DETAIL_SITE_COND"] = ""

    # ── XML: INSERT (감사컬럼 배열 = admin 순서 교정안:
    #        업무 → FRST_REG_DT,NOW() → FRST_RGTR → LAST_MDFCN_DT,NOW() → LAST_MDFR → DEL_YN)
    ins = []
    # PK는 항상 INSERT 컬럼에 포함(UUID=서비스단 채번, 수치=MAX+1 selectKey 채번 후 세팅)
    ins.append((pk.upper, "#{%s}" % pk.camel))
    if site:
        ins.append((site.upper, "#{%s}" % site.camel))
    for c in editable:
        ins.append((c.upper, "#{%s}" % c.camel))
    if "frst_reg_dt" in audit:
        ins.append(("FRST_REG_DT", "NOW()"))
    if "frst_rgtr_idntf_no" in audit:
        ins.append(("FRST_RGTR_IDNTF_NO", "#{frstRgtrIdntfNo}"))
    if "last_mdfcn_dt" in audit:
        ins.append(("LAST_MDFCN_DT", "NOW()"))
    if "last_mdfr_idntf_no" in audit:
        ins.append(("LAST_MDFR_IDNTF_NO", "#{lastMdfrIdntfNo}"))
    ins.append(("DEL_YN", "'N'"))
    blocks["INSERT_COLS"] = "\n".join(("" if i == 0 else ",") + c for i, (c, _) in enumerate(ins))
    blocks["INSERT_VALS"] = "\n".join(("" if i == 0 else ",") + v for i, (_, v) in enumerate(ins))

    # ── XML: modify 동적 <set>
    set_lines = []
    for c in ([site] if site else []) + editable:
        set_lines.append('<if test="%s != null">' % c.camel)
        set_lines.append("    %s = #{%s}," % (c.upper, c.camel))
        set_lines.append("</if>")
    if "last_mdfcn_dt" in audit:
        set_lines.append("LAST_MDFCN_DT = NOW(),")
    if "last_mdfr_idntf_no" in audit:
        set_lines.append("LAST_MDFR_IDNTF_NO = #{lastMdfrIdntfNo},")
    blocks["SET_LINES"] = "\n".join(set_lines)  # <set>이 말미 콤마 자동 제거

    # ── XML: delete(soft) 감사 SET
    del_sets = []
    if "last_mdfcn_dt" in audit:
        del_sets.append(",LAST_MDFCN_DT = NOW()")
    if "last_mdfr_idntf_no" in audit:
        del_sets.append(",LAST_MDFR_IDNTF_NO = #{lastMdfrIdntfNo}")
    blocks["DELETE_AUDIT_SETS"] = "\n".join(del_sets)

    # ── 컨트롤러: 등록화면 기본값 빌더 체인(Y/N 필드)
    chain = ""
    for c in editable:
        if c.is_yn:
            default = c.default if c.default in ("Y", "N") else "N"
            chain += '.%s("%s")' % (c.camel, default)
    ctx["subs"]["DEFAULT_BUILDER"] = chain

    # ── index.html 검색 옵션
    opts = []
    for c in search_cols:
        if c is site:
            continue  # 사이트 스코핑은 서버 주입 — 검색 UI 미노출
        opts.append('<div class="schbox__option">')
        if c.is_yn:
            opts.append('    <select name="%s" class="select-txt" title="%s">' % (c.camel, c.comment))
            opts.append('        <option value="">%s 전체</option>' % c.comment)
            opts.append('        <option value="Y" th:selected="${search.%s == \'Y\'}">Y</option>' % c.camel)
            opts.append('        <option value="N" th:selected="${search.%s == \'N\'}">N</option>' % c.camel)
            opts.append("    </select>")
        else:
            opts.append("    <!-- TODO(디자인): %s 옵션 목록 확정(공통코드 셀렉트 등) -->" % c.comment)
            opts.append('    <select name="%s" class="select-txt" title="%s">' % (c.camel, c.comment))
            opts.append('        <option value="">%s 전체</option>' % c.comment)
            opts.append("    </select>")
        opts.append("</div>")
    blocks["SEARCH_OPTIONS"] = "\n".join(opts)

    # ── insert.html 폼 행
    rows = []
    for c in editable:
        required_mark = ' <i class="required">필수</i>' if (c.required and not c.is_yn) else ""
        rows.append("<tr>")
        rows.append('    <th scope="row">%s%s</th>' % (c.comment, required_mark))
        rows.append("    <td>")
        if c.is_yn:
            rows.append('        <fieldset class="checkradio-group">')
            rows.append("            <legend>%s 선택</legend>" % c.comment)
            for val, label in (("Y", "예"), ("N", "아니오")):
                rid = "%s%s" % (c.camel, val)
                rows.append('            <div class="checkradio">')
                rows.append('                <input type="radio" id="%s" value="%s" th:field="*{%s}">' % (rid, val, c.camel))
                rows.append('                <label for="%s" class="checkradio__label">' % rid)
                rows.append('                    <i class="ico-checkradio"></i><span class="checkradio__tit">%s</span>' % label)
                rows.append("                </label>")
                rows.append("            </div>")
            rows.append("        </fieldset>")
        else:
            rows.append("        <!-- TODO(디자인): %s 입력 컴포넌트 확정 -->" % c.comment)
            input_type = "number" if c.java_type in ("Integer", "Long") else "text"
            rows.append('        <input type="%s" id="%s" th:field="*{%s}" title="%s">'
                        % (input_type, c.camel, c.camel, c.comment))
        rows.append("    </td>")
        rows.append("</tr>")
    blocks["FORM_ROWS"] = "\n".join(rows)

    # ── index.js 그리드 컬럼(업무컬럼 기반)
    grid = ["{ headerName: 'No', field: 'rowNum', width: 80, flex: 0, headerClass: 'center', cellClass: 'center' },"]
    for c in business_visible:
        grid.append("{ headerName: '%s', field: '%s' }," % (c.comment.replace("'", ""), c.camel))
    if use_yn:
        grid.append("{ headerName: '%s', field: 'useYn', width: 100, flex: 0, headerClass: 'center', cellClass: 'center' },"
                    % use_yn.comment.replace("'", ""))
    if "frst_reg_dt" in audit:
        grid.append("{ headerName: '등록일', field: 'frstRegDt', width: 120, flex: 0, headerClass: 'center', cellClass: 'center' },")
    blocks["GRID_COLUMNS"] = "\n".join(grid)

    # ── reg.js 검증 메시지·클라 검증(필수 필드)
    required_cols = [c for c in editable if c.required and not c.is_yn]
    txts = []
    vals = []
    for c in required_cols:
        txts.append('%sRequired: "%s을(를) 입력하세요.",' % (c.camel, c.comment))
        vals.append("const %sEl = formEl.querySelector('[name=\"%s\"]');" % (c.camel, c.camel))
        vals.append("if (%sEl && !%sEl.value.trim()) {" % (c.camel, c.camel))
        vals.append("    %s.alert(TXT.%sRequired);" % (JS_NS, c.camel))
        vals.append("    %sEl.focus();" % c.camel)
        vals.append("    return;")
        vals.append("}")
    blocks["TXT_MESSAGES"] = "\n".join(txts)
    blocks["CLIENT_VALIDATIONS"] = "\n".join(vals)

    _ = kor  # (한글명은 subs 마커로 사용)
    return blocks


# ── 메인 ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="CRUD 스캐폴드 생성기 (eGov/멀티모듈)")
    parser.add_argument("--table", required=True, help="물리 테이블명(예 tn_sample_rsvt)")
    parser.add_argument("--domain", required=True, help="도메인명 PascalCase(예 EduRsvt)")
    parser.add_argument("--module", required=True, help="모듈 패키지(예 mypkg)")
    parser.add_argument("--pkg", required=True, help="소문자 패키지(예 edursvt)")
    parser.add_argument("--admin", action="store_true", help="BO 웹레이어 5파일 추가 생성")
    parser.add_argument("--pk", help="PK 컬럼 지정(복합PK·PRI 부재 시 필수)")
    parser.add_argument("--uuid-prefix", dest="uuid_prefix", help="UUID 채번 접두 축약(기본 --pkg 값)")
    parser.add_argument("--dry-run", dest="dry_run", action="store_true", help="경로 목록만 출력")
    parser.add_argument("--force", action="store_true", help="기존 파일 덮어쓰기 허용")
    args = parser.parse_args()

    _guard_reextract()

    if not re.match(r"^[A-Z][A-Za-z0-9]*$", args.domain):
        die("--domain 은 PascalCase 여야 함(예 EduRsvt): %s" % args.domain)
    if not re.match(r"^[a-z][a-z0-9]*$", args.pkg):
        die("--pkg 는 소문자 패키지명이어야 함(예 edursvt): %s" % args.pkg)
    if not re.match(r"^[a-z][a-z0-9]*$", args.module):
        die("--module 은 소문자 패키지명이어야 함(예 mypkg): %s" % args.module)

    kor, cols = load_table(args.table)
    by_name = dict((c.name, c) for c in cols)

    # PK 결정
    if args.pk:
        if args.pk.lower() not in by_name:
            die("--pk 컬럼 '%s' 이(가) 테이블에 없음" % args.pk)
        pk = by_name[args.pk.lower()]
    else:
        pris = [c for c in cols if c.key == "PRI"]
        if len(pris) != 1:
            die("PK(PRI) 컬럼이 %d개 — --pk 로 단일 컬럼을 지정하라: %s"
                % (len(pris), ", ".join(c.name for c in pris) or "(없음)"))
        pk = pris[0]

    # 감사/사이트/업무 분류
    audit = dict((c.name, c) for c in cols if c.name in AUDIT_COLS)
    if "del_yn" not in audit:
        die("테이블 '%s' 에 del_yn 없음 — 소프트 딜리트 규약 적용 불가(스캐폴드 대상 아님)." % args.table)
    site = by_name.get(SITE_COL)
    use_yn = audit.get("use_yn")
    business = [c for c in cols
                if c.name not in AUDIT_COLS and c is not pk and c is not site]

    # PK 타입/채번 방식 — 수치(또는 *_sn)=하우스 MAX+1 채번(Long), 그 외=UUID(String).
    # 이 DB엔 auto_increment 컬럼이 없어 useGeneratedKeys 경로는 dead code → 미지원(제거).
    pk_long = pk.is_numeric or pk.name.endswith("_sn")
    pk_type = "Long" if pk_long else "String"

    # UUID 채번 PK: 물리길이(접두어 + '-' + 32hex = 접두어+33) 초과 검증
    if not pk_long:
        uuid_prefix = args.uuid_prefix or args.pkg
        if pk.char_len is None:
            die("UUID 채번 대상 PK '%s'의 물리타입이 char/varchar 가 아님(%s) — 문자열 PK 아님. --pk 재확인." % (pk.name, pk.type))
        needed_len = len(uuid_prefix) + 33
        if needed_len > pk.char_len:
            die("UUID PK 길이 초과: 접두어 '%s'(%d) + 33 = %d > %s %s(len %d). "
                "① --uuid-prefix 로 접두어를 줄이거나 ② 컬럼 길이를 늘리거나 "
                "③ 공유 참조 키(외래 식별자)라면 채번 대상이 아님 — 입력형 PK로 전환하라."
                % (uuid_prefix, len(uuid_prefix), needed_len, pk.name, pk.type, pk.char_len))

    conds = {
        "SITE": site is not None,
        "USE_YN": use_yn is not None,
        "AUDIT_RGTR": "frst_rgtr_idntf_no" in audit,
        "AUDIT_REG_DT": "frst_reg_dt" in audit,
        "AUDIT_MDFR": "last_mdfr_idntf_no" in audit,
        "AUDIT_MDFCN": "last_mdfcn_dt" in audit,
        "AUDIT_USER": ("frst_rgtr_idntf_no" in audit) or ("last_mdfr_idntf_no" in audit),
        "PK_UUID": not pk_long,
        "PK_NUMERIC": pk_long,
    }

    domain = args.domain
    domain_var = domain[0].lower() + domain[1:]
    kor_name = kor.strip() or domain
    subs = {
        "Domain": domain,
        "domain": domain_var,
        "module": args.module,
        "pkg": args.pkg,
        "PkField": pk.pascal,
        "pkField": pk.camel,
        "pkType": pk_type,
        "TABLE": args.table.upper(),
        "PK_COLUMN": pk.upper,
        "uuidPrefix": (args.uuid_prefix or args.pkg),
        "KOR": kor_name,
        "ORDER_BY": ("a.FRST_REG_DT DESC, a.%s DESC" % pk.upper)
                    if "frst_reg_dt" in audit else ("a.%s DESC" % pk.upper),
    }

    ctx = {
        "pk": pk, "site": site, "business": business, "use_yn": use_yn,
        "audit": audit, "conds": conds, "subs": subs,
        "Domain": domain, "domain": domain_var, "kor": kor_name,
        "pkType": pk_type, "uuidPrefix": subs["uuidPrefix"],
    }
    blocks = build_blocks(ctx)

    # 산출 경로
    core_java = os.path.join(REPO_ROOT, MODULE_CORE, "src", "main", "java",
                             *(_split_path(PKG_PATH_CORE) + [args.module, args.pkg]))
    xml_dir = os.path.join(REPO_ROOT, MODULE_CORE, "src", "main", "resources",
                           "egovframework", "mapper",
                           *(_split_path(PKG_PATH_CORE_XML) + [args.module, args.pkg]))
    admin_java = os.path.join(REPO_ROOT, MODULE_ADMIN, "src", "main", "java",
                              *(_split_path(PKG_PATH_ADMIN) + [args.module, args.pkg, "web"]))
    admin_tpl = os.path.join(REPO_ROOT, MODULE_ADMIN, "src", "main", "resources",
                             "templates",
                             *(_split_path(PKG_PATH_ADMIN_TPL) + [args.module, args.pkg]))
    admin_js = os.path.join(REPO_ROOT, MODULE_ADMIN, "src", "main", "resources",
                            "static", "resources", "js",
                            *(_split_path(PKG_PATH_ADMIN_JS) + [args.module, args.pkg]))

    targets = [
        ("PaSrch.java.tmpl", os.path.join(core_java, "dto", "Pa%sSrch.java" % domain)),
        ("Pa.java.tmpl", os.path.join(core_java, "dto", "Pa%s.java" % domain)),
        ("Rs.java.tmpl", os.path.join(core_java, "dto", "Rs%s.java" % domain)),
        ("Entity.java.tmpl", os.path.join(core_java, "entity", "%s.java" % domain)),
        ("Mapper.java.tmpl", os.path.join(core_java, "mapper", "%sMapper.java" % domain)),
        ("Service.java.tmpl", os.path.join(core_java, "service", "%sService.java" % domain)),
        ("ServiceImpl.java.tmpl", os.path.join(core_java, "service", "impl", "%sServiceImpl.java" % domain)),
        ("Mapper_sql.xml.tmpl", os.path.join(xml_dir, "%sMapper_sql.xml" % domain)),
    ]
    if args.admin:
        targets.extend([
            ("MngController.java.tmpl", os.path.join(admin_java, "Mng%sController.java" % domain)),
            ("index.html.tmpl", os.path.join(admin_tpl, "%sIndex.html" % domain_var)),
            ("insert.html.tmpl", os.path.join(admin_tpl, "%sInsert.html" % domain_var)),
            ("indexJs.js.tmpl", os.path.join(admin_js, "%sIndex.js" % domain_var)),
            ("regJs.js.tmpl", os.path.join(admin_js, "%sReg.js" % domain_var)),
        ])

    if args.dry_run:
        for _, path in targets:
            print("WOULD CREATE %s" % path)
        return 0

    conflicts = [path for _, path in targets if os.path.exists(path)]
    if conflicts and not args.force:
        print("[중단] 기존 파일 충돌 %d건 — 덮어쓰지 않음(--force 로만 허용):" % len(conflicts))
        for path in conflicts:
            print("  CONFLICT %s" % path)
        sys.exit(3)

    for tmpl_name, path in targets:
        text = render(load_template(tmpl_name), subs, blocks, conds)
        directory = os.path.dirname(path)
        if not os.path.isdir(directory):
            os.makedirs(directory)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text if text.endswith("\n") else text + "\n")
        print("CREATED %s" % path)

    print("완료: %d파일 생성 (table=%s, domain=%s, pk=%s:%s%s)"
          % (len(targets), args.table, domain, pk.name, pk_type,
             ", uuidPrefix=" + subs["uuidPrefix"] if conds["PK_UUID"] else ""))
    print("다음 단계: harness 게이트(--changed-only) → 컴파일 → 그리드/폼 TODO 마감 → tn_menu 화면 등록")
    return 0


if __name__ == "__main__":
    sys.exit(main())
