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

The rotation to glm-5.2 (2026-09-06, the same 22 scenarios) passed 21 of 22
on the first run, and the miss was the doctrine's, not a tool's: "tell me if
the door stays unlocked for an hour" in a house with two locks was proposed
for the front door. The general rule — a name that fits two devices is a
question — sits eight paragraphs above the rule paragraph, and a model reading
the rule paragraph for what to do did not carry it down. The rule paragraph
now says it itself, and the rerun asked which door in one turn, without
listing the rules first. No tool hook changed for this model. The other shape
the run showed was the deterministic boundary doing its work: told "yes, I'm
sure, go ahead" in the same breath as the request, the model called
`confirm_rule` in the turn that proposed, the later-turn guard refused, and
the reply relayed the refusal and showed the rule. The claim that a rule
nobody agreed to in a later message cannot watch held with no help from the
doctrine, at the price of one extra turn. Across the 21 scenarios both models
passed, the tool sequences were identical in 20; glm-5.2's tokenizer counts
the same prompt about a third higher (8,135 against 5,968 input tokens per
model turn), end-to-end time was the same within a second on average, and its
replies carry the speaker's name and a clause more.

The house block was blind, and the survey for the child-agent question found
it. `RequestTransformer.transform_request/4` read the world model from its
second argument, which jido_ai fills with the run's own `%ReAct.State{}`; the
agent's state, where `ObserveDevice` writes the world model, arrives as the
fourth. So every device rendered "state not yet known" on every real turn
since the first commit, and the model paid a `*_get_status` turn to learn
what the block was meant to say: both models did so before proposing the
humidity rule, and the redundant status round trip TK-032 measured at about
4,700 tokens was the same fault. Nothing crashed, and no replay scenario
looked at the messages the runner built, which is why it lasted. Fixed, with
a scenario that substitutes a per-request transformer to capture the block
the model is actually sent, on the first turn and on the second turn of a
request that ran a tool between them.

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
- The same 22 ran against z-ai/glm-5.2 on 2026-09-06: 21 of 22 on the first
  run, and the miss was the door in a house with two locks, proposed for the
  front door. One doctrine sentence, pinned in `SoulTest`, and the rerun asked
  which door in one turn. No tool hook changed. Per model turn GLM counts
  8,135 input tokens where Luna counts 5,968 for the same prompt; end-to-end
  time was the same within a second on average; the tool sequences were
  identical in 20 of 21 shared scenarios, the exception being the same-breath
  `confirm_rule` the later-turn guard refused. The eval report now prints a
  per-step line: which seconds were the model's and which the tools'.
- The house block carried no device state before this branch, on any turn,
  for any model. Fixed here with `Dobby.Scenarios.HouseBlockTest`, which
  fails against the old transformer. The eval numbers above were measured
  with the blind block; a proposal that opened with a status read should
  now be one turn shorter, and every turn carries about 245 tokens more of
  state. Not re-measured against a paid model.

Not done, and left as follow-ups: the notice sentence is templated
(`Front door: locked equals false`) rather than phrased per type; an absence
notice cites the watch start rather than the last recorded event, which the
record now holds; form-made rules take a UUID id where a slug from the name
would read better in the file.

## Design: should the record and the rules be a child agent?

Status: open for Greg's decision, tracked as TK-050. Design mode, not
implementation. Measured
on 2026-09-06 in the rig house (18 devices, 49 tools, no rules) with the
branch as committed; tokens are o200k counts of the exact bytes, and the
provider's own count is given where a run reported it.

### What every turn carries

| Part | Bytes | Tokens | Rides on | Cacheable |
|---|---|---|---|---|
| soul.md | 1,447 | 339 | every turn | yes, byte-identical |
| doctrine, 11 paragraphs about devices, schedules, adoption, honesty | 4,339 | 1,014 | every turn | yes |
| doctrine, 2 paragraphs about the record and the rules | 2,104 | 469 | every turn | yes |
| house block, clock and roster, with state | 2,546 | 691 | every turn | no, it changes |
| tool schemas, 35 device tools | 10,128 | 2,173 | every turn | yes |
| tool schemas, 7 record and rule tools | 5,247 | 1,160 | every turn | yes |
| tool schemas, 4 schedule tools | 1,876 | 431 | every turn | yes |
| tool schemas, 3 adoption tools | 2,232 | 472 | every turn | yes |
| `list_rules` result, zero rules, vocabulary for 18 devices | 2,648 | 624 | the rest of the window | no |
| `history` result, zero rows | 517 | 138 | the rest of the window | no |

Two corrections to the table from the provider's own count. Luna's first turn
with no tool result was 5,522 tokens; the text parts above account for 2,300
of it, so the provider serialises the 49 schemas at about 3,200 tokens, three
quarters of the raw JSON count, which puts the seven record and rule schemas
near 880 tokens on the wire. And the house block the model has been sent is
the blind one, 446 tokens, because of the defect fixed on this branch (below);
the 691 figure is what it carries now.

