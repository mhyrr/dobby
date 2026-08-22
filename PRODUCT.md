# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The household — Greg, his wife, and their kids — all talking to the same
Dobby in one shared thread that everyone can read. Kids type into it, so
copy has to be readable and controls hard to fat-finger.

There is no operator role and no admin role. The admin dashboard is open to
anyone in the house, per flat trust. `speaker` on every utterance exists for
personalization and attribution and never for permissions.

Three usage scenes, in the order they matter:

1. **Phone, standing in a room.** The primary viewport. One-handed, thumb
   reach, quick in-and-out.
2. **Kitchen iPad.** Landscape, often left open. It is **not a special device
   class** — it is a browser logged into the same app as everything else, and
   it updates live because every connected surface does. Several people share
   it; whoever set the name last is who it speaks as.
3. **Laptop.** Where Greg reads the activity log and edits schedules. The
   admin's real home.

No surface gets a bespoke mode. Real-time updates everywhere is the rule.

## Product Purpose

Dobby runs the house. A household says what it wants in plain language —
"set the thermostat to 70", "I always want it at 70 by 8pm on weekdays" —
and the house does it, or says plainly why it did not.

Success is a house that feels *run* rather than merely controllable: it
holds standing intentions, it reports refusals instead of swallowing them,
and it never claims something happened that did not.

Dobby is not a replacement for Home Assistant's dashboard. HA owns devices,
protocols, and observed state. Dobby owns the conversation, the household's
intentions, and the record of what changed.

## Positioning

**Deterministic below, probabilistic above.** The LLM never touches Home
Assistant and cannot invent a device operation. It acts only through a closed
set of typed tools; each tool dispatches to a deterministic device agent that
owns its own validation and its own mapping to HA. The closed tool set is a
construction guarantee, not a prompt instruction.

The same line runs through schedules. The model *authors* a schedule as a
Postgres row from ordinary conversation; a deterministic agent *fires* it,
with zero model calls at fire time. Authoring is the probabilistic act;
firing is not.

The consequence a neighboring product cannot truthfully copy: the house keeps
working when the model is down, wrong, or expensive. Card controls and
schedule firings are a complete control path with no inference in it.

## Operating Context

One Linux mini-server in the house running Proxmox, with Home Assistant OS in
one VM and Phoenix + Jido + Postgres in another. Dobby is reachable at
`http://dobby.local:4000` on the home LAN only — no inbound port forwarding, no
remote access, no TLS. Outbound HTTPS to the model provider is the only
traffic that leaves.

Browsers are on household Wi-Fi. The kitchen iPad is mounted and stays awake.
Phones come and go.

Dobby ships as an OTP release under `/opt/dobby` supervised by systemd. Two
files under `/opt/dobby/config/` are read at boot from outside the release:
the home manifest and the soul. Credentials stay in the service environment;
the manifest contains only `env:VARIABLE` references. Changing the house, or
changing how Dobby talks, is edit-and-restart — never a rebuild.

`mix phx.server` in dev boots the entire application against a fake HA client
at the one honest boundary. The whole surface can be built, clicked, and
screenshotted with no server, no HAOS, and no house.

## Capabilities and Constraints

**v1 devices.** Thermostats, lights, vacuums, and read-only Wi-Fi endpoints,
plus the scheduler. Each device type owns its bindings, settings, tools, and
discovery rules.

**Confirmed surface decisions.** One shared, persistent, Discord-like thread,
single page, thread-first. Actuations post muted system lines whenever
anything changes the house by any path — tool call, card tap, schedule
firing, or external change seen via HA. Passive observations stay on the
cards and in the admin log. The thread records interventions; the admin
records everything. Identity is a first-visit "Who's this?" prompt plus a
cookie-pinned device; MAC-based identity was considered and rejected.

**Flat household trust.** The browser surfaces have no login; LAN access is
household access and the Wi-Fi password is their boundary. MCP requires a
Dobby-minted bearer token. Possession of that token means household, with its
label used for attribution rather than permission tiers.

