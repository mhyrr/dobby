# Dobby — Design Specification

**A household convenience agent on Home Assistant + Hermes** Draft v0.2 — July 2026 · Target build: Fall 2026

https://docs.google.com/document/d/1hYYSnjpTv6lTxS_57AhJy7vqHfvWqUp58ESfDVS8XjM/edit?tab=t.0

***

## 1. Concept

Dobby is a house-scoped AI agent. Anyone on the home WiFi can converse with it (web UI or Telegram) to control and query the house. It is a **convenience system, not a security system**: the WiFi password is the trust boundary, and everyone inside it is family-or-guest-we-trust with full access.

**Design principles**
1. **Deterministic below, probabilistic above.** Home Assistant (HA) owns protocols, device state, and dumb automations. Hermes owns intent, judgment, and conversation. The model never improvises plumbing.
2. **LAN residency of the control plane.** No inbound ports. Credentials and device control never leave the box.
3. **Flat trust.** WiFi password = full household access. No tiers, no per-person permissions. Identity exists only for personalization ("play _my_ playlist"), never for gatekeeping.
4. **Convenience scope.** Dobby controls media, lights, climate, and notifications. Locks, alarms, and anything security-critical stay in their own vendor systems, out of Dobby's tool set entirely. (If that ever changes, that's the moment to introduce a ratification gate — not before.)
5. **Schedules are deterministic.** Time-based device behavior lives in HA automations; Hermes authors and explains schedules but never executes them. (Detail in §7.5.)
6. **Agent amnesia, explicit state.** Hermes invocations are stateless. All memory (pairings, preferences, standing instructions) lives in gateway-owned storage. No self-modifying workspace.
7. **Log everything from day one.** Every invocation and tool call recorded — for debugging, for evals, and because the corpus is useful R\&D.

***

## 2. Hardware

**Single box:** one Linux mini-server running Proxmox VE, hosting everything as VMs/containers.

# Component Recommendation Notes Host **Option-dependent (§6).** Option A (local inference): mini-PC/SFF with ≥64GB RAM, 1TB NVMe, GPU ≥24GB VRAM. Option B (cloud inference): N100-class mini-PC, 32GB RAM, 1TB NVMe ($200) GPU exists only to serve local inference; everything else in the stack is lightweight Zigbee/Z-Wave radio USB coordinator (SkyConnect / Zooz 800) Only if sensors on these protocols get added later; USB-passthrough to the HA VM UPS Small line-interactive UPS House brain should survive a blip; HA can monitor it via NUT Voice satellites 2× HA Voice Preview Edition ($60 ea), kitchen + family room to start Ears only; responses route to Sonos (§7.7). Expand room-by-room if it earns it Energy monitor Emporia Vue 3 (\~$150) in the electrical panel Circuit-level usage → cost-aware history queries (§7.8). Electrician or confident-DIY install

**Layout on Proxmox:**
- **VM 1 — HAOS** (Home Assistant OS, official VM image): 2 vCPU / 4GB. HAOS gets its own VM rather than Docker so the supervisor, add-ons, and updates work as designed.
- **VM 2 — Services** (Debian): Hermes agent, the Dobby gateway app (Phoenix), Postgres, and (Option A) Ollama with GPU passthrough. ("Dobby" names both the system and this app — the app is the front door, so the identity collapse is intentional.)

_Alternative if one-box proves annoying:_ HA Green ($99) as a dedicated appliance + compute box for everything else. Decide after a month of running.

***

## 3. Network topology

**One flat, encrypted WiFi network.** The WiFi password is the trust boundary; everyone on the network has flat access to everything on it, including Dobby and device APIs directly.
- Dobby served at `dobby.local` via mDNS (works across Google mesh) + static IP fallback on the QR placard.
- All service traffic (Dobby ↔ Hermes ↔ HA ↔ Ollama) stays on the host's internal bridge; HA's dashboard also exposed on the LAN since everyone's trusted (nice on the kitchen iPad).
- **Zero inbound port forwarding.** Outbound only: model inference, Telegram long-polling, Nest Pub/Sub.
- Remote access for Greg: Tailscale on the services VM. Beach-house HA instance (future) joins the same tailnet.

***

## 4. Software stack

```
┌─────────────────────────────────────────────────┐
│  Clients: browsers on LAN · Telegram (paired)   │
└──────────────┬──────────────────────────────────┘
               │
        ┌──────▼──────┐     Phoenix/LiveView
        │    DOBBY    │     sessions · pairing
        │   gateway   │     invocation log
        └──────┬──────┘
               │ invokes (stateless)
        ┌──────▼──────┐     agent loop + MCP client
        │   HERMES    │────► inference (§6: local or cloud)
        │   (local)   │
        └──────┬──────┘
               │ MCP
        ┌──────▼──────┐     entities · event bus
        │      HA     │     recorder · automations
        └──────┬──────┘
               │ native integrations
     Sonos · Nest · thermostats · lights · …
```