So the record and the rules ride on every turn at about 1,350 tokens: 469 of
doctrine and roughly 880 of schemas, a quarter of a 5,600-token turn. That is
the whole of what a child agent could take off a turn about the lights.

### Where the seconds go

Timed with no model in the loop: `list_rules` runs in 12 ms and `history` in
7 ms. Timed with one, on the single stepped run so far: the model turn was
2,614 ms of a 2,691 ms request. Tool execution is noise. Every second is a
model turn, and the turn count is the multiplier: a history question is two
turns (extract, then speak), a rule proposal three because the doctrine asks
for `list_rules` first, propose then confirm five across two household
messages. The eval report now prints the per-step line, and the ten normal-turn
scenarios run on GLM 5.3 Flash, latency-sorted, showed the same shape: every
tool in 1 to 4 ms, "set the thermostat to 70" at 4.1 s as two model turns
of about 2 s each, a terse "72" at 2.7 s, and the tail entirely the model
thinking, 14.8 s and 18.7 s for one turn each at low effort. Against the
August line on main (first token 0.69 to 0.85 s per turn) the first token of
turn one now lands near 2.0 s; the prompt is 38 percent larger per turn, and
one run cannot split that gap between prompt size, routing, and load.

The same ten then ran on main, minutes later, on the same model and routing,
to put a number on what this branch added. Tokens: 1,970 more per model turn
on Flash's count, 5,900 to 7,865 in the rig house and 2,850 to 4,830 in the
two-thermostat house, since it is a constant added to whatever the house
already carries; roughly the seven schemas at half or more, the two doctrine
paragraphs at a third, the clock and the block's state for the rest. Turns:
none. Seconds: not attributable, because main ran slower with the smaller
prompt, 3.2 s to the first token of turn one against 2.0 s, 19.6 s for "set
to 70" against 4.4 s, one request that timed out and two that ended with no
Home Assistant call, where the branch passed all seven. The endpoint's
variance within one hour is larger than anything two thousand tokens of
prefill could carry, so the record and the rules made a normal turn a third
more expensive and, on the evidence, no slower. The speed levers that remain
are the provider under the model and the reasoning tail, both settings in
the house file, not the agent's shape.

| Request | Turns | Luna input tokens | GLM 5.2 input tokens | Luna ms | GLM ms |
|---|---|---|---|---|---|
| history question | 2 | 11,300 | 15,800 | 3,600 to 6,200 | 1,900 to 11,400 |
| rule proposal | 3 | 18,250 | 24,100 | 7,200 to 9,800 | 3,400 to 8,000 |
| propose, then confirm in a later message | 5 | 31,400 | 40,700 | 4,000 | 2,200 |
| pause, delete, or acknowledge by name | 3 | 18,300 | 24,100 | 4,400 to 5,400 | 2,100 to 2,800 |

Three findings from the runs that matter more than the schema bytes.

The house block was blind. `RequestTransformer.transform_request/4` read the
world model from jido_ai's per-run `%ReAct.State{}`, which has no such key;
the agent's own state, where `ObserveDevice` writes it, arrives as the fourth
argument (`deps/jido_ai/lib/jido_ai/reasoning/react/runner.ex`,
`maybe_transform_request/4`; the payload is built in
`reasoning/react/strategy.ex` under `worker_start_payload`). Every device has
rendered as "state not yet known" on every real turn, and the model has paid a
`*_get_status` turn to learn what the block was meant to say: both models did
so before proposing the humidity rule, and TK-032's redundant status round
trip, measured at about 4,700 tokens, is the same fault. Fixed on this branch
with a regression test that captures the block the model is actually sent.

The `list_rules` turn is the single largest avoidable cost, and it exists
because the observables vocabulary lives only in that tool's result. Rendering
it in the house block, the way `can be scheduled to:` already renders the
schedulable surface, costs 297 tokens per turn for 18 devices; a line naming
the standing rules and notices costs about 21 plus 10 per rule. That is the
price of a two-turn proposal instead of three, and of a two-turn pause or
delete.

Tool results stay in the conversation. The window is 40 projected messages
and tool traffic counts, so a `list_rules` payload of 624 tokens and every
`history` row set ride on every following turn until they fall out. The evals
restart the house per scenario and never see this; a live house does, and
nobody has measured it, because production records no per-request usage.
Cached input is likewise unmeasured: ReqLLM normalises `cached_tokens` and
the runtime's `:llm_completed` event carries it, but jido_ai's telemetry
measurements drop it, so the eval's `Trace` cannot see it.

### What Jido 2.3 offers

