# GuessTheAnime — Project Rules

## Hard boundary: this folder only

`D:\Projects\GuessTheAnime` is the entire world for this project. Treat everything
outside it as if it does not exist.

**Never, without an explicit new instruction from the user in the current turn:**

- Read, write, list, glob, or grep any path outside `D:\Projects\GuessTheAnime`.
- Write to the user's home directory, `%APPDATA%`, `%USERPROFILE%`, or any drive root.
- Touch global tool config: `~/.gitconfig`, `~/.npmrc`, `~/.aws`, `~/.ssh`,
  `~/.claude/settings.json`, Windows registry, or system environment variables.
- Install anything globally (`npm i -g`, `pip install --user`, winget, choco, scoop).
- Use a system temp directory. Temp files go in `.tmp/` inside this folder.

**All project config lives inside this folder**, never at a laptop-wide location:

| Purpose | Location |
| --- | --- |
| Claude Code permissions | `.claude/settings.json` |
| Secrets, API keys, tokens | `.env.local` (never committed) |
| Secret template | `.env.example` (committed, placeholder values only) |
| Tool configs (node, lint, format, CI) | project root or `config/` |
| Scratch / temp output | `.tmp/` |

If a task appears to require stepping outside this folder, stop and ask first.
State what you need and why. Do not step outside and report it afterwards.

## No code without approval

This project is in design phase. Produce documentation only. Do not scaffold a
project, create source files, install dependencies, or write implementation code
until the user explicitly approves moving to implementation.

## Documentation updates after every task (mandatory)

**Every completed task ends with a documentation update — no exceptions.** Before a
task may be reported as done:

1. **`doc/PROGRESS.md` must gain an entry**: what was done, how it was done
   (mechanism, not just outcome), what it changed in the live project/repo, and what
   became possible next. One dated entry per task batch.
2. **Any doc the task made stale must be corrected** in the same pass: decisions
   recorded where the decision lives (`DATA-MODEL`, `GAME-DESIGN`, `ARCHITECTURE`),
   blockers opened/closed in `doc/BLOCKERS.md`, new cross-references use `doc/…`
   paths.
3. If a task produced a reusable lesson (a tool, a bug class, a quota fact), it goes
   into the most relevant doc — not into chat history alone. Chat history is not
   documentation.

A task whose only deliverable was code or SQL, with untouched docs, is an incomplete
task. This rule exists because context that lives only in a conversation dies with
the conversation.

## Cost rule: free tier only

Every service in the design must have a genuinely free tier that supports the
stated usage, including test and CI environments. If a component has no free
option, say so plainly rather than quietly assuming a paid plan. Record the
actual quota numbers and the arithmetic showing the design fits inside them.

## Testing happens in the cloud

Test and preview environments run on hosted free tiers, not on the user's
machine. Do not add local database servers, local Docker daemons, or anything
that installs a background service on the laptop.
