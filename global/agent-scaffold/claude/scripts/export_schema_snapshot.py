#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dev DB 스키마 스냅샷 추출기 (스캐폴드 템플릿).

information_schema 에서 테이블·컬럼 메타를 읽어 JSON 스냅샷으로 저장한다.
용도: ①harness 컨벤션 룰 K(매퍼↔실스키마 대조 lint)의 대조 기준 스냅샷
     ②CRUD 스캐폴드 생성기의 입력
     ③MCP/DB 왕복 없이 로컬 grep 으로 컬럼 확인(토큰 절약)

- 접속정보: 관리자 모듈 application.properties + application-dev.properties 를 겹쳐 로드
  (프로파일 분리 이후 베이스는 비어 있다). 비밀번호는 출력하지 않는다.
- 안전가드: DEV_HOST_ALLOWLIST 밖 호스트면 즉시 중단(운영 보호).
  ※ 부트스트랩 시 프로젝트 dev 호스트를 DEV_HOST_ALLOWLIST 에 추가할 것.
- 출력: <프로젝트>/.claude/schema-snapshot.json (git 격리 영역 — 커밋 안 됨)
- 사용:
    export_schema_snapshot.py            # 스냅샷 생성/갱신
    export_schema_snapshot.py --stdout   # 파일 저장 없이 표준출력
"""
import json
import re
import sys
import os
import datetime

# 부트스트랩 시 프로젝트 dev 호스트 추가 (예: {"localhost", "127.0.0.1", "dev.example.com"})
DEV_HOST_ALLOWLIST = {"localhost", "127.0.0.1"}   # ⚠️ 설치 시 이 레포 dev DB 호스트를 추가
PROJECT_DIR = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())
_RES = os.path.join(PROJECT_DIR, "{{MODULE_ADMIN}}/src/main/resources")
# 환경별 프로파일 분리를 쓰는 레포에서는 베이스가 접속정보를 비워 둔다(안전 기본값).
# 뒤 파일이 앞 파일을 덮어쓴다 — 실제 값은 dev 프로파일에 있다.
# 운영(prod) 프로파일은 의도적으로 읽지 않는다(스냅샷은 dev 스키마 전용).
PROPS_CHAIN = [
    os.path.join(_RES, "application.properties"),
    os.path.join(_RES, "application-dev.properties"),
]
OUT_PATH = os.path.join(PROJECT_DIR, ".claude/schema-snapshot.json")


def load_conn_info():
    props = {}
    for path in PROPS_CHAIN:
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("Globals.mariadb.") and "=" in line:
                    k, v = line.split("=", 1)
                    v = v.strip()
                    if v:  # 베이스의 빈 값이 dev 값을 지우지 않도록
                        props[k.split(".")[-1]] = v
    url = props.get("Url", "")
    m = re.search(r"(?:mariadb|mysql)://([^:/]+):(\d+)/([^?;\s]+)", url)
    if not m:
        sys.exit("[중단] properties 에서 mariadb URL 파싱 실패: %s" % re.sub(r"//.*", "//****", url))
    host, port, db = m.group(1), int(m.group(2)), m.group(3)
    if host not in DEV_HOST_ALLOWLIST:
        sys.exit("[중단] '%s' 는 dev allowlist 에 없음 — 운영 보호 가드. 실행 거부." % host)
    return dict(host=host, port=port, database=db,
                user=props["UserName"], password=props["Password"])


def main():
    info = load_conn_info()
    import pymysql
    conn = pymysql.connect(charset="utf8mb4", **info)
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT TABLE_NAME, TABLE_COMMENT FROM information_schema.TABLES "
            "WHERE TABLE_SCHEMA=%s AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME",
            (info["database"],),
        )
        tables = {}
        for tbl, tcomment in cur.fetchall():
            tables[tbl.lower()] = {"comment": tcomment or "", "columns": {}}
        cur.execute(
            "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, "
            "COLUMN_DEFAULT, EXTRA, COLUMN_COMMENT FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA=%s ORDER BY TABLE_NAME, ORDINAL_POSITION",
            (info["database"],),
        )
        for tbl, col, ctype, nullable, key, default, extra, comment in cur.fetchall():
            t = tables.get(tbl.lower())
            if t is None:
                continue  # 뷰 등 BASE TABLE 밖은 제외
            t["columns"][col.lower()] = {
                "type": ctype,
                "nullable": nullable == "YES",
                "key": key or "",
                "default": default,
                "extra": extra or "",
                "comment": comment or "",
            }
    finally:
        conn.close()

    snapshot = {
        "database": info["database"],
        "host": info["host"],
        "generated_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "table_count": len(tables),
        "tables": tables,
    }
    payload = json.dumps(snapshot, ensure_ascii=False, indent=1)
    if "--stdout" in sys.argv:
        print(payload)
    else:
        with open(OUT_PATH, "w", encoding="utf-8") as f:
            f.write(payload)
        print("[완료] %s — 테이블 %d개, 컬럼 %d개" % (
            OUT_PATH, len(tables), sum(len(t["columns"]) for t in tables.values())))


if __name__ == "__main__":
    main()
