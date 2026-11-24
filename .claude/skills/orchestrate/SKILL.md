---
name: orchestrate
description: Run orchestrated PR work on this repo, with one agent per PR, acceptance criteria, independent review, behavioural verification and an evidence bundle. Use only after the maintainer has confirmed this session as orchestrator.
---

# Orchestrator workflow (homelab-scripts)

## Before you take this role: ask the maintainer

**No session acts as orchestrator unless the maintainer has said so in that session, in his own words.** Invoking `/orchestrate` counts. This workflow is how orchestrated PR work is run once he has asked for it. It is not a standing instruction to start.

- A request such as "run the environment checks", "continue", "pick up where we left off", or a pointer to a handoff does not start the workflow. Do the specific thing asked and stop.
- A handoff marked ACTIVE, a list of open tasks, or PRs waiting for review does not start it either. Another session may be running that work right now. The maintainer often has more than one session open on this repo.
- If the request could mean orchestrating, ask first: "Do you want me to take over as orchestrator for <the work>, or is another session handling it?" Wait for the answer.
- Until he says yes, do not dispatch agents, review or verify PRs, write acceptance criteria, push, open or edit PRs, or rewrite the handoff. Reading the repo and the handoff is fine.
- When he says yes, take the role in the records repo before dispatching anything. Run `git pull --ff-only`, then read line 1 of `homelab-scripts/handoff.md`. If it says ACTIVE with a session other than yours, stop and ask the maintainer, and do not replace it. ACTIVE with your own session URL means you already hold the role (a restart). If line 1 is missing, or is neither `IDLE` nor `ACTIVE: ...`, stop and ask the maintainer. Take the role only when it says IDLE or the maintainer names the session you are replacing. Then commit and push the new line 1 (`ACTIVE: <session URL>, since <date>`) before anything else. The commit changes line 1 only. If its push is rejected, run `git pull --rebase`. If it applies cleanly, push again. If it conflicts, another session wrote line 1: run `git rebase --abort`, discard your one-line commit (`git reset --hard origin/main` is safe here and only here, because the commit holds nothing but that line), re-read line 1, and stop and ask the maintainer if it is ACTIVE with another session. Never force-push the records repo.

## The role

There is one orchestrator per repository. This role covers homelab-scripts only. It is independent of the homelab-manager orchestrator's: holding one gives no role in the other, and each has its own handoff, criteria and evidence.

The main Claude session acts as **orchestrator**. It does not do PR work itself. Its job:
- write acceptance criteria for each PR or task
- dispatch one agent per PR or task
- run independent reviews and relay the findings
- run behavioural verification, one PR at a time
- assemble the evidence for each PR
- sequence merges
- bring decisions to the maintainer

The maintainer approves and merges. Agents never merge.

A PR is approval-ready only when every acceptance criterion is `pass` at the head SHA, with a recorded result and proof (section 6). Review findings being resolved is not enough. A `not run` row keeps the PR out of approval-ready until the maintainer accepts that row in the session. Use "ready with N not run" for as long as any row is `not run`, accepted or not, never "ready", and record each accepted row in the handoff with the date.

**Everything runs in this cloud box.** Agents, reviewers, and verifiers never use the maintainer's computer. `environment/setup.sh` in the records repo is the box's setup script. It installs homelab-manager's dependencies and the maintainer's personal instructions, and none of this repo's tools, so section 0 installs those.