Child agents are first class: `%SpawnAgent{}` with parent tracking and
`emit_to_parent/3` (`deps/jido/lib/jido/agent/directive.ex`), and the ReAct
strategy already runs its loop in exactly such a child, a `Worker.Agent` per
DobbyAgent. A tool whose `run/2` starts a second agent and awaits `ask_sync`
ships as `Jido.AI.Actions.Reasoning.RunStrategy`; it runs six processes below
the parent's server, cannot block the parent's mailbox, and is bounded by the
tool timeout of 15 s by default. Tool results are JSON with no size cap. Per
request, `:tools` on ask resolves once and is frozen for the run; the only
seam that can change the tool set between iterations of one request is the
request transformer, which may override `:tools` and sees the model's last
message. Tool schemas are rebuilt and sent on every iteration. There is no
agent-as-tool helper, no conditional tool attachment at the plugin layer, and
no signal-level request and reply; delegation is a request id and
`await_completion`.

### The options

**A. A child agent for the record and the rules.** DobbyAgent keeps one tool,
"ask the house's memory", and the child carries the seven schemas, the two
doctrine paragraphs, and its own small soul. Saves about 1,350 tokens on
every turn that is not about the record. Costs one extra model turn on every
turn that is, because a tool result is not a reply: the parent must still
speak, and the child must extract and, if it answers in prose, speak too. A
history question becomes three or four model turns for roughly the tokens it
costs today. The honesty doctrine splits across two prompts, and the claim
that a command in the record is not proof it worked has to be true in both.
The propose-then-confirm boundary survives only if the child inherits the
parent's request id, since the later-turn guard keys on it, and the proposal
id must round-trip through the parent's reply. The thread and the activity
record stay one record only if the child's tool calls are written under the
parent's request; `Turn` reads the parent's event stream and would not see
them. The replay tier scripts two agents, and the eval tier judges the
parent's reply against the child's arguments. When the child is down, the
tool errors and the parent says so; the forms and the board still work. This
is the option Greg asked about, and the measurement says it makes the
requests he named slower.

**B. A per-request tool set.** Keep one agent and choose the schemas before or
during the request. A classifier in code is a keyword router deciding whether
the model may see the record, which is the boundary the design refuses to put
in code. The version Jido supports is two-stage: iteration one carries a stub
tool ("open the record") and the request transformer adds the seven schemas
for iteration two once the model calls it, the shape of jido_ai's `LoadSkill`
applied to schemas. Saves about 880 tokens on turns that never open it, costs
one turn on those that do, same latency verdict as A, without a second agent
or a second prompt. Worth reaching for when the tool count doubles, not now.

**C. One agent, less on every turn.** In order of what they return:

1. The house block carries state (fixed): removes the status turn the model
   was paying to read a blind block.
2. Observables in the house block and no `list_rules` before a proposal:
   +297 tokens per turn, one turn and 2 to 3 seconds fewer on every rule
   request. A rules line in the block does the same for pause, delete, and
   acknowledge.
3. Earlier requests' tool traffic dropped from the window, keeping only what
   people and Dobby said: unmeasured in a live house and likely the largest
   number here. A transformer change with a replay test.
4. Cached input recorded per request, from the runtime event `Turn` already
   consumes, written on the request's activity row, so the next paid run
   says what the cache actually returns and whether the doctrine's placement
   in the system prompt is earning anything.
5. The two doctrine paragraphs tightened, but not moved: 469 tokens, cached,
   and the sentences that stopped a model answering the past from the thread.

**D. Do nothing.** 11,300, 17,500, and 30,000 as measured, four to six
seconds a request on Luna, and every new tool family adds about 880 tokens
per turn for good.

### Recommendation, with its caveat

C, then measure. The child agent costs a model turn on the requests it is
meant to speed up, and what it removes from the other turns is 1,350 tokens
that the provider caches anyway. The turn count is the lever, and C.2 removes
a turn from every rule request for 297 tokens; C.1 already removed one from
any request the model opened with a status read. The caveat: C keeps every
schema on every turn, so the per-turn floor still grows with the house's
capabilities. At roughly double today's tool count, B's two-stage loading is
the mechanism to adopt, and it is a transformer change, not an architecture
change. A child agent is the answer to a different problem than speed: a
second voice, a second doctrine, or a second budget, none of which the record
and the rules need.

### Questions only Greg can answer

1. Is agreement in a later household message fixed as the rule boundary? It
   sets the floor: a rule is two messages and at least four model turns,
   whatever else changes.
2. Should the house block carry each device's observables and the standing
   rules, at about 320 tokens per turn in the rig house, so a proposal skips
   the `list_rules` turn?
3. Is the target seconds or tokens? Per-turn tokens shrink cost; turns shrink
   seconds. C.2 and C.3 pull in different directions on the first and the same
   direction on the second.
4. Should the window forget earlier requests' tool rows while keeping what
   was said? Dobby would remember answering "who set the thermostat" and not
   the rows it answered from; the record still holds them.
5. Does the rotation change the model in force? GLM 5.2 counts a third more
   tokens for the same prompt at the same speed; Luna is the cheaper per turn
   today.
