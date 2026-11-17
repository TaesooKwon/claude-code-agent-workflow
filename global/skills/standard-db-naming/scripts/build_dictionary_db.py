from __future__ import annotations

import sqlite3
import sys
from pathlib import Path
from typing import Final

from parse_standard_excel import read_sheet_rows

TERM_FILE: Final = "TermList.xlsx"
WORD_FILE: Final = "WordList.xlsx"
DOMAIN_FILE: Final = "DomainList.xlsx"


def _source_id(raw: str) -> int:
    try:
        return int(float(raw))
    except ValueError:
        return 0


def _number_text(raw: str) -> str:
    try:
        number = float(raw)
    except ValueError:
        return raw.strip()
    if number.is_integer():
        return str(int(number))
    return str(number)


def _sql_type(data_type: str, length: str, scale: str) -> str:
    base = data_type.strip().upper()
    size = _number_text(length)
    decimal = _number_text(scale)
    if base in {"DATE", "DATETIME", "TIME"}:
        return base
    if base in {"NUMERIC", "NUMBER", "DECIMAL"}:
        if decimal != "" and decimal != "0":
            return f"{base}({size},{decimal})"
        return f"{base}({size})"
    if size != "":
        return f"{base}({size})"
    return base


def _create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        "drop table if exists standard_terms;"
        "drop table if exists standard_words;"
        "drop table if exists standard_domains;"
        "create table standard_terms ("
        "id integer primary key,"
        "logical_name text not null unique,"
        "physical_name text not null unique,"
        "domain_name text not null,"
        "data_type text not null,"
        "composition text not null,"
        "formal_english_name text not null,"
        "definition text not null"
        ");"
        "create table standard_words ("
        "id integer not null,"
        "word_name text not null,"
        "abbreviation text not null,"
        "formal_english_name text not null,"
        "definition text not null"
        ");"
        "create table standard_domains ("
        "id integer primary key,"
        "domain_name text not null unique,"
        "data_type text not null,"
        "length text not null,"
        "scale text not null,"
        "sql_type text not null,"
        "definition text not null"
        ");"
        "create index idx_standard_words_name on standard_words(word_name);"
        "create index idx_standard_terms_logical on standard_terms(logical_name);"
        "create index idx_standard_domains_name on standard_domains(domain_name);"
    )


def build_dictionary_db(asset_dir: Path, output_path: Path) -> None:
    terms = read_sheet_rows(asset_dir / TERM_FILE).rows
    words = read_sheet_rows(asset_dir / WORD_FILE).rows
    domains = read_sheet_rows(asset_dir / DOMAIN_FILE).rows

    with sqlite3.connect(output_path) as conn:
        _create_schema(conn)
        conn.executemany(
            "insert into standard_terms values (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    _source_id(row["번호"]),
                    row["용어명"],
                    row["용어영문명"],
                    row["도메인명"],
                    row["데이터타입"],
                    row["용어구성"],
                    row["용어영문정식명"],
                    row["정의"],
                )
                for row in terms
            ],
        )
        conn.executemany(
            "insert into standard_words values (?, ?, ?, ?, ?)",
            [
                (
                    _source_id(row["번호"]),
                    row["단어명"],
                    row["단어영문명"],
                    row["단어영문정식명"],
                    row["정의"],
                )
                for row in words
            ],
        )
        conn.executemany(
            "insert into standard_domains values (?, ?, ?, ?, ?, ?, ?)",
            [
                (
                    _source_id(row["번호"]),
                    row["도메인명"],
                    row["데이터타입"],
                    _number_text(row["길이"]),
                    _number_text(row["소수점"]),
                    _sql_type(row["데이터타입"], row["길이"], row["소수점"]),
                    row["정의"],
                )
                for row in domains
            ],
        )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: build_dictionary_db.py <asset-dir> <output-sqlite>", file=sys.stderr)
        return 2
    build_dictionary_db(Path(argv[1]), Path(argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
