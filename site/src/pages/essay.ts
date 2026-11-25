import { common, root } from "../common";
import { Engine } from "../engine";
import { renderText } from "../render";
import { mountSignMatrix } from "../sign-matrix";

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

run.hidden = false;
run.addEventListener("click", async () => {
  run.disabled = source.readOnly = true;
  stop.hidden = false;
  consoleBox.hidden = true;
  status.textContent = "Checking this file in your browser…";
  try {
    const { records, ms } = await engine.check(source.value);
    renderText(output, records);
    if (!records.length) output.textContent = "No queries or claims in this file.";
    consoleBox.hidden = false;
    consoleBox.open = true;
    const errors = records.filter((r) => r.severity === "error");
    const rejected = errors.filter((r) => r.accepted === false).length;
    const faults = errors.length - rejected;
    status.textContent = [`Checked in ${(ms / 1000).toFixed(1)} s`, `${records.length} result${records.length === 1 ? "" : "s"}`,
      ...(rejected ? [`${rejected} rejected`] : []), ...(faults ? [`${faults} error${faults === 1 ? "" : "s"}`] : [])].join(" · ");
  } catch (e) {
    status.textContent = e instanceof Error ? e.message : String(e);
  } finally {
    run.disabled = source.readOnly = false;
    stop.hidden = true;
  }
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
