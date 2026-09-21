# personal-assistant

A personal assistant agent for the DAM platform, serving exactly one person. It keeps their
task list, answers questions and drafts text in a direct message channel, and — when they
opt in — sends a weekday morning brief and a Monday review.

**The definition ships no identity.** Who the assistant is, how it speaks, and what it is
responsible for are decided by its owner during onboarding and stored in `work/`, never in
this repository. Two deployments of this same repo can be a terse task-keeper and a chatty
morning companion; nothing here is baked in, and nothing about one owner — name, member ID,
timezone, tasks — appears in the definition.

## How it works

- **Direct message (reactive)** — every inbound message is classified, acted on, answered
  once, and recorded in a ledger so a re-delivered message is never answered twice. What the
  owner may do from the channel is bounded by one setting, `dm_control`.
- **Morning brief** (weekdays, opt-in) — `scripts/preflight.sh brief` computes what is
  overdue, due today, coming up, and back from snooze; the agent writes and sends the
  message. Nothing due means a quiet run that costs one script invocation.
- **Weekly review** (Monday, opt-in) — `scripts/preflight.sh review` counts the week and
  finds stale tasks; the agent writes the review and runs the memory consolidation.
- **Weekly audit** (always) — `scripts/preflight.sh audit` runs the deterministic health
  checks (state shape, cadence gaps, error signatures, version drift, retention); the agent
  diagnoses, verifies the schedules exist, samples its own output, and reports traffic-light.

Scripts only ever **detect and compute** — they perform no messages and no external writes.
Every action is the agent's, driven by the worklist and re-checked at the moment of acting.
The definition is split so the always-loaded core stays small (`CLAUDE.md` = contracts and
invariants; `docs/` read on demand), and it is versioned: `VERSION` plus a `CHANGELOG.md`
whose entries are per-version upgrade steps for already-deployed instances.

## Setup

Created from the **starter kit** ([`kit.yaml`](kit.yaml)), the platform does all of this:
it asks for the connections, seeds this definition into the agent's home, registers the
three schedules (the two opt-in ones disabled), and starts the agent on the runbook. Set
`GITHUB_REPO_WORK` first if the state is to be backed up. By hand instead:

1. **Create the agent** on the DAM platform and grant it:
   - **Slack** (or **Telegram**) — the channel the owner talks to it in. Required.
   - **GitHub** — for the definition repo (self-update, PRs) and, optionally, the private
     state-backup repo. Required.
2. **Set the environment variables** — see the table below.
3. **Grab the link to [`ONBOARDING.md`](ONBOARDING.md)** — **from the repo (or fork) you
   actually deploy from**; the agent derives its definition repo from this URL, so a fork's
   agent stays pinned to the fork.
4. **Tell the agent**, in its first message:

   > Here is a file — read it and set yourself up according to it:
   > `https://github.com/<your-org>/personal-assistant/blob/main/ONBOARDING.md`

The agent reads the runbook and, in one pass, checks out its definition, wires up `work/`,
interviews the owner about its identity and duties, writes the configuration, registers the
schedules, and marks itself onboarded. The interview is the product here — it takes a few
minutes and it is what makes the assistant theirs.

## Configuration

### Environment variables

| Variable | Required | Description |
| --- | --- | --- |
| `GITHUB_REPO_WORK` | No | `<owner>/<repo>` of a **private** repo backing up `work/` after every state-changing run. Unset = the state lives on the volume only and **cannot be reconstructed** if the volume is lost — there is no external system mirroring it. |
| `DEF_HOST` | No | GitHub host of the definition repo when it is not `github.com`. |
| Any config key, upper-cased | No | Overrides the stored value for that run (`OWNER_MEMBER_ID`, `TIMEZONE`, …). The env var always wins; the stored copy exists because scheduled runs start a fresh shell. |

### `work/CONFIG.md` — instance configuration

Filled interactively at onboarding. Exact per-key semantics: [docs/config.md](docs/config.md).

