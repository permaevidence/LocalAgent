---
name: pdf
description: Generate polished PDFs of any kind — presentations, essays, reports, invoices, letters. Classify the document type first, then apply the rules for that type. Use when the user asks for a PDF, report, printable document, presentation, invoice, or contract.
---

# PDF Skill

PDFs are not one thing. A pitch deck and a research paper need opposite layout strategies: the deck needs visual variety between pages, the paper needs rigid consistency. **Classify the document type first**, then apply the rules for that type.

## Workflow

1. **Classify the document type** (see matrix below).
2. **Pick the renderer** — `weasyprint` by default (Python-installable, great CSS support); `chromium --headless --print-to-pdf` for complex CSS (grid, flex edge cases). Never use imperative libraries (reportlab / fpdf) for flowing content.
3. **Write one HTML + CSS file.** Baseline stylesheet below; type-specific additions in each section.
4. **Render**: `weasyprint input.html output.pdf`
5. **Verify visually.** `read_file` on the PDF — the rendered pages come back as inline multimodal content. Inspect every page of multi-page docs, not just page 1.
6. **Fix objective bugs and re-render.** Cap at 3 iterations. Fix layout bugs, not subjective polish.

## Document type matrix

| Type | Examples | Layout rule | Density | Apply rules in |
| --- | --- | --- | --- | --- |
| **Presentation / deck** | Pitch, value props, summary slides | **Vary layouts** across consecutive pages; never repeat the same pattern | 150-200 wds/page min | `Presentation` section |
| **Essay / paper / article** | Research paper, op-ed, analysis | **Same layout every page** — single column, consistent rhythm | 400+ wds/page typical | `Essay` section |
| **Long-form report** | 20+ pages, structured, with TOC | Same as essay + chapters, TOC, running header | 300+ wds/page | `Report` section |
| **Transactional** | Invoice, receipt, statement, quote | Tabular, precise alignment, minimal decoration | Tables drive it | `Transactional` section |
| **Letter / memo** | Formal correspondence, cover letter | Single-page block-format template | Correspondence | `Letter` section |
| **Brochure / marketing** | Fold brochure, one-sheet, flyer | Visual-heavy, brand-driven | Designer-intensive | Out of scope — defer |

Don't conflate types. A "report" with card grids and pullquotes is wrong; a pitch deck with 6 dense prose pages is wrong.

## Shared foundation

### Typography baseline

- One serif for body, one sans-serif for headings. Charter + Inter is a reliable pairing (both exist on macOS + common Linux). Always list fallbacks: `'Charter', 'Georgia', serif`.
- Body 10-12pt, line-height 1.4-1.6. Margins 1.8-2.5cm.
- Heading scale: H1 ~2x body, H2 ~1.5x, H3 ~1.2x. Similar H1/H2 sizes break hierarchy.
- Page numbers: footer, right-aligned, 9pt gray.
- Justify is fine for Italian / Spanish / French / German; left-align English (narrow columns create ugly rivers).
- CJK: include font stack like `'PingFang SC', 'Hiragino Sans', 'Noto Sans CJK', sans-serif`. RTL (Arabic, Hebrew): `dir="rtl"` on the relevant block.

### Baseline CSS (drop into `<style>` for any type)

```css
@page { size: A4; margin: 2cm 2cm 2.5cm 2cm;
  @bottom-right { content: counter(page) " / " counter(pages); font-family: 'Inter', sans-serif; font-size: 9pt; color: #888; } }
* { box-sizing: border-box; }
html { font-size: 11pt; }
body { font-family: 'Charter', 'Georgia', serif; line-height: 1.5; color: #222; margin: 0; }
h1, h2, h3, h4 { font-family: 'Inter', system-ui, sans-serif; font-weight: 600; line-height: 1.25; page-break-after: avoid; margin: 1.4em 0 0.4em; }
h1 { font-size: 22pt; margin-top: 0; } h2 { font-size: 16pt; } h3 { font-size: 13pt; }
h4 { font-size: 11pt; text-transform: uppercase; letter-spacing: 0.04em; color: #555; }
p { margin: 0 0 0.7em; }
a { color: #0b57d0; text-decoration: none; }
img, svg, figure { max-width: 100%; height: auto; page-break-inside: avoid; }
table { width: 100%; border-collapse: collapse; margin: 0.8em 0; font-size: 10pt; }
th, td { padding: 6pt 8pt; border-bottom: 0.5pt solid #ddd; text-align: left; vertical-align: top; }
th { background: #f6f8fa; font-family: 'Inter', sans-serif; font-weight: 600; font-size: 9.5pt; }
tr { page-break-inside: avoid; }
blockquote { border-left: 3pt solid #bbb; margin: 0 0 1em; padding: 0 0 0 1em; color: #555; }
```

### Verification (all types)

