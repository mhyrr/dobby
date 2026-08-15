# Dobby — the Phoenix surface

**Working design for Phase A step 4. Draft 1, August 2026.**

**Status:** signed. Folds into `dobby-design-jido.md` §10 as v0.13 when step 4
lands, and this file goes away. The visual system has already left for
`DESIGN.md`, which outlives both. Nothing here overrides the design of record;
where they disagree, say so and the doc wins.

TK-001 is the owning ticket. Its already-decided constraints — one shared
thread, system lines for actuations, cookie-pinned identity, card controls with
no LLM — are inputs here, not questions.

---

## 1. The world

**Moved to `DESIGN.md`** (2026-08-15), which is now the single home for the
visual system: the departure board, the state vocabulary, the palette law, the
type ramp, the components, and the named rules — derived from what shipped
rather than from what was intended.

This file keeps the *surface* decisions: routes, streaming, persistence,
identity, and the reasoning behind them. Where the two touch, `DESIGN.md` wins
on how a thing looks and this file wins on what it does.

---

## 2. Routes and LiveViews

**Decided (Greg, 2026-08-14): three routes.** The first draft folded cards into
the thread page. Wrong for the real case — any house worth its salt has a lot of
devices, and a strip of them wedged above a conversation stops working at about
six. Devices get their own page and their own space.

```
/        DobbyWeb.ThreadLive    the conversation
/house   DobbyWeb.HouseLive     every device, as cards
/admin   DobbyWeb.AdminLive     activity feed, scheduler CRUD, health
```

The thread page keeps a **compact house band** — a few rows of state, not the
full card set — because "what is the thermostat at" should be answerable
without navigating, and without spending 600 input tokens and a second of
latency asking. On wide screens `/house` may sit beside the thread rather than
replacing it; on a phone it is a route.

No auth on any of them. Flat trust, LAN-only, per §10.4.

---

## 3. The phone layout

Phone is the primary viewport (Greg, 2026-08-14). Everything else adapts to it.

```
┌──────────────────────────────┐
│ THE HOUSE           LISTENING│  board header — brass rule under
│ MAIN THERMOSTAT  70°  SET    │  a few flap rows; tapping the
│ KITCHEN TV            QUIET  │  band opens /house
├──────────────────────────────┤
│                              │
│  greg              4:12 PM   │
│  set the thermostat to 70    │  utterance at board scale
│                              │
│  Dobby                       │
│   ↳ setting the main         │  live step (§5.3)
│     thermostat…              │
│                              │
│  Dobby             4:12 PM   │
│  Done — main thermostat      │
│  set to 70.                  │
│   ▸ 2 steps          2.1 s   │  collapsed after
│                              │
│  · thermostat SET 70 — greg  │  system line
│                              │
├──────────────────────────────┤
│ say something            [→] │  the set line
└──────────────────────────────┘
```

The band is not the card set. It is the two or three devices worth standing
watch over, always visible for about 96px, and tapping it opens `/house`. It
means "what's the thermostat at" is answered before anyone asks — the cheapest
possible improvement to a product whose alternative costs 600 input tokens and a
second of waiting.

Which devices earn the band once there are twenty of them is open.
Most-recently-changed is the obvious first answer and probably right.

---

## 4. Every surface is live, and none of them is special

**Decided (Greg, 2026-08-14), reversing draft 1.** The kitchen iPad is not a
kiosk. It is a browser logged into the same Phoenix app as everyone else. It
gets updates in real time because *every* connected surface does — that is what
PubSub over LiveView already gives us — and it does not wake, invert, or hold a
resting state of its own.

Draft 1 proposed an idle inversion where the iPad became a glanceable house
face after 90s. That is cut. It invented a device class the product does not
have, and it would have meant one LiveView with two compositions and an idle
timer to keep in sync, for a behaviour nobody asked for.

What survives from the thinking: the *reason* the resting face was attractive
was that a wall-mounted tablet wants to answer "what is the house doing"
without a conversation. That is now `/house` (§2), which is a route anyone can
leave open — on an iPad, a laptop, or a phone — and which updates live like
everything else.

The responsive rule is ordinary: phone is the primary layout, wider viewports
get more room and the fixed speaker column (§5.1). No device gets a bespoke
mode.

