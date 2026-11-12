// The tour: short chapters, each with an editable example and its output.
import { common, root, pageData } from "../common";
import { mountWidget } from "../widget";
import type { Record_ } from "../engine";

interface Chapter { id: string; title: string; html: string; code: string; records: Record_[] }

common();
const { chapters } = pageData<{ chapters: Chapter[] }>();
const nav = document.getElementById("tour-nav")!;
const prose = document.getElementById("tour-prose")!;
const host = document.getElementById("tour-widget")!;
const prev = document.getElementById("tour-prev") as HTMLButtonElement;
const next = document.getElementById("tour-next") as HTMLButtonElement;
const counter = document.getElementById("tour-count")!;

nav.replaceChildren(...chapters.map((c, i) => {
  const a = document.createElement("a");
  a.href = `#${c.id}`;
  a.textContent = `${i + 1}. ${c.title}`;
  return a;
}));

function show() {
  const id = location.hash.slice(1);
  const i = Math.max(0, chapters.findIndex((c) => c.id === id));
  const c = chapters[i];
  prose.innerHTML = c.html;
  counter.textContent = `${i + 1} of ${chapters.length}`;
  prev.disabled = i === 0;
  next.disabled = i === chapters.length - 1;
  prev.onclick = () => (location.hash = chapters[i - 1].id);
  next.onclick = () => (location.hash = chapters[i + 1].id);
  nav.querySelectorAll("a").forEach((a, j) => a.classList.toggle("active", i === j));
  mountWidget(host, { presets: [{ id: c.id, title: c.title, blurb: "", code: c.code, records: c.records }], root: root(), hideSelect: true, live: true });
  document.title = `${c.title} · Haze tour`;
}
addEventListener("hashchange", show);
show();
