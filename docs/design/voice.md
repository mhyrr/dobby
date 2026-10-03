# Voice — TK-028

Design, 2026-10-03. Not yet built. Home Assistant was read at 2026.9.4 from
source (`core@dev`). **Sources** has the citations. The ticket's notes keep
the history; this document is the current answer.

## What the house wants

"Hey Dobby, turn the lights off," said in the kitchen, turns off the
kitchen's lights. The words and the reply appear in the one thread, like any
other turn. Nobody opens an app.

Every channel Dobby has today has no place. A browser, an MCP token and a
message do not say which room they come from. That is why the ambiguity
doctrine must refuse "turn the lights on" in a house with six lights. A
microphone in a room is the first input that arrives with a place. The room
is what this design adds to Dobby. The microphone only delivers it.

## The answer

Home Assistant carries the audio. Our own engines turn speech into text and
text into speech. Dobby decides what to do and what to say.

```text
puck: wake word, on the device
  → HA Assist pipeline
      → Parakeet (our container): speech to text
      → custom_components/dobby (in HA): text and room to Dobby
          → Dobby /voice: the thread, the tools, the reply
      ← the reply text
      → Piper or Kokoro (our container): text to speech
  ← puck plays the reply
```

HA's job is to move audio between the puck and our engines. It recognises
nothing and decides nothing. Greg's direction is to rely on HA as little as
possible. This design meets that direction in the engines and the decisions,
and accepts HA as the carrier.

**Rejected: Dobby owns the pucks.** ESPHome satellites (Voice PE,
Satellite1) talk to their host over the ESPHome native API, not Wyoming.
`voice_assistant.cpp` accepts one voice subscriber per device. So Dobby can
own a puck's voice only by taking the puck away from HA. Prior art exists:
Tater in Python, and `espex` on Hex, which has the generated protobuf
modules. But Dobby would have to rebuild these:

- device discovery and the API client;
- the audio stream and end-of-speech detection;
- serving speech as a URL that the puck fetches;
- timers, announcements, follow-up listening, the stop word and LED states;
- compatibility with every ESPHome API change.

That is weeks of work plus upkeep, to own plumbing that does not make Dobby
Dobby. The one thing it would buy is control over speaker identification
(V6). Reopen this decision if speaker identification becomes the point.

**Rejected: Dobby as an OpenAI-compatible endpoint.** HA's OpenAI
integration has no base-URL option. Posing as Ollama works, but the
satellite's area reaches only HA's own tools as `preferred_area_id`. It never
reaches the endpoint. The room is the point, so this route fails.

**Rejected: Webhook Conversation as a stopgap with no Python.** It sends the
device's area, but it misses a satellite entity's area override. It sends no
`satellite_id`, supports only Basic auth, and raises on errors. A raised
error gives the silent red LED (V3).

## Decisions for review

Each decision has a number, so each can be approved or struck on its own.
V1–V9 are the first build. V10 follows it. V11–V14 are deferred or are
facts to plan around.

### V1. HA carries the audio; Dobby owns every decision

HA's Assist pipeline on the puck has three slots, and they are filled like
this:

| Slot | Filled by |
|---|---|
| Speech to text | Parakeet-TDT 0.6B v2, through `wyoming-onnx-asr`, in a container on the Debian VM |
| Conversation agent | Dobby, through `custom_components/dobby` |
| Text to speech | Piper (streams since 1.6.0), or Kokoro if Piper's voice undercuts the personality. Both run in a container on the Debian VM |

The pipeline has no subscriptions and sends no audio off the LAN. The
language model is still cloud, so local engines protect the audio's privacy,
not availability. With the model down, voice is down, as the thread is.

### V2. Two HA behaviours are turned off

1. **"Prefer handling commands locally" is off.** When it is on, HA's own
   intent matcher runs first. A match executes in HA, Dobby never hears it,
   and the change lands on the thread as nobody's doing.
2. **No automation uses a `conversation` (sentence) trigger.** Sentence
   triggers are matched before the conversation agent, whatever the setting
   above says.