## 5. Thread rendering

### 5.1 Interleaved speakers

**Options.** (a) Discord-style grouping — consecutive messages from one speaker
collapse under one header. (b) Every message attributed, always. (c) Speaker as
a fixed column: `NAME | TIME | WHAT WAS SAID`. (d) Alignment by author, me right
/ others left.

**Recommend (c) on wide, (b) on phone.** A fixed name column is board-native and
makes interleaving trivially scannable — the eye tracks one column. At 390px it
costs too much width, so the phone attributes inline above each utterance.

(a) is rejected on measurement, not taste: in a house, consecutive messages from
one speaker are the *exception*, so grouping almost never fires and you carry its
complexity for nothing.

**(d) is rejected on principle.** The thread is a shared household record.
Positioning a message differently depending on who is holding the phone means
two people reading the same conversation see two different documents. That is
wrong for a room everyone reads.

### 5.2 System lines

**Open, your call (5a):** §10.1 implies a card tap posts a system line.
**Confirm it does.** The rule "the thread records interventions" says nothing
about which surface the intervention came from, and a card tap that leaves no
line makes the thread lie by omission — someone scrolls back, sees 70°, and
finds no reason for it.

System lines carry a `via`:

```
· MAIN THERMOSTAT   SET 70°   — greg, card
· MAIN THERMOSTAT   SET 70°   — schedule "weeknight heat"
· MAIN THERMOSTAT   SET 68°   — changed at the thermostat
```

That last one is the interesting case: someone physically turned the dial. It is
an intervention Dobby did not make and it belongs in the thread.

**This needs a new callback, and it grows the extension contract.** §10.1 splits
interventions (thread) from passive observations (cards only), but Home
Assistant does not report intent. The discriminator is *which attribute
changed*: a setpoint is commanded, connectivity is observed. That is per-device
knowledge, so it belongs on the device agent:

```elixir
@callback intervention?(attribute :: atom()) :: boolean()
```

`Thermostat` answers true for `:setpoint`, false for `:current_temperature`.
`WifiEndpoint` answers false for everything. Narrow, and it keeps §4.2's
extension contract honest — a new device type brings its own answer rather than
editing a central list.

### 5.3 Activity steps

Decided: named steps live, collapsing after the reply. Steps are written in
device language, not tool language — "setting the main thermostat…", never
`thermostat_set_temperature`.

