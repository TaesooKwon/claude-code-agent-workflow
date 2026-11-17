# Naming Rules

## Priority

1. Exact standard term match
2. Standard word composition
3. Domain suffix inference
4. Non-standard candidate with warning

## Table Prefix

| Kind | Prefix | Use when |
|---|---:|---|
| normal | `tn_` | General business entity |
| common | `tc_` | Common/shared code or reference table |
| history | `th_` | Log, history, audit, event, or change table |

If kind is not provided, infer it from Korean words:

- `로그`, `이력`: history
- `공통`: common
- otherwise: normal

## Table Suffix

| Meaning | Suffix |
|---|---:|
| history | `_hist` |
| detail | `_dtl` |
| code | `_cd` |
| mapping | `_map` |
| relation | `_map` |
| change log | `_log` |

`변경로그` is a special suffix. Drop `변경` from the base entity and append `_log`.

## Letter Case

Use the user's requested case:

- lower: `tn_site_dmn`
- upper: `TN_SITE_DMN`

## Duplicate Standard Words

`공통` exists twice in the word dictionary:

- `CM`
- `COM`

For table names, prefer `COM` so common-code examples become `tc_com_cd` and `th_com_cd_log`.
For columns, exact standard terms take priority. If no exact term exists, use the same `COM` preference for deterministic output.

## Column Domain Inference

When an exact standard term is missing, infer common domains from the final semantic token:

| Ending | Preferred domain |
|---|---:|
| 여부 | `여부C1` |
| 내용 | `내용V4000` |
| 명 | `명V100` |
| 일시 | `연월일시분초D` |
| 일자 | `연월일C8` |
| 수 | `수N10` |
| 금액 | `금액N15` |
| 율 | `율N5.2` |
| 코드 | `코드C10` |

If no domain can be inferred, leave the type blank and emit a warning.

## Repeated Column Consistency

Across all tables generated in the same request, the same logical column name must use the same physical column name and SQL data type.

Examples:

| Logical column | Required result |
|---|---|
| 등록일시 | Always `reg_dt` + `DATETIME` |
| 공통코드명 | Always `com_cd_nm` + `VARCHAR(100)` |

If a duplicate logical column would produce a different physical name or type:

1. Do not silently choose one.
2. Report the conflict.
3. Reuse the exact standard term result if one exists.
4. Ask the user only if the conflict cannot be resolved from the standard dictionary.
