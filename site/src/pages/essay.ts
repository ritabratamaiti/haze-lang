import { common, root } from "../common";
import { Engine, type Record_ } from "../engine";
import { renderText } from "../render";
import { mountSignMatrix } from "../sign-matrix";
import { assembleEssay, blockOutput } from "../../literate.mjs";

common();
document.querySelectorAll<HTMLElement>(".essay .sign-example").forEach(mountSignMatrix);
const source = document.querySelector<HTMLTextAreaElement>("#model-input")!;
const download = document.querySelector<HTMLAnchorElement>("#model-download")!;
const run = document.querySelector<HTMLButtonElement>("#model-run")!;
const stop = document.querySelector<HTMLButtonElement>("#model-stop")!;
const status = document.getElementById("model-status")!;
const consoleBox = document.querySelector<HTMLDetailsElement>("#model-console")!;
const output = consoleBox.querySelector("pre")!;
// The full essay solves several 101-state chains; it takes longer than one playground snippet.
const engine = new Engine(new URL(`${root()}engine/worker.js`, document.baseURI), 180_000);
const cells = [...document.querySelectorAll<HTMLElement>(".essay-cell")].map((el) => ({
  line: Number(el.dataset.line),
  editor: el.querySelector("textarea")!,
  run: el.querySelector<HTMLButtonElement>(".cell-run")!,
  stop: el.querySelector<HTMLButtonElement>(".cell-stop")!,
  reset: el.querySelector<HTMLButtonElement>(".cell-reset")!,
  status: el.querySelector<HTMLElement>("[role=status]")!,
  output: el.querySelector("pre")!,
}));
const runButtons = [run, ...cells.map((c) => c.run)];

async function check(code: string, notice: HTMLElement, cancel: HTMLButtonElement, show: (records: Record_[]) => void, firstLine = 1) {
  for (const btn of runButtons) btn.disabled = true;
  for (const cell of cells) { cell.editor.readOnly = true; cell.reset.disabled = true; }
  source.readOnly = true;
  cancel.hidden = false;
  notice.textContent = "Checking in your browser…";
  try {
    const { records, ms } = await engine.check(code);
    show(records);
    const count = records.filter((r) => r.line >= firstLine).length;
    const errors = records.filter((r) => r.severity === "error");
    const rejected = errors.filter((r) => r.accepted === false).length;
    const faults = errors.length - rejected;
    notice.textContent = [`Checked in ${(ms / 1000).toFixed(1)} s`, `${count} result${count === 1 ? "" : "s"}`,
      ...(rejected ? [`${rejected} rejected`] : []), ...(faults ? [`${faults} error${faults === 1 ? "" : "s"}`] : [])].join(" · ");
  } catch (e) {
    notice.textContent = e instanceof Error ? e.message : String(e);
  } finally {
    for (const btn of runButtons) btn.disabled = false;
    for (const cell of cells) { cell.editor.readOnly = false; cell.reset.disabled = false; }
    source.readOnly = cells.length > 0;
    cancel.hidden = true;
  }
}

for (const btn of runButtons) btn.hidden = false;
run.addEventListener("click", () => {
  consoleBox.hidden = true;
  void check(source.value, status, stop, (records) => {
    renderText(output, records);
    if (!records.length) output.textContent = "No queries or claims in this file.";
    consoleBox.hidden = false;
    consoleBox.open = true;
  });
});
stop.addEventListener("click", () => engine.stop());
source.addEventListener("input", () => {
  consoleBox.hidden = true;
  const edited = source.value !== source.defaultValue;
  download.textContent = edited ? "Download edited file" : `Download ${download.download}`;
  status.textContent = edited ? "Edited. Run to check your changes." : "";
});
download.addEventListener("click", (e) => {
  if (source.value === source.defaultValue) return;
  e.preventDefault();
  const url = URL.createObjectURL(new Blob([source.value], { type: "text/plain;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = download.download;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});

function assembled() {
  return assembleEssay(source.defaultValue, cells.map(({ line, editor }) => ({
    line, originalLength: editor.defaultValue.split("\n").length, value: editor.value,
  })));
}

cells.forEach((cell, i) => {
  cell.editor.readOnly = false;
  cell.editor.addEventListener("input", () => {
    source.value = assembled().code;
    source.dispatchEvent(new Event("input"));
    cell.reset.hidden = cell.editor.value === cell.editor.defaultValue;
    for (const later of cells.slice(i)) {
      later.output.hidden = true;
      later.status.textContent = later === cell ? "Run to check this edit." : "Earlier code changed. Run to update.";
    }
  });
  cell.reset.addEventListener("click", () => {
    cell.editor.value = cell.editor.defaultValue;
    cell.editor.dispatchEvent(new Event("input"));
  });
  cell.run.addEventListener("click", () => {
    const { code, ranges } = assembled();
    const { first, last } = ranges[i];
    cell.output.hidden = true;
    void check(code.split("\n").slice(0, last).join("\n"), cell.status, cell.stop, (records) => {
      cell.output.textContent = blockOutput(records, first);
      cell.output.hidden = false;
    }, first);
  });
  cell.stop.addEventListener("click", () => engine.stop());
  cell.editor.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); cell.run.click(); }
  });
});

for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-edit-line]")) {
  link.addEventListener("click", (e) => {
    if (e.ctrlKey || e.metaKey || e.shiftKey || e.altKey || e.button !== 0) return;
    e.preventDefault();
    const line = source.defaultValue.split("\n")[Number(link.dataset.editLine) - 1];
    const needle = line.match(/^(?:system|param|def) \w+/)?.[0] ?? line;
    const pos = source.value.indexOf(needle);
    source.closest("details")!.open = true;
    source.focus();
    if (pos >= 0) {
      const end = source.value.indexOf("\n", pos);
      source.setSelectionRange(pos, end < 0 ? source.value.length : end);
      const lineCount = source.value.slice(0, pos).split("\n").length;
      source.scrollTop = Math.max(0, lineCount - 3) * parseFloat(getComputedStyle(source).lineHeight);
    } else {
      status.textContent = "That line has changed. Your edits are still in the source.";
    }
  });
}
