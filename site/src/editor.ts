// The code editor: CodeMirror 6 with a Haze language mode, a theme that follows the site, error
// underlines from Haze's messages, and Ctrl/Cmd+Enter to run.
import { EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection } from "@codemirror/view";
import { EditorState, Compartment } from "@codemirror/state";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { StreamLanguage, HighlightStyle, syntaxHighlighting, bracketMatching, indentOnInput } from "@codemirror/language";
import { linter, Diagnostic, lintGutter, setDiagnostics } from "@codemirror/lint";
import { tags as t } from "@lezer/highlight";
import type { Record_ } from "./engine";

const KEYWORDS = new Set(("logic enum param input def observe system var step claim theorem with prob if then else let in " +
  "forall exists match and or not implies is very assert skip always eventually after given explore levels steps until").split(" "));
const ATOMS = new Set(["true", "false", "crashed"]);
const TYPES = new Set(["Num", "Bool", "Deg"]);
const BUILTINS = new Set(("flip bernoulli uniform binomial tri trap likelihood ramp_up ramp_down abs floor min max deg num").split(" "));

/** A simple tokenizer for Haze, which is all the highlighting needs. */
export const hazeLanguage = StreamLanguage.define<{ comment: number }>({
  name: "haze",
  startState: () => ({ comment: 0 }),
  token(stream, state) {
    if (state.comment > 0) {
      while (!stream.eol()) {
        if (stream.match("/-")) state.comment++;
        else if (stream.match("-/")) { if (--state.comment === 0) break; }
        else stream.next();
      }
      return "comment";
    }
    if (stream.eatSpace()) return null;
    if (stream.match("--")) { stream.skipToEnd(); return "comment"; }
    if (stream.match("/-")) { state.comment = 1; return "comment"; }
    if (stream.match(/^#[a-z]+/)) return "keyword";
    if (stream.match(/^\d+(\.\d+)?/)) return "number";
    if (stream.match(/^(\|=|~=|:=|=>|->|==|!=|<=|>=|⊨|≈|≤|≥|≠|→|⇒|[~+\-*/<>=|])/)) return "operator";
    if (stream.match(/^[A-Za-z_][A-Za-z0-9_']*/)) {
      const w = stream.current();
      if (KEYWORDS.has(w)) return "keyword";
      if (ATOMS.has(w)) return "atom";
      if (TYPES.has(w)) return "typeName";
      if (BUILTINS.has(w)) return "function";
      return /^[A-Z]/.test(w) ? "className" : "variableName";
    }
    stream.next();
    return null;
  },
  languageData: { commentTokens: { line: "--", block: { open: "/-", close: "-/" } } },
});

const highlight = HighlightStyle.define([
  { tag: t.comment, color: "var(--code-comment)", fontStyle: "italic" },
  { tag: t.keyword, color: "var(--code-keyword)", fontWeight: "600" },
  { tag: t.number, color: "var(--code-number)" },
  { tag: t.atom, color: "var(--code-number)" },
  { tag: t.operator, color: "var(--code-operator)" },
  { tag: t.typeName, color: "var(--code-type)" },
  { tag: t.className, color: "var(--code-type)" },
  { tag: [t.function(t.variableName), t.standard(t.name)], color: "var(--code-fn)" },
]);

const theme = EditorView.theme({
  "&": { color: "var(--text)", backgroundColor: "var(--code-bg)", fontSize: "14px", height: "100%" },
  ".cm-content": { fontFamily: "var(--mono)", caretColor: "var(--accent)", padding: "12px 0" },
  ".cm-scroller": { fontFamily: "var(--mono)", lineHeight: "1.55" },
  ".cm-gutters": { backgroundColor: "var(--code-bg)", color: "var(--muted)", border: "none" },
  ".cm-activeLine": { backgroundColor: "var(--code-active)" },
  ".cm-activeLineGutter": { backgroundColor: "transparent", color: "var(--text)" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": { backgroundColor: "var(--code-selection) !important" },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor": { borderLeftColor: "var(--accent)" },
});

export interface HazeEditor {
  view: EditorView;
  get(): string;
  set(code: string): void;
  showRecords(records: Record_[]): void;
}

/** Turns Haze's messages into editor diagnostics, underlining the line each one points at. */
export function diagnostics(view: EditorView, records: Record_[]): Diagnostic[] {
  const doc = view.state.doc;
  return records.filter((r) => r.severity === "error" && r.line >= 1 && r.line <= doc.lines).map((r) => {
    const line = doc.line(r.line);
    const from = Math.min(line.from + Math.max(0, r.column - 1), line.to);
    return { from, to: line.to > from ? line.to : from, severity: "error", message: r.message } as Diagnostic;
  });
}

export function createEditor(parent: HTMLElement, code: string, opts: { onRun?: () => void; onChange?: () => void; readOnly?: boolean } = {}): HazeEditor {
  const readOnly = new Compartment();
  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc: code,
      extensions: [
        lineNumbers(), history(), drawSelection(), highlightActiveLine(), bracketMatching(), indentOnInput(),
        hazeLanguage, syntaxHighlighting(highlight), theme, lintGutter(), linter(null),
        keymap.of([
          { key: "Mod-Enter", run: () => { opts.onRun?.(); return true; } },
          { key: "Shift-Enter", run: () => { opts.onRun?.(); return true; } },
          indentWithTab, ...defaultKeymap, ...historyKeymap,
        ]),
        EditorView.updateListener.of((u) => { if (u.docChanged) opts.onChange?.(); }),
        readOnly.of(EditorState.readOnly.of(!!opts.readOnly)),
        EditorView.contentAttributes.of({ "aria-label": "Haze code editor" }),
      ],
    }),
  });
  return {
    view,
    get: () => view.state.doc.toString(),
    set(c) { view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: c } }); },
    showRecords(records) { view.dispatch(setDiagnostics(view.state, diagnostics(view, records))); },
  };
}
