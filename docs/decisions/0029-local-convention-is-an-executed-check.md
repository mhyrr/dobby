# 29. A local convention is an executed check, not a sentence in CLAUDE.md

2026-09-28. Greg, thinking about what a codebase owes the agents that now
write it: "what do you want to see so that you can do the right things in
the future?" The answer was `docs/design/agent-ergonomics.md`, and this is
its first consequence.

## Decision

A rule that is specific to this repository, the kind no training set
carries, is enforced by a test, a compiler error, or a script. `CLAUDE.md`
states the rule and points at the check; it does not stand in for one.
Three checks land with this decision: the layer boundary test, the
tool-and-action schema drift test, and the completed device-type
checklist in the library contract test.

## Why

An agent starts every session cold and reads by the token. Prose in the
entry point is read once and dropped when the context is summarised; a
failing test is read every time, and does not care what the agent
remembers. The three rules chosen first were each already written down
and already unenforced, and one of them had already been broken: the
brightness tool and the brightness action disagreed about whether zero is
a brightness, and nothing had noticed.

## Rejected

- **Keep the rules in `CLAUDE.md` and rely on review.** Review is a human
  reading a diff, which is the scarce resource this whole line of thinking
  exists to spend less of. The rule about layers was in the file for the
  entire life of the repository and the drift happened anyway.
- **`mix reach.check` as the enforcement.** It already sees a layer
  crossing, and it is advisory by design, because most of what it flags is
  a lead and not a verdict. The layer rule is a verdict. It gets a test that
  fails, and reach keeps its job of finding the next lead.
- **A generator that writes a device type's files.** Fewer places to touch
  was considered and lost: the compile-time tool list in `Dobby.DobbyAgent`
  cannot be computed, so the places are what they are. A checklist that is
  executed and names each missing piece costs less than a generator and
  never drifts from the tree it checks.

## Where it lives

`test/dobby/layer_boundary_test.exs`, `test/dobby/tools/schema_drift_test.exs`,
`test/dobby/device_agents/library_contract_test.exs`. The argument is
`docs/design/agent-ergonomics.md` §3 and §7.
