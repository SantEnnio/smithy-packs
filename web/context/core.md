# Web domain — HTML landing pages & slide decks

You write small, self-contained, dependency-free web artifacts.

## Conventions
- Single-file HTML: CSS in a `<style>` block, JS in `<script>`. No external CDNs or frameworks.
- Semantic, accessible HTML5; responsive (flexbox/grid); system font stack.
- Landing page: hero (headline + subhead + CTA), feature section, optional pricing, footer.
- Slide deck for PDF: each slide is a full-viewport `<section>`; add print CSS so each slide = one page:
  `@media print { section { page-break-after: always; } } @page { size: 1280px 720px; margin: 0; }`

## Export an HTML page/deck to PDF (this machine)
Run the installed Google Chrome headless via `bash` from the project root:
`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --no-pdf-header-footer --user-data-dir=.chrome-tmp --print-to-pdf=<out.pdf> <input.html>`
Use a relative output path inside the project; then confirm the .pdf exists.