- **Home Assistant OS** — device layer. Official MCP server exposed to Hermes; long-lived access token scoped for it.
- **Hermes (fresh local instance)** — completely separate from the personal cloud Hermes. Own vault, own identity. Credentials: HA token, Telegram bot token, inference API key. _Nothing else_ — no AgentMail/AgentPhone/AgentCard, no 1Password scopes from the personal instance. (Not because guests are threats — because blast-radius hygiene is free.)
- **Dobby** — new Phoenix/LiveView app (§7).
- **Postgres** — Dobby's DB: sessions, pairings, preferences, invocation log.

***

## 5. Device integrations

# System HA integration Path Notes Sonos `sonos` (native, local) LAN discovery, zero cloud Grouping, volume, favorites, TTS announcements ("Dinner!") all local Nest cameras/doorbell `nest` via Google **Device Access** Cloud (Google) One-time $5 registration + GCP project; delivers WebRTC streams and person/package/motion events via Pub/Sub → HA event bus. Powers the FedEx pattern Main thermostat If Nest: same Device Access project. If Ecobee/other: native integration Cloud or local per vendor Heated-floor thermostat **Likely Nuheat (Signature/Home)** — pending verification. HA `nuheat` integration is native (cloud-polling via MyNuheat account); exposes climate entity + schedule hold modes Cloud Verify model from reno paperwork; if it's the newer nVent/Nuheat app generation, confirm the integration still authenticates (community reports vary by firmware) Lighting Lutron Caséta (local bridge) / Hue (local) / whatever the reno installed Local preferred **Action: inventory** Google WiFi Community integrations Limited Presence detection (who's home) is the useful piece Future Zigbee/Z-Wave ZHA / Z-Wave JS Local radio Leak sensors, temp sensors, etc.

**Scope rule (per §1.4):** locks and alarm systems are not integrated even if technically possible. Camera _events and snapshots_ are in scope (delivery pings); consider whether live-stream viewing through Dobby is wanted or whether the Nest app remains the place for that.

***

## 6. Model strategy — two options

Inference is stateless; everything stateful (tools, credentials, preferences, memory) lives in Hermes/Dobby regardless. This choice is about hardware cost, latency, and privacy posture — not architecture. Both options keep the same stack above the model.

### Option A — Local inference

- **Hardware:** the GPU box from §2 (≥24GB VRAM or 64GB Apple Silicon); adds roughly $1.5–2.5k over Option B.
- **Model:** \~30B-class instruct model on Ollama (Qwen3-30B / GLM-Air class as of mid-2026 — choose from the eval, not this doc). Reliable structured tool-calling, <2s first token.
- **Posture:** household utterances never leave the house. Works when the internet doesn't. Optional cloud escalation for hard reasoning stays available but becomes the exception.
- **Costs:** hardware upfront, electricity, and you own model upgrades (quarterly eval re-runs).

### Option B — Cloud inference (Ollama Cloud)

- **Hardware collapses:** an N100-class mini-PC (\~$200, 32GB) runs HAOS VM + Hermes + Dobby + Postgres comfortably. No GPU.
- **Model:** GLM-5.2 (or successor) via Ollama Cloud — same endpoint family the personal cloud Hermes already uses. Frontier-adjacent quality on every request; no router logic needed.
- **Posture, stated honestly:** control plane stays local, but _transcripts_ — everything anyone says to the house — transit Ollama Cloud. Internet outage degrades Dobby to "HA-only smart home" (deterministic automations unaffected, per §8).
- **Costs:** per-token, ongoing. A chatty household is still likely <$20/mo at current pricing; proactive events and the morning brief are the volume drivers to watch.

### Sharing inference with the personal cloud Hermes

Yes — both agents can point at the same Ollama Cloud account/endpoint. The model holds no state between calls, so the agents can't leak into each other through it; the separation that matters (credentials, tools, memory) is enforced upstream in each agent.

One discipline: **same account, separate API keys.** Revoke the house key without decapitating the personal agent; per-agent usage attribution; independent rate limits.

### Recommendation

Start with **Option B** — $200 box, zero model ops, ships weeks earlier. Instrument everything (§10). If the invocation log later shows the privacy or latency itch is real, Option A is a drop-in swap: add the GPU box, point Hermes's model URL at localhost, re-run the eval.

***

## 7. Dobby — gateway spec

Phoenix 1.8 / LiveView. The multi-tenant front: sessions, channels, logging. Radically simpler now that there's no permission machinery.

### 7.1 Web UI

- `http://dobby.local` — chat interface, streaming responses, session-scoped history.
- Device summary tiles (temp, now playing) — HA's own dashboard remains the power-user UI; don't rebuild it.
- Admin view (any household member, honestly): pairing list, invocation log browser, quiet-hours settings.

