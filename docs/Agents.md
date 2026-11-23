# Coding agents

Coding agents such as Claude Code, GitHub Copilot CLI, Codex and Cursor can write Haze models,
check them, and turn them into tests. `haze agent install` teaches them how, and keeps their work
in step with the models as they change the code. Run it once at the root of a repository:

```console
$ haze agent install
ok: wrote .claude/skills/haze-model/SKILL.md
ok: wrote .claude/skills/haze-check/SKILL.md
ok: wrote .claude/skills/haze-tests/SKILL.md
ok: added the Haze hooks to .claude/settings.json
```

Claude Code and GitHub Copilot CLI both read this layout. For Codex, OpenCode, Cursor and other
agents that read `AGENTS.md`, add `--agent agents-md`, or `--agent all` for both. Commit the files
so that everyone working on the repository, and every agent, gets them.

## Skills

A skill is a set of instructions an agent loads when a task calls for it.

| Skill | What it teaches |
|---|---|
| `haze-model` | When a model helps, how to write one from the code, the language on one page, and how to write a rate that's only roughly known. |
| `haze-check` | How to run Haze, read its JSON output, and report the result to you. |
| `haze-tests` | How to turn `#tests` output into tests of the real code, including the statistical test. |

The skills tell the agent to ask you for failure rates rather than invent them, to report a
rejected claim before changing anything, and never to weaken a requirement (a bound, a
possibility or a horizon) to make a check pass without your agreement.

## Linking code to models

A comment containing `haze:` and the path of a model links code to the model that describes it,
in any language:

```python
# haze: models/payments.hz#Client
MAX_ATTEMPTS = 3
```

The part after `#` is optional and only for readers. A path is relative to the repository root,
or to the file it's in. `haze agent links` lists the links, and `haze agent links --check` also
checks every linked model, which makes it a useful step in CI: it fails if a link points to a
missing file or a linked model has a rejected claim.

## Hooks

The hooks run `haze` at two points:

- **When a session starts**, the agent is told which models the repository has and how to use
  the skills, and is asked to offer a refresh if the installed skills are older than `haze`.
- **After the agent edits a file**: if the file is a model, Haze checks it and passes the result
  on, including the details of any rejected claim; if the file has a `haze:` link, the agent is
  reminded to check whether the change affects the model.

A hook adds a note to the agent's context and never blocks it. It exits successfully and prints
nothing when it has nothing to say, or when its input isn't what it expects. Checking a model
uses the default options; set `HAZE_HOOK_CHECK=0` to have the hook ask the agent to run Haze
instead, which is better for models that take long to check. Set `HAZE_HOOK_LOG` to a file name
to record each hook's input and output.

The hooks need `haze` on the `PATH` of the agent. GitHub Copilot CLI runs a repository's hooks
only in folders you trust.

## Managing the installation

```console
$ haze agent status                    # what is installed, and for which version of haze
$ haze agent install                   # again, after upgrading haze, to refresh the skills
$ haze agent install --no-hooks        # the skills only
$ haze agent uninstall --agent all     # remove everything haze agent install added
```

Installing twice leaves one copy of each hook. Other hooks and settings in
`.claude/settings.json`, and the rest of `AGENTS.md`, are kept as they are; uninstalling removes
only what `haze agent install` added.
