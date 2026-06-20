# pii-stream website

Marketing/landing site for **PII Stream Guard**, a live privacy preview for
screen sharing on macOS. Built as a single-page Astro static site, styled with a
dark "security-lab" theme (vermillion accent, monospace type, film-grain +
vignette atmosphere) and deployed on Vercel.

## Structure

```text
website/
├── public/
│   ├── og.png              # generated Open Graph card (1200x630)
│   ├── favicon.svg
│   └── favicon.ico
├── scripts/
│   ├── og-card.html        # source for the OG card
│   └── build-og.sh         # regenerates public/og.png
├── src/
│   ├── layouts/Layout.astro  # head meta, global styles, nav + footer
│   └── pages/index.astro     # the page (content, guard demo, scripts)
└── package.json
```

## Commands

| Command         | Action                                       |
| :-------------- | :------------------------------------------- |
| `bun install`   | Install dependencies                         |
| `bun dev`       | Local dev server at `localhost:4321`         |
| `bun run build` | Build the static site to `./dist/`           |
| `bun run preview` | Preview the production build               |
| `bun run astro check` | Type-check the Astro files             |

## Regenerating the Open Graph image

`public/og.png` is rendered from [`scripts/og-card.html`](scripts/og-card.html)
using local macOS tools (WeasyPrint for HTML→PDF, `pdftoppm` for PDF→PNG, and
`sips` to force the exact 1200×630 size):

```sh
bash scripts/build-og.sh
```

Edit `scripts/og-card.html` and re-run the script to update the card.
