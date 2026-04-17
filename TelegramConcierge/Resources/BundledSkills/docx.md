---
name: docx
description: Generate Microsoft Word (.docx) documents for reports, letters, contracts, CVs, and any text-heavy document the user plans to edit in Word. Use when the user asks for a Word file, .docx, editable document, or mentions collaborators who need Word.
---

# DOCX Skill

Use `.docx` when the user needs an **editable** document — they or their recipients will open it in Word or Google Docs and modify. Use the `pdf` skill instead for final, non-editable output.

## Renderer choice

**Primary: pandoc.** Write clean markdown, convert to .docx with a reference document for styling.
```bash
pandoc input.md --reference-doc=template.docx -o output.docx
```

**Secondary: python-docx.** Use when you need precise structural control — tables with specific formatting, custom styles, form fields, positioned images, headers/footers with page numbers.
```python
from docx import Document
doc = Document()  # or Document('template.docx') to inherit styles
doc.add_heading('Title', 0)
doc.add_paragraph('Body...')
doc.save('output.docx')
```

Avoid LibreOffice or AppleScript automation — slower, fragile across machines.

## Workflow

1. **Draft in markdown first.** Easier to iterate on structure than to fight python-docx early.
2. **Convert with pandoc.** Handles ~80% of cases.
3. **Verify visually.** DOCX isn't directly viewable inline, so convert to PDF and inspect:
   ```bash
   libreoffice --headless --convert-to pdf output.docx
   ```
   Then `read_file output.pdf` — the rendered pages come back as inline multimodal content, you see the actual layout.
4. **Sample ALL pages, not just the first.** Multi-page docs often have layout issues that only manifest on page 2+ (orphan headings, broken tables, footer overlap). Read each page and verify:
   - Headings have visible hierarchy (H1 ≠ H2 ≠ body)
   - Page numbers / headers / footers render correctly
   - Tables fit the page width (no column cutoff)
   - Images don't overflow
   - No orphan headings at page bottoms
   - Body text 10-12pt, consistent font across pages
5. **Fix and re-render.** Cap at 3 iterations. Fix objective bugs only, don't chase subjective polish.

### Secondary sanity check: programmatic structure

Before or alongside the visual inspection, a quick python-docx walk catches bugs the eye might miss in a long doc:
```python
from docx import Document
doc = Document('output.docx')
print(f"Paragraphs: {len(doc.paragraphs)}, Tables: {len(doc.tables)}")
for t in doc.tables:
    print(f"  Table: {len(t.rows)} rows × {len(t.columns)} cols")
for h in [p for p in doc.paragraphs if p.style.name.startswith('Heading')]:
    print(f"  {h.style.name}: {h.text}")
```
Good for confirming expected counts — e.g., "I wanted 3 H2 sections and see 3." Not a substitute for the visual check.

## Reference styling via template.docx

If the user's organization has a corporate style guide, ask for a template:
- With pandoc: `--reference-doc=template.docx`
- With python-docx: `Document('template.docx')` and add content into the pre-styled doc

Do **not** invent brand colors, fonts, or logos without a template or explicit spec.

## Common bugs

- **Pandoc ignores inline HTML**: pandoc's markdown→docx doesn't carry all inline HTML. For complex layout (floated images, multi-column), switch to python-docx.
- **Fonts missing on recipient's machine**: stick to system fonts (Calibri, Times New Roman, Arial) unless the user specifies.
- **Broken line breaks in tables**: python-docx paragraphs inside a cell need `cell.paragraphs[0].add_run('...')`, not `cell.text += '...'` in a loop.
- **Page breaks in odd places**: insert explicit `doc.add_page_break()` rather than relying on implicit flow; pandoc uses `\newpage` in markdown.

## When to push back

- "Editable PDF" → that's DOCX (or a PDF with form fields). Clarify.
- Heavy typography/layout control → suggest PDF; DOCX is a weak layout engine.
- Spreadsheet-like table with formulas → XLSX, not DOCX.

## Stopping criterion

Each rendered page (all of them, not just page 1) looks clean, headings have visible hierarchy, nothing cut off or missing. Ship it.
