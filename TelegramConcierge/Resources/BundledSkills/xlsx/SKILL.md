---
name: xlsx
description: Generate Microsoft Excel (.xlsx) spreadsheets for data tables, reports, budgets, invoices, CSV conversions. Use when the user asks for an Excel file, .xlsx, spreadsheet, or needs structured data with formulas/formatting.
---

# XLSX Skill

Spreadsheets are about **data integrity** first, **visual polish** second. Verification in this skill looks different from the PDF/DOCX loop — don't fake a visual inspection; check the cell values programmatically.

## Renderer choice

**Primary: openpyxl (Python).** Full control over cells, formulas, styling, multiple sheets, conditional formatting.
```python
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
wb = Workbook()
ws = wb.active
ws.title = "Summary"
ws['A1'] = "Header"
ws['A1'].font = Font(bold=True, size=12)
wb.save('output.xlsx')
```

**Alternative: pandas `to_excel`.** Right choice when the source data is already in a DataFrame. Combine with openpyxl for post-export styling.
```python
import pandas as pd
df.to_excel('output.xlsx', index=False, sheet_name='Data')
```

## Workflow

1. **Understand the schema first.** Ask: how many sheets? what are the column headers? any formulas? any merged cells? any conditional formatting? Don't guess.
2. **Generate.**
3. **Verify programmatically.** Spreadsheets can't be `read_file`'d visually. Open the file with openpyxl and walk it:
   ```python
   from openpyxl import load_workbook
   wb = load_workbook('output.xlsx')
   for sheet in wb.sheetnames:
       ws = wb[sheet]
       print(f"Sheet '{sheet}': {ws.max_row}x{ws.max_column}")
       for row in ws.iter_rows(min_row=1, max_row=3, values_only=True):
           print(row)
   ```
4. **Fix and re-run.** Cap at 3 iterations.

## What to verify

- **Row/column counts match expectation.** If user said "50 line items," `ws.max_row` should be 51 (50 + header).
- **Formulas computed, not strings.** Cells with formulas should show their formula via `cell.value` (e.g., `=SUM(B2:B10)`), not the literal string `"=SUM(B2:B10)"` as text.
- **Data types.** Numbers should be numbers, dates should be dates. `cell.data_type` tells you: `n` (number), `s` (string), `d` (date), `f` (formula).
- **Headers present.** Row 1 should match the expected schema.
- **No leading/trailing whitespace in string values.** Common CSV→XLSX gotcha.

## If visual formatting matters (invoices, branded reports)

Convert to PDF for visual check, same as DOCX:
```bash
libreoffice --headless --convert-to pdf output.xlsx
```
Then `read_file` the PDF and verify columns fit the page, headers are styled, etc.

## Common bugs

- **Numbers stored as strings.** Happens when you write `ws['A1'] = "42"` instead of `ws['A1'] = 42`. Sorts and SUMs break.
- **Dates as strings.** Use `datetime.date` / `datetime.datetime` objects and set `cell.number_format = 'YYYY-MM-DD'`.
- **Formulas as literal text.** The cell value must start with `=` to be a formula; if you're building strings from a template, escape quoting.
- **Column widths not auto-fitting.** openpyxl doesn't auto-fit; set explicitly: `ws.column_dimensions['A'].width = 20`.
- **Encoding issues with non-ASCII.** Save with `wb.save(filename)` — openpyxl handles UTF-8 by default. If you see mojibake, something upstream stripped the encoding.

## Formulas reference (common)

| Want | Formula |
| --- | --- |
| Sum a range | `=SUM(B2:B10)` |
| Count non-blank | `=COUNTA(B2:B10)` |
| Conditional sum | `=SUMIF(A:A, "Category", B:B)` |
| Average ignoring zero | `=AVERAGEIF(B2:B10, ">0")` |
| VLOOKUP | `=VLOOKUP(A2, Sheet2!A:C, 3, FALSE)` |
| Today's date | `=TODAY()` |

## Stopping criterion

Row/column counts match schema, formulas evaluate correctly when opened in Excel, headers are present, data types are right. Ship it.
