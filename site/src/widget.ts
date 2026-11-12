// The interactive editor used on the home page and in the playground: a preset dropdown, the
// editor, and rich results. Presets show their precomputed output at once, before the engine has
// loaded; edited code is checked by the WebAssembly engine.
import { createEditor, HazeEditor } from "./editor";
import { engine, Record_, EngineState } from "./engine";
import { renderRecords, renderText, h } from "./render";
import { linkTo, encode } from "./share";

export interface Preset { id: string; title: string; blurb: string; code: string; records: Record_[] }

export interface WidgetOptions {
  presets: Preset[];
  root: string;
  initial?: { code: string; presetId?: string };
  live?: boolean;            // re-check while typing
  compact?: boolean;         // the home page's smaller version
  hideSelect?: boolean;      // a single example, as in the tour
  onResult?: (records: Record_[]) => void;
}

export function mountWidget(host: HTMLElement, opts: WidgetOptions) {
  const eng = engine(opts.root);
  const select = h("select", { class: "preset", "aria-label": "Example" },
    ...opts.presets.map((p) => h("option", { value: p.id }, p.title))) as HTMLSelectElement;
  const blurb = h("p", { class: "blurb" });
  const status = h("span", { class: "status", role: "status", "aria-live": "polite" });
  const runBtn = h("button", { class: "btn primary", title: "Run (Ctrl+Enter)" }, "Run");
  const stopBtn = h("button", { class: "btn", hidden: "" }, "Stop");
  const shareBtn = h("button", { class: "btn", title: "Copy a link to this code" }, "Share");
  const dlBtn = h("button", { class: "btn", title: "Download as a .hz file" }, "Download");
  const liveBox = h("input", { type: "checkbox", id: `live-${Math.random().toString(36).slice(2)}` }) as HTMLInputElement;
  liveBox.checked = opts.live ?? !opts.compact;
  const results = h("div", { class: "results" });
  const text = h("pre", { class: "results-text", hidden: "" });
  const tabR = h("button", { class: "tab active", role: "tab", "aria-selected": "true" }, "Results");
  const tabT = h("button", { class: "tab", role: "tab", "aria-selected": "false" }, "Text");
  const editorHost = h("div", { class: "editor" });

  let records: Record_[] = [];
  let current: Preset | undefined;
  let dirty = false;

  const editor: HazeEditor = createEditor(editorHost, opts.initial?.code ?? opts.presets[0].code, {
    onRun: () => run(),
    onChange: () => {
      dirty = true;
      if (liveBox.checked) schedule();
    },
  });

  function show(rs: Record_[], note?: string) {
    records = rs;
    renderRecords(results, rs, (line) => {
      const l = editor.view.state.doc.line(Math.min(line, editor.view.state.doc.lines));
      editor.view.dispatch({ selection: { anchor: l.from }, scrollIntoView: true });
      editor.view.focus();
    });
    renderText(text, rs);
    editor.showRecords(rs);
    if (note) status.textContent = note;
    opts.onResult?.(rs);
  }

  function setState(s: EngineState, detail?: string) {
    runBtn.toggleAttribute("disabled", s === "failed");
    stopBtn.toggleAttribute("hidden", s !== "running");
    if (s === "loading") status.textContent = "loading the engine…";
    else if (s === "running") status.textContent = "checking…";
    else if (s === "failed") status.textContent = `the engine couldn't start in this browser${detail ? ` (${detail})` : ""}`;
  }
  eng.onState(setState);

  let timer = 0;
  function schedule() {
    clearTimeout(timer);
    timer = window.setTimeout(run, 450);
  }

  async function run() {
    clearTimeout(timer);
    const code = editor.get();
    try {
      const r = await eng.check(code);
      show(r.records, `checked in ${r.ms < 1000 ? `${r.ms.toFixed(0)} ms` : `${(r.ms / 1000).toFixed(1)} s`}, in your browser`);
    } catch (e: any) {
      if (e.message !== "superseded") status.textContent = e.message;
    }
  }

  function load(p: Preset) {
    current = p;
    select.value = p.id;
    blurb.textContent = p.blurb;
    const live = liveBox.checked;
    liveBox.checked = false;     // don't re-check the preset we already have output for
    editor.set(p.code);
    liveBox.checked = live;
    dirty = false;
    show(p.records, "precomputed output; edit the code or press Run to check it live");
  }

  select.addEventListener("change", () => {
    const p = opts.presets.find((x) => x.id === select.value);
    if (p) load(p);
  });
  runBtn.addEventListener("click", run);
  stopBtn.addEventListener("click", () => eng.stop());
  shareBtn.addEventListener("click", async () => {
    const url = await linkTo(new URL(`${opts.root}play/`, document.baseURI), editor.get());
    history.replaceState(null, "", opts.compact ? location.href : url);
    await navigator.clipboard?.writeText(url).catch(() => {});
    status.textContent = "link copied";
  });
  dlBtn.addEventListener("click", () => {
    const a = h("a", { href: URL.createObjectURL(new Blob([editor.get()], { type: "text/plain" })), download: `${current?.id ?? "model"}.hz` });
    a.click();
  });
  for (const [tab, other, show_, hide] of [[tabR, tabT, results, text], [tabT, tabR, text, results]] as const) {
    tab.addEventListener("click", () => {
      tab.classList.add("active"); other.classList.remove("active");
      tab.setAttribute("aria-selected", "true"); other.setAttribute("aria-selected", "false");
      show_.removeAttribute("hidden"); hide.setAttribute("hidden", "");
    });
  }

  host.replaceChildren(...[
    h("div", { class: "widget-bar" }, opts.hideSelect ? null : select, h("div", { class: "spacer" }),
      h("label", { class: "live", for: liveBox.id }, liveBox, " live"), stopBtn, runBtn, shareBtn, opts.compact ? null : dlBtn),
    opts.hideSelect ? null : blurb,
    h("div", { class: "widget-main" },
      editorHost,
      h("div", { class: "output" },
        h("div", { class: "tabs", role: "tablist" }, tabR, tabT, h("div", { class: "spacer" }), status),
        results, text)),
  ].filter((x): x is HTMLElement => x !== null));

  const first = opts.initial?.presetId ? opts.presets.find((p) => p.id === opts.initial!.presetId) : undefined;
  if (opts.initial && !first) {
    blurb.textContent = "Code from a shared link.";
    eng.start();
    run();
  } else {
    load(first ?? opts.presets[0]);
  }
  // start downloading the engine once the page has settled
  setTimeout(() => eng.start(), opts.compact ? 1500 : 0);

  return { editor, run, load, get records() { return records; }, get dirty() { return dirty; }, encode: () => encode(editor.get()) };
}
