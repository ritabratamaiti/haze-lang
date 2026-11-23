"""
Tests `haze agent`: installing skills, hooks and the AGENTS.md section, the hooks themselves, the
`haze:` links, and uninstalling, in a throwaway repository. Build Haze with `lake build` first,
then run it from any directory:

    python scripts/test_agent.py
"""
import json, os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HAZE = str(ROOT / ".lake" / "build" / "bin" / ("haze.exe" if os.name == "nt" else "haze"))
results = []

def context(out):
    """The context a hook's output adds, in either agent's format."""
    if not out.strip(): return ""
    j = json.loads(out)
    return j.get("additionalContext") or j.get("hookSpecificOutput", {}).get("additionalContext", "")

def check(ok, name):
    results.append((bool(ok), name))

def run(args, cwd, stdin="", env=None):
    e = dict(os.environ, **(env or {}))
    p = subprocess.run([HAZE, *args], cwd=cwd, input=stdin, capture_output=True, text=True, encoding="utf-8", env=e)
    return p.returncode, p.stdout, p.stderr

MODEL = """\
param loss : Num ~= {0.01: 1, 0.05: 0.5}
enum Phase = Sending | Done | GaveUp
system Client(max_attempts : Num) {
  var phase : Phase := Sending
  var attempts : Num := 0
  step {
    match phase {
      Sending => {
        attempts := attempts + 1
        if flip(loss) { if attempts >= max_attempts { phase := GaveUp } } else { phase := Done }
      }
      _ => skip
    }
  }
}
claim delivered : Client(3) |= eventually phase == Done with prob >= 0.99
"""

