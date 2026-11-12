// The home page: the hero animation, the try-it editor and the feature cards.
import { common, root, pageData } from "../common";
import { mountHero } from "../hero";
import { mountWidget, Preset } from "../widget";
import { renderRecords } from "../render";
import { linkTo } from "../share";
import type { Record_ } from "../engine";

interface Data { presets: Preset[]; hero: Record<string, string>; features: Record<string, Record_[]> }

common();
const data = pageData<Data>();
const r = root();

const playLink = document.getElementById("hero-play") as HTMLAnchorElement | null;
mountHero({
  canvas: document.getElementById("hero-canvas") as HTMLCanvasElement,
  slider: document.getElementById("hero-loss") as HTMLInputElement,
  toggle: document.getElementById("hero-idem") as HTMLInputElement,
  readout: document.getElementById("hero-exact")!,
  sim: document.getElementById("hero-sim")!,
  lossLabel: document.getElementById("hero-loss-value")!,
  root: r,
  precomputed: data.hero,
  playLink: playLink ?? undefined,
});
playLink?.addEventListener("click", async (e) => {
  if (!playLink.dataset.code) return;
  e.preventDefault();
  location.href = await linkTo(new URL(`${r}play/`, document.baseURI), playLink.dataset.code);
});

const tryHost = document.getElementById("try");
if (tryHost) mountWidget(tryHost, { presets: data.presets, root: r, compact: true });

for (const el of document.querySelectorAll<HTMLElement>("[data-feature]")) {
  const recs = data.features[el.dataset.feature!];
  if (recs) renderRecords(el, recs);
}
for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-open]")) {
  a.addEventListener("click", async (e) => {
    const code = document.getElementById(a.dataset.open!)?.textContent;
    if (!code) return;
    e.preventDefault();
    location.href = await linkTo(new URL(`${r}play/`, document.baseURI), code);
  });
}
