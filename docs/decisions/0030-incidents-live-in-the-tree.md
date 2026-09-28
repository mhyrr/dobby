# 30. An incident or gotcha goes into the tree, not only into a memory system

2026-09-28. Greg agreed with the note's pushback on `CLAUDE.md`'s last
line, which sent incidents to HIVE memory: "we need to save that in the
repository."

## Decision

When something bites, the durable record is in the repository, at the
place it bit: a test that fails the way the incident did, a comment at
the line that caused it saying what was observed, or a decision under
`docs/decisions/` when the incident changed one. A memory system may hold
the story as well; the tree holds the defence. `CLAUDE.md` still does not
accumulate gotchas, for the same reason as before: every line added to
the entry point is a line every session pays for.

## Why

Memory is per agent and per installation. The next agent to work here may
run somewhere the memory does not reach, and the household member who
opens the repository has no memory system at all. A gotcha that lives
only outside the tree protects only the sessions that happen to have it.
The repository already does this well where it does it: the coercion in
`Dobby.Tools.LightSetBrightness` says "because we have watched them do
it", and that sentence is worth more at that line than in any note.

## Rejected

- **HIVE memory as the store.** Where the rule stood until now. It is not
  wrong as a place to keep the narrative, and nothing here forbids writing
  there. It is wrong as the only place, for the reason above.
- **A gotchas section in `CLAUDE.md`.** The entry point stays short and
  doctrinal. A gotcha in it is a gotcha that should have been a test.
- **A `docs/incidents/` log.** A log is read by someone looking for it. A
  comment at the line and a test that fails are read by the person about
  to repeat the mistake, which is the only reader who matters.

## Where it lives

`CLAUDE.md`, Conventions. The practice is enforced by review and by the
habit this decision records; there is no mechanical check that an incident
became a test, and this section admits it.