| Key | Filled by | Purpose |
| --- | --- | --- |
| `display_name`, `owner_name` | asked | What to call the assistant, and how it addresses its owner. |
| `owner_channel`, `owner_member_id` | asked (ID pasted by the owner) | The one conversation partner. No message ever goes anywhere else. |
| `timezone`, `working_hours` | asked | Local dates for briefs, reviews and due dates; advisory hours. |
| `dm_control` | asked (`answers` / `tasks` / `full`) | How much the owner may do from the channel. Missing → `tasks`. |
| `channel_notifications`, `daily_brief`, `weekly_review` | asked, **opt-in** | Every message the agent starts by itself. Missing → off. |
| `audit_report` | defaulted `enabled` | Whether the weekly audit also goes to the channel (the chat UI always gets it). |
| `duty_tasks`, `duty_briefing`, `duty_answers`, `duty_drafting` | asked | The four shipped duty modules. Missing → off; a request for a disabled module is declined, never improvised. |
| `web_research` | defaulted `enabled` | May the answering duty read the open web when the harness offers a fetch tool. |
| `task_prefix` | defaulted `T` — **immutable once used** | Prefix of every task ID; changing it later orphans every row, note file, and past message. |
| `reminder_lead_days`, `stale_task_days` | defaulted `1` / `14` | How far ahead the brief looks; when the review calls a task stale. |
| `definition_repo` | derived | `[<host>/]<owner>/<repo>`, so a fresh scheduled shell can check versions and file issues. |
| `log_level` | defaulted `info` | Diagnostic verbosity; never gates behavior. |

## Runtime requirements

- **Platform:** the DAM agent infrastructure — `$HOME` at `/home/agent` on a persistent
  volume, the platform's outbound auth proxy for tokens, and the `mcp__platform-outbound__*`
  tools for schedules and channel messages.
- **Pod tooling:** `bash`, `git`, `gh`, `jq`, GNU `date`, `tar`. No `awk` (the scripts are
  awk-free by design).
- **Identity:** the agent acts as the account behind its token. The GitHub token needs
  `repo`-level access to its own definition repo (read, and write to open PRs) and to the
  private state-backup repo when one is configured — nothing else. It never needs access to
  anything the owner works on.
- **External surfaces:** one. The owner's direct message conversation, and — when
  configured — the private backup repository. The agent posts nothing publicly, sends mail
  to nobody, and writes to no third system; a draft it writes is handed back, never
  delivered.

## Privacy

This agent holds one person's tasks, notes, and preferences. Three rules are built into the
definition rather than left to good behavior: the owner's content never enters a log line
(logs carry IDs, counts, and intents), it never reaches the definition repo (the allowlist
`.gitignore` makes `git add` incapable of it), and the only two places it leaves the agent
are the owner's own channel and the private backup remote. The weekly audit checks the first
two; the third is the deployment's choice of repository.

## Persistence

`work/` is a plain data directory on the persistent volume — never a git repo, because the
shared NFS-backed volume corrupts a `.git` mutated by concurrent runs. With
`GITHUB_REPO_WORK` set, every state-changing run ends by snapshotting `work/` into a
disposable tmpfs clone and pushing it; live state stays on the volume, history lives in the
remote. Without it, the volume is the only copy.

The definition updates independently: `git fetch` + fast-forward (a hard reset only for a
diverged checkout), which never touches `work/`. Versions and migrations happen only in the
direct session; the weekly audit reports drift but never acts on it. Details:
[docs/persistence.md](docs/persistence.md).

## Files

- [`CLAUDE.md`](CLAUDE.md) — the slim core manual loaded on every run.
- [`AGENTS.md`](AGENTS.md) — harness entry pointer to `CLAUDE.md`; carries no rules.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup runbook: the interview, the `work/`
  seeds, the schedules, ending in `scripts/verify-onboarding.sh --live`.
- [`docs/`](docs/) — detailed procedures, read on demand.
- [`scripts/`](scripts/) — the pre-flight, the onboarding verification, the backup, logging,
  and the offline test suite.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — definition semver and per-version
  upgrade steps.
- [`kit.yaml`](kit.yaml) — the starter kit this definition is offered as: the connections
  it asks for, the schedules it creates, and the definition it seeds.
- [`LICENSE`](LICENSE) — Apache 2.0.