The house guide states both as setup steps. Dobby cannot see either
setting, so the guide is the only enforcement. The follow-up turn after a
question skips both routes by itself, because HA sets `_intent_agent_only`.

### V3. The integration carries messages and holds no logic

`custom_components/dobby/` lives in this repo, so one commit changes both
sides. It installs once into HA by copying the folder, or through HACS. It
adds "Dobby" to HA's list of conversation agents. On each turn it does six
things:

1. **It resolves the room** in HA's own order. First it reads the
   `assist_satellite` entity's area, `entity_registry.async_get(satellite_id).area_id`.
   If that is empty, it reads the device's effective area. This is the order
   `assist_pipeline/default_pipeline.py` uses.
2. **It posts to Dobby's `/voice`** with the text, the area id and name, the
   `device_id`, the `satellite_id`, the `conversation_id` and any
   `extra_system_prompt`. HA's `start_conversation` puts its opening
   question in `extra_system_prompt`, so Dobby must receive it to know what
   it asked.
3. **It enforces a deadline of 8 seconds.** HA gives satellite runs no
   conversation-stage timeout. An exception in the agent makes the Voice PE
   show a red LED and speak nothing. On timeout or error, the integration
   returns a spoken response: "Dobby isn't answering." It never raises.
4. **It does not fall back to HA's intents.** Greg's call, 2026-10-03.
   When Dobby is down, the house says so; HA does not act in Dobby's place.
5. **It returns Dobby's reply** for HA to speak.
6. **It sets `continue_conversation` from Dobby's answer.** Dobby says
   explicitly whether it asked a question, and the puck reopens the
   microphone. HA's fallback is to check whether the reply ends in "?".

The closest prior art, `hermes-ha-integration`, has a 951-line
`conversation.py`. This integration does less than that one, but the
ticket's estimate of 150 lines was low.

**Auth.** The integration sends a bearer token minted on `/admin`, like an
MCP token. Holding the token proves the caller is the house's HA. The token's
label, for example "home assistant voice", is what the activity feed shows.
The room names the speaker (V6). The token does not.

**Two layers of failure.**

- Dobby unreachable: the integration speaks the fixed line, and nothing
  reaches the thread, because nothing reached Dobby.
- Dobby up but its model down: `/voice` answers in time with the reply the
  thread already gives when the model fails, and the turn is in the
  thread.

### V4. The room rides on the utterance and in the per-turn context

- `Dobby.Utterance` gains `room`. `channel: :voice` is already in its type.
- A device in the house file gains `room:`, an HA area id. Discovery fills
  it from HA's area registry, so nobody retypes it. The convention that a
  device id reads `type:place` stays a convention; `room` is the fact.
- The room goes in the context the request transformer injects before the
  utterance. It is never appended to the utterance. `Jido.AI.Test.ReActScript`
  matches the last user message exactly, and the context block is where the
  house already goes.
- A doctrine line in code: a request spoken in a room refers to that room's
  devices unless it names another room or the whole house. "The lights" from
  the kitchen puck means the kitchen's lights. "The thermostat" from a room
  with none still gets a question.

The room is context only. No device agent, tool or permission changes per
room.

### V5. Every voice utterance posts to the thread

What the house heard is on the thread, including a mishearing. A misheard
"turn off the heat" must be visible. That visibility is also how the house
learns how accurate the transcription is, without a separate log.

### V6. The speaker is the room

