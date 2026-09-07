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

## Decision: the endpoint under each model is measured and pinned — TK-051

Decided 2026-09-07, from one sweep per model. Greg's standing decisions
frame it: the model is project configuration (`system.model`, or
`DOBBY_MODEL` over it, as TK-037's `model_in_force` resolves it), never
chosen per turn; the models in force are GLM 5.2, GLM 5.3 Flash, and Luna;
reasoning stays low; the provider pin and the reasoning setting sit under
the model in the same file.

### What was measured

`Dobby.Eval.ProviderEvalTest`, one run per endpoint per model, with Greg's
authorisation. The endpoint list is OpenRouter's own listing for the model
(`/api/v1/models/{model}/endpoints`), read at run time and never written
down: 24 endpoints under Flash, 31 under GLM 5.2, 7 under Luna. Per
endpoint, the three streaming scenarios once at low effort, each pinned
with `provider.order` of one and `allow_fallbacks: false` — "set the
thermostat to 70", "what can you do?", and "set to 70" again — with the
streaming tier's invariants as the pass mark, then one more "set to 70" at
effort none, judged on the doctrine. Every request started a fresh house, so
every endpoint was sent the same first-turn prompt: 15,600 input tokens over
two turns on GLM's count, 11,200 on Luna's. First token is measured from the
model call that produced it, per turn; the median is over the five turns the
three low-effort runs make.

The first attempt died at endpoint five: the test sandbox's ownership timeout
is two minutes, and one sweep is one test. `Dobby.RigCase` now turns that
timeout off and lets ExUnit's be the bound; the two endpoints cut mid-run
(z-ai/fp8 under Flash, deepinfra/fp4 under GLM 5.2) were run again whole, and
the tables below merge the two attempts.

### GLM 5.3 Flash, 24 endpoints, 15 passed

| Endpoint | First token p50 | Worst turn | Set to 70 | What can you do |
|---|---|---|---|---|
| wafer | 517 ms | 978 ms | 2,179 ms | 8,301 ms |
| fireworks | 820 ms | 5,385 ms | 4,245 ms | 2,468 ms |
| sail-research/fp8 | 826 ms | 2,700 ms | 2,738 ms | 2,886 ms |
| io-net/fp8 | 865 ms | 1,316 ms | 1,886 ms | 2,309 ms |
| parasail/fp8 | 998 ms | 4,149 ms | 3,569 ms | 5,181 ms |
| coreweave/fp8 | 1,183 ms | 3,335 ms | 3,488 ms | 4,573 ms |
| relace/fp4 | 1,279 ms | 2,669 ms | 2,950 ms | 4,496 ms |
| reka/fp8 | 2,195 ms | 3,289 ms | 3,433 ms | 6,588 ms |
| streamlake/fp8 | 4,390 ms | 5,364 ms | 8,352 ms | 9,780 ms |
| z-ai/fp8 | 4,521 ms | 6,494 ms | 9,180 ms | 9,855 ms |
| novita/fp8 | 4,569 ms | 7,284 ms | 9,168 ms | 8,747 ms |
| deepinfra/fp4 | 4,605 ms | 6,924 ms | 11,290 ms | 9,325 ms |
| siliconflow/fp8 | 4,652 ms | 4,974 ms | 8,212 ms | 11,442 ms |
| nextbit/fp8 | 4,751 ms | 4,973 ms | 8,463 ms | 8,402 ms |
| gmicloud/fp8 | 5,578 ms | 6,572 ms | 11,817 ms | 10,427 ms |

Nine failed the invariants, none on judgment: makora, modal/fp8 and
digitalocean answered 429 on every request ("temporarily rate-limited
upstream", OpenRouter's shared pool for that provider), baseten/fp8,
cloudflare, together and morph/fp8 on some, and friendli and venice never
answered inside the 30-second request timeout. The model's own endpoint,
z-ai/fp8, sits at 4.5 s to the first token. The spread between the fastest
and the slowest passing endpoint is a factor of ten, on one model, in one
quarter of an hour.

Effort none: refused by all 24, in about 60 ms, by OpenRouter itself
("Reasoning is mandatory for this endpoint and cannot be disabled", no
provider named). It is the model card, not an endpoint.

### GLM 5.2, 31 endpoints, 29 passed

| Endpoint | First token p50 | Worst turn | Set to 70 | What can you do | Effort none |
|---|---|---|---|---|---|
| together | 274 ms | 478 ms | 1,099 ms | 2,726 ms | holds, 1,133 ms |
| digitalocean | 448 ms | 611 ms | 1,773 ms | 2,298 ms | holds, 7,566 ms |
| friendli | 458 ms | 1,119 ms | 1,754 ms | 2,135 ms | holds, 1,488 ms |
| fireworks | 551 ms | 1,110 ms | 1,825 ms | 3,640 ms | narrated |
| coreweave/fp4 | 606 ms | 4,186 ms | 3,039 ms | 1,565 ms | narrated |
| alibaba/fast | 608 ms | 902 ms | 1,920 ms | 2,491 ms | narrated |
| mistral | 611 ms | 698 ms | 1,417 ms | 1,545 ms | holds, 1,459 ms |
| inceptron/fp4 | 645 ms | 881 ms | 2,041 ms | 3,345 ms | holds, 1,918 ms |
| mistral/zdr | 676 ms | 1,341 ms | 1,897 ms | 1,643 ms | narrated |
| decart/fast | 679 ms | 710 ms | 1,525 ms | 1,017 ms | narrated |
| crusoe/fp8 | 699 ms | 794 ms | 1,709 ms | 2,094 ms | narrated |
| parasail/fp4 | 740 ms | 940 ms | 1,819 ms | 2,469 ms | holds, 1,457 ms |
| mistral/eu | 816 ms | 1,149 ms | 1,995 ms | 1,238 ms | narrated |
| alibaba/fp8 | 861 ms | 1,778 ms | 2,862 ms | 3,425 ms | narrated |
| deepinfra/fp4 | 908 ms | 3,905 ms | 3,462 ms | 4,284 ms | holds, 4,229 ms |
| ambient/fp8 | 991 ms | 4,669 ms | 4,836 ms | 4,974 ms | narrated |
| siliconflow/fp8 | 1,013 ms | 1,475 ms | 2,461 ms | 4,673 ms | narrated |
| baidu/fp4 | 1,076 ms | 1,363 ms | 2,551 ms | 3,019 ms | narrated |
| baseten/fast | 1,080 ms | 1,680 ms | 2,372 ms | 2,387 ms | holds, 2,577 ms |
| baidu/fp8 | 1,168 ms | 1,491 ms | 2,900 ms | 4,668 ms | narrated |
| venice/fp8 | 1,219 ms | 1,500 ms | 3,749 ms | 4,694 ms | holds, 3,160 ms |
| atlas-cloud/fp8 | 1,589 ms | 1,721 ms | 3,539 ms | 4,002 ms | narrated |
| gmicloud/fp8 | 1,711 ms | 2,145 ms | 3,835 ms | 8,833 ms | holds, 4,857 ms |
| phala/fp8 | 1,898 ms | 2,243 ms | 4,381 ms | 4,018 ms | narrated |
| cloudflare | 2,029 ms | 4,455 ms | 5,412 ms | 4,901 ms | timed out |
| novita/fp8 | 2,106 ms | 2,276 ms | 4,913 ms | 4,258 ms | narrated |
| z-ai/fp8 | 2,123 ms | 4,957 ms | 5,390 ms | 6,144 ms | narrated |
| baseten/fp8 | 2,512 ms | 3,050 ms | 5,876 ms | 1,591 ms | holds, 3,201 ms |
| streamlake/fp8 | 4,996 ms | 7,856 ms | 11,576 ms | 6,162 ms | narrated |

fireworks/fast-us and fireworks/fast answered 429 on every request. Pinned
to together, "set the thermostat to 70" is done in 1.1 s, against 4.1 s on
Flash under latency routing on 2026-09-06 and 3.6 to 6.2 s for a two-turn
request on Luna in the table above; the same model on streamlake takes
11.6 s. Effort none was accepted by 28 endpoints, and the doctrine held on
every one: no reply claimed a reading it had not taken, and the judge said
so 28 times. What broke was the shape. On 17 of the 28 the first turn
streamed "Setting the main thermostat to 70°, Greg." as content before the
tool call, and the second turn said "Done — thermostat's set to 70°"; the
thread would paint both, and the streaming tier's first invariant — an
actuating turn calls the tool and says nothing first — is exactly the one
that fails. Eleven endpoints kept the shape with thinking off, and which
eleven does not follow the price, the quantisation, or the speed. On
together, none took 1,133 ms against 1,099 at low: thinking at low effort
was already costing this model nothing on this turn.

### Luna, 7 endpoints, 4 passed

| Endpoint | First token p50 | Worst turn | Set to 70 | What can you do | Effort none |
|---|---|---|---|---|---|
| amazon-bedrock/us-east-1 | 674 ms | 1,896 ms | 1,304 ms | 1,977 ms | holds, 1,326 ms |
| openai/fast | 1,132 ms | 1,369 ms | 3,201 ms | 1,660 ms | holds, 2,559 ms |
| azure/eu | 1,454 ms | 1,488 ms | 3,278 ms | 2,017 ms | holds, 3,488 ms |
| openai | 1,469 ms | 1,655 ms | 3,405 ms | 2,096 ms | holds, 6,579 ms |

azure and azure/us answered 429 on nearly every request, and openai/flex
passed two runs and let the third sit for 42 s before the timeout. Luna holds
its shape with thinking off — the tool first, then "Setting the downstairs
thermostat to 70°, Greg." — and gains nothing by it: 1,326 ms against 1,304
on Bedrock. Four endpoints is a small list, and Bedrock's 674 ms comes with
the widest worst turn of the four.

### The decisions

**Pin by first-token median, one per model, in the house file.** Flash:
`wafer`, in `config/homes/local.yaml` today. GLM 5.2: `together`. Luna:
`amazon-bedrock/us-east-1`. The setting is `system.provider`, a slug as
OpenRouter's listing writes it, translated by `Dobby.HomeConfig.System` to
`provider.order` of one with `allow_fallbacks` off — the shape the model
settings eval had already proven on the wire by pinning a provider that does
not exist. It is refused on a model not reached through OpenRouter in the
words the file used, at boot and on save, exactly as `routing` is; it
applies live; `/admin` grows the box from the schema. The caveat is the one
the pin buys: no fallback. Nine of Flash's endpoints were refusing for a
minute at a time during the sweep, and wafer's listed uptime over the
previous half hour was 96 percent, the lowest under Flash. io-net/fp8 is the
alternative with the tightest worst turn (865 ms median, 1,316 ms worst) and
99 percent; swapping is one word in the file, and the house file says so
beside the pin. Routing is left out of the local house on purpose: with a
pin in force the sort has nothing to choose, and both are still sent if both
are written, because the file's words all travel.

**Reasoning stays low, and none is not a file word.** Flash cannot take it.
GLM 5.2 takes it and narrates before the tool on 17 of 28 endpoints, and on
the pinned endpoint it saved nothing. Luna takes it, holds, and saved
nothing either. A setting that changes the shape of an actuating turn on
more than half the endpoints of one model, for no measured gain, is not
offered to the household as a word. The lever left unpulled is a thinking
budget: OpenRouter takes `reasoning.max_tokens`, and ReqLLM's OpenRouter
provider deletes `reasoning_token_budget` in `translate_options/3` rather
than sending it, so reaching it means a provider option ReqLLM does not have
today, and a paid run nobody has authorised.

**The record, and what it cost.** Both tables are one afternoon's; the eval
reruns in two to eight minutes per model, and `DOBBY_EVAL_PROVIDERS` names a
subset. The sweep cost about 1.1 million input tokens on Flash, 1.5 million
on GLM 5.2, and 250 thousand on Luna, roughly two and a half dollars in all,
most of it GLM 5.2 at twenty times Flash's price per token. The speed a pin
buys is bought again on every reply: GLM 5.2 on together answers "set to 70"
in half Flash's time at about twenty times its cost per token, and Luna on
Bedrock sits between them on both.

## Decision: the house block names what can be watched — TK-054

Decided 2026-09-07. Option C.2 from the child-agent survey above, agreed in
direction by Greg on 2026-09-06.

The `list_rules` turn before every proposal was the single largest avoidable
cost in the rules work — about 5,800 tokens and two to three seconds — and
it existed for one reason: the observables vocabulary lived only in that
tool's result. The house block already rendered the schedulable surface per
device (`can be scheduled to:`), for the same reason and in the same place;
the observables now ride beside it (`watches: current_temperature_f
(number), hvac_mode (off/heat/cool/heat_cool/auto/dry/fan_only),
target_temperature_f (number)`), in the words `list_rules` returns, so the
model that reads the block and the model that reads the tool see one
vocabulary. Beneath the roster, one line names the standing rules by id and
name with paused ones marked, and one the notices standing, by rule id —
which is what pausing, deleting and acknowledging take. A house with no rules
costs the words "Standing rules: none."

The doctrine's rule paragraph no longer asks for `list_rules` before a
proposal; it says to propose from the block, naming the observable exactly
as the block names it, and to call `list_rules` only when the block's rules
line does not identify a rule. `SoulTest` pins both sentences, so the turn
cannot come back without a test saying so. `list_rules` keeps its whole
vocabulary for the MCP door, whose callers get no house block; the three
rule tools' `id` docs and `propose_rule`'s `attribute` and `unit` docs name
the block first and the tool second, since both audiences read them.

The replay tier proves it through `HouseBlockTest`'s probe, which reads the
messages the runner built rather than calling `render/1`: the thermostat's
line carries the three observables in the tool's own words, the block lists
two saved rules with the paused one marked and the standing notice by rule
id, and a scripted "pause the cold room rule" is one `set_rule_enabled` call
with no list first. The two-turn scenario in `RulesHistoryTest` now scripts
the proposal as one call and the answer. Each of the probe's assertions
fails against the transformer as it was.

Not yet measured against a paid model. The 15 rules scenarios on Luna and
GLM 5.2 are the run that says whether a proposal is now two turns and a
pause two, and that run waits for Greg's word; the pause and list scenarios
no longer assert a `list_rules` call, since the model has the list in hand.

## Decision: every request records what it cost — TK-052

Decided 2026-09-07. Option C.4 from the survey above.

Production recorded no per-request usage, so the two costs the survey could
not measure stayed unmeasured: what the forty-message window carries in a
house that has been talking all day, and what the provider's cache returns
for a system prompt kept byte-identical on purpose. The number was in hand
all along. The runtime's `:llm_completed` event carries the provider's whole
usage map per model turn, as ReqLLM normalises it, cached and reasoning
tokens included; jido_ai's llm telemetry keeps input, output and total and
drops the rest, which is why `Dobby.Trace` never saw them. `Turn` already
folded every runtime event and wrote the request row; it now sums the four
counters over the `:llm_completed` events, counts the turns, and writes
them under `usage` on that row beside the end-to-end it already wrote.
`Turn.cost/1` is the one definition of the sum, and the eval tier's report
reads the same events through it — `say!/2` moved onto the streaming path
to get them, which is also the thread's path — or reads the row back after
`turn!/2`, the way `/admin` does. The feed's request line says the cost in
the record voice: "2 turns · 15,613 in · 37 out · 12,800 cached · 96
reasoning"; a row from before the counters still says what it said.

The replay tier proves the sum with scripted turns that carry usage, and
proves two claims this codebase had made about every request without ever
asserting them: the probe in `HouseBlockTest` now reads the whole request,
and the system prompt is the same bytes on the second model turn as on the
first, the tools offered are this house's closed set by name and the same on
both turns, and the block is the message before the utterance on both.
Whether the provider's cache honours the identical prompt is the eval tier's
to say, on the next paid run, in the new column.

Not measured yet: the live-house week the ticket asks for, which is a
number that accrues rather than one a run produces. The trim (TK-053) is the
change that number was going to size; it is taken on the survey's reasoning
instead, and the row will say afterwards what it was worth.

## Decision: the window keeps what was said — TK-053

Decided 2026-09-07. Option C.3 from the survey above, agreed in direction by
Greg on 2026-09-06 (question 4: Dobby remembers answering "who set the
thermostat" and not the rows it answered from; the record still holds them).

The forty-message window counted tool traffic, so a `list_rules` result of
624 tokens with no rules in it and every `history` row set rode on every
following turn until they fell out — and the evals never saw it, because
they restart the house per scenario. `RequestTransformer.window/1` now
forgets, for every request before the current one, the assistant's tool
calls and their results together, never one without the other, since a
provider rejects an orphaned result outright; keeps the person's words and
the assistant's words, stripping `tool_calls` off a message that carried
both; drops an earlier turn's house block, which is not conversation; and
keeps the current request's own traffic whole, because the model asked for
that result a moment ago and the next turn is about it. The forty-message
cap then applies to what remains, still cutting at somebody speaking. Boot
rehydration replays only what people and Dobby said, so what boot remembers
was already in this shape, and the window leaves it alone — the same policy
at two moments, now the same shape too.

The ticket's open question was the proposal id: `propose_rule` returns it
in a tool result, the agreement comes in a later message by design, and the
reply shows the household the description word for word rather than a
number. The ticket offered two answers — keep that one tool result, or put
the id in the reply — and this takes a third, the one TK-054 had just made
natural: the house block lists every proposal awaiting agreement, rule and
device, with the id the confirming tool takes, on every turn until it is
confirmed or expires. The window can then forget uniformly, the id is in
front of the model on the turn the household says yes and on no other, and
it costs nothing while nothing is proposed. The doctrine's rule paragraph
says to read the id from there.

Proven in the replay tier: the window's own tests (the pair goes together,
words beside a call stay as words, the current request keeps its traffic,
an earlier block is not conversation, the cap still starts at somebody
speaking, and boot's shape passes through unchanged), and a probe scenario
that runs a proposal and its agreement as two household turns through the
thread's own path and reads the second request as the runner built it: no
tool row and no tool call from the first request, the words of both
present, the proposal named in the block with its id, and `confirm_rule`
the only call. Unmeasured in a live house, by construction; the request row
TK-052 writes is what will say what it was worth, once a house has talked
for a day.

## Decision: the catalog knows GLM 5.3 — TK-056, first half

Done 2026-09-07: LLMDB 2026.7.5 to 2026.9.1, which ReqLLM 1.22.0 requires,
so ReqLLM 1.20.0 to 1.22.0 with it. The catalog now carries both GLM 5.3
entries, and what it says agrees with what the wire said in the September
runs. GLM 5.3 and 5.3 Flash: reasoning enabled and mandatory, efforts low,
high and max, tool calling on, tool-call streaming on, 1.31 million
context; 5.3 at $1.40 in and $4.40 out per million, Flash at $0.075 and
$0.25, cache reads at about a fifth of input. The mandatory flag is the
sweep's finding on Flash, now in the catalog. GLM 5.2 is listed with
reasoning optional and efforts xhigh and high, where the wire took low on
every endpoint and none on 28 of 31; the catalog is conservative and
ReqLLM's OpenRouter provider does not validate an effort against it, so
the house's `reasoning: low` still passes the boot check on every model in
force and still reaches the provider. Luna lists none among its efforts,
which the sweep confirmed.

Two consequences in the eval tier. `Dobby.Eval.reasoning_model?/0` now
answers true for Flash and 5.3, so the tier's default effort of low is sent
to them without `DOBBY_EVAL_REASONING`, which is the standing decision
either way. And the unverified-model warning that printed once per model
call under Flash is gone. ReqLLM's two releases between carried nothing for
OpenRouter beyond the catalog; the replay tier is green on the new pair.

Not done, and it is what makes 5.3 a model in force: the billed
tool-streaming and judgment evals on 5.3, once, which wait for Greg's word.
GLM 5.2 stays the model in force until then.

## Decision: a form-made rule's id is its name — TK-055, third item

Done 2026-09-07. The form generated a UUID for every rule it saved, and the
house file is the household's to read: `cold-room`, which Dobby already
writes from the thread, says what a rule is where
`3f2a…` says nothing. The form now slugs the name — lowercase, anything
that is not a letter or a digit becomes a hyphen, trimmed — and refuses a
name with nothing left in it. The collision is the form's to refuse, not
the writer's: `Dobby.Rules.save/2` replaces a rule of the same id, which is
what an edit is, and the form is the one path that makes ids from names,
so a second "Warm room" would have silently become the first. It is refused
before the writer sees it, naming the id and asking for another name. The
first rule stands.

The other two items stay open, on purpose. A notice phrased per device
type from the type's own words is a voice decision on a line the household
reads under the board, and the vocabulary that governs the board is closed
at eight words by design; that is a design walk, not a commit. An absence
notice citing the last recorded event rather than the watch start is a
change in `Dobby.Rules`' notice sentence, and this session's constraint
kept every change out of `Dobby.Rules` and `Dobby.History`. Both are
follow-ups on the ticket.