## 0. Start of session
- **Base clone:** the session's checkout of this repo. A session with more than one repository starts in their parent directory, so do not rely on the working directory or on Docker already running. Find the checkout (`git rev-parse --show-toplevel`, or the directory that holds this skill's `.claude/`) and `cd` into it.
- `mkdir -p /home/claude/work`, then check the box: `nproc`, `free -g`, and `command -v shellcheck bats tmux fzf docker`. Install `shellcheck`, `bats`, `tmux` and `fzf` with the package manager if `command -v` finds them missing. The proof types the box can produce follow from this (section 2).
- **Docker** is needed for the `e2e` and `lab` proof types. When the homelab-manager checkout is attached, run `bash scripts/cloud/session-start.sh` from it: it starts Docker with a registry mirror, without which Docker Hub answers 429. When it is not attached and `pgrep -x dockerd` finds nothing, start Docker yourself with `nohup dockerd --registry-mirror=https://mirror.gcr.io > /home/claude/work/dockerd.log 2>&1 &`. Either way, wait up to 60 seconds for `docker info` to succeed. If it still fails, read the log (`/home/claude/work/dockerd.log` when you started it), mark the `e2e` and `lab` criteria `not run` naming Docker as the blocked tool, and tell the maintainer. Only the orchestrator starts Docker. Never have a harness or a check start its own daemon.
- The box runs as uid 0, and root ignores file modes, so the pve bats suite's permission fixtures pass without testing anything. Run that suite as an unprivileged user (for example `setpriv --reuid 65534 --regid 65534 --clear-groups bats ...`). The clone must be readable by that uid and the suite needs a writable `TMPDIR`.
- The memory rules in sections 4 and 5 assume a small box. Loosen them only if the box clearly has room.
- **Records clone:** a separate records repo holds the handoff, criteria and evidence (section 9). The environment variable `HLM_RECORDS_REPO` names it as `owner/name`. This repo's records are under `homelab-scripts/` in it. Use the session's checkout of it, or clone it to `/home/claude/work/records`. If the session cannot reach the repo and has a tool for adding a repository to the session, add it with push access. If the variable is unset or the repo is still unreachable, stop and ask the maintainer where records go before doing anything else.
- Fetch the working branches into the base clone, one at a time, because the git proxy allows 2 concurrent operations:
  `git -C <base> fetch --depth 200 origin "+refs/heads/<branch>:refs/remotes/origin/<branch>"`
- Make each per-agent clone locally, so it costs no proxy operation:
  ```bash
  git clone -q --no-hardlinks <base> /home/claude/work/<slug>
  cd /home/claude/work/<slug>
  git fetch -q <base> '+refs/remotes/origin/*:refs/remotes/origin/*'
  git remote set-url origin https://github.com/jaredglaser/homelab-scripts
  git checkout -B <branch> origin/<branch>
  mkdir -p /home/claude/work/<slug>-meta
  ```
- **Docker-heavy checks run one at a time:** the pve end-to-end check and the sshl lab, where the repo has them, each start containers, so no two run together (section 5). The orchestrator lets one agent use Docker at a time and tells that agent when to start. An owner asks and waits for the answer. A verifier never runs while an owner holds it.

## 1. Survey
- List the open PRs via REST (`repos/jaredglaser/homelab-scripts/pulls?state=open`), using whichever of `gh api` or the GitHub MCP tools the session has. GraphQL is unavailable in these sessions, so `gh pr view/checks/edit` fail.
- For each PR, collect:
  - base and head
  - mergeable state
  - CI check-runs
  - review threads
  - file list
  - stacking: the base branch is not `main`, or the PR contains another PR's commits
- Test-merge in a scratch clone, in the proposed order, to find conflicts.
- Note which open PRs edit the same shared file (`sshl/sshl-lib.sh`, `sshl/homelab.tmux.conf`, `CLAUDE.md`, a workflow): those must stack.
- Propose a merge order, and flag anything to defer or close.

## 2. Acceptance criteria (before any agent starts)
The orchestrator writes the criteria. The agent that will do the work does not write its own.

- **Per PR or task, 3 to 8 criteria**, each one observable from outside the code: what a user, operator, or CI run sees. "Refactor X" is not a criterion. "Running `<script>` with a missing config file prints the error and exits 1" is.
- **Each criterion gets an ID and a proof type**, chosen before the work starts:
  - `bats`: a named bats test that fails with the source change reverted (a `must-not-change` criterion is instead proved by its test passing on the head and on the base)
  - `e2e`: the pve end-to-end check, which must run against real Proxmox packages in a Debian container
  - `lab`: the sshl lab, which must use real SSH hosts in Docker and a konsole on a virtual display, with a screenshot per criterion
  - `ci`: a specific CI job and step, for things only CI can show
  - `run`: a command and its output (`shellcheck` on a script, a script run on a violating and a clean input)