with tempfile.TemporaryDirectory() as d:
    repo = pathlib.Path(d)
    (repo / "models").mkdir()
    (repo / "models" / "retry.hz").write_text(MODEL, encoding="utf-8")
    (repo / "client.py").write_text("# haze: models/retry.hz#Client\ndef send():\n    pass\n", encoding="utf-8")
    (repo / "README.md").write_text("Link with `haze: models/<name>.hz`.\n", encoding="utf-8")
    (repo / ".claude").mkdir()
    theirs = {"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo theirs"}]}]},
              "model": "x"}
    (repo / ".claude" / "settings.json").write_text(json.dumps(theirs), encoding="utf-8")
    (repo / "AGENTS.md").write_text("# Our rules\n\nUse tabs.\n", encoding="utf-8")

    # install, twice
    code, out, err = run(["agent", "install", "--agent", "all"], repo)
    check(code == 0, "install exits 0")
    code, out, err = run(["agent", "install", "--agent", "all"], repo)
    check(code == 0, "a second install exits 0")
    for s in ["haze-model", "haze-check", "haze-tests"]:
        text = (repo / ".claude" / "skills" / s / "SKILL.md").read_text(encoding="utf-8")
        check(text.startswith("---\nname: " + s) and "{{HAZE_VERSION}}" not in text and "haze_version: " in text,
              f"skill {s} is installed with its version filled in")
    settings = json.loads((repo / ".claude" / "settings.json").read_text(encoding="utf-8"))
    post = settings["hooks"]["PostToolUse"]
    ours = [h for g in post for h in g["hooks"] if "haze agent hook" in h["command"]]
    check(len(ours) == 1, "a second install leaves exactly one Haze PostToolUse hook")
    check(any(h["command"] == "echo theirs" for g in post for h in g["hooks"]), "install keeps the user's own hooks")
    check(settings.get("model") == "x", "install keeps the user's other settings")
    check(len(settings["hooks"]["SessionStart"]) == 1, "a second install leaves one SessionStart hook")
    agents = (repo / "AGENTS.md").read_text(encoding="utf-8")
    check(agents.count("<!-- haze:begin") == 1 and agents.startswith("# Our rules"), "AGENTS.md keeps its content and gets one Haze section")

    code, out, err = run(["agent", "status"], repo)
    check(code == 0 and "skill haze-check: installed" in out and "hooks: installed" in out and "models: 1" in out,
          "status reports the installation")

    # hooks
    code, out, err = run(["agent", "hook", "session-start"], repo,
                         stdin=json.dumps({"session_id": "s", "transcript_path": "t.jsonl", "permission_mode": "default",
                                         "hook_event_name": "SessionStart", "source": "startup"}))
    j = json.loads(out) if out.strip() else {}
    ctx = j.get("hookSpecificOutput", {})
    check(code == 0 and ctx.get("hookEventName") == "SessionStart" and "models/retry.hz" in ctx.get("additionalContext", "")
          and "additionalContext" not in j, "session-start lists the models, in Claude Code's format for Claude Code")
    # Copilot CLI sends Claude Code's field names to Claude Code-style hooks, without transcript_path
    code, out, err = run(["agent", "hook", "session-start"], repo,
                         stdin=json.dumps({"hook_event_name": "SessionStart", "session_id": "s", "cwd": str(repo), "source": "new"}))
    j = json.loads(out) if out.strip() else {}
    check(code == 0 and "models/retry.hz" in j.get("additionalContext", ""),
          "session-start gives Copilot CLI a top-level additionalContext")

    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"tool_name": "Edit", "tool_input": {"file_path": str(repo / "client.py")}}))
    ctx = context(out)
    check(code == 0 and "client.py" in ctx and "models/retry.hz#Client" in ctx, "editing linked code points the agent to its model")

    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"toolName": "edit", "toolArgs": json.dumps({"path": "models/retry.hz"})}))
    ctx = context(out)
    check(code == 0 and "all accepted" in ctx, "editing a model checks it (Copilot-style input)")

    (repo / "models" / "retry.hz").write_text(MODEL.replace("0.99", "0.99999"), encoding="utf-8")
    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"tool_name": "Write", "tool_input": {"file_path": "models/retry.hz"}}))
    ctx = context(out)
    check(code == 0 and "1 error" in ctx and "claim delivered" in ctx and "bound fails" in ctx,
          "a rejected claim reaches the agent with its details")

    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"tool_name": "Write", "tool_input": {"file_path": "models/retry.hz"}}),
                         env={"HAZE_HOOK_CHECK": "0"})
    check(code == 0 and "Run `haze models/retry.hz`" in out, "HAZE_HOOK_CHECK=0 asks the agent to run Haze instead")

    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"toolName": "view", "toolArgs": {"path": str(repo / "client.py")}}))
    check(code == 0 and out == "", "reading a linked file isn't treated as an edit")
    code, out, err = run(["agent", "hook", "post-tool-use"], repo,
                         stdin=json.dumps({"toolName": "edit", "toolArgs": {"path": str(repo / "client.py")}}))
    j = json.loads(out) if out.strip() else {}
    check(code == 0 and j.get("additionalContext", "").startswith("You edited client.py"),
          "Copilot's edit tool triggers the hook, with a top-level additionalContext")
    patch = "*** Begin Patch\n*** Update File: " + str(repo / "client.py") + "\n@@\n+# x\n*** Add File: models/retry.hz\n*** End Patch\n"
    code, out, err = run(["agent", "hook", "post-tool-use"], repo, stdin=json.dumps({"toolName": "apply_patch", "toolArgs": patch}))
    ctx = context(out)
    check(code == 0 and "You edited client.py" in ctx and "Haze checked models/retry.hz" in ctx,
          "a patch that edits code and a model gets a note for each file")
    for bad in ["not json", "", json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}})]:
        code, out, err = run(["agent", "hook", "post-tool-use"], repo, stdin=bad)
        check(code == 0 and out == "", f"the hook stays silent and exits 0 on {bad[:20]!r}")
    code, out, err = run(["agent", "hook", "no-such-event"], repo)
    check(code == 0 and out == "", "an unknown hook event is silent")

    # links
    code, out, err = run(["agent", "links", "--check"], repo)
    check(code == 1 and "client.py:1: models/retry.hz#Client" in out and "1 error" in out,
          "links --check fails when a linked model has a rejected claim")
    check("README.md" not in out, "links ignore prose files")
    (repo / "models" / "retry.hz").write_text(MODEL, encoding="utf-8")
    code, out, err = run(["agent", "links", "--check"], repo)
    check(code == 0 and "all accepted" in out, "links --check passes when every linked model holds")
    (repo / "worker.go").write_text("// haze: models/missing.hz\n", encoding="utf-8")
    code, out, err = run(["agent", "links"], repo)
    check(code == 1 and "missing.hz (missing)" in out, "links reports a link to a missing model")

    code, out, err = run(["agent", "install", "--agent", "nope"], repo)
    check(code == 2, "an unknown agent is an error")

    # uninstall
    code, out, err = run(["agent", "uninstall", "--agent", "all"], repo)
    check(code == 0, "uninstall exits 0")
    check(not (repo / ".claude" / "skills" / "haze-model").exists(), "uninstall removes the skills")
    settings = json.loads((repo / ".claude" / "settings.json").read_text(encoding="utf-8"))
    check(settings == theirs, "uninstall leaves the user's settings exactly as they were")
    check((repo / "AGENTS.md").read_text(encoding="utf-8") == "# Our rules\n\nUse tabs.\n", "uninstall restores AGENTS.md")

passed = sum(ok for ok, _ in results)
for ok, name in results:
    print("PASS" if ok else "FAIL", name)
print(f"{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
