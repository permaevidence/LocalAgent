---
name: docx
description: Generate Microsoft Word (.docx) documents for reports, letters, contracts, CVs, and any text-heavy document the user plans to edit in Word. Use when the user asks for a Word file, .docx, editable document, or mentions collaborators who need Word.
---

# DOCX Skill

Use `.docx` when the user needs an **editable** document — something they or their recipients will open in Word or Google Docs and modify. Use the `pdf` skill instead for final, non-editable output.

## Renderer choice

**Primary: pandoc.** Write clean markdown, convert to .docx with a reference document for styling.
```bash
pandoc input.md --reference-doc=template.docx -o output.docx
```

**Secondary: python-docx.** For precise structural control — tables with specific formatting, custom styles, form fields, headers/footers with page numbers, embedded images positioned exactly.
```python
from docx import Document
doc = Document()  # or Document('template.docx') to inherit styles
doc.add_heading('Title', 0)
doc.add_paragraph('Body...')
doc.save('output.docx')
```

Avoid LibreOffice or Word automation (AppleScript) — slower, fragile across machines.

## Workflow

1. **Draft in markdown first.** Simpler to iterate on structure than to fight python-docx from the start.
2. **Convert with pandoc.** Works for 80% of cases.
3. **Verify.** DOCX files are not directly viewable — `read_file` can't render them visually. Two options:
   - Convert to PDF and inspect that: `libreoffice --headless --convert-to pdf output.docx`, then `read_file output.pdf` and inspect the rendered pages.
   - Use `python-docx` to open the file and walk paragraphs/tables programmatically to confirm structure is correct even without seeing the layout.
4. **Fix and re-run.** Cap at 3 iterations. Same rules as the PDF skill: fix objective bugs, don't chase subjective polish.

## What to verify in the PDF render

- Headings have visible hierarchy (H1 ≠ H2 ≠ body)
- No broken page numbers in headers/footers
- Tables fit the page width (no column cutoff)
- Images don't overflow
- No orphan headings
- Body text 10-12pt, consistent font

## Reference styling via template.docx

Users often have a corporate style guide. Ask if they have a Word template. If yes:
- Use `--reference-doc=template.docx` with pandoc, OR
- `Document('template.docx')` with python-docx and add content into the pre-styled document
- The agent should **not invent** corporate colors, fonts, or logos without a template or explicit user spec

## Common bugs

- **Pandoc ignoring inline HTML**: pandoc's markdown→docx doesn't carry over all inline HTML. If you need complex layout (floated images, multi-column), switch to python-docx.
- **Fonts missing on the recipient's machine**: stick to system fonts (Calibri, Times New Roman, Arial) unless the user specifies. Exotic fonts render as fallbacks elsewhere.
- **Broken line breaks in tables**: python-docx paragraphs inside a cell need explicit `cell.paragraphs[0].add_run('...')` — leading blank paragraphs accumulate if you `cell.text += '...'` in a loop.
- **Page breaks in odd places**: insert explicit `doc.add_page_break()` rather than relying on implicit flow; pandoc uses `\newpage` in markdown for the same.

## When to push back

- User asks for "editable PDF" → that's a DOCX (or a PDF with form fields). Clarify.
- User wants heavy typography/layout control → suggest PDF instead, DOCX is a weak layout engine.
- User wants a spreadsheet-like table with formulas → XLSX, not DOCX.

## Stopping criterion

The document opens cleanly in Word, headings are visibly different sizes, nothing is cut off or missing. Ship it.
