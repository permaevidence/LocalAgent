---
name: pdf
description: Generate polished multi-page PDFs via HTML+CSS rendered by weasyprint or chromium headless. Use when the user asks for a PDF, printable report, presentation PDF, invoice, contract, or any multi-page visual document.
---

# PDF Skill

Your goal is a PDF that looks professionally laid out, not a PDF that merely contains the right words. Layout matters as much as content.

## Workflow

1. **Pick the renderer.**
   - Default: `weasyprint` (fast, great CSS support, Python-installable). `pip install weasyprint`.
   - Fallback: `chromium --headless --print-to-pdf`. Use when the document needs complex CSS (grid, flex-gap on old renderers, SVG quirks) that weasyprint handles poorly.
   - Do NOT use imperative PDF libraries (`reportlab`, `fpdf`, `fpdf2`, `pypdf`) for anything with multi-line flowing content — you'll spend more time fighting the library than writing HTML.

2. **Write one HTML file + one CSS block.** Keep it all in a single `.html` or emit via Python. Template in the next section.

3. **Render.** Example:
   ```bash
   weasyprint input.html output.pdf
   ```

4. **Inspect the output.** Call `read_file` on the PDF. The tool returns the rendered pages inline — you will actually see the layout, not just metadata.

5. **Fix objective bugs and re-render.** Look for:
   - Typography hierarchy broken (H1 same size as body, fonts mismatched)
   - Body text outside the 9-14pt range
   - Margins inconsistent between pages
   - Orphan headings (heading alone at the bottom of a page, content on the next)
   - Images overflowing the page width
   - Tables cut off at the right edge
   - Empty pages or runaway page breaks
   - Text clipped at page boundaries

6. **Cap at 3 iterations.** If it's still wrong after 3 render-inspect-fix rounds, stop and tell the user what's broken and what you've tried. Do not burn infinite tokens on subjective polish.

## Baseline HTML+CSS template

