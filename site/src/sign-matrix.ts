import { signEquation } from "../literate.mjs";

/** Enhance the static matrix without changing the order of its entries. */
export function mountSignMatrix(figure: HTMLElement) {
  const matrix = figure.querySelector<HTMLElement>(".sign-matrix")!;
  const values = [...matrix.querySelectorAll<HTMLElement>("[data-value]")].map((cell) => Number(cell.dataset.value));
  const result = figure.querySelector("output")!;
  function show() {
    result.textContent = signEquation(values);
    buttons.forEach((btn, i) => {
      btn.textContent = values[i] < 0 ? "−1" : "+1";
      btn.setAttribute("aria-label", `Row ${1 + Math.floor(i / 2)}, column ${1 + i % 2}: ${values[i]}. Flip sign`);
    });
  }
  const buttons = values.map((_, i) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.addEventListener("click", () => { values[i] *= -1; show(); });
    return btn;
  });
  matrix.replaceChildren(...buttons);
  figure.querySelector("figcaption")!.hidden = false;
  show();
}