- `read_file` the output. Inspect every page.
- Check typography hierarchy, margins, page breaks, orphan headings, image overflow, table cutoffs, empty pages.
- For data-heavy or visual content: also verify images render (not broken icons), tables fit page width, columns align.

## Presentation

Pitch decks, feature summaries, value props. **Vary layouts on consecutive pages.** Never repeat the same pattern. Do NOT default to a square card grid on every page — that's the "lazy deck" failure mode.

### Named layout patterns

| Pattern | Best for | Key features |
| --- | --- | --- |
| **Manifesto** | Philosophy, vision, intros, narrative | 1 or 2-column running prose + large italic pull-quote with left accent bar |
| **Stack** | Architecture layers, process steps, roadmaps | Vertical rows, bold uppercase tag left + description right |
| **Split** | Feature showcases, comparisons | 40/60 or 50/50 horizontal: visual one side, prose/list the other |
| **Pillars** | Value props, capabilities | Grid of cards — **3-column or asymmetric**, colored top-border accent. Never square grids. |
| **Hero** | A concept better shown than told | Full-width image/diagram + caption + short context |
| **Quote** | Section transitions, memorable statements | Large typographic treatment (28-40pt italic), minimal surround |
| **Data** | Technical depth, metrics | Table or chart carries the page, annotation supports |

**Plan the sequence before rendering.** Example 5-page deck: cover → Manifesto → Stack → Split → Hero → Quote. Every page different from its neighbor.

**Density floor**: 150-200 words per content page. Below that, the page reads as a headline, not a section. Add an "intro bridge" (2-3 sentence paragraph) under every H2 for context.

**Cover / divider pages** (intentionally sparse): use flex distribution so content doesn't bunch at the top.
```css
.cover { min-height: 24cm; display: flex; flex-direction: column; justify-content: space-between; }
```

### CSS snippets for patterns

```css
.manifesto-cols { column-count: 2; column-gap: 1.5cm; text-align: justify; }
.pull-quote { font-size: 20pt; font-style: italic; color: #0b57d0; border-left: 4pt solid #0b57d0; padding: 0.8cm 1cm; margin: 1.5cm 0; background: #f0f7ff; }
.stack-layer { display: grid; grid-template-columns: 180px 1fr; gap: 1cm; padding: 0.8cm; border: 1pt solid #eee; margin-bottom: 0.5cm; border-radius: 4pt; page-break-inside: avoid; }
.layer-label { font-family: 'Inter', sans-serif; font-weight: 800; color: #0b57d0; text-transform: uppercase; font-size: 9pt; letter-spacing: 0.1em; }
.split-view { display: flex; gap: 1.5cm; flex-grow: 1; }
.visual-pane { flex: 1; background: #f9f9fb; border-radius: 8pt; padding: 1cm; display: flex; align-items: center; justify-content: center; page-break-inside: avoid; }
.pillar-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 0.8cm; }
.pillar-card { padding: 0.8cm; border-top: 4pt solid #0b57d0; background: #fff; box-shadow: 0 4pt 12pt rgba(0,0,0,0.03); page-break-inside: avoid; }
.quote-page { display: flex; flex-direction: column; justify-content: center; min-height: 24cm; }
.quote-page blockquote { font-size: 32pt; line-height: 1.25; font-style: italic; color: #0b57d0; border: none; padding: 0; max-width: 14cm; }
```

## Essay / paper / article

Research papers, op-eds, analyses. **Consistency IS the goal**, not variety. Every page uses the same single-column layout, same typography, same rhythm. Readers shouldn't notice layout — it should disappear under the prose.

**Do NOT** use card grids, pull-quotes, decorative accents, or column variety. Do NOT introduce visual surprises between pages.

### Structure
- Page 1: title + author/affiliation + date at top, then body starts ~1/3 down the page
- Body: single column, 10-12pt, line-height 1.5-1.6
- Section headings (H2) with modest top margin; no boxes or background fills
- First paragraph after a heading: no indent. Subsequent paragraphs: small first-line indent (1em) OR blank-line separation, not both
- Footnotes at page bottom with 9pt, separator rule above
- Running footer: page number only (or "Author — Title — page N"), 9pt gray

### Essay-specific CSS additions

```css
body { font-size: 11pt; line-height: 1.55; }
h1.paper-title { font-size: 20pt; margin: 0 0 0.3em; }
.authors { font-family: 'Inter', sans-serif; font-size: 11pt; color: #555; margin-bottom: 2em; }
p + p { text-indent: 1em; }  /* first-line indent from paragraph 2 onward */
h2 + p, h3 + p { text-indent: 0; } /* no indent right after a heading */
.footnote { font-size: 9pt; line-height: 1.35; color: #444; }
```

**Density**: 400+ words/page is typical. A half-empty essay page signals awkward section breaks, not minimalism.

