# Standing rules and household history — TK-025 / TK-027

Implementation branch: `tk-025-027-house-memory`.

## Decisions for review

The model interprets a request. Code validates conditions, resolves dates,
queries the record, measures elapsed time, and decides whether to speak.
No inference runs on a timer or device event. Rules only report; they never
command a device. Hands-only devices remain readable by rules.

History reads Dobby's activity record, including command refusals and missing
echoes. It does not claim HA recorder coverage. A missing row means no recorded
event, not proof nothing happened. Tool results distinguish commands from
observations. Counts cover the entire requested window even when returned rows
are capped. Duration queries must disclose unknown coverage rather than turn
an unobserved interval into a measurement.

Time uses the house timezone. Calendar phrases are a closed vocabulary resolved
by code: today, yesterday, this week, last week, last night, and named weekdays.
Explicit instants carry offsets. Ambiguous or nonexistent local instants are
refused. Query intervals are half-open. No guessed meaning for “bedtime”.

Rules have two shapes: a device predicate held for a duration, or no matching
recorded device event for a duration. Optional local daily windows and weekdays
limit when they watch. A window crossing midnight belongs to its starting day.
State predicates use observables declared by each device type, not arbitrary
snapshot keys. Comparisons are closed and type checked.

Absence means no matching recorded state transition of the watched attribute.
A vacuum battery update cannot count as the start of cleaning. Environmental
absence rules are refused because grouped readings do not supply that evidence.
Environmental state rules require a bound reading and an explicit unit.
Each rule has one device and one predicate. Compound conditions and calendar
deadlines require clarification; the model must not silently split them.

Tool inputs carry separate number, boolean, and state fields. Exactly one is
required. This avoids a generic value schema that the tool exporter describes
as a string. The model extracts a duration and its unit; code converts to seconds.
Numeric thresholds use NimbleOptions `:float` with integer normalization before
validation. Its JSON schema is `number`; NimbleOptions itself rejects `:number`.
Regression tests exercise both schema export and runtime validation.

The two-turn replay keeps the same agent alive. Jido's ReActScript counts
assistant tool turns across retained history, so the second script includes
two consumed response slots before confirmation. The test asserts that only
`confirm_rule` executes on the second turn and that the agent PID is unchanged.

Unknown state and HA disconnection break continuous observation. A restart
starts a fresh duration; downtime is never evidence that a condition held.
An absence rule reports only absence in Dobby's record and begins its first
full interval when activated. It does not invent history before installation.

One notice per breach. A persistent breach stays visible until resolved or
acknowledged. Acknowledgment silences that occurrence, not the rule forever.
Pause is explicit and reversible. A recovered condition arms a new occurrence.
Persist occurrence and acknowledgment state so restart cannot repeat a notice.
Timer messages must not revive deleted, paused, or changed rules.

The canonical definitions live under `house.rules` in home.yaml. Every edit
uses HomeConfig.Writer. Rule-only edits apply live without restarting the
conversation. Proposals live in Postgres, expire, and must be confirmed in a
later household turn before they watch. The deterministic description returned
by the proposal tool is the contract; keep the original sentence as provenance.
File and form authors already express their intent directly.
MCP retains its existing token-as-household authority: confirmation is a separate
tool call, but does not require a conversation turn. The later-turn check applies
to the household conversation.

The thread records breaches in plain deterministic household sentences. The
board lists standing notices without inventing a ninth flap word or overloading
HELD. Forms and tools share validation. Rules can be listed, paused, resumed,
acknowledged, and deleted without an LLM.

## Test coverage authored

Pure tests cover predicate types, duration boundaries, windows crossing
midnight, weekdays, DST, unknown state, and occurrence transitions. Database
tests cover history filters/counts/caps, proposal expiry and confirmation,
occurrence persistence, and acknowledgment. Rig tests drive real device signals
through the Fake boundary, author rules through tools, and observe one thread
notice with no model call or HA command. Tests cover restart, disconnection,
pause/resume, edits, removal, duplicate delivery, and more than one browser.
Eval scenarios cover interpretation, clarification, no premature confirmation,
unsupported requests, temporal language, and honest answers from the record.
Paid evals are authored but not run: HIVE's hard limit forbids spending money.

Ship in green layers: history; rule definitions and persistence; runtime and
surfaces; end-to-end scenarios, evals, and the household guide. No push or deploy
is part of this branch work.

## Verification status — 2026-09-05

Implementation is present on the branch, but the tickets remain open.

- After the reported fixture/schema failures were corrected, 37 isolated tests
  passed across rule validation, configuration round trips, engine transitions,
  numeric tool validation, watch windows, and history time windows. The isolated
  run loaded the installed timezone data without starting the application.
  Test compilation emitted stale-BEAM export warnings for HomeConfig; full Mix
  compilation remains the authority for warnings and integration.
- An isolated compiler check compiled 41 changed backend modules without warnings.
  It started no application and does not replace a full application check.
- `git diff --check` passes. Elixir source formatting ran without the Mix plugins.
- `mix precommit` fails before compilation because Mix cannot open its local
  PubSub TCP socket (`:eperm`), including when requested outside the sandbox.
- Greg reran the tests locally and reported all passing after the fixture,
  numeric schema, and retained-history replay corrections. This is user-reported
  verification; the agent's own full Mix run remains blocked. Browser checks
  and paid evals have not run. No server or browser was started by the agent.

The migration generator hit the same Mix failure. The migration was scaffolded
manually; the local database tests exercise it through the test alias. Greg
authorized committing after reporting passing tests. No push or deploy has
occurred. Concurrent release, changelog-policy, and README edits were preserved.

Before release, inspect the rules form and notices in the browser and retain
the full `mix precommit` output from an environment where Mix can start. Do not
run `mix test --include eval` under the current no-spend rule.
