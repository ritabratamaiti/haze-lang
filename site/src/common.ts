// Behavior shared by every page: copy buttons, install tabs, and reading the page's data.
export function root(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="root"]')?.content ?? "./";
}

export function pageData<T>(): T {
  const el = document.getElementById("page-data");
  return el ? JSON.parse(el.textContent || "{}") : ({} as T);
}

function setupCopy() {
  for (const btn of document.querySelectorAll<HTMLButtonElement>("[data-copy]")) {
    btn.addEventListener("click", async () => {
      const target = document.getElementById(btn.dataset.copy!);
      await navigator.clipboard?.writeText(target?.textContent?.trim() ?? "").catch(() => {});
      const old = btn.textContent;
      btn.textContent = "Copied";
      setTimeout(() => (btn.textContent = old), 1200);
    });
  }
}

function setupTabs() {
  for (const group of document.querySelectorAll<HTMLElement>("[data-tabs]")) {
    const tabs = [...group.querySelectorAll<HTMLButtonElement>("[role=tab]")];
    const panels = tabs.map((t) => document.getElementById(t.getAttribute("aria-controls")!)!);
    tabs.forEach((t, i) => t.addEventListener("click", () => {
      tabs.forEach((u, j) => {
        u.setAttribute("aria-selected", String(i === j));
        u.classList.toggle("active", i === j);
        panels[j].hidden = i !== j;
      });
    }));
  }
}

function setupNav() {
  const btn = document.querySelector<HTMLButtonElement>(".nav-toggle");
  btn?.addEventListener("click", () => {
    const open = document.body.classList.toggle("nav-open");
    btn.setAttribute("aria-expanded", String(open));
  });
}

export function common() {
  document.documentElement.classList.add("js");
  setupCopy();
  setupTabs();
  setupNav();
}
