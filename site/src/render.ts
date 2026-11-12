// Rich output: turns Haze's JSON records into cards with interval bars, histograms,
// counterexamples and probability-weighted test suites. Hovering a number shows its exact value.
import type { Record_ } from "./engine";
import { fmtRat, ratTitle, parseRat, toFloat, fmtNum } from "./rat";

type Child = Node | string | null | undefined | false;

export function h(tag: string, attrs: Record<string, any> = {}, ...children: Child[]): HTMLElement {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, String(v));
  }
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

const SVG = "http://www.w3.org/2000/svg";
function s(tag: string, attrs: Record<string, any> = {}, ...children: (Node | null)[]): SVGElement {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== undefined && v !== null) el.setAttribute(k, String(v));
  for (const c of children) if (c) el.append(c);
  return el;
}

/** A number with its exact value on hover. */
export function num(q: string | null | undefined, cls = "num"): HTMLElement {
  return h("span", { class: cls, title: ratTitle(q) }, fmtRat(q));
}

function value(v: any): string {
  if (typeof v === "boolean") return String(v);
  if (typeof v === "string" && /^-?\d+(\/\d+)?$/.test(v)) return fmtRat(v);
  return String(v);
}

function params(p: Record<string, any> | undefined): string {
  if (!p) return "";
  return Object.entries(p).map(([k, v]) => `${k} = ${value(v)}`).join(", ");
}

function firstLine(r: Record_): string {
  return r.message.split("\n")[0];
}

function status(r: Record_): { text: string; cls: string } {
  if (r.kind === "theorem") return r.accepted ? { text: "proved", cls: "ok" } : { text: "rejected", cls: "bad" };
  if (r.kind === "claim") {
    if (!r.accepted) return { text: "bound fails", cls: "bad" };
    if (r.message.includes("bound holds")) return { text: "bound holds", cls: "ok" };
    return { text: "computed", cls: "info" };
  }
  if (r.severity === "error") return { text: "error", cls: "bad" };
  return { text: "", cls: "info" };
}

/** A horizontal bar from 0 to 1: solid up to the belief, translucent up to the plausibility. */
function intervalBar(bel: string, pl: string): HTMLElement {
  const b = toFloat(parseRat(bel)), p = toFloat(parseRat(pl));
  return h("div", { class: "ibar", role: "img", "aria-label": `between ${fmtRat(bel)} and ${fmtRat(pl)}` },
    h("div", { class: "ibar-bel", style: { width: `${Math.max(0, Math.min(1, b)) * 100}%` } }),
    h("div", { class: "ibar-gap", style: { left: `${b * 100}%`, width: `${Math.max(0, p - b) * 100}%` } }));
}

function intervalText(bel: string, pl: string, lo = "belief", hi = "plausibility"): HTMLElement {
  if (bel === pl) return h("div", { class: "big" }, num(bel));
  return h("div", { class: "big" }, h("span", { class: "label" }, `${lo} `), num(bel), h("span", { class: "sep" }, " · "),
    h("span", { class: "label" }, `${hi} `), num(pl));
}

function branchTable(branches: any[], cell: (b: any) => Child): HTMLElement | null {
  if (!branches || branches.length <= 1) return null;
  const rows = branches.slice(0, 12).map((b) => {
    const pi = toFloat(parseRat(b.possibility));
    return h("tr", {},
      h("td", { class: "params" }, params(b.parameters)),
      h("td", { class: "pi", title: `possibility ${fmtRat(b.possibility)}` },
        h("span", { class: "pibar" }, h("span", { style: { width: `${pi * 100}%` } })), fmtRat(b.possibility)),
      h("td", {}, cell(b)));
  });
  return h("details", { class: "branches", open: branches.length <= 6 ? "" : undefined },
    h("summary", {}, `by fuzzy parameter · ${branches.length} assignments${branches.length > 12 ? " (first 12 shown)" : ""}`),
    h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "parameters"), h("th", {}, "π"), h("th", {}, "result"))), h("tbody", {}, ...rows)));
}

function rangeCell(b: any): Child {
  if (b.lower === undefined) return num(b.expectation);
  return b.lower === b.upper ? num(b.lower) : h("span", {}, num(b.lower), " – ", num(b.upper));
}

function counterexample(c: any, happens: boolean): HTMLElement {
  const state = Object.entries(c.state ?? {});
  const inputs = Object.entries(c.inputs ?? {});
  return h("div", { class: "cex" },
    h("div", { class: "cex-head" },
      h("span", { class: "cex-title" }, happens ? "A run where it happens" : "Counterexample"),
      c.step !== undefined ? h("span", {}, ` · step ${c.step}`) : null,
      h("span", {}, " · probability "), num(c.mass)),
    Object.keys(c.parameters ?? {}).length ? h("div", { class: "kv" }, h("span", { class: "k" }, "parameters"), h("span", {}, params(c.parameters))) : null,
    inputs.length ? h("div", { class: "kv" }, h("span", { class: "k" }, "inputs"), h("span", {}, inputs.map(([k, v]) => `${k} = ${value(v)}`).join(", "))) : null,
    state.length ? h("div", { class: "state" }, ...state.map(([k, v]) => h("span", { class: "var" }, h("span", { class: "k" }, k), h("span", { class: "v" }, value(v))))) : null);
}

