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

A schema says what a field is. When to call, and what never to do, is said
once, in the doctrine; the same sentence in a tool description rides on every
request and can drift from the one that counts. The closed vocabularies the
model chooses from — record kinds, calendar periods, modes, units, operators —
are typed enums, so the exporter shows the choices and the validator refuses
the rest. Constants the file carries are set by code, not asked of the model:
an absence rule's event kind and action are fixed today, and two copied
strings are two more ways to get a rule wrong. One field per fact: `history`
takes `kinds` and not also `kind`; `propose_rule` takes a duration and its
unit and not also seconds. Measured on 2026-09-05, the seven tools were
6,084 bytes of JSON per request before this and 5,297 after, with `history`
and `propose_rule` still the two largest schemas in the house.

Blank is absent. The first eval run (2026-09-06, gpt-5.6-luna) sent every
property a schema named: `""` for since, until, actor, and the unused value
slots, `[]` for kinds, a weekday beside a period that takes none, and `false`
and `0` in the two value fields it did not mean. Each refusal was retryable,
the model sent the same shape again, and six of nine turns timed out or gave
up. So the tool layer drops blank fields before validation
(`Dobby.Tools.without_blanks/1`), `history` drops a weekday unless the period
is weekday, and `propose_rule` keeps the one value slot the device's declared
observable calls for. Validation still refuses what is actually wrong; what
it no longer refuses is absence spelled as filler. This is transport, and it
lives in the tool hooks, not in `Dobby.History` or `Dobby.Rules`.

The second run (14 of 22) showed the other shape of the same fault: fields a
model fills wrongly rather than emptily. `history`'s `action` came back as a
kind name (`device_changed`, `control`) or an invented verb (`heating`), each
matching no row, so a real record read as "nothing recorded"; the field is
no longer offered to the model. The next runs showed `actor` filled with the
speaker's own name on every call, so "who set the thermostat?" was answered
from the rows Greg wrote and nothing else, and it went the same way. Device,
kinds, and period answer the household's questions, and the rows carry their
actor and action for the reply to read. Both hooks also keep only the
schema's own fields, because Jido's validator lets an unknown key through and
the domain module would honour it. `propose_rule`'s
`unit` came back as "°F" for a thermostat number, which takes none; it is
dropped unless the observable is a reading. The three rule tools' `id` had
no doc, and the model tried a notice's own id first; the doc now names the
rule id, and `acknowledge_rule` accepts either, since both name one notice.
A zero duration is now spelled out in the `duration` doc, because "the moment
the door unlocks" came back as one second.

The house block now opens with the house clock — weekday, date, time, zone,
and UTC offset — rendered per turn beside the roster, not in the cacheable
system prompt. Without it the model answered "September 1st" with "which
year?", since it had no way to make an instant. And the doctrine now says
that every question about the past is answered by calling history, never
from the thread: with the conversation in its context the model sometimes
answered "did you record any refusals?" from what the thread showed, which
is not the record, and said zero over rows that existed.

With the clock in hand the model made "September 1st" into the right two
instants, then filled `period: weekday, weekday: 2` beside them, hit "not
both", and fanned out one failing call per device because nothing said a
device was optional. And "when did it last happen" arrived as `mode: latest`
with `period: today` filled beside it, which searched today instead of all
recorded history. So the hook lets the household's instants win over any
period, lets latest win over any period, and the `device` doc says to omit
it for the whole house. Every one of these is the same defect: a slot the
model fills beside the one it meant, and a validator that read the filler as
intent.

The last history miss was the opposite fault: narrowing on purpose. Asked
who set the thermostat, the model listed every kind but `control`, and the
card tap that was the answer fell outside its own filter. The fifteen kind
words now carry a clause of meaning each in the schema, and the doctrine
says not to narrow by kinds unless the household named a kind of event:
who set something, or when it last happened, means a hand on a card and a
schedule as much as a request in the thread.

`source` is provenance when the household said a sentence. A rule from the
form or from a file has none, and a made-up one is worse than an absence, so
the field is optional and blank is absent.

A rule with a window must have a duration shorter than the window. The watch
restarts at every window edge, so a longer duration is a rule that can never
fire while its agreed description says it will. Refused at load, where the
form, the tool, and the file all pass.

The two-turn replay keeps the same agent alive. Jido's ReActScript counts
assistant tool turns across retained history, so the second script includes
two consumed response slots before confirmation. The test asserts that only
`confirm_rule` executes on the second turn and that the agent PID is unchanged.

Unknown state and HA disconnection break continuous observation. A restart
starts a fresh duration; downtime is never evidence that a condition held.
The readings are reread from the device agents on reconnect rather than
waited for: the resync that follows a reconnect emits no state change for a
device that did not move, so a cache emptied at disconnect would stay empty
until the device physically changed, and a door left open across a blip
would never be noticed. Elapsed time still restarts at the reconnect.
An absence rule reports only absence in Dobby's record and begins its first
full interval when activated. It does not invent history before installation.

One notice per breach. A persistent breach stays visible until resolved or
acknowledged. Acknowledgment silences that occurrence, not the rule forever.
Pause is explicit and reversible. A recovered condition arms a new occurrence.
Persist occurrence and acknowledgment state so restart cannot repeat a notice.
Timer messages must not revive deleted, paused, or changed rules. The database
holds one standing occurrence per rule, and the watcher defers to it: when a
notice cannot be written because a row already stands — a second watcher on
the same database, or a crash between the commit and the in-memory put — the
watcher adopts that row rather than telling the household again. Any other
failure leaves the notice pending for the next tick and is logged once per
outage, not once per tick.

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

## Verification status — 2026-09-05, after review

The branch was reviewed on 2026-09-05 and three runtime defects were fixed:
a reconnect that blinded every state rule until the device moved, a duration
longer than its window that could never fire, and a memory/database split on
an occurrence that logged every tick and never told the household. The tool
schemas were rewritten so that each says what its fields are, the doctrine
says when, and the closed vocabularies are typed enums.

- `mix precommit`: compile with warnings as errors, unused deps, format, and
  623 tests with 0 failures, 44 eval tests excluded. The runtime suite now
  drives the production watcher through the house writer, and each new test
  was checked to go red on the regression it names.
- Browser, rig house, phone and desktop widths: the notice under the board
  with its acknowledge act, the standing-rule line in the thread, and the
  rules panel on `/house`. Console clean on both routes. The rule form was not
  driven in a browser, because the rig house is read only.
- The eval tier ran on 2026-09-06 against gpt-5.6-luna through OpenRouter,
  with Greg's authorisation: 22 scenarios, 7 for history and 15 for rules,
  22 of 22 on the final run after ten runs of reshaping the tools. The first
  run failed 6 of 9 without a single misjudgment by the model; every failure
  was a slot the model filled that a validator read as intent, a field the
  model could fill wrongly, or a fact the model did not have. The decisions
  above record each one. A history question costs two model turns and about
  5,600 input tokens; a rule proposal costs three, because the doctrine asks
  for `list_rules` first, and about 17,500.

Not done, and left as follow-ups: the notice sentence is templated
(`Front door: locked equals false`) rather than phrased per type; an absence
notice cites the watch start rather than the last recorded event, which the
record now holds; form-made rules take a UUID id where a slug from the name
would read better in the file.
