# Ralph for Codex

Ralph is a CLI workflow that runs a continuous Codex loop with rate limiting,
session tracking, and project templates. This repo provides the scripts and
templates to set up Ralph-enabled projects and monitor progress.

## Features

- Continuous Codex loop with call limits and session lifecycle tracking
- Project scaffolding that keeps Ralph files in `.ralph/`
- Task import from beads, GitHub issues, or PRD documents
- Optional tmux monitor plus JSON status/progress files
- Global CLI install to `~/.local/bin`

## Requirements

- OpenAI Codex CLI (`codex`)
- `jq`
- `git`
- `coreutils` for `timeout` (macOS: `gtimeout`)
- `tmux` (optional, for `--monitor`)

## Install

```
./install.sh
```

Make sure `~/.local/bin` is on your PATH.

## Quick start

New project:

```
ralph-setup my-project
cd my-project
ralph --monitor
```

Existing project:

```
cd your-project
ralph enable
ralph --monitor
```

## Commands

- `ralph`              Run the loop (see `ralph --help`)
- `ralph-monitor`      Live status/progress view
- `ralph-setup`        Create a new Ralph project
- `ralph-enable`       Add Ralph to an existing project (interactive)
- `ralph-enable-ci`    Non-interactive enable with task import
- `ralph-import`       Convert a PRD into Ralph files
- `ralph-migrate`      Migrate older Ralph layouts into `.ralph/`

## Project layout

Ralph-specific files live under `.ralph/`:

- `.ralph/PROMPT.md`         Project instructions
- `.ralph/fix_plan.md`       Prioritized tasks
- `.ralph/AGENT.md`          Agent guidance
- `.ralph/specs/`            Requirements and specs
- `.ralph/logs/`             Loop logs
- `.ralph/docs/generated/`   Generated docs
- `.ralph/status.json`       Current loop status
- `.ralph/progress.json`     Progress summary

## Configuration

Create a `.ralphrc` in your project root to override defaults. Common settings:

- `MAX_CALLS_PER_HOUR`
- `CODEX_TIMEOUT_MINUTES`
- `CODEX_OUTPUT_FORMAT`
- `CODEX_ALLOWED_TOOLS`
- `CODEX_SESSION_EXPIRY_HOURS`

## Troubleshooting

- tmux error: install `tmux` or drop `--monitor`.
- Missing deps: install `codex`, `jq`, `git`, and `coreutils`.
- Check status: run `ralph --status` in a Ralph project.
