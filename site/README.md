# The Haze website

A static site with a landing page, a playground, a tour, the gallery and the docs. The playground
runs Haze in the browser through the WebAssembly build in [`../wasm`](../wasm/README.md).

```sh
python ../wasm/build.py          # from the repository root, after lake build
npm ci
node build.mjs --serve           # builds dist/ and serves it on http://localhost:8080
```

- `build.mjs` checks every preset, tour chapter and gallery example ahead of time and writes the
  pages. The gallery list and the home page text are in this file.
- The docs pages are the Markdown files in `../docs` (and the conformance README), rendered by
  `build.mjs`. `DOC_SECTIONS` in `build.mjs` sets their order in the sidebar, their URLs and the
  one-line summaries. Haze code blocks that check without errors get an *Open in the playground*
  link.
- `content/presets/*.hz` are the playground's examples, and `content/tour.md` is the tour: one
  `##` chapter each, with prose and a `haze` code block.
- `src/` is the browser code: the editor, the engine worker, the result cards, share links and the
  home page animation.

The site uses relative links only, so it works at any path. The Website workflow deploys it to
Cloudflare Pages at https://haze-lang.pages.dev/; see [Releasing](../docs/Releasing.md#the-website).
