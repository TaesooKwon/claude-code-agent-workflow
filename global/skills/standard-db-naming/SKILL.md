---
name: standard-db-naming
description: Use this skill when creating or reviewing database table names, column names, and SQL data types from Korean business terms using administrative standard terms, words, and domains.
---

# Standard DB Naming

Use this skill when a user asks to create DB table names, column names, DDL, ERD fields, or table definitions from Korean business names.

This skill only reviews or generates names, SQL data types, and DDL drafts. Do not connect to MariaDB or any live database, and do not apply generated SQL automatically unless the user explicitly asks for execution.

The source dictionaries are **not included in this repository** (dictionaries are project-specific and not redistributed). Place your own copies in `assets/` before first use:

- `assets/TermList.xlsx`: standard terms, physical column names, domains, and SQL data types — header columns `번호`·`용어명`·`용어영문명`·`도메인명`·`데이터타입`·`용어구성`·`용어영문정식명`·`정의`
- `assets/WordList.xlsx`: standard Korean words and English abbreviations — `번호`·`단어명`·`단어영문명`·`단어영문정식명`·`정의`
- `assets/DomainList.xlsx`: standard domains and SQL type rules — `번호`·`도메인명`·`데이터타입`·`길이`·`소수점`·`정의`

A good public source is the Korean government's 공공데이터 공통표준용어·단어·도메인 (data.go.kr); rename its headers to the columns above if they differ.

Important: exported XLSX files may contain valid sheet XML but incorrect worksheet dimensions (`A1`). Do not rely on workbook `max_row` or `max_column`; use the bundled parser scripts.

## Workflow

1. Build or reuse the local dictionary DB:
   - Run `scripts/build_dictionary_db.py assets standard_dictionary.sqlite` (stdlib only; runs on the stock macOS `python3`). `standard_dictionary.sqlite` is a build artifact (git-ignored), so run this once after placing the XLSX files and again whenever they change.
   - There is no name-suggestion automation script in this skill: look terms, words, and domains up with direct SQLite queries against `standard_dictionary.sqlite` (see `references/schema.md`) and apply the rules below yourself.
   - For other DBMSs, use a separately provided read-only schema export in the same JSON shape described in `references/schema.md`.
2. For columns:
   - First search `standard_terms.logical_name` by exact Korean logical name.
   - If found, use its `physical_name`, `domain_name`, and `data_type`.
   - If not found, split the logical name into `standard_words.word_name` tokens and join their abbreviations with underscores.
   - Infer type from the final semantic token and `standard_domains`.
   - 숫자형 컬럼은 `INT`보다 `DECIMAL`을 우선 사용한다. 표준 사전 또는 기존 스키마가 `INT`를 명시한 경우에만 예외로 둔다.
   - 코드(예: `CD`, `CODE` 등으로 끝나는 컬럼 등)가 들어가는 컬럼은 `CHAR(10)`으로 지정하여 적용한다.
   - Mark non-exact names as candidates, not confirmed standard terms.
   - If the same logical column name appears in multiple generated tables, reuse exactly the same physical column name and SQL data type.
   - If a repeated logical column would produce a different physical name or type, treat it as a conflict and stop for user confirmation.
3. For tables:
   - Split the business entity name into standard words.
   - Respect the user's requested letter case: `lower` or `upper`.
   - Use project prefixes:
     - `tn_`: normal business table
     - `tc_`: common table
     - `th_`: log or history table
   - Apply suffix rules:
     - history: `_hist`
     - detail: `_dtl`
     - code: `_cd`
     - mapping or relation: `_map`
     - change log: `_log`
4. Always return the basis for each generated name:
   - exact standard term, word composition, inferred domain, or non-standard warning.
5. Maintain a per-request column registry:
   - key: logical column name
   - value: physical column name, SQL data type, and domain
   - every repeated logical column must match the first registered value.
6. When an existing schema snapshot is provided:
   - Compare generated physical column names with existing DB columns.
   - If an existing column has the same physical name, its SQL data type must match the generated SQL data type.
   - Report mismatches before producing final DDL.

## Table Naming Rules

- Normal table: `tn_` + entity words.
- Common table: `tc_` + entity words.
- Log/history table: `th_` + base entity words + log/history suffix.
- If the user requests uppercase, return names like `TN_SITE`; if lowercase, return names like `tn_site`.
- Prefer explicit user table kind over inference. If omitted:
  - names containing `로그` or `이력` are history/log tables
  - names containing `공통` are common tables
  - otherwise use normal tables
- Use `COM` for the duplicated word `공통` in table names, matching examples such as `tc_com_cd`.

Examples:

| Korean table | Kind | lower result |
|---|---:|---|
| 사이트 | normal | `tn_site` |
| 사이트도메인 | normal | `tn_site_dmn` |
| 공통코드 | common | `tc_com_cd` |
| 공통코드변경로그 | history | `th_com_cd_log` |

## Output Contract

When producing table definitions, include:

- logical table name
- physical table name
- logical column name
- physical column name
- SQL data type
- naming basis
- repeated-column consistency status
- existing-schema consistency status, if provided
- warnings, if any

Read `references/naming_rules.md` for detailed naming behavior and `references/schema.md` for the dictionary DB schema.
