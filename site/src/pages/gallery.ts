// The gallery: every example in the repository, with its output, filterable by field.
import { common, root, pageData } from "../common";
import { renderRecords, h } from "../render";
import { linkTo } from "../share";
import type { Record_ } from "../engine";

interface Example { id: string; path: string; title: string; field: string; desc: string; code: string; records: Record_[]; slow: boolean }

common();
const { examples } = pageData<{ examples: Example[] }>();
const r = root();
const list = document.getElementById("gallery")!;
const filters = document.getElementById("gallery-filters")!;
const fields = ["All", ...new Set(examples.map((e) => e.field))];
const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
let active = fields.find((f) => slug(f) === location.hash.slice(1)) ?? "All";

function draw() {
  list.replaceChildren(...examples.filter((e) => active === "All" || e.field === active).map((e) => {
    const out = h("div", { class: "results" });
    const open = h("a", { class: "btn", href: `${r}play/` }, "Open in the playground");
    open.addEventListener("click", async (ev) => {
      ev.preventDefault();
      location.href = await linkTo(new URL(`${r}play/`, document.baseURI), e.code);
    });
    const details = h("details", { class: "example" },
      h("summary", {}, h("span", { class: "field" }, e.field), h("strong", {}, e.title), h("span", { class: "muted" }, e.desc)),
      h("div", { class: "example-body" },
        h("div", { class: "example-bar" },
          h("a", { href: `https://github.com/ritabratamaiti/haze-lang/blob/main/${e.path}` }, e.path),
          h("div", { class: "spacer" }),
          e.slow ? h("span", { class: "muted small" }, "takes minutes in the browser; output computed in advance") : null,
          open),
        h("div", { class: "example-cols" }, h("pre", { class: "code" }, e.code), out)));
    details.addEventListener("toggle", () => { if (details.open && !out.childElementCount) renderRecords(out, e.records); }, { once: true });
    return details;
  }));
}

filters.replaceChildren(...fields.map((f) => {
  const b = h("button", { class: `chip-btn ${f === active ? "active" : ""}` }, f);
  b.addEventListener("click", () => {
    active = f;
    filters.querySelectorAll("button").forEach((x) => x.classList.toggle("active", x === b));
    draw();
  });
  return b;
}));
draw();
