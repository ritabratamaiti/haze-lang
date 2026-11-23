/-
Copyright (c) 2026 Ritabrata Maiti. All rights reserved.
Released under the Functional Source License 1.1 (FSL-1.1-ALv2) as described in the file LICENSE.md.
Authors: Ritabrata Maiti
-/
import Lean.Data.Json
import Haze.Frontend

/-!
# Coding Agent Integration

`haze agent` teaches coding agents to use Haze. It installs three skills (writing a model,
checking it and reporting the result, and turning it into tests), hooks that keep an agent's work
in step with the models, and a section for `AGENTS.md`.

Code is linked to the model that describes it by a comment containing `haze: path/to/model.hz`,
in any language. When an agent edits a linked file, the `post-tool-use` hook reminds it to check
the model again; when it edits a model, the hook checks it and passes the result on.

Hooks reach the agent through `hookSpecificOutput.additionalContext`, the field that Claude
Code, and GitHub Copilot CLI with Claude Code hooks, add to the model's context. A hook never
fails: anything unexpected makes it print nothing and exit 0, so a missing or older `haze` can't
block the agent.

This module is used only by the command-line tool, not by the WebAssembly build.

## Main Definitions

* `Haze.Agent.main`: the `haze agent` subcommands.
-/

namespace Haze.Agent
open System (FilePath)

/-- Lean's JSON type, which `Haze.Json` (Haze's JSON output) would otherwise shadow. -/
abbrev LJ := Lean.Json

/-! ## Bundled files -/

/-- A skill, with the template of its `SKILL.md`. -/
structure Skill where
  name : String
  template : String

/-- The bundled skills. Their names are part of the install layout, so renaming one is breaking. -/
def skills : List Skill := [
  ⟨"haze-model", include_str "../agents/skills/haze-model/SKILL.md"⟩,
  ⟨"haze-check", include_str "../agents/skills/haze-check/SKILL.md"⟩,
  ⟨"haze-tests", include_str "../agents/skills/haze-tests/SKILL.md"⟩]

/-- The section added to `AGENTS.md`, for agents that read it instead of skills. -/
def agentsBlock : String := include_str "../agents/AGENTS-block.md"

/-- Fills in the version of Haze and normalizes line endings. -/
def render (version template : String) : String :=
  (template.replace "\r\n" "\n").replace "{{HAZE_VERSION}}" version

/-- The substring that identifies Haze's hook commands in a settings file. -/
def hookMarker : String := "haze agent hook"

/-- The hooks: the event, the tool matcher (if any) and the command. -/
def hookEntries : List (String × Option String × String) := [
  ("SessionStart", none, "haze agent hook session-start"),
  ("PostToolUse", some "Edit|Write|MultiEdit", "haze agent hook post-tool-use")]

def beginMark : String := "<!-- haze:begin (written by `haze agent install`; edit outside these markers) -->"
def endMark : String := "<!-- haze:end -->"

/-! ## Small helpers -/