## Report

Long-form (20+ pages, structured, formal). Like essay but with:
- **Table of contents** on page 2 (auto-generated if the renderer supports it; weasyprint does via `target-counter`)
- **Chapter title pages**: sparse page with just chapter number + title, then body starts on the next page
- **Running header**: chapter name left, page number right, 9pt, thin bottom border
- **Appendix** and **index** if applicable

Density and typography inherit from essay. Same consistency rule applies.

## Transactional

Invoices, receipts, statements, quotes. Precision over decoration.

### Structure
- **Header block**: two columns. Left = sender logo/name + address. Right = document type ("INVOICE"), number, date, due date.
- **Recipient block**: below header, left-aligned, with clear label ("Bill to:").
- **Line-item table**: consistent column widths, right-aligned numeric columns. Use `font-variant-numeric: tabular-nums` for alignment.
- **Totals row**: bold, top border, right-aligned.
- **Footer**: payment terms, bank details, legal disclaimers in 8-9pt gray.

No color beyond a single brand accent. No gradients, shadows, or marketing flair.

### Transactional CSS additions

```css
.invoice-header { display: grid; grid-template-columns: 1fr 1fr; gap: 2cm; margin-bottom: 2cm; }
.invoice-header .meta { text-align: right; }
.invoice-header h1 { font-size: 24pt; text-transform: uppercase; letter-spacing: 0.08em; margin: 0 0 0.5em; color: #0b57d0; }
.line-items { font-variant-numeric: tabular-nums; }
.line-items td.num, .line-items th.num { text-align: right; }
.line-items tr.total td { font-weight: 700; border-top: 1pt solid #222; }
.legal-footer { font-size: 8.5pt; color: #777; margin-top: 2cm; border-top: 0.5pt solid #ddd; padding-top: 0.5cm; }
```

## Letter / memo

Formal single-page correspondence: cover letter, business letter, internal memo.

### Structure (block format)
- Sender letterhead / name + address, top-left
- Date, ~1 line below
- Recipient name + address, ~2 lines below date
- Salutation ("Dear X,"), ~1 line below
- Body paragraphs, block style (no indent, blank line between)
- Closing ("Sincerely,"), ~1 line below last paragraph
- Signature space (3 lines), then printed name + title

Margins 2.5-3cm. No page number on a single page. No decorative elements.

## Brochure / marketing

Out of scope. Brochures depend on brand identity, imagery decisions, and visual craftsmanship that an LLM producing HTML+CSS can't deliver to a professional standard. Ask the user to engage a designer, or offer a pitch deck (Presentation type) as an adjacent deliverable.

## Common bugs

| Symptom | Cause | Fix |
| --- | --- | --- |
| Body text huge on every page | Root `font-size` unset (inherits 16pt default) | `html { font-size: 11pt; }` |
| Heading alone at page bottom | No `page-break-after: avoid` on h1-h4 | Add to heading CSS |
| Table cut at right edge | Column widths sum > page width | `width: 100%` with % columns, or `table-layout: fixed` |
| Image bleeds off page | No `max-width` on img | `img { max-width: 100%; height: auto; }` |
| "1 of 0" page counter | Renderer doesn't support `counter(pages)` | Use weasyprint (supports it) or drop "/ N" |
| Fonts inconsistent across machines | Font name unavailable on rendering host | Always list fallbacks |
| Every paragraph indents | Parent stylesheet's `text-indent` | `p { text-indent: 0; }` explicitly |
| Cover content bunched at top | Missing flex on page container | flex-column + `justify-content: space-between` on a 24cm min-height container |
| Content page half-empty | Under-written section | Merge pages, expand prose, add intro bridge under H2, or enlarge a figure |
| Every page looks identical (presentation) | One layout pattern applied to all | Alternate Manifesto / Stack / Split / Pillars / Hero / Quote / Data |
| Essay has pullquotes or card grids | Misclassified as presentation | Strip decorative elements; essays want consistency |
| Invoice columns misaligned | Mixed numeric + text columns, no tabular figures | `font-variant-numeric: tabular-nums` on numeric cells |
| Tables cut at page breaks | No `page-break-inside: avoid` on rows | Add to `tr` |

## Images and figures

- Embed raster at 2x the final rendered size, then let CSS scale. Avoids blur on high-DPI print.
- SVG for charts (vector, infinite resolution). JPEG q85 for photos. PNG for screenshots / line art.
- All images: `page-break-inside: avoid`.
- For charts, generate SVG via matplotlib/plotly and embed.

## Stopping criterion

The document looks right for its TYPE. A presentation varies cleanly across pages; an essay reads as continuous prose; an invoice aligns precisely; a letter follows block format. Nothing clipped, no orphan headings, no half-empty content pages. Ship.