The tension worth naming: the soul bans process narration in Dobby's *voice*.
These steps are not Dobby's voice, they are the board showing its work — which
is the thesis. They must never be phrased as Dobby speaking ("Let me just check
the thermostat…"). They are labels, not sentences.

### 5.4 Markdown

**Open, your call (5b).** luna emits `**bold**`.

**Options.** (a) Strip at render. (b) Render a safe subset — needs `mdex` or a
hand-rolled inline parser. (c) Tell the soul not to emit it.

**Recommend (a) + (c).** Strip deterministically at render, and add one soul
line so the model stops spending tokens on it. Both are nearly free. Adding a
markdown dependency to render bold inside a two-sentence reply is a fence
larger than the loss — and (c) alone cannot be relied on, since models drift and
the eval tier catches this only sometimes.

---

## 6. Streaming

**Verified in source, not docs.** Three findings that shape this:

1. `ask_stream/3` sets `stream_to: {:pid, self()}` — the **calling** process is
   the event sink (`deps/jido_ai/lib/jido_ai/agent.ex:571`). The task is not a
   style choice, it is forced. And the LiveView cannot call `ask_stream` itself,
   because the returned enumerable is a `Stream.resource` that blocks in
   `receive` (`request/stream.ex:107`).
2. Events are `%Jido.AI.Runtime.Event{seq, iteration, kind, tool_name, data}`
   with 16 kinds (`runtime/event.ex:10`). `seq` is monotonic per run, so
   ordering within a request is real — unlike telemetry across sources.
3. Token deltas flow **by default**: `emit_llm_deltas?: true`
   (`react/strategy.ex:2397`), gated on `capture_deltas?`
   (`react/runner.ex:1470`). Streaming needs no configuration change.

```
LiveView ──"say"──▶ Task.Supervisor.async_nolink
                        │
                        │ 1. persist the user message
                        │ 2. DobbyAgent.ask_stream(...)   ← task is the sink
                        │ 3. for event <- events:
                        │      republish to "dobby:thread"
                        │ 4. persist the reply + activity
                        ▼
                    dies
LiveView ◀──subscribed to "dobby:thread"──
```

Event mapping:

| Event | Thread |
|---|---|
| `:request_started` | open a pending reply row |
| `:tool_started` | a live step, in device language |
| `:tool_completed` | the step resolves |
| `:llm_delta` (`chunk_type: :content`) | flap text into the pending row |
| `:request_completed` | finalize; `data.result`, `data.usage` |
| `:request_failed` / `:request_cancelled` | an honest failure row |

**6a — measured, and the answer is that there is nothing to do.** An actuating
request emitted **zero content deltas in iteration 1**: luna calls the tool and
says nothing first. The fold-into-step rule was written against a case that
does not happen, and was dropped rather than built.

The same measurement found two things that were not in the design.

**A tool call streams as a delta.** Iteration 1 emitted exactly one
`:llm_delta` with `chunk_type: :tool_call` whose payload is the tool's *name*.
A thread rendering every delta would have put `thermostat_set_temperature` in
the middle of Dobby's reply. The `chunk_type: :content` filter above was
already written; it is now known to be load-bearing rather than tidy.

**Arrival order is not `seq` order.** Deltas reach a subscriber through the
agent server and PubSub, and a two-event swap was observed in the rig —
rendering "connectivity and , set" for "connectivity, and set". Rare, invisible
to tests, and exactly the kind of thing that makes an honest board look broken.
The thread keys deltas by `seq` and renders them sorted.

`Dobby.Eval.StreamingEvalTest` keeps all three honest, including the invariant
the surface stands on: the content deltas concatenate to the stored result.

---

## 7. Identity

**Decided (Greg, 2026-08-14): keep it simple.** Enter a name from this browser
and it stays until someone switches it. That is the whole feature.

No `shared` flag, no idle re-prompt, no per-session identity. The kitchen iPad
is a browser like any other; if four people use it, it says whatever the last
person set it to, and Dobby occasionally calls someone by the wrong name.

That cost is affordable *because* identity gates nothing — it personalizes and
attributes, never permits (§10.2 of the design of record). The blast radius of a
wrong name is a wrong name in one sentence and a wrong `created_by` on a
schedule.

Draft 1 proposed a `browser_devices` table carrying a shared-device flag. Cut
with the resting face; the cookie holds a speaker id and that is enough.

**Named risk, unchanged:** the kids will set it to each other's names as a joke.
Still affordable, still better said now than discovered in October.

## 8. Cards

One thermostat card (state + a direct setpoint control), one card per Wi-Fi
endpoint (state only). Live from `Dobby.DeviceEvents`. No LLM anywhere in the
path.

The setpoint control is the one place a fat finger actuates the house. Given
kids: the control commits on release with a brief undo window on the card, not
on every drag tick. Cheaper than a confirm dialog and it does not train anyone
to dismiss dialogs.

Cards render the same flap vocabulary as the board. A card is a board row that
grew a control.

---

## 9. Admin

`/admin`, open to the house, laptop-shaped:

- **Activity feed** — every request, tool call, result, state change, and
  firing. The full record; the thread's interventions are a subset of it. TK-004
  reads this table.
- **Schedules** — a LiveView form over `Dobby.Schedules` and nothing more.
  `create_schedule/1`, `set_enabled/2`, `delete_schedule/1` already re-register
  timers, and `created_via: :admin` is already in the enum. `describe/2` gives
  status and next fire at read time.
- **Health** — agent liveness, HA connection, and `SchedulerAgent.unregistered/0`,
  which is the most useful row on the page: enabled schedules with no live timer.

---

## 10. Persistence

**Three tables, as TK-001 said.** Draft 1 proposed a fourth
(`browser_devices`) to carry a shared-device flag; §7 cut the flag, so the
table goes with it. The cookie holds a speaker id.

1. `speakers` — `name` (unique, case-insensitive), timestamps. A person.
2. `messages` — the transcript. `speaker_id` (null for Dobby and for system
   lines), `role` (`:user | :assistant | :system`), `channel`, `text`,
   `request_id`, `meta` (map), timestamps.
3. `activity_entries` — everything. `request_id`, `kind`, `actor`, `device`,
   `action`, `args`, `result`, `duration_ms`, timestamps.

**One table for the transcript, not two.** A system line is a message with
`role: :system` and a `meta` map. Splitting messages and system lines into
separate tables means merging two ordered reads by timestamp on every scrollback
page, which is the classic version of this mistake.

Migrations follow `20260814150950_create_schedules.exs` — a `@moduledoc` saying
why the table exists, and comments on the columns whose shape is a decision.

### 10.1 Rehydration

§10.5 requires DobbyAgent to rebuild its recent conversation window from the
transcript on restart. **This is cheaper than the ticket assumed.**

`initial_state[:context]` accepting a `%Jido.AI.Context{}` is a supported,
validated seam (`react/strategy.ex:920-941` — it even raises a specific error
for the retired `:thread` key). So rehydration is: read the last N messages at
boot, build a `Jido.AI.Context`, and hand it to the agent at construction. No
custom action, no signal, and no exposure to the deep-merge trap that bit the
scheduler.

One ordering note: a supplied context with `system_prompt: nil` gets the
compile-time doctrine, and `Dobby.Home` then installs soul+doctrine over it via
`ai.react.set_system_prompt` exactly as it does today. The existing boot order
survives.

---

## 11. PubSub topics

**Open, your call (11a):** confirm one topic per concern holds. **It does.**

Per-device topics would mean N subscriptions per LiveView to receive the same
total volume, because every card is on one page and the page needs all of them.
They do not even help the worst case — a flapping endpoint reaches every
connected LiveView under either topology, since they all render that card.

Step 4 adds two:

```
dobby:devices     exists    device state changes
dobby:schedules   exists    firings and their outcomes
dobby:thread      new       deltas, steps, messages, system lines
dobby:activity    new       the full log; the admin subscribes
```

`dobby:thread` is one topic, not one per request. The thread is shared, so every
viewer wants every request's deltas; per-request topics would mean every
LiveView subscribing and unsubscribing on every utterance for no benefit.

---

## 12. Module breakdown

```
lib/dobby/
├── conversation.ex                the context — speakers, devices, transcript
├── conversation/speaker.ex
├── conversation/message.ex
├── conversation/turn.ex           the streaming task; calls ask_stream
├── conversation/rehydrate.ex      transcript → Jido.AI.Context at boot
├── thread_events.ex               "dobby:thread" seam
├── activity.ex                    the context
├── activity/entry.ex
└── activity_events.ex             "dobby:activity" seam

lib/dobby_web/
├── plugs/speaker.ex               cookie → speaker assign
├── live/
│   ├── thread_live.ex
│   ├── thread_live/
│   │   ├── board.ex               the header band + resting face
│   │   ├── message.ex             one transcript row
│   │   ├── system_line.ex
│   │   ├── activity.ex            live steps, then the collapsed row
│   │   ├── composer.ex
│   │   ├── identity.ex            "Who's this?" + speaking-as switcher
│   │   └── cards/{thermostat,wifi_endpoint}.ex
│   ├── house_live.ex
│   ├── admin_live.ex
│   └── admin_live/{activity_feed,schedules,schedule_form,health}.ex
└── components/flap.ex             the flap primitives — row, flap, rule
```

`Dobby.ThreadEvents` and `Dobby.ActivityEvents` follow `DeviceEvents` and
`ScheduleEvents` exactly: `topic/0`, `subscribe/0`, and one place where both
sides agree on the payload.

---

## 13. Decisions

**Answered 2026-08-14 (Greg).**

- **4a** — dead. The iPad is not special; nothing wakes. Every connected surface
  is live (§4).
- **5.1** — (c). Speaker as a fixed column on wide, inline attribution on phone.
- **5.2** — Home Assistant *does* push external changes, and the plumbing
  exists: `HomeAssistant.configure_routing/1` installs the entity→agent table
  for exactly this, and `Thermostat` already routes `ha.state_changed` to
  `SyncState`. Someone turning the dial by hand reaches the agent, the cards,
  and DobbyAgent's world model. The real WebSocket client is still unwritten —
  §2.3 lists `home_assistant/websocket.ex` but `lib/` has only the behaviour and
  the fake — so this is true by design today and true in fact in Phase C.
- **5.4** — (a) + (c). Strip markdown at render, and tell the soul to stop
  emitting it.
- **Identity** — simplest thing: a name entered on a browser sticks until
  switched (§7).
- **Cards** — their own page (§2). A house worth its salt has too many devices
  for a strip above a conversation.
- **10a** — three tables, not four.

**Still open.**

- **13a — approved (Greg).** `DeviceAgent.intervention?(attribute)` (§5.2). A
  setpoint someone turned by hand is an intervention and belongs in the thread;
  an endpoint flapping is weather and belongs on the cards. Good enough to
  start with.
- **11a — approved (Greg).** One PubSub topic per concern, plus `dobby:thread`
  and `dobby:activity`.
- **16a — decided (Greg): the Ear, and the Eyes, in different jobs.** See §16.

Nothing is open. The design is signed except for the drawing itself.

## 14. Verify in code before designing further against it

TK-002's record is that three of four verify items came back different from the
docs. These are the step-4 equivalents, ordered by how much they would cost if
wrong:

1. **Turn-1 deltas (§6a) — done.** No turn-1 narration; the fold-into-step rule
   was dropped. Two other findings came out of the same request; see §6.
2. **Rehydration round trip.** Build a `Jido.AI.Context` from rows, boot with
   it, and assert the model resolves a pronoun against a pre-restart turn. The
   seam is confirmed; the behavior is not. **Still open.**
3. **Delta volume against LiveView — done.** Deltas are words, not characters:
   twenty-five for a long answer, nine for a short one, over a second or two.
   No batching.
4. **`Jido.AI.Context` truncation — done, and the answer is different from what
   §6.3 assumed.** There is no cap. `Jido.AI.Context` says of itself "no
   policies, no windowing", `to_messages/2` takes an optional `:limit`, and
   both callers in jido_ai call `to_messages/1` with no limit
   (`react/runner.ex:339`, `react/strategy.ex:384`). The 40-message window in
   `Dobby.Conversation.Rehydrate` is therefore the **only** cap in the system
   and it applies at boot alone: a process that has been up for a week sends a
   week of conversation on every request, and input tokens grow without bound
   between restarts. Not blocking step 4, and it needs its own ticket.

### 14.1 Found by building it

**One ReAct agent takes one request at a time.** A second utterance arriving
while a turn is in flight is rejected with `{:rejected, :busy, ...}` and
dropped. Two people saying something within a few seconds of each other is the
ordinary case in a house at six in the evening, and the whole premise of this
surface is one shared conversation, so this needs a real answer: hold the
utterance and re-issue it when the agent frees up, or inject it into the
running turn (jido has `:input_injected` for exactly that, and it would mean
Dobby answers both in one reply). Both change what a turn *is*, so both are
Greg's call. The thread currently says "Dobby is still working on the last
one", which is at least true.

---

## 15. Commit sequence

Layered, each green alone, per your standing rule:

1. **Persistence.** Four migrations, `Dobby.Conversation`, `Dobby.Activity`,
   plus rehydration and its test. No web.
2. **The thread and streaming.** `ThreadLive`, `Conversation.Turn`,
   `ThreadEvents`, the flap component. RigCase-backed LiveView tests against the
   real house and FakeHA.
3. **Identity.** The speaker plug, the name prompt, the switcher, attribution
   in the transcript.
4. **Cards.** Thermostat and endpoints, plus `intervention?/1` and system lines
   for every path.
5. **Admin.** Activity feed, scheduler CRUD, health.

The resting face lands with (4), not (2) — it needs cards to have anything to
rest on.

---

## 16. Dobby's mark

**Moved to `DESIGN.md` → Components → The Mark** (2026-08-15). Greg supplied
the drawing, and having it settled both open questions: the mark is Dobby's
face in the plate at 44px, leaning fifteen degrees when he is attending, and
the ambient eyes are cut because the header cannot carry two sets of his eyes.

The reasoning — why it is not a 26px byline, why the ears alone read as
leaves, and why subtle comes from colour rather than opacity — is recorded
there.