### 7.2 Sessions & identity

- Session = browser session. Optional first-visit name prompt ("Who's this?") purely for personalization: "my playlist," "set _my_ usual temperature," addressing people by name in the group channel.
- Known devices (phones, kitchen iPad) can be pinned to a name in Dobby's DB. Unknown devices just get asked. No identity → no personalization, but full control regardless.

### 7.3 Telegram channel + pairing

- One bot (BotFather, one-time manual). Dobby runs the long-poll loop and owns the chat-ID whitelist; Hermes never touches the bot admin surface.
- **Pairing flow (proof-of-WiFi-presence):**
  1. `dobby.local` (or the framed QR placard by the door) shows `t.me/<bot>?start=<token>` — single-use token, 10-min TTL, minted per page load, visible only on the LAN.
  2. Bot receives `/start <token>` → Dobby validates → whitelists that chat ID, optionally tied to a name.
  3. Pairings persist until removed in the admin view. (Telegram works from anywhere after pairing — that's the feature: text the house from the office. The proof-of-presence step just ensures only people who've been _in_ the house can pair.)
- Group channel: "#house" group the bot posts proactive events to; DMs for individual control.

### 7.4 Proactive events

- HA automations → webhook to Dobby → Dobby invokes Hermes with event context → Hermes composes message → Telegram.
- Launch set: package/person at door (Nest event), water/temp anomalies, "house is empty but the spa heater is on," morning brief (opt-in per person).
- Rate limits and quiet hours enforced in Dobby, not the model.

### 7.5 Schedules

"Heated floors on at 5:00, off at 9:00" — the defining feature of a house that feels _run_ rather than merely controllable. The architecture rule (per §1.1): **schedules execute in HA, never in Hermes.**
- A schedule is a deterministic thing; it must fire at 5am even if Hermes, inference, or the internet is down. HA's automation engine + schedule helpers are built for exactly this and survive reboots.
- Hermes's role is **authoring, not executing**: conversational schedule management. "Turn the floors on at 5 and off at 9 on weekdays" → Hermes calls HA's MCP/API to create the automation. "What's scheduled for the floors?" → reads it back in plain language. "Skip tomorrow, we're at the beach" → adds a one-time exception.
- The gateway's admin view lists active schedules (read from HA) so there's one place to see what the house does on its own.
- Hermes-side cron (heartbeat-style agent wake-ups) is reserved for _conversational_ recurrences only — the morning brief, a weekly "here's what the house did" digest — where composing language is the job. If the task is "actuate a device at a time," it's an HA automation, full stop.
- Nuheat wrinkle: the thermostat has its own onboard schedule. Pick one owner — either let Nuheat self-schedule and have Dobby only do holds/overrides, or blank the onboard schedule and let HA own it entirely. **Recommend HA owns it** so "skip tomorrow" works conversationally and all house scheduling lives in one visible place.

### 7.6 House PA — Sonos announcements

Dobby speaks through the house. HA's TTS service targets any Sonos zone or group (Sonos pauses music, plays the announcement, resumes).
- Triggers: Telegram → announce ("tell the kids dinner's ready" from upstairs or from the office), proactive events ("package at the front door"), schedule-adjacent nudges ("leave in 10 for practice").
- Zone-aware: Hermes resolves "the kids" / "everyone" / "the kitchen" to Sonos groups.
- Quiet hours from §7.4 apply. Announcement voice = same TTS engine as interactive voice (§7.7) for one consistent house voice.

### 7.7 Voice — talking to Dobby

The primary hands-free interface (chosen over any kitchen-display route). Two paths share one voice:
- **Inbound (interactive):** wake word on a room satellite → HA Assist pipeline (STT → conversation agent → TTS). The conversation agent slot points at Hermes (exposed as an OpenAI-compatible endpoint or custom conversation integration), so voice Dobby _is_ Dobby — same tools, same logging through the gateway.
- **Outbound (announcements):** §7.6, no microphone involved.

**Satellite hardware:** see the voice hardware assessment (companion note). Baseline plan: 2× HA Voice Preview Edition pucks (kitchen + family room, \~$60 each) with audio _output_ routed to the room's Sonos so responses play through good speakers; the puck is ears, Sonos is mouth. Firmware pinned per §8.4 — Voice PE has had wake-word regressions from ESPHome updates.

**STT:** Whisper — local (GPU, Option A) or via HA Cloud / hosted Whisper (Option B). **TTS:** quality ladder in the companion note; default to a modern API voice (OpenAI TTS class) over local Piper — announcements are the personality of the system and robotic voice undercuts it.