- **Pick a proof type the box can produce.** `e2e` and `lab` need Docker running and their images and packages reachable (section 0). If one is unavailable, a CI job can stand in only if it installs the real package or starts the real hosts. A job that runs bats against stubs proves only `bats` criteria. Name the job and step in the Proof column.
- **The harness is the repo's existing one.** Take the pve check or the lab from the PR's head if it is there, as the Testing section of `CLAUDE.md` names it. If not, take it from `main`, or from the open PR or branch that carries it, and run it against the code at the PR's head: check out the PR's head, then bring in only the harness directory from the other ref, in the verifier's own clone. Record in the evidence which ref and commit the harness came from, next to the PR's head SHA. The verifier does not change the harness to get a pass. If the harness cannot run that PR's code unchanged, that is a finding for the orchestrator, and the criterion is `not run` until it is settled. Never write a new harness or stand-in to produce a proof: `not run` is for when no ref in the repo has a harness, or the real package or host is unreachable, and it names the missing script or host. A run that stubs `dpkg-query`, `ssh`, `nmap` or the package source is a `bats` result, whatever the criterion says. A PR that adds or changes a harness is reviewed as code. The orchestrator names the harness ref in the verifier's prompt.
- **Include what must not change.** At least one criterion per PR names existing behaviour the change sits next to and could break.
- **Sources, in order:** the linked issue, the PR body, the maintainer's request, then the diff. For an existing PR with no stated intent, derive the criteria from the diff and mark them `derived`.
- **Write them to** `/home/claude/work/pr-<N>-meta/criteria.md` and to `homelab-scripts/criteria/pr-<N>.md` in the records repo. A unit of work with no PR number yet gets a criteria file named after its branch.
- **Send the maintainer all criteria in one message at the start.** Agents start immediately on PRs whose criteria restate a stated intent. A PR with `derived` criteria, or one where the orchestrator had to choose between readings, waits for the maintainer's answer on that PR only.
- **Criteria change only through the orchestrator.** An agent that finds a criterion wrong or impossible raises it. A changed criterion is noted in the evidence table with the reason.

Format (placeholders show the form, they are not real criteria):

```
AC1 [bats] Running `<script>` with `<input>` prints `<message>` and exits `<code>`.
AC2 [lab] After `<action>`, the konsole shows `<result>`.
AC3 [bats, must-not-change] `<Existing behaviour next to the change>` still works as before.
```

## 3. Dispatch one agent per PR or task
- **Agent:** `pr-owner`, in the background. Its definition carries the shared brief, so the prompt does not repeat it.
- **Model tier:** pick one per PR and set it on the dispatch. The definition's default is the top tier.

  | Tier | Model and effort | Use for |
  |---|---|---|
  | Trivial | Sonnet, medium | Docs, copy, comments, a config example value |
  | Low | Sonnet, high | A contained fix or small feature in one script, with no installer, no code that runs as root, and no CI workflow change |
  | Higher | Opus, medium | Everything else: changes across several scripts, anything in a stack, a CI workflow change, an installer or anything that runs as root on a Proxmox node, any PR with an `e2e` or `lab` criterion |

  When unsure between two tiers, take the higher one. List each PR's tier in the criteria message (section 2) so the maintainer can change it. If an agent on a Sonnet tier stalls or its review finds serious problems twice, replace it with a fresh Opus agent rather than sending a third round.
- **Workspace:** each agent works in its own full clone at `/home/claude/work/pr-<N>`, with scratch files in `/home/claude/work/pr-<N>-meta/`. These are separate clones, not worktrees, so no agent can touch another's git state. `/tmp` is shared, so never use fixed `/tmp` paths: agents clobbered each other's PR bodies that way.
- **Prompt:** each agent's prompt gives what is specific to its PR:
  - the PR number, branch, base and clone path
  - the acceptance criteria, verbatim
  - scope
  - stacking and coordination with other PRs: who conflicts with whom, and the resolution plan
  - what to focus on when trying to break the change
