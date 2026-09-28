# Decisions

One file per decision about how Dobby is built, written when the decision
is made, carrying the alternatives it rejected. The numbering continues the
list in `docs/design/dobby-design-jido.md` §13: decisions 1 to 28 live
there and are not moved, because moduledocs cite them by number
(`decision 24`) and the number is the contract. Decision 29 onward is a
file here, cited the same way.

A decision here is a durable fact, not a discussion. Read the code for
what is true and the decision for why, and for what would have been true
had the other road been taken. That second half is the point of the file:
the rejected alternative is exactly the change the next reader would
otherwise propose, and the cheapest way to stop a good idea being re-had
is to record why it lost.

## Writing one

`NNNN-a-few-words.md`, the next number, four digits. The title is the
decision as a sentence. The first line under it is the date and, where
somebody in the house asked for it, who and what they said, in the voice
§13 already uses. Then four sections, always these, always in this order:

```
## Decision
What is now true. Short. Present tense.

## Why
The pressure that made it true, and the evidence if there was any.

## Rejected
Each alternative that was seriously considered, and why it lost. This
section is never empty: a decision with nothing rejected was not a
decision.

## Where it lives
The test, check, script or module that enforces it, or that would fail
if it were undone. A decision enforced by nothing is a wish, and this
section is where that is admitted.
```

To change a decision, write a new one that names the one it supersedes,
and add one line under the old one's title: `Superseded by decision N.`
Decision 27 in §13 is the model: it relaxes 23 on purpose, says who asked,
and names the instrument that would bring the old rule back.

`test/dobby/decisions_test.exs` holds the shape: the numbering is
contiguous from 29, every file has the four sections, and every
`decision N` the code cites exists.