**Wake word:** stock options are "Okay Nabu / Hey Jarvis / Hey Mycroft." A custom "Hey Dobby" requires training a microWakeWord model (community tooling exists; nontrivial but very on-theme). Start with a stock word; treat "Hey Dobby" as a stretch goal.

### 7.8 Conversational house history

The recorder (§10) makes the house queryable in past tense: "why was the basement cold Tuesday?", "how many hours did the floors run in January?" Hermes gets a history tool (HA's history/statistics API via MCP).
- **Energy:** add an Emporia Vue 3 (\~$150, panel-installed, HACS integration) so runtime questions become cost questions: "what did the heated floors cost last month?" Circuit-level data → HA Energy dashboard → queryable by Dobby.

### 7.9 Presence intelligence

WiFi presence (phones on the mesh) + Nest events → occupancy state in HA.
- Last-person-out sweep: house empties → check floors/HVAC/lights against policy → act + note in #house ("everyone's out; floors were on, shut them off").
- First-person-home prep: arrival within schedule windows → nothing (schedules own it); arrival outside them → gentle prep or a "want the floors on?" ping.
- Deterministic parts (detect occupancy, run sweep checklist) live in HA automations; Hermes composes the messages and handles exceptions ("leave it on, cleaner's coming").

***

## 8. Reliability & hygiene

Reframed from "security model" — the threats worth engineering against in a convenience system:
1. **Availability.** The house must work without Dobby: physical switches, HA dashboard, vendor apps all keep functioning. Safety-relevant automations (leak → water alert) live in HA's deterministic layer and never depend on Hermes, Dobby, or inference. UPS on the box.
2. **Injection via device data** (a Sonos track title or calendar entry containing instructions). Low stakes given the convenience scope — worst case is weird lighting — but Hermes still treats tool results as data, and the eval suite includes these cases. Costs nothing.
3. **Credential hygiene.** Secrets on the services VM only (sops/age), disk encryption, Tailscale-only SSH. House Hermes shares zero credentials with the personal agent. Separate Ollama Cloud API keys. Worst-case full box compromise yields control of the lights and the thermostat — annoying, not catastrophic — precisely because of the §1.4 scope rule.
4. **Drift.** Pin versions; HA and Hermes update on your schedule. Monthly manual check, not auto-update, for anything in the control path.

***

## 9. Family UX

- Wife/kids acceptance test: the house must work _without_ Dobby (switches still switch; HA dashboard on the fridge iPad; optional Google Home bridge so existing habits keep working).
- Dobby is additive: the conversational layer, the "why is it cold in here," the announcements, the pings.
- One laminated QR placard near the entry: "Talk to the house" → pairing flow. Houseguests get the WiFi password and the placard; that's the whole onboarding.

***

## 10. Data & evals

- **HA recorder** → ground truth of every state change (retain 90d+, Postgres).
- **Dobby invocation log** → every prompt, tool call, model used, latency, outcome.
- Weekly: sample transcripts → grow the eval set; re-run model eval on candidates quarterly (the local-model landscape moves fast, relevant if/when migrating to Option A).
- The corpus remains useful R\&D for multi-principal agent patterns even though Dobby itself no longer needs them.

***

## 11. Build phases (fall)

1. **Weekend 1 — Substrate.** Proxmox, HAOS VM, integrate Sonos + lighting + thermostats + Nest (start Device Access approval early — it's the fiddly one). Family gets the HA dashboard. _Value shipped before any AI exists._
2. **Weekend 2 — Brain.** Hermes with HA MCP against Ollama Cloud (Option B); small tool-calling eval harness; CLI-only Dobby for Greg.
3. **Weekends 3–4 — Dobby.** Phoenix gateway: web chat, sessions, invocation log. LAN-wide soft launch.
4. **Weekend 5 — Channels.** Telegram bot, pairing flow, proactive events, quiet hours, Sonos announcements (§7.6 — small lift, big payoff, do it here).
5. **Weekend 6 — Voice.** Voice PE pucks, Assist pipeline → Hermes, TTS selection bake-off (§7.7), presence automations (§7.9).
6. **Ongoing.** Eval growth, Emporia install + history tooling (§7.8), beach-house HA + tailnet bridge, "Hey Dobby" wake word, Option A migration if the data argues for it.

***

## 12. Open questions

- Nuheat verification: confirm model generation + HA integration auth works with the reno-installed units.
- Lighting system from the reno → local-path integration available?
- Live camera streams through Dobby, or events/snapshots only with the Nest app for viewing?
- Kids get Telegram pairing, or web-only? (Telegram accounts for minors is its own question.)
- Bot discoverability: set privacy mode + obscure username so randoms can't find it (pairing tokens already gate function, but why invite noise).
- TTS engine choice: run the bake-off (companion note) with the family as judges — the house voice is a domestic aesthetic decision, not just a technical one.
- Voice satellite count/placement after the first two rooms prove the pattern.