function histogram(dist: any[]): HTMLElement {
  const rows = [...dist].sort((a, b) => toFloat(parseRat(b.probability)) - toFloat(parseRat(a.probability))).slice(0, 16);
  const max = Math.max(...rows.map((d) => toFloat(parseRat(d.probability))), 1e-12);
  return h("div", { class: "hist" }, ...rows.map((d) => {
    const p = toFloat(parseRat(d.probability));
    return h("div", { class: "hrow" },
      h("span", { class: "hval" }, value(d.value)),
      h("span", { class: "htrack" }, h("span", { class: "hbar", style: { width: `${(p / max) * 100}%` } })),
      num(d.probability, "num hnum"));
  }), dist.length > 16 ? h("div", { class: "muted" }, `and ${dist.length - 16} more values`) : null);
}

/** The probability-weighted coverage curve of a `#tests` suite. */
function coverageCurve(runs: any[]): SVGElement {
  const suite = runs.filter((r) => r.suite);
  const W = 320, H = 120, pad = 22;
  const n = Math.max(1, suite.length);
  let cum = 0;
  const pts: [number, number][] = [[pad, H - pad]];
  suite.forEach((r, i) => {
    const x = pad + ((i + 1) / n) * (W - 2 * pad);
    pts.push([pts[pts.length - 1][0], H - pad - cum * (H - 2 * pad)]);
    cum += toFloat(parseRat(r.probability));
    pts.push([x, H - pad - cum * (H - 2 * pad)]);
  });
  const path = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
  const fails = suite.map((r, i) => (r.passes === false ? s("circle", { cx: pad + ((i + 1) / n) * (W - 2 * pad), cy: H - pad, r: 3.5, class: "cov-fail" }) : null));
  return s("svg", { viewBox: `0 0 ${W} ${H}`, class: "coverage", role: "img", "aria-label": `the ${suite.length} most likely runs cover ${fmtNum(cum)} of the probability` },
    s("line", { x1: pad, y1: H - pad, x2: W - pad, y2: H - pad, class: "axis" }),
    s("line", { x1: pad, y1: pad, x2: pad, y2: H - pad, class: "axis" }),
    s("line", { x1: pad, y1: pad, x2: W - pad, y2: pad, class: "grid" }),
    s("text", { x: 4, y: pad + 4, class: "tick" }, document.createTextNode("1")),
    s("text", { x: 4, y: H - pad + 4, class: "tick" }, document.createTextNode("0")),
    s("text", { x: W - pad, y: H - 6, class: "tick", "text-anchor": "end" }, document.createTextNode(`${suite.length} tests`)),
    s("path", { d: path, class: "cov-line" }), ...fails);
}

function testRun(r: any, i: number): HTMLElement {
  const steps = (r.steps ?? []).filter((st: any) => st.choices.length);
  const final = r.steps?.length ? r.steps[r.steps.length - 1].state : r.initial;
  return h("div", { class: `run ${r.passes === false ? "run-fail" : r.passes === true ? "run-pass" : ""}` },
    h("div", { class: "run-head" },
      h("span", { class: "run-id" }, r.suite ? `#${i + 1}` : "failing"),
      h("span", { class: `chip ${r.passes === false ? "bad" : "ok"}` }, r.passes === false ? "fails" : r.passes === true ? "passes" : "unknown"),
      h("span", { class: "muted" }, "probability "), num(r.probability)),
    h("div", { class: "steps" }, ...(steps.length ? steps.map((st: any) => h("span", { class: "step" },
      h("span", { class: "step-n" }, `step ${st.step}`),
      st.choices.map((c: any) => `${c.what} = ${value(c.value)}`).join(", "))) : [h("span", { class: "muted" }, "no random decisions")])),
    final ? h("div", { class: "state small" }, ...Object.entries(final).map(([k, v]) => h("span", { class: "var" }, h("span", { class: "k" }, k), h("span", { class: "v" }, value(v))))) : null);
}