HA gives a satellite run no user: `Context()` has `user_id` None. HA closed
its proposal to add speaker recognition to the pipeline (architecture
#1223, Nov 2025). The thread shows `[kitchen] lights off`. A person who
wants their name on a request says it.

Community speaker-recognition proxies exist (`speaker-recognition`,
Murdock) and publish no accuracy figures. If one is added later, its result
is a hint for personalisation. It never gates an action, as `speaker` never
does.

### V7. A spoken reply is speech-safe, in code

On `channel: :voice`, code renders the reply for speech before it leaves
`/voice`. It removes markdown, list markers and asterisks. A Feb 2025 review
of the Voice PE has Piper reading "asterisk" aloud repeatedly. The doctrine
also asks for short spoken replies, but the strip is in code, because a rule
the model can forget is not a guarantee.

### V8. Spoken names are normalised before exact matching

Decision M11 makes "play Summer 26" match a favorite exactly. Parakeet may
write "summer twenty six". The resolver normalises both sides before it
compares them: number words to digits, and punctuation and case removed. The
same applies to device names and aliases. The model passes the words it
heard. It never corrects them.

### V9. The latency is the model's, and streaming hides little of it

| Stage | Expected |
|---|---|
| Wake word | ~0.3 s |
| Speech to text, Parakeet on the N100 | under 1 s (estimated, not measured) |
| Dobby turn, two model calls | 1.7–2.7 s (measured) |
| First speech chunk | ~0.3 s |

About 3–4 s to the first spoken word. Alexa takes about 1.5 s.

HA streams speech only after the reply passes 60 characters
(`STREAM_RESPONSE_CHARS`). "Kitchen lights are off." is shorter, so the full
reply waits for the model. `/voice` streams anyway, for long answers. The
lever for short replies is in the model turn: prompt caching and a one-turn
reply path (design §6.5).

### V10. The puck is a device type, and it pauses the room's music on wake

A puck is a `voice_satellite` in the library, bound to its
`assist_satellite.*` entity, with a `room`. It has no tools for the model;
its state is `idle`, `listening`, `processing` or `responding`.

The XMOS echo cancellation removes only the puck's own audio. A Sonos playing
in the same room is noise to it. So when a puck goes to `listening`, Dobby
pauses every playing speaker in that room. When the puck returns to `idle`,
Dobby resumes the speakers it paused. It resumes a speaker only if that
speaker is still paused; a speaker somebody started, stopped or changed in
between is left alone. If the reply itself changed the music, as "play
Summer 26" does, that command wins and nothing is resumed. No model is
involved. The command takes the direct control path, as a card tap does.

Pause, not a lower volume: Greg's call, 2026-10-03. The house plays
playlists, which resume where they paused. A paused radio station resumes
live, which is acceptable for a house that rarely plays one.

The pause writes no thread line. It is the house's own reflex, not
somebody's request, and a line per wake would bury the thread. The
confirmation seam must treat the pause and the resume as Dobby's own
commands, so neither reads as somebody's hand.

This works whoever owns the pipeline, which is part of why it is Dobby's
job and not an HA automation.

### V11. Timers are HA's timers, handed back to HA — deferred

Greg's call, 2026-10-03. HA's timers belong to the puck: the puck counts
down, rings, and shows the time on its light ring. Dobby does not rebuild
them. With local handling off (V2), "set a timer for ten minutes" reaches
Dobby, and Dobby passes it back.

The house does not use timers, so this is not in the build order. It is
tracked as GitHub issue #27. Until then, a timer request is an ordinary
refusal: Dobby says it cannot set timers.

**Unverified: the mechanism.** HA has no service that starts a timer on a
given puck. The only entry is the `HassStartTimer` intent family, bound to a
`device_id`. Two candidates:

1. Dobby's answer to `/voice` carries a timer handoff, and the integration
   runs the intent in HA with the satellite's `device_id`. This puts one
   narrow job in the Python.
2. Dobby runs it over the WebSocket, if HA's `conversation/process` or the
   intent API accepts a `device_id`. That keeps the integration free of
   logic, but the source has not been read for it.

Read the source before choosing. Either way, a timer writes a thread line,
and the model extracts the duration while code computes the end time.

### V12. Announcements are opt-in, and separate

Saying something out loud without being asked is the owner's choice, per
household. One example is announcing a doorbell ring (TK-014). The mouths
are the Sonos, through `tts.speak` with `announce: true`, and the pucks,
through `assist_satellite.announce`. Both are HACalls Dobby can own. This is
TK-025's design, not this one's.

### V13. The wake word starts as "Okay Nabu"

Day one runs the stock firmware and the stock word. "Hey Dobby" comes after
the pipeline works. A community trainer now exists for Apple Silicon:
TaterTotterson's microWakeWord-Trainer-AppleSilicon. It has a web UI,
generates samples with several TTS engines, and retrains with false wakes as
hard negatives. Expect an evening to a first model, then two to four weeks of
tuning.

The cost: a custom word means building the firmware with ESPHome Builder, and
the puck leaves Nabu Casa's automatic update track. Pin the firmware version
from then on, because Voice PE wake-word behaviour has regressed across
ESPHome updates before.

### V14. What stays out, and where it goes

- **Sonos as the voice of replies.** HA routes the reply to the puck that
  heard you. Sending replies to a Sonos is a community workaround (HA
  discussion #689 is open). Replies come from the puck; announcements may
  come from the Sonos (V12).
- **`ask_question`.** It cuts the pipeline after speech to text and hands
  the answer to an automation, so Dobby never sees it. It may suit a later
  yes/no confirmation that needs no model.
- **Speaker identification.** V6.
- **Per-room tools or room agents.** V4.
- **Dobby-owned audio.** "The answer".

## Hardware

Hardware problems are tested on real hardware, when it is in the house.

- **Rooms where people talk to Dobby:** FutureProofHomes Satellite1.1 Smart
  Speaker, $132.99, assembled. It has four microphones, though the firmware
  uses two today, and a 25 W amplifier with a woofer and tweeter. It is
  backordered until about 2026-11-11.
- **Now, to build and test against:** one Home Assistant Voice Preview
  Edition, $69. It is still the reference device; firmware 26.9.0 shipped on
  2026-09-17. Its weaknesses are a 3 W speaker and middling pickup across a
  room.
- **If pickup across a room is the problem:** the Seeed reSpeaker XVF3800.
  Its four microphones beamform today, and it is rated to about 5 m. It is a
  dev board in a case and needs an external speaker.

The Proxmox box changes only by gaining the speech containers on the Debian
VM. It needs no GPU and no USB device.

## What the house needs

1. Parakeet and Piper containers running on the Debian VM, each added in HA
   as a Wyoming service at host and port.
2. An Assist pipeline in HA. Speech to text is Parakeet, the conversation
   agent is Dobby, text to speech is Piper, and "Prefer handling commands
   locally" is off.
3. Each puck assigned to that pipeline and given an HA area.
4. No automation with a `conversation` trigger.
5. A `/voice` token minted on `/admin` and pasted into the integration's
   setup.

**Try this first, before any build.** Speech-to-text accuracy is the one
thing that would make the design worthless, and it can be measured without
a puck or HA. Each person in the house records 30–40 real commands on a
phone, in the kitchen, with the Sonos playing. Run the clips through
Parakeet on the real box. Compare the transcripts with what was said, and
note the names, numbers and anything said over music.

## Tests

The Fake must move what HA moves:

- the satellite's state goes `idle` → `listening` → `processing` →
  `responding` → `idle`;
- a paused speaker pauses and resumes.

Replay scenarios, each asserting the thread's lines:

- a voice turn posts `[kitchen] …` and Dobby's reply;
- "turn off the lights" from the kitchen turns off only the kitchen's
  lights;
- "turn off the lights in the den" from the kitchen turns off the den's;
- "the thermostat" from a room with none asks;
- "summer twenty six" plays the favorite "Summer 26";
- a reply with markdown reaches `/voice`'s response as plain speech;
- wake in a room with a playing speaker pauses it, writes no line, and
  resumes it;
- a speaker somebody starts or changes during the pause is not resumed
  over;
- "play Summer 26" spoken over paused music plays Summer 26 and resumes
  nothing;
- `/voice` without a valid token is refused.

The Python integration gets its own small test suite with HA's
`pytest-homeassistant-custom-component`. It tests the area order, the
deadline that returns speech, and `continue_conversation`.

Eval tier, which needs Greg's go-ahead to spend:

- "turn off the lights" from the kitchen must not turn off the house;
- "the thermostat" from a room with none must still ask;
- the model passes heard words unchanged and does not "correct" a name;
- a question in the reply sets the continue flag.

## Build order

These are layered commits. Each is green on its own with `mix precommit`.

0. **The recording test above**, on the real box. It is not a commit, but
   it comes first.
1. **Rooms.** `room:` on devices, discovery filling it from HA's areas, the
   house guide's row for it.
2. **The room in the turn.** `Utterance.room`, the context block, and the
   doctrine line from V4.
3. **`/voice`.** The endpoint, the token, speech rendering (V7), name
   normalisation (V8), and the continue flag.
4. **The integration.** `custom_components/dobby/` and its tests.
5. **The puck as a device type, and the pause.** `voice_satellite` with its
   contract test, and V10.
6. **The guide.** A voice page in `docs/`: the pipeline setup and the two
   settings from V2.
7. **One eval run**, approved first.

Then the first real-hardware walk: wake reliability over music, pickup
across the kitchen, and the latency in V9 as measured on the box.

## Settled

2026-10-03:

- HA carries the audio; Dobby owns every decision; the engines are ours.
- When Dobby is down, the puck says "Dobby isn't answering", with no HA
  fallback.
- Timers are HA's and are handed back to HA, later (#27).
- The room's music pauses on wake and resumes after.
- Every voice utterance posts to the thread; the speaker is the room; the
  room is context only; the Python lives in this repo.
- Hardware issues are tested on real hardware.

## Sources

Home Assistant `2026.9.4` (`core@dev`), `homeassistant/components/`:

- `conversation/models.py`: `ConversationInput` (text, context,
  conversation_id, device_id, satellite_id, language, agent_id,
  extra_system_prompt) and `ConversationResult.continue_conversation`.
- `conversation/chat_log.py`: `async_add_delta_content_stream`, and the
  "ends with ?" continue heuristic.
- `assist_pipeline/default_pipeline.py`: `_get_all_targets_in_satellite_area`,
  the area order; `recognize_intent`, local intents first and sentence
  triggers always; `_intent_agent_only` on follow-ups.
- `assist_pipeline/const.py`: `STREAM_RESPONSE_CHARS = 60`,
  `DEFAULT_PIPELINE_TIMEOUT = 300`.
- `assist_satellite/entity.py` and `services.yaml`: `announce`,
  `start_conversation`, `ask_question`.
- `esphome/assist_satellite.py`: `satellite_id` from `self.entity_id`, and
  no user context.
- `helpers/llm.py`: device area used only as `preferred_area_id`.
- `openai_conversation/config_flow.py`: no base-URL option.

ESPHome and devices:

- `esphome/components/voice_assistant/voice_assistant.cpp`: one voice API
  subscriber.
- github.com/esphome/home-assistant-voice-pe, `home-assistant-voice.yaml`:
  `on_error` shows the LED and speaks nothing; ducking applies only to the
  puck's own mixer.
- github.com/rhasspy/wyoming-satellite: archived 2026-01 and replaced by
  linux-voice-assistant, which speaks the ESPHome API.

Prior art:

- github.com/WolframRavenwolf/hermes-ha-integration: area as prompt text,
  spoken errors, and advice to turn off local handling.
- github.com/EuleMitKeule/webhook-conversation.
- github.com/TaterTotterson/Tater: owning the pucks with no HA.
- hex.pm/packages/espex: the ESPHome native API in Elixir, device side.
- github.com/TaterTotterson/microWakeWord-Trainer-AppleSilicon.
- github.com/chiabre/wyoming-onnx-asr: Parakeet over Wyoming.
- github.com/home-assistant/architecture/discussions/1223: speaker
  recognition, closed.
- michaelsleen.com/voice-pe-sat1-echo (Feb 2025): its failures came from the
  conversation layer, not transcription.

Hardware:

- home-assistant.io/voice-pe
- futureproofhomes.net/products/satellite1-smart-speaker
- seeedstudio.com/ReSpeaker-XVF3800-With-Case-XIAO-ESP32S3-p-6628.html