- **Follow-up work** goes to new agents, each opening its own follow-up PR, each with its own criteria.
- **Dependent PRs go in linear stacks** so the maintainer can approve them all and merge bottom-up. A follow-up that edits the same files as an open PR stacks on top of it. Sibling PRs on one base get chained (A ← B ← C), not left side by side.
- **After a session restart,** earlier agents may not be resumable. Start a fresh owner agent with the full context: PR, branch, base, head, criteria, the findings to fix, and stack position.

## 4. Independent review (run by the orchestrator)
Per-PR agents cannot spawn subagents, and an author's review of its own PR is not independent, so the review is the orchestrator's. When an agent reports:
- **Every reviewer gets the acceptance criteria.** Its first job is to say, per criterion, whether the diff and its tests can satisfy it. Breaking the change comes second.
- **Large or non-trivial PR:**
  - the `pr-review-toolkit:code-reviewer` agent, plus `pr-review-toolkit:pr-test-analyzer` for test-heavy PRs. If the session does not have the toolkit, use `general-purpose` reviewers, one per angle: code, silent failures, shell pitfalls (quoting, errexit, unset variables), tests, comments, simplification.
  - at least two independent adversarial `general-purpose` reviewers that have not seen each other's output, each told to try to break the change with concrete scenarios
  - for test-only PRs, mutation testing that compares which mutations are caught on `main` against the PR
- **Small PR:** one review pass plus one adversarial pass.
- **Test changes get a mutation check.** A test must fail when the line it covers is removed. Stubs for external hosts and system tools (`ssh`, `nmap`, `dpkg-query`) are fine, as the Testing section of `CLAUDE.md` describes, but the script under test runs for real, and so does the tool a test names as its subject. The reviewer picks a sample of the new or changed tests, removes the covered line in a scratch copy of its own, and confirms the test fails on its own assertion, as section 5 describes.
- **Check the diff for traces of the machine it was written on** (section 5). Run `git fetch origin <base>`, then scan the added lines: `git diff origin/<base>...HEAD | grep -E '^\+[^+]' | grep -niE 'proxy|ca-bundle|\.crt|/home/claude|/root/|/tmp/|cloud|sandbox|429|claude\.ai/code'`. An error from git is not a clean result. Every hit is explained or removed. These two instruction files match the pattern themselves, so a PR that edits them expects those hits.
- **All reviewers are read-only.** They must not start Docker, the pve end-to-end check or the sshl lab, because the box runs out of memory when many agents run. They run `shellcheck`, `bash -n` and targeted bats files only, and the pve suite as section 0 says. They may edit only a scratch copy of their own, never a PR clone. Never print a whole log.
- **The orchestrator verifies findings itself** before passing them on (for example, by reproducing a claimed shell or tool behavior). It sends the valid ones back to the owning agent as one list, and keeps decisions that belong to the maintainer out of that list.
- **After a substantial round of fixes,** run one more adversarial pass on just the new commits. Repeat until a pass finds nothing serious.

Review reads the code. It does not count as proof for any criterion.

## 5. Behavioural verification (run by the orchestrator, one PR at a time)
This step runs the change. It starts for a PR once its review findings are resolved and CI is green.

- **One verifier at a time, and only while no other agent is running Docker.** The e2e check and the lab need the memory that parallel agents use up. Queue PRs bottom of each stack first.
- **The verifier is a fresh `general-purpose` agent.** It gets the PR number, the head SHA, the criteria, and the ref to take the harness from (section 2). It does not get the owner agent's report or the review findings, so it tests what was asked for, not what the author says was built.
- **It works in its own clone** at `/home/claude/work/verify-<N>`, checked out at the head SHA, and writes evidence to `/home/claude/work/pr-<N>-meta/evidence/`.
- **It never edits the PR.** It reports. Fixes go back to the owner agent.
- **It installs what the checks need,** and checks `docker info` first. If Docker is down it stops and reports, and the orchestrator restarts it as section 0 says.
- **A substitute is not verification.** When the real package, distro or host a criterion names cannot be reached, name the blocked host or tool and stop. Do not build a stand-in: no fake package, no stubbed repository, no local imitation of a Proxmox node or an SSH host. Record the criterion as `not run` with the blocked host.
- **Nothing about the machine the check ran on goes into the repo.** Proxy handling, sandbox paths and rate-limit fallbacks stay out of scripts, tests and READMEs. If a check needs the box to behave differently, record that box fact in the handoff's Notes or in `environment/` in the records repo, not in the PR.