Copy this as your starting point, then customize. It gets you 80% of the way there without thinking.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Document</title>
<style>
  @page {
    size: A4;
    margin: 2cm 2cm 2.5cm 2cm;
    @bottom-right {
      content: counter(page) " / " counter(pages);
      font-family: 'Inter', system-ui, sans-serif;
      font-size: 9pt;
      color: #888;
    }
  }

  * { box-sizing: border-box; }

  html {
    font-size: 11pt;
  }

  body {
    font-family: 'Charter', 'Georgia', 'Iowan Old Style', serif;
    line-height: 1.5;
    color: #222;
    margin: 0;
  }

  h1, h2, h3, h4 {
    font-family: 'Inter', system-ui, 'Helvetica Neue', sans-serif;
    font-weight: 600;
    line-height: 1.25;
    page-break-after: avoid;
    margin-top: 1.4em;
    margin-bottom: 0.4em;
  }
  h1 { font-size: 22pt; margin-top: 0; }
  h2 { font-size: 16pt; }
  h3 { font-size: 13pt; }
  h4 { font-size: 11pt; text-transform: uppercase; letter-spacing: 0.04em; color: #555; }

  p { margin: 0 0 0.7em 0; }

  a { color: #0b57d0; text-decoration: none; }

  code, pre {
    font-family: 'JetBrains Mono', 'SF Mono', Menlo, monospace;
    font-size: 9.5pt;
  }
  pre {
    background: #f6f8fa;
    padding: 10pt;
    border-radius: 4pt;
    overflow-wrap: break-word;
    white-space: pre-wrap;
    page-break-inside: avoid;
  }

  blockquote {
    border-left: 3pt solid #bbb;
    margin: 0 0 1em 0;
    padding: 0 0 0 1em;
    color: #555;
  }

  img, svg, figure {
    max-width: 100%;
    height: auto;
    page-break-inside: avoid;
  }

  table {
    width: 100%;
    border-collapse: collapse;
    margin: 0.8em 0;
    page-break-inside: auto;
    font-size: 10pt;
  }
  th, td {
    padding: 6pt 8pt;
    border-bottom: 0.5pt solid #ddd;
    text-align: left;
    vertical-align: top;
  }
  th {
    background: #f6f8fa;
    font-family: 'Inter', system-ui, sans-serif;
    font-weight: 600;
    font-size: 9.5pt;
  }
  tr { page-break-inside: avoid; }

  .cover {
    page-break-after: always;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: flex-start;
    min-height: 24cm;
  }
  .cover h1 { font-size: 34pt; margin-bottom: 0.3em; }
  .cover .subtitle { font-size: 14pt; color: #555; }

  .page-break { page-break-before: always; }
</style>
</head>
<body>
  <section class="cover">
    <h1>Document Title</h1>
    <div class="subtitle">Subtitle or context</div>
  </section>

  <h2>Section 1</h2>
  <p>Body copy goes here. Use two or three short paragraphs per page max for reports; dense blocks are fine for academic or legal docs.</p>

  <!-- more content -->
</body>
</html>
```

## Typography rules worth internalizing

- **One serif for body, one sans-serif for headings.** Mixing more than two type families looks amateur. Charter (serif) + Inter (sans-serif) is a reliable pairing because both exist on macOS by default and on common Linux distros.
- **Body text 10-12pt, line-height 1.4-1.6.** Below 10pt is hard to read in print; above 12pt looks like a children's book.
- **Margins 1.8-2.5cm.** Tighter margins look cramped on A4/Letter; wider margins waste paper.
- **Heading scale uses a clear ratio.** H1 ~2x body, H2 ~1.5x, H3 ~1.2x. Similar sizes between H1 and H2 break hierarchy.
- **Page numbers in the footer**, right-aligned, 9pt, gray. Always useful, never distracting.
- **Never justify text unless the language supports it well.** Italian, Spanish, French, German — justify is fine. English with short lines (narrow columns) produces ugly rivers; left-align instead.

## Common bugs and fixes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Body text huge on every page | Root `font-size` wrong or unset; inheriting browser default (16pt) | Set `html { font-size: 11pt; }` |
| Heading alone at page bottom | No `page-break-after: avoid` on h1-h4 | Add it to the heading CSS |
| Table cut at right edge | Fixed-width columns sum > page width | Use `width: 100%` + percentage column widths, or `table-layout: fixed` |
| Image bleeds off page | No max-width on `img` | Add `img { max-width: 100%; height: auto; }` |
| Pagination count shows "1 of 0" | Your renderer doesn't support CSS `counter(pages)` | Switch to weasyprint (supports it) or drop the "/ N" part |
| Fonts inconsistent across systems | Font name not available on rendering machine | Always list fallbacks: `'Charter', 'Georgia', serif` |
| Every paragraph indents | Leftover `text-indent` from a parent stylesheet | Explicitly set `p { text-indent: 0; }` |
| Cover page content at top instead of centered | Missing flexbox; `min-height` not sufficient for A4 | Use `min-height: 24cm;` + `display: flex; flex-direction: column; justify-content: center;` |

## Images

- Embed raster images at 2x the final rendered size, then let CSS scale down — avoids blurriness on high-DPI print.
- For charts, prefer SVG (vector, infinite resolution) over PNG/JPEG.
- Photos: JPEG, quality 85. Screenshots and line art: PNG.
- Always give images `page-break-inside: avoid` so they don't split across pages.

## Multi-language content

- Italian / French / Spanish / German: justify works well, line length can be wider.
- Chinese / Japanese / Korean: set `font-family` to a system font stack that includes CJK fonts (`'PingFang SC', 'Hiragino Sans', 'Noto Sans CJK', sans-serif`).
- Right-to-left (Arabic, Hebrew): add `dir="rtl"` to `<body>` or the relevant block.

## What this skill will NOT do for you

- **Design-language decisions.** If the user's brand requires a specific color palette, ask them for it — don't invent.
- **Chart generation.** Use matplotlib or plotly to generate SVG first, then embed in the HTML.
- **Logo insertion.** Ask the user for the asset path; don't fabricate logos.
- **Page-count prediction.** PDF pagination depends on content — if the user wants "exactly 4 pages," you'll need to iterate on content density.

## Example end-to-end run

```python
# pdf_gen.py — example scaffold
from weasyprint import HTML

html_string = """<!DOCTYPE html>...""" # build from the template above
HTML(string=html_string, base_url='.').write_pdf('output.pdf')
```

Then: `read_file` on `output.pdf`, inspect, fix, re-run. Max 3 iterations.

## Stopping criterion

The document is done when, in rendered form, it looks like something you'd be comfortable attaching to a professional email without a cover note apologizing for the layout. Nothing more. Don't try to make it beautiful; make it objectively correct.
