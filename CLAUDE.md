# Project Guidelines for Claude

## Project Overview

Bash scripts for running a homelab. Each script lives in its own subdirectory with its own README, tests and supporting files.

The user's desktop is KDE, so scripts that open a terminal default to `konsole`.

## Structure Convention

```
<script-name>/
  <script-name> or <script-name>.sh   # main executable
  README.md                            # for the person running it: install, use, recover
  config.example                       # only for a script with user config, whose real copy is gitignored
  *.conf, *.sh                         # supporting files
  tests/                               # bats suite, run from the repo root, with its own README.md
```

## Rules

1. **Never commit machine-specific or sensitive files**: Anything with IPs, credentials, local paths, or runtime-generated state belongs in `.gitignore`. The committed version is always a `.example` template. When adding a new script, identify its equivalents upfront and gitignore them before the first commit.
2. **Scope discipline**: When asked to plan, research, or review, produce only that deliverable. Do not start executing unless explicitly asked.
3. **Commit scope**: Only commit files relevant to the current task.
4. **Verify the way a user meets the change**: Before calling a change done, run its bats suite, then run the changed path for real: for sshl, in the lab under Testing, looking at the screenshots. If a check needs a tool, a version or an environment this machine lacks, install or build it on a disposable VM. "Not verified" is only for what no machine you can reach could test, and the report says why. Report what you ran and what you saw. A finding from a subagent or another session counts once you have reproduced it.
5. **READMEs are for the person running the script**: what it does, how to install, use and recover it, and what its messages mean. Test mechanics, version-check evidence and implementation reasons go in `tests/README.md` or a code comment. Keep a README change to the words a user needs, and give a word budget to any agent that edits one.
6. **No claudisms in written output**: Applies to code, comments, commit messages, and docs. Banned: em dashes, en dashes, `--` as a dash substitute, vocabulary tells ("leverage", "utilize", "delve", "robust", "comprehensive", "meticulous", "facilitate", "it's worth noting"), performative qualifiers ("carefully", "thoroughly"), boilerplate sign-offs. Use plain alternatives.
7. **Document automation in rollback steps**: When a script re-applies state via apt/dpkg hooks, cron, systemd timers, or file watchers, its README's recovery/rollback section must include the step to disable that automation. Otherwise restoring from a backup gets undone on the next trigger.

## Comments

Write comments that capture project-specific WHY: non-obvious constraints, workarounds for specific behavior, invariants a reader would otherwise reverse-engineer. Don't restate what the code obviously does.

Good example (from sshl):
```bash
# Nuke the whole server, not just the base session. kill-session -t =homelab
# leaves any grouped sessions (open konsoles) running with stale windows.
```

Bad example:
```bash
# Loop through all IPs
for ip in "${ips[@]}"; do
```

## Error Handling

Scripts fail loudly with actionable messages: say what happened, what the script did about it, and what the user should do next, then exit non-zero. The missing-config branch near the top of `sshl/sshl-lib.sh` is the reference.

Use `>&2` for all error and status output. Check dependencies (sshl's `require()`) before doing real work.

## Testing

Run each suite from the repo root. Its `tests/README.md` says how it stays away from real hosts, real config and real system files.

- `bats sshl/tests/`, then `sshl/tests/lab/lab.sh up` for real SSH hosts and a konsole on a disposable VM. Use the lab for any change a user sees on screen or that talks to hosts.
- `bats pve-zfs-large-block-patch/tests/`, then `pve-zfs-large-block-patch/tests/e2e/run.sh` for a change to the install or apt hook path. It runs the README's one-liner against a pushed branch on a stand-in node.

Before adding tests to other scripts, consider blast radius: scripts that could cause real damage (data loss, network changes, service disruption) are higher priority than easily-recovered ones.