**How each proof type is produced**
- `bats`: run the named test on the PR head with `bats --tap`, since the default formatter shows skips differently, and confirm its line starts `ok` with no `# skip`: a skipped test is not a pass. A `must-not-change` criterion is proved by its test passing on the head and on the base. If the test is new in the PR, run it against the base's source. For every other `bats` criterion, revert the source change in the scratch clone (keep the test) and confirm the test fails on its own assertion. For a new script a revert would delete the file, so disable the specific behaviour instead (comment out the line or return early) and leave the script present and passing `bash -n`. The failing block must show a failed command from the test body, not from `setup`, `teardown`, `command not found` or `No such file`. A test that passes both ways (outside `must-not-change`), or fails for another reason, proves nothing, and is reported as a failed criterion. The commands are in the Testing section of this repo's `CLAUDE.md`. Run the pve suite as section 0 says.
- `e2e`: run the pve end-to-end check against the PR's head, using the harness section 2 names, with its entry point and README. It installs real Proxmox packages into a Debian container and runs the PR's own script against them. Save the command, the trimmed output, and the installed package versions. Before recording `pass`, show in the saved output that the real thing was used: the installed package versions and the repository they came from. If a package host is unreachable, the substitute rule above applies. A CI job stands in only as section 2 says.
- `lab`: bring up the sshl lab against the PR's head, using the harness section 2 names, with its entry point and README: real SSH hosts in Docker and a konsole on a virtual display. Install what it needs on the box. Drive the criterion in the konsole and save one screenshot per criterion at the moment that shows the result, plus the relevant log lines. Before recording `pass`, show in the saved output that each host answered over ssh. If the lab cannot start in the box, the substitute rule above applies, and the check does not move to the maintainer's computer.
- `ci`: record the job, step, run URL, and the log lines that show it. For a criterion typed `e2e` or `lab`, open the workflow file at the PR's head and quote, in the Proof column, the line that installs the real package or starts the real hosts.
- `run`: record the command and its output, trimmed to the lines that matter. For a guard or a check, show it failing on a violating input and passing on a clean one. `shellcheck` and `bash -n` count here.

**Results**
- Each criterion ends as `pass`, `fail`, or `not run`, with a pointer to its proof. There is no "looks fine". A `not run` is not a pass.
- A `fail` goes to the owner agent with the evidence. After the fix, the verifier re-runs the failed criteria and every criterion that touches the files the fix changed, on the new head SHA.
- Anything the verifier notices outside the criteria (an error in the output, a broken neighbouring flow) is reported as an observation, with a screenshot where there is one, and the orchestrator decides whether it is in scope.
- Evidence is tied to a head SHA. A push after verification makes it stale. Re-run the criteria the new commits could affect, and say which were re-run.

## 6. Evidence bundle (one per PR)
The maintainer reviews the evidence, not a summary of it.

- **The PR body gets an Acceptance table**, written by the owner agent from the verifier's results:

```
## Acceptance (verified at <head SHA>)
| ID | Criterion | Proof | Result |
|---|---|---|---|
| AC1 | Running `<script>` with `<input>` prints `<message>`... | bats: `<file>.bats` "<test name>", fails with source reverted | pass |
| AC2 | After `<action>`, the konsole shows `<result>` | lab: evidence page, AC2 screenshot | pass |
| AC3 | `<Existing behaviour>` still works as before | bats: `<file>.bats` "<test name>", passes on head and on base | pass |
```

