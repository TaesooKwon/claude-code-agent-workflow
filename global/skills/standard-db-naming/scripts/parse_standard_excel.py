from __future__ import annotations

import json
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Final
from xml.etree import ElementTree

NS: Final = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
CELL_REF_PATTERN: Final = re.compile(r"([A-Z]+)([0-9]+)")


# dataclass(slots=True) is Python 3.10+; omitted so these scripts run on the
# stock macOS python3 (3.9.x). slots is an optimization only, not behavior.
@dataclass(frozen=True)
class WorkbookRows:
    headers: list[str]
    rows: list[dict[str, str]]


@dataclass(frozen=True)
class WorkbookParseError(Exception):
    path: Path
    detail: str

    def __str__(self) -> str:
        return f"{self.path}: {self.detail}"


def _column_index(cell_ref: str) -> int:
    match = CELL_REF_PATTERN.match(cell_ref)
    if match is None:
        return 0
    value = 0
    for char in match.group(1):
        value = (value * 26) + ord(char) - 64
    return value


def _shared_strings(workbook: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in workbook.namelist():
        return []
    root = ElementTree.fromstring(workbook.read("xl/sharedStrings.xml"))
    values: list[str] = []
    for item in root.findall(f"{NS}si"):
        values.append("".join(text.text or "" for text in item.iter(f"{NS}t")))
    return values


def _cell_text(cell: ElementTree.Element, shared_strings: list[str]) -> str:
    cell_type = cell.attrib.get("t", "")
    if cell_type == "inlineStr":
        return "".join(text.text or "" for text in cell.iter(f"{NS}t")).strip()
    value = cell.find(f"{NS}v")
    if value is None or value.text is None:
        return ""
    raw = value.text.strip()
    if cell_type == "s":
        return shared_strings[int(raw)].strip()
    return raw


def _row_values(row: ElementTree.Element, shared_strings: list[str]) -> list[str]:
    values: list[str] = []
    for cell in row.findall(f"{NS}c"):
        index = _column_index(cell.attrib.get("r", ""))
        while len(values) < index:
            values.append("")
        values[index - 1] = _cell_text(cell, shared_strings)
    return values


def read_sheet_rows(path: Path, sheet_xml: str = "xl/worksheets/sheet1.xml") -> WorkbookRows:
    try:
        with zipfile.ZipFile(path) as workbook:
            shared_strings = _shared_strings(workbook)
            source = workbook.open(sheet_xml)
            raw_rows: list[list[str]] = []
            for event, element in ElementTree.iterparse(source, events=("end",)):
                if element.tag == f"{NS}row":
                    values = _row_values(element, shared_strings)
                    if any(value != "" for value in values):
                        raw_rows.append(values)
                    element.clear()
    except (KeyError, OSError, zipfile.BadZipFile) as exc:
        raise WorkbookParseError(path=path, detail=str(exc)) from exc

    if not raw_rows:
        raise WorkbookParseError(path=path, detail="no rows found")

    headers = raw_rows[0]
    rows: list[dict[str, str]] = []
    for raw_row in raw_rows[1:]:
        padded = [*raw_row, *([""] * (len(headers) - len(raw_row)))]
        rows.append({headers[index]: padded[index] for index in range(len(headers))})
    return WorkbookRows(headers=headers, rows=rows)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: parse_standard_excel.py <xlsx-path>", file=sys.stderr)
        return 2
    parsed = read_sheet_rows(Path(argv[1]))
    print(json.dumps({"headers": parsed.headers, "row_count": len(parsed.rows)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