def contains (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- Splits `s` at the first occurrence of `sep`. -/
def splitOnce (s sep : String) : Option (String × String) :=
  match s.splitOn sep with
  | a :: b :: rest => some (a, sep.intercalate (b :: rest))
  | _ => none

def trim (s : String) : String := s.trimAscii.toString

/-- A path for messages: relative to `root` when it's inside it, with forward slashes. -/
def display (root p : FilePath) : String :=
  let r := root.toString.replace "\\" "/"
  let s := p.toString.replace "\\" "/"
  let r := if r.endsWith "/" then r else r ++ "/"
  if s.startsWith r then (s.drop r.length).toString else s

/-- The value of `haze_version:` in a skill's front matter, if there is one. -/
def versionOf (content : String) : Option String :=
  (content.splitOn "\n").findSome? fun l =>
    let l := trim l
    if l.startsWith "haze_version:" then some (trim (l.drop "haze_version:".length).toString) else none

def readFile? (p : FilePath) : IO (Option String) := do
  match ← (IO.FS.readFile p).toBaseIO with
  | .ok s => return some s
  | .error _ => return none

/-! ## Walking a repository -/

/-- Directories that never hold code worth scanning. -/
def skipDirs : List String :=
  [".git", ".hg", ".svn", ".lake", "node_modules", "target", "dist", "build", "out", ".venv",
   "venv", "__pycache__", ".next", ".cache", ".claude", ".idea", ".vscode", "vendor"]

/--
The files under `root` that `keep` accepts, in sorted order. The walk stops after `limit`
directory entries, so a huge repository can't make a hook slow.
-/
def walkFiles (root : FilePath) (keep : FilePath → Bool) (limit : Nat := 20000) :
    IO (Array FilePath) := do
  let mut out := #[]
  let mut stack := #[root]
  let mut seen := 0
  while !stack.isEmpty do
    let dir := stack.back!
    stack := stack.pop
    let some entries := (← dir.readDir.toBaseIO).toOption | continue
    for e in entries do
      seen := seen + 1
      if seen > limit then return out.qsort (·.toString < ·.toString)
      if ← e.path.isDir then
        if !skipDirs.contains e.fileName then stack := stack.push e.path
      else if keep e.path then out := out.push e.path
  return out.qsort (·.toString < ·.toString)

def isModel (p : FilePath) : Bool := p.extension == some "hz"

/-- Source files that can carry `haze:` links. Prose files are left out, since they mention links. -/
def sourceExts : List String :=
  ["py", "rs", "go", "ts", "tsx", "js", "jsx", "mjs", "java", "kt", "scala", "cs", "c", "cc", "cpp",
   "h", "hpp", "rb", "swift", "php", "ex", "exs", "erl", "hs", "ml", "lean", "sql", "sh", "ps1",
   "lua", "dart", "zig", "clj", "fs", "tf", "yaml", "yml", "toml"]

def isSource (p : FilePath) : Bool := (p.extension.map (sourceExts.contains ·)).getD false

/-! ## Links from code to models -/

/--
The models that `content` links to, with the line of each link. A link is `haze:` followed by a
path that ends in `.hz`, optionally with `#Name` after it.
-/
def linksIn (content : String) : Array (Nat × String) := Id.run do
  let mut out := #[]
  let lines := content.splitOn "\n"
  for h : i in [0:lines.length] do
    let line := lines[i]
    let parts := line.splitOn "haze:"
    for part in parts.drop 1 do
      let tok := String.ofList ((trim part).toList.takeWhile fun c =>
        !c.isWhitespace && !"\"'`<>(),;".contains c)
      let tok := String.ofList (tok.toList.reverse.dropWhile (fun c => c == '.' || c == ':')).reverse
      let path := (tok.splitOn "#").headD tok
      if path.endsWith ".hz" then out := out.push (i + 1, tok)
  return out

/-- Every link in the source files under `root`: the file, the line and the target. -/
def allLinks (root : FilePath) : IO (Array (FilePath × Nat × String)) := do
  let mut out := #[]
  for f in ← walkFiles root isSource do
    let some content ← readFile? f | continue
    if !contains content "haze:" then continue
    for (line, target) in linksIn content do out := out.push (f, line, target)
  return out

/-- The file a link points to: relative to the repository root, or to the linking file. -/
def resolveLink (root file : FilePath) (target : String) : IO (Option FilePath) := do
  let path := (target.splitOn "#").headD target
  for cand in [root / path, (file.parent.getD root) / path] do
    if ← cand.pathExists then return some cand
  return none

/-! ## Checking a model -/

/-- The outcome of checking a model: the number of errors, claims and theorems, and the errors. -/
structure CheckSummary where
  errors : Nat
  claims : Nat
  problems : Array String

/-- Checks a model with the default options. -/
def checkModel (path : FilePath) (shown : String) : IO (Option CheckSummary) := do
  let some src ← readFile? path | return none
  let st := Haze.Frontend.runState shown src {}
  let mut claims := 0
  let mut problems := #[]
  for msg in st.out do
    let lines := (msg.splitOn "\n").toArray
    let head := lines[0]!
    if contains head ": claim " || contains head ": theorem " then claims := claims + 1
    if contains head ": error: " then
      problems := problems.push ("\n".intercalate (lines.toList.take 4))
  return some { errors := st.errors, claims, problems }

/-! ## Hooks -/

/-- Appends a line to the file named by `HAZE_HOOK_LOG`, if it is set, for debugging hooks. -/
def logHook (line : String) : IO Unit := do
  let some p ← IO.getEnv "HAZE_HOOK_LOG" | return
  try
    let h ← IO.FS.Handle.mk p .append
    h.putStrLn line
  catch _ => pure ()

/-- Reads all of standard input. -/
def readStdin : IO String := do
  let stdin ← IO.getStdin
  let mut acc := ""
  for _ in [0:1000000] do
    let l ← stdin.getLine
    if l.isEmpty then break
    acc := acc ++ l
  logHook s!"input: {acc.trimAscii}"
  return acc

/--
Which agent ran a hook. Claude Code's input always has `transcript_path` and `permission_mode`.
Copilot CLI sends Claude Code's field names to hooks configured with Claude Code's event names,
but not those two fields.
-/
inductive Caller where
  | claude | other

def callerOf (input : Option LJ) : Caller :=
  match input with
  | some j =>
    if ["transcript_path", "permission_mode", "tool_response"].any (fun k => (j.getObjVal? k).toOption.isSome)
    then .claude else .other
  | none => .other

/--
Prints the hook output that adds `text` to the agent's context. Claude Code reads
`hookSpecificOutput.additionalContext`, and Copilot CLI a top-level `additionalContext`; other
callers get both.
-/
def emitContext (caller : Caller) (event text : String) : IO Unit := do
  let claude := ("hookSpecificOutput", Lean.Json.mkObj [("hookEventName", .str event), ("additionalContext", .str text)])
  let copilot := ("additionalContext", Lean.Json.str text)
  let out := (Lean.Json.mkObj (match caller with
    | .claude => [claude] | .other => [copilot, claude])).compress
  logHook s!"output: {out}"
  IO.println out

/-- Tools that change files, as Claude Code and Copilot CLI name them. Other tools are ignored. -/
def editTools : List String :=
  ["edit", "write", "multiedit", "notebookedit", "create", "str_replace", "str_replace_editor",
   "apply_patch", "insert"]

/-- Whether a hook input is about a tool that changes files. Without a tool name, it is assumed to be. -/
def isEdit (input : LJ) : Bool :=
  match ["tool_name", "toolName"].findSome? fun k => (input.getObjVal? k >>= Lean.Json.getStr?).toOption with
  | some n => editTools.contains n.toLower
  | none => true

/-- The files named in a patch (`*** Update File: …`, `*** Add File: …`, `*** Move to: …`). -/
def patchPaths (patch : String) : List String :=
  (patch.splitOn "\n").filterMap fun l =>
    let l := trim l
    ["*** Update File:", "*** Add File:", "*** Move to:"].findSome? fun pre =>
      if l.startsWith pre then some (trim (l.drop pre.length).toString) else none

/--
The files a tool call edited, from Claude Code's or Copilot's hook input. The arguments may be an
object with a path, a JSON string of one, or a patch.
-/
def editedPaths (input : LJ) : List String :=
  let fromObj := fun (o : LJ) =>
    (["file_path", "path", "filePath"].findSome? fun k => (o.getObjVal? k >>= Lean.Json.getStr?).toOption).toList
  let args := ["tool_input", "toolArgs", "toolInput"].findSome? fun k => (input.getObjVal? k).toOption
  let found := match args with
    | some (.str s) =>
      match Lean.Json.parse s with
      | .ok o => fromObj o
      | .error _ => patchPaths s
    | some o =>
      match fromObj o with
      | [] => match o.getObjVal? "input" >>= Lean.Json.getStr? with
        | .ok s => patchPaths s
        | .error _ => []
      | ps => ps
    | none => []
  found.eraseDups

/-- What the post-tool-use hook says about one edited file, if anything. -/
def noteFor (root : FilePath) (p : String) : IO (Option String) := do
  let path : FilePath := if (p : FilePath).isAbsolute then p else root / p
  let shown := display root path
  if isModel path then
    if (← IO.getEnv "HAZE_HOOK_CHECK") == some "0" then
      return some s!"You edited the Haze model {shown}. Run `haze {shown}` and report the result (see the haze-check skill)."
    let some r ← checkModel path shown | return none
    if r.errors == 0 then
      return some s!"Haze checked {shown}: {r.claims} claim(s) and theorem(s), all accepted."
    let shownProblems := r.problems.toList.take 8
    let more := if r.problems.size > 8 then s!"\n… and {r.problems.size - 8} more" else ""
    return some (s!"Haze checked {shown} and found {r.errors} error(s). Report them to the user before changing any bound, rate or claim (see the haze-check skill):\n" ++
      "\n".intercalate shownProblems ++ more)
  if isSource path then
    let some content ← readFile? path | return none
    let links := linksIn content
    if links.isEmpty then return none
    let targets := (links.map (·.2)).toList.eraseDups
    return some (s!"You edited {shown}, which a `haze:` comment links to {", ".intercalate targets}. " ++
      "If the change affects what the model describes (failure handling, retries, timeouts, states or rates), " ++
      "update the model and run `haze` on it, then report the result to the user (see the haze-check skill).")
  return none

def hookPostToolUse (root : FilePath) : IO Unit := do
  let some input := (Lean.Json.parse (← readStdin)).toOption | return
  if !isEdit input then return
  let mut notes := #[]
  for p in editedPaths input do
    if let some n ← noteFor root p then notes := notes.push n
  if !notes.isEmpty then emitContext (callerOf (some input)) "PostToolUse" ("\n\n".intercalate notes.toList)

def hookSessionStart (root : FilePath) (version : String) : IO Unit := do
  let caller := callerOf (Lean.Json.parse (← readStdin)).toOption
  let models ← walkFiles root isModel
  let mut stale := #[]
  for s in skills do
    let some content ← readFile? (root / ".claude" / "skills" / s.name / "SKILL.md") | continue
    if versionOf content != some version then stale := stale.push s.name
  if models.isEmpty && stale.isEmpty then return
  let mut parts := #[]
  if !models.isEmpty then
    let names := (models.toList.take 10).map (display root ·)
    let more := if models.size > 10 then s!" and {models.size - 10} more" else ""
    parts := parts.push (s!"This repository has {models.size} Haze model(s): {", ".intercalate names}{more}. " ++
      "Code that a model describes carries a `haze:` comment. When you change such code, check the model again " ++
      "and report the result (haze-check skill); write new models with the haze-model skill, and tests from them with haze-tests.")
  if !stale.isEmpty then
    parts := parts.push s!"The installed Haze skills ({", ".intercalate stale.toList}) don't match Haze {version}. Offer the user to refresh them with `haze agent install`."
  emitContext caller "SessionStart" (" ".intercalate parts.toList)

/-! ## Settings files -/

def isOurs (h : LJ) : Bool :=
  match h.getObjVal? "command" >>= Lean.Json.getStr? with
  | .ok c => contains c hookMarker
  | .error _ => false

/-- Removes Haze's hooks from a list of hook groups, dropping groups that become empty. -/
def removeOurs (groups : Array LJ) : Array LJ :=
  groups.filterMap fun g =>
    match g.getObjVal? "hooks" >>= Lean.Json.getArr? with
    | .ok hs =>
      let kept := hs.filter (!isOurs ·)
      if kept.isEmpty then none
      else if kept.size == hs.size then some g
      else some (g.setObjVal! "hooks" (Lean.Json.arr kept))
    | .error _ => some g

def eraseKey : LJ → String → LJ
  | .obj kvs, k => .obj (kvs.erase k)
  | j, _ => j

def isEmptyObj : LJ → Bool
  | .obj kvs => kvs.isEmpty
  | _ => false

/-- Adds Haze's hooks to a settings object, replacing any earlier ones. Other hooks are kept. -/
def withHooks (settings : LJ) : LJ :=
  let hooks := (settings.getObjVal? "hooks").toOption.getD (Lean.Json.mkObj [])
  let hooks := hookEntries.foldl (init := hooks) fun hk (ev, matcher, cmd) =>
    let groups := removeOurs ((hk.getObjVal? ev >>= Lean.Json.getArr?).toOption.getD #[])
    let entry := Lean.Json.mkObj ((match matcher with | some m => [("matcher", Lean.Json.str m)] | none => []) ++
      [("hooks", Lean.Json.arr #[Lean.Json.mkObj [("type", .str "command"), ("command", .str cmd)]])])
    hk.setObjVal! ev (Lean.Json.arr (groups.push entry))
  settings.setObjVal! "hooks" hooks

/-- Removes Haze's hooks from a settings object. Other hooks are kept. -/
def withoutHooks (settings : LJ) : LJ := Id.run do
  let some hooks := (settings.getObjVal? "hooks").toOption | return settings
  let mut hk := hooks
  for (ev, _, _) in hookEntries do
    let some groups := (hk.getObjVal? ev >>= Lean.Json.getArr?).toOption | continue
    let kept := removeOurs groups
    hk := if kept.isEmpty then eraseKey hk ev else hk.setObjVal! ev (Lean.Json.arr kept)
  return if isEmptyObj hk then eraseKey settings "hooks" else settings.setObjVal! "hooks" hk

/-- Reads a settings file, or an empty object if there is none. -/
def readSettings (p : FilePath) : IO (Except String LJ) := do
  let some text ← readFile? p | return .ok (Lean.Json.mkObj [])
  if (trim text).isEmpty then return .ok (Lean.Json.mkObj [])
  match Lean.Json.parse text with
  | .ok j@(.obj _) => return .ok j
  | .ok _ => return .error s!"{p} is not a JSON object"
  | .error e => return .error s!"can't parse {p}: {e}"

/-! ## AGENTS.md -/

/-- `content` with Haze's section replaced by `block`, or removed when `block` is empty. -/
def withBlock (content block : String) : String :=
  let sect := if block.isEmpty then "" else s!"{beginMark}\n{block.trimAscii.toString}\n{endMark}\n"
  match splitOnce content "<!-- haze:begin" with
  | some (before, rest) =>
    let after := match splitOnce rest endMark with
      | some (_, a) => (a.dropWhile (· == '\n')).toString
      | none => ""
    if sect.isEmpty then before.trimAsciiEnd.toString ++ (if after.isEmpty then "\n" else "\n\n" ++ after)
    else before ++ sect ++ (if after.isEmpty then "" else "\n" ++ after)
  | none =>
    if sect.isEmpty then content
    else if (trim content).isEmpty then sect
    else content.trimAsciiEnd.toString ++ "\n\n" ++ sect

/-! ## Commands -/

def usage : String :=
  "usage: haze agent install [--agent claude|agents-md|all] [--no-hooks]\n" ++
  "       haze agent uninstall [--agent claude|agents-md|all]\n" ++
  "       haze agent status\n" ++
  "       haze agent links [--check]\n" ++
  "       haze agent hook session-start|post-tool-use\n" ++
  "Teaches coding agents to use Haze, in the current directory (the repository root).\n" ++
  "  --agent claude     skills in .claude/skills and hooks in .claude/settings.json, read by\n" ++
  "                     Claude Code and GitHub Copilot CLI (the default)\n" ++
  "  --agent agents-md  a Haze section in AGENTS.md, read by Codex, OpenCode, Cursor and others\n" ++
  "  --no-hooks         install the skills without the hooks\n" ++
  "  links              list the `haze:` links from code to models; --check also checks the models"

def writeFile (root p : FilePath) (content : String) : IO Unit := do
  if let some d := p.parent then IO.FS.createDirAll d
  IO.FS.writeFile p content
  IO.println s!"ok: wrote {display root p}"

def install (root : FilePath) (version : String) (claude agentsMd hooks : Bool) : IO UInt32 := do
  if claude then
    for s in skills do
      writeFile root (root / ".claude" / "skills" / s.name / "SKILL.md") (render version s.template)
    if hooks then
      let p := root / ".claude" / "settings.json"
      match ← readSettings p with
      | .error e => IO.eprintln s!"haze: {e}; fix it or install with --no-hooks"; return 2
      | .ok j =>
        IO.FS.createDirAll (root / ".claude")
        IO.FS.writeFile p ((withHooks j).pretty ++ "\n")
        IO.println s!"ok: added the Haze hooks to {display root p}"
  if agentsMd then
    let p := root / "AGENTS.md"
    let content := (← readFile? p).getD ""
    IO.FS.writeFile p (withBlock content (render version agentsBlock))
    IO.println s!"ok: wrote the Haze section of {display root p}"
  return 0

def uninstall (root : FilePath) (claude agentsMd : Bool) : IO UInt32 := do
  if claude then
    for s in skills do
      let d := root / ".claude" / "skills" / s.name
      if ← d.pathExists then
        IO.FS.removeDirAll d
        IO.println s!"ok: removed {display root d}"
    let p := root / ".claude" / "settings.json"
    if ← p.pathExists then
      match ← readSettings p with
      | .error e => IO.eprintln s!"haze: {e}"; return 2
      | .ok j =>
        let j' := withoutHooks j
        if j'.compress != j.compress then
          IO.FS.writeFile p (j'.pretty ++ "\n")
          IO.println s!"ok: removed the Haze hooks from {display root p}"
  if agentsMd then
    let p := root / "AGENTS.md"
    if let some content ← readFile? p then
      if contains content "<!-- haze:begin" then
        IO.FS.writeFile p (withBlock content "")
        IO.println s!"ok: removed the Haze section of {display root p}"
  return 0

def status (root : FilePath) (version : String) : IO UInt32 := do
  IO.println s!"haze {version}"
  for s in skills do
    let p := root / ".claude" / "skills" / s.name / "SKILL.md"
    let line := match ← readFile? p with
      | none => "not installed"
      | some c => match versionOf c with
        | some v => if v == version then "installed" else s!"installed for haze {v}; run `haze agent install` to refresh"
        | none => "installed (unknown version)"
    IO.println s!"skill {s.name}: {line}"
  let settings := (← readFile? (root / ".claude" / "settings.json")).getD ""
  IO.println s!"hooks: {if contains settings hookMarker then "installed" else "not installed"}"
  let agents := (← readFile? (root / "AGENTS.md")).getD ""
  IO.println s!"AGENTS.md section: {if contains agents "<!-- haze:begin" then "present" else "absent"}"
  let models ← walkFiles root isModel
  IO.println s!"models: {models.size}"
  return 0

def links (root : FilePath) (check : Bool) : IO UInt32 := do
  let found ← allLinks root
  if found.isEmpty then
    IO.println "no `haze:` links found"
    return 0
  let mut bad := 0
  let mut targets : Array FilePath := #[]
  for (f, line, target) in found do
    match ← resolveLink root f target with
    | some t =>
      IO.println s!"{display root f}:{line}: {target}"
      if !targets.contains t then targets := targets.push t
    | none =>
      IO.println s!"{display root f}:{line}: {target} (missing)"
      bad := bad + 1
  if check then
    for t in targets do
      let shown := display root t
      match ← checkModel t shown with
      | none => IO.println s!"{shown}: can't be read"; bad := bad + 1
      | some r =>
        if r.errors == 0 then IO.println s!"{shown}: {r.claims} claim(s) and theorem(s), all accepted"
        else
          IO.println s!"{shown}: {r.errors} error(s)"
          for p in r.problems do IO.println s!"  {p.replace "\n" "\n  "}"
          bad := bad + 1
  return if bad == 0 then 0 else 1

/-- Parses `--agent` for install and uninstall: whether to use the Claude layout and `AGENTS.md`. -/
def parseAgent (args : List String) : Except String (Bool × Bool × Bool) := do
  let mut claude := true
  let mut agentsMd := false
  let mut hooks := true
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--agent" :: a :: tl =>
      match a with
      | "claude" | "claude-code" | "copilot" => claude := true; agentsMd := false
      | "agents-md" | "codex" | "opencode" | "cursor" => claude := false; agentsMd := true
      | "all" => claude := true; agentsMd := true
      | _ => throw s!"unknown agent {a} (expected claude, agents-md or all)"
      rest := tl
    | "--no-hooks" :: tl => hooks := false; rest := tl
    | a :: _ => throw s!"unknown option {a}"
    | [] => pure ()
  return (claude, agentsMd, hooks)

/-- `haze agent …`. Hooks always exit 0; the other commands exit 2 on bad arguments. -/
def main (args : List String) (version : String) : IO UInt32 := do
  let root ← IO.currentDir
  match args with
  | ["hook", "post-tool-use"] =>
    try hookPostToolUse root catch _ => pure ()
    return 0
  | ["hook", "session-start"] =>
    try hookSessionStart root version catch _ => pure ()
    return 0
  | "hook" :: _ => return 0
  | "install" :: rest =>
    match parseAgent rest with
    | .ok (c, a, h) => install root version c a h
    | .error e => IO.eprintln s!"haze agent: {e}\n{usage}"; return 2
  | "uninstall" :: rest =>
    match parseAgent rest with
    | .ok (c, a, _) => uninstall root c a
    | .error e => IO.eprintln s!"haze agent: {e}\n{usage}"; return 2
  | ["status"] => status root version
  | ["links"] => links root false
  | ["links", "--check"] => links root true
  | ["-h"] | ["--help"] | [] => IO.println usage; return 0
  | _ => IO.eprintln usage; return 2

end Haze.Agent