- **Screenshots, logs, and long output go in the records repo,** under `homelab-scripts/evidence/pr-<N>/<short head SHA>/`, with a `README.md` that has one heading per criterion and shows its screenshots and trimmed output. The box does not survive the session, so the records repo is the durable copy. The Proof column links to the criterion's heading there. The link opens only for people with access to the records repo.
- **`not run` and `fail` rows are never dropped.** They go at the top of that PR's entry in the wrap-up, with the reason and what would close them. A `not run` row keeps the PR out of approval-ready until the maintainer accepts it.
- **A PR with no table, or a table at a different SHA than the head, is not approval-ready.** The final sweep checks this.

## 7. Coordination
- When a base or stacked branch moves, tell the dependent agents to merge it in, bottom of the stack first. Never rebase.
- When something changes under another PR (a renamed function in a shared library script, a moved test helper, a changed config key), tell the affected agent so its conflict plan stays current.
- Tell the maintainer a PR is ready to approve only after its agent has finished pushing, because a push after verification makes the evidence stale. Say "ready with N not run" for as long as any row is `not run`, accepted or not.
- **Before the wrap-up,** do a final sweep of every open PR. Check the head SHA, that every check group has a success, that the branch is 0 behind its base, and that it is mergeable. Check that each PR body still matches its PR, and that its Acceptance table is at the head SHA.

## 8. Talking to the maintainer
- Send the acceptance criteria for every PR in one message at the start (section 2).
- Relay each agent report as a short summary: state, what changed, open risks, and questions with options plus a recommendation.
- Keep a running list of open questions and the merge order.
- Repo settings and the cloud environment's allowed domains cannot be changed from the session. Give the maintainer the steps instead.
- The maintainer reviews everything at once at the end. Get all PRs approval-ready, then send one wrap-up. For each PR the wrap-up leads with the criteria that are `fail` or `not run`, then links the evidence.
- Bring a decision with each option's concrete impact (what it changes, what it costs, what it locks in) and a recommendation.

## 9. Records (handoff, criteria, evidence)
Session records live in the records repo named by `HLM_RECORDS_REPO`, under `homelab-scripts/`, not in this repo. Only the session holding this repo's orchestrator role writes to `homelab-scripts/` and the shared files named below, and it writes to no other repo's records. Agents write to their meta folders and the orchestrator copies what belongs in the records.

Read the records repo's `README.md` first and follow it. It describes the layout, and `templates/` there holds the starting point for each file. The criteria template lists homelab-manager's proof types: use this repo's (`bats`, `e2e`, `lab`, `ci`, `run`).

```
homelab-scripts/handoff.md                        the current handoff
homelab-scripts/criteria/pr-<N>.md                acceptance criteria per PR
homelab-scripts/evidence/pr-<N>/<short SHA>/      README.md plus screenshots, logs and output
homelab-scripts/archive/<date>-<task>.md          finished handoffs
homelab-scripts/designs/                          design plans and the decisions made on them
```

- The first line of `homelab-scripts/handoff.md` is the status line: `ACTIVE: <session URL>, since <date>` or `IDLE`.
- Run `git pull --ff-only` before every write. Commit straight to the records repo's `main` and push. Commit before you push, and never leave records edits uncommitted across a pull. If a push is rejected, run `git pull --rebase` and push again. If the rebase conflicts on a file under `homelab-scripts/`, or line 1 of `homelab-scripts/handoff.md` is no longer yours afterwards, run `git rebase --abort`, stop, and tell the maintainer. Never use `reset --hard` in the records repo once you hold the role, and never force-push. If the pull shows that another session changed `homelab-scripts/handoff.md` while this one holds the role, stop and tell the maintainer. Another repo's records changing is expected and is not a reason to stop. A shared file (`README.md`, `templates/`, `environment/`) may be changed by either orchestrator: say so in the commit subject.
- Keep `handoff.md` current throughout, so a new session can resume without the old context. It carries the task, the merge order, each PR's tier, criteria and current results, open questions for the maintainer, and links to the evidence.
- At the wrap-up, copy `handoff.md` to `archive/`, then reset it from the template with the status line `IDLE`.
- Questions and findings go to the maintainer in the session first. For a decision, a follow-up or an environment problem that is still open when the session ends, open an issue in the records repo from its matching template and link it from `handoff.md`.
- Check `designs/` for a plan that covers the work before writing criteria for it.
- Never put secrets in the records.
