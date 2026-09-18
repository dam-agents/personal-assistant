# Conversations — handling an inbound message

Read this file for every inbound channel message. The trust rules it applies live in
`CLAUDE.md` → **Instruction sources & trust boundary**; this file is the procedure.

## Per message

1. **Read `work/PERSONA.md`** — it decides voice, length, language, and formatting — and
   `work/DUTIES.md` for what this owner asked to be responsible for.
2. **Identify the sender** from the platform's message metadata. Not `owner_member_id`
   (or no ID available) → answer briefly and helpfully, do nothing else, surface the
   message to the owner in the chat UI, record it as `intent=other action=declined`. Stop.
3. **Check the ledger** — `work/INBOX.log` already carries this message ID → do not reply
   again. Stop.
4. **Classify the intent** (below) and check it against `dm_control` and the duty keys. Out
   of bounds → one line saying so and what would enable it; record `action=declined`.
5. **Act**, then **reply once**, then **record** — a ledger line as the very next action
   after the reply ([logging.md](logging.md) → **`work/INBOX.log`**). Send first and record second:
   a message is repeatable but not recallable, so a lost reply that the next sweep repeats
   beats a ledger claiming a reply nobody got. Task writes invert it — the row lands before
   the confirmation ([tasks.md](tasks.md) → **Operations**).
6. **Persist** `work/` when anything changed (`CLAUDE.md` → **Run procedures**).

## Intents

| Intent | Needs | Procedure |
| --- | --- | --- |
| `task_add`, `task_update`, `task_list` | `duty_tasks`, `dm_control: tasks`\|`full` | [tasks.md](tasks.md) |
| `question` | `duty_answers` | Answer from memory, state files, and — when `web_research: enabled` and a fetch tool exists — the web. Name what you read; never claim a source you could not open. |
| `draft` | `duty_drafting` | Write it in the persona's voice, hand it back in the reply, keep nothing. A draft is never sent anywhere by the agent. |
| `memory` | `dm_control: tasks`\|`full` | [preferences.md](preferences.md) |
| `config`, `persona`, `duties`, `schedule`, `definition` | `dm_control: full` | **Changes with lasting effect** below |
| `other` | — | Answer if you can; say plainly when you cannot. Never improvise a duty that is disabled ([duties.md](duties.md)). |

A message can carry several intents; handle each in order, then send **one** reply covering
all of them.

## Changes with lasting effect

Persona, duties, configuration, schedules, and the definition change how the agent behaves
from then on. At `dm_control: full` the owner may request all of them in the channel; the
procedure is the same there and in the direct session:

1. **Restate the change** — the exact key, file section, or schedule, with old value → new
   value. An ambiguous request is clarified before anything is written, never guessed.
2. **Apply it**, then **read it back and ask for an explicit confirmation** in the same
   conversation. Write-before-send: a confirmation for a change that did not land is the
   worse failure. A "no" at this point is a second change — undo it the same way.
3. **Log it** — `logev info config_change "<key> <old> -> <new>"` (values only; never the
   surrounding message). Persona and duty edits log the section name, not the text.
4. **Refuse and explain** for `task_prefix` after the first task exists ([config.md](config.md)).

Per target:

- **Configuration** — [config.md](config.md). One key per request.
- **Persona / duties** — [preferences.md](preferences.md). The owner's seed text is theirs;
  replace what they point at, never rewrite the rest.
- **Schedules** — `mcp__platform-outbound__list_schedules` first; create, toggle, or delete
  one schedule per request, keeping the `personal-assistant-<runtype>-<cadence>` naming and
  the task text of `ONBOARDING.md` Step 4. Turning a proactive run *off* is normally a
  config key, not a schedule deletion — offer that first; it keeps the run able to come back
  without a re-registration.
- **Definition** — [self-modification.md](self-modification.md) first, then
  [persistence.md](persistence.md) → **Evolving the agent definition**: branch, commit, PR.
  The agent's job ends at "PR opened"; say so in the reply, with the link.

## Replies

- One reply per inbound message, in the persona's voice and language, as short as the
  content allows. No signature unless the persona asks for one; the channel already says who
  is speaking.
- Say what you did in the words the owner used — "added T-0042", not "row appended".
- **Errors are honest**: a failed write or send is reported in the reply and in the chat UI,
  never silently retried into duplicates. The next scheduled run retries what it can.
- Never echo back the owner's whole message, and never quote one conversation in another.
