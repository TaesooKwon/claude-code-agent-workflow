# Dictionary DB Schema

The build script creates a SQLite database optimized for lookup by project-generation agents.

## `standard_terms`

| Column | Meaning |
|---|---|
| `id` | Source row number |
| `logical_name` | Korean standard term |
| `physical_name` | Standard physical column name |
| `domain_name` | Standard domain name |
| `data_type` | SQL data type from source term |
| `composition` | Korean word composition separated by `_` |
| `formal_english_name` | Full English name |
| `definition` | Korean definition |

## `standard_words`

| Column | Meaning |
|---|---|
| `id` | Source row number |
| `word_name` | Korean word |
| `abbreviation` | English abbreviation |
| `formal_english_name` | Full English word |
| `definition` | Korean definition |

## `standard_domains`

| Column | Meaning |
|---|---|
| `id` | Source row number |
| `domain_name` | Korean domain name |
| `data_type` | Base SQL type |
| `length` | Type length |
| `scale` | Numeric scale |
| `sql_type` | Normalized SQL type |
| `definition` | Korean definition |

Indexes are created for exact term, word, and domain lookups.

## Existing Schema Snapshot

Existing DB schemas can be checked without writing to the DB. Use this JSON shape:

```json
{
  "columns": [
    {
      "table_name": "tn_student",
      "column_name": "reg_dt",
      "data_type": "DATETIME"
    }
  ]
}
```

Gather it yourself from the target database — this skill bundles no inspection script.
For SQLite: `sqlite3 project.sqlite '.schema'`. For MySQL/MariaDB: query
`information_schema.columns`. Read the existing physical names and types directly.

Then reuse those existing physical names and types verbatim for every column whose
logical meaning already exists in the project — one logical column must never get a
second, differently-spelled physical name. Check that consistency yourself; there is no
tool that reports it for you.
