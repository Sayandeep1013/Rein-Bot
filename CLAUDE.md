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

## Cost rule: free tier only

Every service in the design must have a genuinely free tier that supports the
stated usage, including test and CI environments. If a component has no free
option, say so plainly rather than quietly assuming a paid plan. Record the
actual quota numbers and the arithmetic showing the design fits inside them.

## Testing happens in the cloud

Test and preview environments run on hosted free tiers, not on the user's
machine. Do not add local database servers, local Docker daemons, or anything
that installs a background service on the laptop.
