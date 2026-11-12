// The page's side of the Haze engine: a Web Worker running the WebAssembly build, with a time
// limit. Only the latest request matters, so a new check replaces one that is still waiting.

export interface Record_ {
  file: string; line: number; column: number; severity: "info" | "error"; message: string;
  kind?: string; [k: string]: any;
}
export interface Result { records: Record_[]; ms: number }
export type EngineState = "loading" | "ready" | "running" | "failed";

export class Engine {
  private worker: Worker | null = null;
  private seq = 0;
  private pending = new Map<number, { resolve: (r: Result) => void; reject: (e: Error) => void; timer: number }>();
  private listeners: ((s: EngineState, detail?: string) => void)[] = [];
  state: EngineState = "loading";

  constructor(private url: URL, private limitMs = 20000) {}

  onState(f: (s: EngineState, detail?: string) => void) {
    this.listeners.push(f);
    f(this.state);
  }

  private set(s: EngineState, detail?: string) {
    this.state = s;
    for (const f of this.listeners) f(s, detail);
  }

  /** Starts the worker, which downloads and starts the engine in the background. */
  start() {
    if (this.worker) return;
    try {
      this.worker = new Worker(this.url, { type: "module" });
    } catch (e) {
      this.set("failed", "this browser can't run module workers");
      return;
    }
    this.set("loading");
    this.worker.onmessage = (e) => {
      const m = e.data;
      if ("ready" in m) {
        this.set(m.ready ? (this.pending.size ? "running" : "ready") : "failed", m.error);
        return;
      }
      const p = this.pending.get(m.id);
      if (!p) return;
      this.pending.delete(m.id);
      clearTimeout(p.timer);
      if (this.pending.size === 0) this.set("ready");
      if (m.error) p.reject(new Error(m.error));
      else p.resolve({ records: parseLines(m.json), ms: m.ms });
    };
    this.worker.onerror = (e) => {
      this.set("failed", e.message);
      this.restart(new Error(`the engine crashed: ${e.message}`));
    };
  }

  /** Checks a source text. Rejects if the check is stopped or takes longer than the limit. */
  check(src: string): Promise<Result> {
    this.start();
    // a newer check supersedes any that are still running
    if (this.pending.size) this.restart(new Error("superseded"));
    this.start();
    const id = ++this.seq;
    this.set("running");
    return new Promise((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.restart(new Error(`stopped after ${this.limitMs / 1000} s; this model needs more time than the browser allows, so run it with the haze command`));
      }, this.limitMs);
      this.pending.set(id, { resolve, reject, timer });
      this.worker!.postMessage({ id, src });
    });
  }

  /** Stops the running check by terminating the worker; the next check starts a new one. */
  stop() {
    this.restart(new Error("stopped"));
  }

  private restart(err: Error) {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
    this.worker?.terminate();
    this.worker = null;
    this.set("loading");
  }
}

export function parseLines(json: string): Record_[] {
  return json.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}

let shared: Engine | null = null;

/** The page's engine, shared by every editor on it. */
export function engine(root: string): Engine {
  if (!shared) shared = new Engine(new URL(`${root}engine/worker.js`, document.baseURI));
  return shared;
}