**Latency is a product fact, not a bug.** Measured against gpt-5.6-luna at
reasoning `:low`: an actuating request is 2 model turns and 1.7–2.7s; a
clarification is 1 turn and 0.9–1.8s; authoring a schedule is 2 turns and
2.3–3.3s. Every interface decision has to hold up across roughly two seconds
of waiting. A card tap has no model in it and is effectively instant — the
gap between those two paths is visible to a person.

**The world model is eventually consistent.** Device state fans out
asynchronously. The thread having an event is not evidence the model has it.

**Replies are plain speech.** Models may emit markdown, and the thread strips
the syntax instead of adding a renderer and a second visual vocabulary.

**Terminology, fixed.** *The house* (the manifest of real devices), *device
agent*, *the thread*, *system line*, *cards*, *the activity log*, *the soul*
(personality, a file on the box), *the doctrine* (honesty rules, in code),
*the rig* (the app running against a fake HA). "Replay" already means the
scripted test tier — it must not be reused for re-examining what happened.

**Existing stack constrains the surface.** Phoenix 1.8 + LiveView 1.2,
Tailwind v4, daisyUI 5 with light and dark themes already present, heroicons.
PubSub topics are currently one per concern (`dobby:devices`,
`dobby:schedules`), not one per device.

**Deliberately not built** (design §11): room and space agents, proactive
announcements, presence, voice, Telegram, cameras, Sonos, policy authoring,
schedule conflict mediation, per-user private threads, multiple houses, local
model hosting.

## Brand Commitments

**The name is Dobby** and it is not up for redesign here.

**The voice is fixed and it is testable.** It lives in `config/soul.md`:
a capable person who lives here too, not a butler and not a search box. Warm,
brief, unfussy. One or two sentences. Says what it did and stops. It
explicitly bans sign-off filler ("Let me know if you need anything else"),
process narration, and speaking its own speaker prefix aloud. That voice
survives a model swap — verified, not assumed.

Interface copy should sound like the same housemate. Nothing on the surface
should be chattier than Dobby is.

Beneath the voice sits **the doctrine**, in code: never invent a device, never
act on a guess, report what you commanded rather than what you observed. On
any conflict, doctrine wins. A personality rewrite must never be able to
delete a safety rule.

## Evidence on Hand

Real, in the repo:

- A working system with replay tests for the application rig and a separate
  eval suite against real models.
- Measured cost and latency per household request, not estimated (§6.5).
- Voice fidelity across two providers, asserted structurally in
  `test/dobby/soul_test.exs`.
- `dobby-design-jido.md` — the design of record, written from working code.
  Its header still stamps "Draft v0.11" though commit 9c0b7c8 and TK-003
  call it v0.12; the content is v0.12.
- `dobby-design-original.md` — the original household vision, superseded on
  scheduler venue but still the source for the hardware and integration plan.

Absent, and not to be fabricated: no users outside this household, no
testimonials, no customers, no pricing, no benchmarks against other products,
and no production uptime record. Replay evidence uses the fake HA client;
installation evidence must come from the real household server and HA.

## Product Principles

1. **Deterministic below, probabilistic above.** The model converses and
   authors. Code actuates and fires. Never blend the two.
2. **Honest over fluent.** Report what was commanded, never claim what was
   observed. A house that lies about whether the heat is on is worse than one
   that says nothing.
3. **The house works when the model doesn't.** Every deterministic path —
   card taps, schedule firings — is first-class, because it is both the test
   surface and the outage fallback.
4. **Attribution, never permission.** Knowing who is speaking makes Dobby
   personal. It never makes anyone privileged.
5. **The things a person changes are outside the release.** The house and the
   voice are files on the box. Credentials are environment values referenced
   by the house file. Only code needs a rebuild.

## Accessibility & Inclusion

No formal standard has been set — that is an open decision, not a stated
requirement. Three real needs are confirmed:

- **Kids read and type into it.** Copy at a plain reading level; errors that
  explain rather than blame; controls that resist accidental actuation.
- **Screens get left open in rooms.** Legible from across a kitchen, and dark
  enough at night not to light it.
- **Phone-first means one-handed.** The composer and the primary controls
  must sit in thumb reach.