function tests(r: Record_): HTMLElement {
  const st = r.statistical;
  const suite = r.runs.filter((x: any) => x.suite);
  return h("div", { class: "tests" },
    h("div", { class: "tests-top" },
      coverageCurve(r.runs),
      h("div", { class: "tests-facts" },
        h("div", {}, h("span", { class: "label" }, "covered "), num(r.covered, "num big"), h("span", { class: "muted" }, ` by ${suite.length} test${suite.length === 1 ? "" : "s"}`)),
        h("div", {}, h("span", { class: "label" }, "fails with probability "), num(r.failure_probability)),
        st ? h("div", { class: "stat" },
          h("div", { class: "label" }, "statistical test"),
          h("div", {}, `Run the real code ${st.runs.toLocaleString()} times, allow ${st.allowed_failures} failures.`),
          h("div", { class: "muted" }, `False alarm ${fmtNum(Number(st.false_alarm))}; code that fails twice as often is caught ${fmtNum(Number(st.power) * 100)}% of the time.`))
          : h("div", { class: "stat" }, h("div", { class: "label" }, "statistical test"), h("div", {}, "The property never fails, so one run is a deterministic test.")))),
    h("div", { class: "runs" }, ...r.runs.slice(0, 12).map((x: any, i: number) => testRun(x, i))));
}

function body(r: Record_): Child[] {
  switch (r.kind) {
    case "theorem":
    case "claim": {
      const happens = r.message.includes("a run where it happens") || r.message.includes("a world where it happens");
      return [intervalText(r.belief, r.plausibility), intervalBar(r.belief, r.plausibility),
        h("div", { class: "muted small" }, (r.message.split("\n").find((l) => /bound|theorem (accepted|rejected)/.test(l)) ?? "").trim()),
        branchTable(r.branches, rangeCell), r.counterexample ? counterexample(r.counterexample, happens) : null];
    }
    case "prob":
      return [intervalText(r.belief, r.plausibility), intervalBar(r.belief, r.plausibility), branchTable(r.branches, rangeCell)];
    case "expect":
      if (r.lower === null || r.upper === null) return [h("div", { class: "big" }, r.lower === null ? "∞" : num(r.lower), r.lower !== r.upper ? [" – ", r.upper === null ? "∞" : num(r.upper)] as any : null), h("pre", { class: "msg" }, r.message.split("\n").slice(1).join("\n"))];
      return [r.lower === r.upper ? h("div", { class: "big" }, h("span", { class: "label" }, "expected "), num(r.lower))
        : intervalText(r.lower, r.upper, "lower", "upper"), branchTable(r.branches, rangeCell)];
    case "eval": {
      const bs = r.branches ?? [];
      if (bs.length <= 1) return [histogram(bs[0]?.distribution ?? [])];
      return bs.slice(0, 4).map((b: any) => h("div", { class: "evalb" }, h("div", { class: "muted small" }, `${params(b.parameters)} (π ${fmtRat(b.possibility)})`), histogram(b.distribution)));
    }
    case "tests":
      return [tests(r)];
    default: {
      const rest = r.message.split("\n").slice(1).join("\n");
      return rest ? [h("pre", { class: "msg" }, rest)] : [];
    }
  }
}

const KIND_LABEL: Record<string, string> = {
  theorem: "theorem", claim: "claim", prob: "#prob", expect: "#expect", eval: "#eval", tests: "#tests",
  observe: "observe", check: "#check",
};

export function card(r: Record_, onLine?: (line: number) => void): HTMLElement {
  const st = status(r);
  const title = r.kind === "theorem" || r.kind === "claim" ? r.name
    : (r.query ?? firstLine(r)).replace(/^(#\w+(\[\d+\])?|observe)\s+/, "");
  const label = KIND_LABEL[r.kind ?? ""] ?? (r.severity === "error" ? "error" : (firstLine(r).match(/^#\w+/)?.[0] ?? "info"));
  return h("article", { class: `rec rec-${st.cls}` },
    h("header", { class: "rec-head" },
      h("span", { class: "kind" }, label),
      h("code", { class: "rec-title" }, r.severity === "error" && !r.kind ? firstLine(r) : title),
      st.text ? h("span", { class: `pill ${st.cls}` }, st.text) : null,
      h("button", { class: "loc", title: "show in the editor", onclick: () => onLine?.(r.line) }, `line ${r.line}`)),
    h("div", { class: "rec-body" }, ...body(r)));
}

/** Renders all records, most important first: errors and rejected results, then the rest. */
export function renderRecords(el: HTMLElement, records: Record_[], onLine?: (line: number) => void) {
  el.replaceChildren(...(records.length ? records.map((r) => card(r, onLine))
    : [h("div", { class: "muted empty" }, "Nothing to report yet. Add a claim, a theorem or a query such as #prob.")]));
}

/** The plain-text output, exactly as the `haze` command prints it. */
export function renderText(el: HTMLElement, records: Record_[]) {
  el.textContent = records.map((r) => `main.hz:${r.line}:${r.column}: ${r.severity}: ${r.message}`).join("\n");
}
