# 31. A decision is a file that carries the alternatives it rejected

2026-09-28. Greg: "this idea of an ADR that is a durable fact that we
save when a decision is made about the architecture, and the fact should
also save the alternatives that were rejected. A list of those feels like
a good thing to hold in the repository."

## Decision

Decisions about how Dobby is built are recorded one per file under
`docs/decisions/`, numbered on from the list in the design record's §13,
each with a Decision, Why, Rejected and Where-it-lives section. Code cites
them as `decision N`, as it already does for 1 to 28. The list in §13 is
closed at 28 and stays where it is.

## Why

Moduledocs in this repository already explain why and name the rejected
alternative, and §13 already does it at the level of the architecture.
What was missing was a place a new decision goes that is not a 1,700-line
design record, a shape that makes the rejected alternatives mandatory
rather than customary, and a check that the shape holds. The rejected
alternative is the highest-value sentence in the repository for whoever
writes the next change, because it is the change they were about to
propose.

## Rejected

- **Keep appending to §13.** It worked for 28 decisions and it would keep
  working, but the record is a document about the whole design, and a
  decision appended to its end is found only by someone who reads to the
  end. A directory listing is a table of contents for free.
- **Renumber from 1 in the new directory.** Every `decision 24` in a
  moduledoc would then be ambiguous. The numbers are load-bearing; the
  directory continues them.
- **Move 1 to 28 into files.** Twenty-eight files nobody asked for, every
  citation to re-check, and §13 turned into a stub. The design record is
  the record of the decisions made while it was being written; the
  directory is the record of the ones made since.
- **Moduledocs alone.** A moduledoc records a decision at the module it
  shaped, and stays. But a decision that shaped four modules gets four
  partial accounts and no whole one, and a decision that removed a module
  has no moduledoc left to live in.

## Where it lives

`docs/decisions/README.md` says how to write one. `test/dobby/decisions_test.exs`
fails when the numbering breaks, a section is missing, or the code cites a
decision that does not exist.
