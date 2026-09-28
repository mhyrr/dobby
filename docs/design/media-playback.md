# Music on the speakers — TK-029

Design, 2026-09-26. Not yet built. Home Assistant was read at 2026.9.3 and
Music Assistant at 2.10.4, from source; **Sources** has the citations.

## The house this is for

Greg's house, as of 2026-09-26:

- Sonos on S1, because the speakers are old. It is controlled directly from
  the Sonos app. There is no Music Assistant.
- YouTube Music, added to Sonos as a service, supplies almost everything.
- Greg's path in the app is Browse → YouTube Music → Library → Playlists →
  "Summer 26" → shuffle. Rooms and each room's volume are set in the app.

What the house wants: "Hey Dobby, play Summer 26." When a mood is asked
for, as in "play some chill music", Dobby picks from the house's own music.
Nothing in this is YouTube Music–specific. A Spotify house works the same
way.

## The answer to the ticket

Music stays on `speaker`. It does not earn a media-provider abstraction.

Dobby never talks to YouTube Music, Spotify or TuneIn, so it needs no layer
that knows them. Home Assistant offers a speaker two kinds of thing to play:

1. **The house's own names: Sonos Favorites.** Somebody adds a playlist,
   station or album to Sonos Favorites once, in the app they already use.
   Sonos pushes every favorite and every Sonos playlist to HA in the
   speaker's `source_list`. Dobby learns the list the way it learns volume:
   pushed, never asked for. `media_player.select_source` plays one by title.
   The favorite carries its own service, so "the house uses YouTube Music"
   never has to be configured.
2. **An open catalog, through Music Assistant.** It is designed below (M4)
   and deliberately not built. Greg's house does not run Music Assistant,
   and favorites cover what the house asked for.

"Load everything into Dobby" is the favorites list. Dobby cannot reach a
YouTube Music library by itself: HA cannot browse a streaming service's
catalog through Sonos, only favorites and a local library. A list kept by
hand in the house file could point only at favorites, and it would drift the
first time somebody renamed one in the app.

## Decisions for review

Each decision has a number, so each can be approved or struck on its own.
M1–M3, M5 and M11–M12 are the first build. M6–M10 follow from them. M4 is
the deferred catalog.

### M1. The house's names come from `source_list`, and play through `select_source`

The speaker keeps `sources`: the titles in its `source_list` attribute, in
HA's order. On Sonos that list is:

1. Line-in or TV, where the model has them.
2. Every favorite.
3. Every Sonos playlist (since HA 2025.6).

A favorite can be a playlist, a station, an album or a podcast. Sonos
resolved it when somebody saved it, through the service account in the
Sonos app. This works on S1: HA's Sonos integration speaks UPnP to both
generations.

`select_source` is a standard `media_player` service behind the
`SELECT_SOURCE` feature bit. An AV receiver uses the same verb for "switch to
the turntable", so nothing here has a Sonos shape. A speaker whose
integration reports sources can play them. A speaker that reports none has
none, for example Cast.

**Each source also has a kind**: playlist, station, album, track, podcast or
other. `source_list` carries only titles. HA's browse tree for a speaker
groups favorites into one folder per kind. The **HA client** reads that tree
in the background at two moments: when it connects, and when a speaker's
`source_list` changes. It hands the kinds to the speaker agents as a signal,
the way it hands them state. This is the same pattern as the entity
registry, which the client fetches on connect and refetches when HA pushes
`entity_registry_updated`. The conversation never waits on it, and nothing
above the boundary asks.

Rules for the background read:

- Favorites belong to the whole Sonos household, so one browse serves every
  speaker that reports the same list.
- The client asks for the favorites node by name
  (`media_content_type: "favorites"`). Sonos's browse root collapses into its
  only child, so the root's shape cannot be trusted.
- A failed or partial read leaves the kinds unknown. An unknown kind never
  blocks a play; it only switches off M12's shuffle default for that
  source.

Rejected: binding `sensor.sonos_favorites` for the `FV:2/n` ids and playing
with `favorite_item_id`. That needs a second binding, to a sensor HA
disables by default, and it is Sonos-only. The ids also buy nothing a person
can say. Two favorites with one title cannot be told apart by voice, with or
without their ids.

### M2. Code resolves; the model only extracts the words

`speaker_play_music` takes the name the person used and, when they said it,
a kind ("the Summer 26 **playlist**"). Its schema has no field for an id or a
URI, so the model has nothing to invent. The tool description tells the
model to pass the name alone. A word like "playlist" goes in `kind`, where it
filters by the kinds from M1 when those are known.

The speaker agent resolves the name against its own `sources`, with no
network:

1. **Normalize** both sides. Case-fold, trim, collapse whitespace, strip
   punctuation. "Summer '26" and "summer 26" are one name. Nothing more: no
   stemming, no dropping "the", no fuzzy distance.
2. **Exactly one normalized match: play it.**
3. **Two sources with one title are refused, and the refusal says why.**
   Sonos refuses this too: `select_source` needs exactly one match. Dobby
   refuses first so the reason is the house's, not an HA error. The fix is a
   rename in the Sonos app, and the refusal says so.
4. **No exact match is a question.** The candidates are the sources whose
   normalized title contains every word of the request, at most five. "Play
   Summer" against "Summer 25" and "Summer 26" is a question, not a pick.
5. **No candidates either: refuse and name nothing.** The model says there
   is no favorite by that name. It does not offer the nearest thing.
   M11 covers requests that hand Dobby the choice.

The model may call again with a candidate's exact title. That is an exact
match under rule 2.

The rule is containment, not similarity. A similarity threshold is a number
somebody tunes until it quietly picks wrong.

A "no such favorite" refusal is written to the activity record with the
words asked for. The count of those rows is the evidence for or against
building M4.

### M3. Which speaker is the model's question, as for every device

"In the kitchen" resolves to a speaker id from the roster, the way "the
thermostat" resolves today. In a house with two speakers, a request with no
room is a question. There is no default speaker. TK-028 will supply the room
of the voice satellite that heard the request. That is where a default
belongs, and it arrives as context, not as a setting here.

### M4. The open catalog: designed, deferred

**Status: not built.** Revisit when the activity record shows the house
asking for music that isn't a favorite. M2 records those refusals.

The catalog is **Music Assistant**, in HA core. It is the only core path to
the streaming services' catalogs and to internet radio. It holds the
credentials, and it can search.

**Not now for Greg's house.** It would need three moving parts to replace
one tap per playlist in the Sonos app:

- the Music Assistant server;
- its YouTube Music provider, which is beta, because YouTube Music has no
  official API;
- its S1 Sonos provider, which Music Assistant's own docs advise against
  running alongside HA's Sonos integration.

**If it is built, it is search first, then play by exact id.**

- **Rejected: hand the words to Music Assistant.**
  `music_assistant.play_media` accepts a plain name and fails open. It tries
  an exact library match first. Then it runs a global search, and **the
  first hit plays**. With no `media_type`, the first hit is a track, so
  "Miles Davis" plays one song. An id that does not verify falls back to a
  name search on the id string itself, so an invented id can still play
  something. Nothing reports what was chosen.
- **Rejected: HA's own `HassMediaSearchAndPlay`.** It plays `results[0]`,
  with no disambiguation.
- **Rejected: core `media_player.search_media` as the contract.** Its results
  carry no separate artist or album, so "which Yesterday?" cannot be asked
  in words. Radio from Music Assistant comes back with class `music`. Native
  Sonos advertises `SEARCH_MEDIA` too, since 2026.6, while searching only
  the local library.
- **Chosen:** `music_assistant.search` returns typed items (`media_type`,
  `uri`, `name`, `artists`, `album`). M2's rules pick one or ask; the
  catalog also accepts `artist` and `album`, and drops trailing qualifiers
  such as "(Remastered 2009)" when comparing. Duplicates from two providers
  collapse to one, with the library item preferred. The agent then plays
  that item with `music_assistant.play_media`, the exact `uri` as
  `media_id`. The id goes from HA's answer to the agent within one tool
  call. It never passes through the model.
- A favorite with the same name as a catalog item wins, because the house's
  own name is the stronger claim.
- **No release year exists in HA's responses.** "The new Taylor Swift
  album" is a question asking for the album's name.

**The cost: the first time code above the boundary asks HA a question
mid-request.** The `Dobby.HomeAssistant.entities/0` moduledoc forbids this
today. Building M4 needs, in its own commit:

- a decision under `docs/decisions/`, with what it rejected (§13 is closed at 28);
- one typed callback, `search_catalog/2`. It is not a general
  service-with-response call.
- a five-second limit, with a timeout reported as a refusal ("the music
  catalog did not answer");
- conversation path only, never cards or schedules;
- the search runs in the tool's process, never in a device agent.

The catalog binding would name the `music_assistant` integration, because
it is that integration's service being called. HA offers no capability bit
that means "has a catalog", and native Sonos's `SEARCH_MEDIA` bit proves it.

The speaker would gain an optional `catalog` binding to the Music
Assistant player entity for the same speaker. Music Assistant makes that a
separate HA device, so discovery must never propose it as a second speaker.
Discovery would offer it as `catalog` for the one native speaker with the
same normalized name, or offer nothing. The client would add
`config_entry_id` from the entity registry it already fetches.

### M5. Arrival is movement, not the thing asked for

Home Assistant never echoes the request:

- After a favorite plays, `media_content_id` is the first track's URI, never
  `FV:2/n`.
- `media_title` is the first track, not the favorite's name.
- `source` is set only for AirPlay, TV, Line-in and Spotify Connect.
- Radio is the one partial exception: `media_channel` carries the station
  name.

So `command_arrived?/2` for a source play works like this:

1. The accepting action records the speaker's `media_content_id` and
   `playback` in the command.
2. Any later snapshot counts as the echo when playback is `:playing` and
   either the content id differs or the speaker was not playing before.

**Known edge.** Asking for the favorite that is already playing, on its
first track, moves nothing, and reads NOT KNOWN. That is honest: the house
cannot tell a restart from nothing. TK-041's hardware walk measures how often
it happens before anybody engineers around it.

**Errors that report success.** Sonos swallows UPnP errors 701, 711 and 712
and returns success. Pausing a stream that cannot pause returns `:ok` and
never moves. The confirmation seam already handles this: no echo inside the
deadline writes NOT KNOWN beneath the reply. It needs a test, not new code.

Volume needs no new rule. Sonos stores an integer 0–100 and echoes `n/100`.
`round(level * 100)` returns the integer Dobby sent.

### M6. The thread says what Dobby commanded; hands stay silent

The 2026-08-23 call stands: a hand on the speaker never reaches the thread.
HA still cannot tell the Sonos app from a button, and a speaker moves on
every track. `intervention?/1` keeps returning false.

Dobby's own commands still write lines. `Turn`, `Controls` and the schedule
watcher write one for every accepted command, whatever `intervention?/1`
says:

    · KITCHEN SPEAKER   SET Summer 26     — greg
    · KITCHEN SPEAKER   SET 30%           — greg, card
    · KITCHEN SPEAKER   SET WNYC          — schedule "weekday radio"

The value is the title of the favorite the command named. There are three
callers. A tool call renders from its accepted result, a card from the
moved value (`controls.ex:176`), and a schedule from the action's own
arguments (`interventions/watcher.ex:484`). The play action's argument and
its accepted result therefore both use the key `:media`, and
`Interventions.reading/1` gains `:media` ahead of `:playback`. One key gives
one word on every path.

The card's flap keeps showing the observed `media_title`, which is the
track. The line says what was asked for, and the card says what is playing.
That split is the existing rule, "reports what it commanded, never what it
observed", applied to music.

### M7. Favorites are on the card and in schedules, with no model

The direct control path is first-class, so the family's favorites belong on
the card. `Speaker` gains `controls/1`:

- a play/pause choice, when the speaker reports those features;
- a volume fader, 0–100, step 1;
- a source choice with the favorites as options, drawn "a tap away" the way
  the appliance cards draw long lists.

Sonos does not report which favorite is playing, so the source choice has no
current value. It is an action row, not a state row.

`scheduled_actions/0` gains `play`, `pause`, `set_volume` and `play_source`:

- A schedule stores the favorite's *title* and resolves it when it fires,
  against the speaker's `sources` at that moment.
- A renamed or deleted favorite fires as HELD with the reason ("no favorite
  called WNYC any more"), in the thread, with no model call.
- "WNYC in the kitchen at seven on weekdays" is an alarm clock the house
  keeps while the model is down.

A card tap and a schedule use M12's shuffle default exactly as a spoken
request does, because the default belongs to the house, not to the path.

### M8. Grouping is its own command on the leader

"Kitchen and living room together" is `media_player.join` on the leader, with
the others as `group_members`. HA makes the leader the Sonos coordinator,
and a play command on any member then plays for the group.

The tool reads each member's snapshot and passes the member's entity id,
integration platform and grouping capability to the leader's action. The
leader validates:

- every speaker is available and reports the `GROUPING` feature;
- every speaker shares the leader's `platform`, from the entity registry the
  client already holds. A Sonos and a Cast speaker cannot join, and HA says
  so only as `entity_not_found`;
- the leader is not asked to join itself.

**Group and play are two tool calls, not one.** An HACall runs inside the
device agent's process and holds it for the length of the call
(`lib/dobby/directives/ha_call.ex:40-44`). `join` does not return until HA
sees the new topology, which can take up to 30 s. A slow join would hold
the leader past the point where a play queued behind it gets the "not
answering" refusal. A normal join takes about a second. TK-041 measures it.

`speaker_ungroup` is `media_player.unjoin` on one speaker.

The snapshot gains `group`: the entity ids in `group_members`. HA writes the
same list on every member, coordinator first. The join echo is a leader
snapshot whose `group` holds every requested member. The unjoin echo is a
`group` of one.

Volume stays per speaker, because HA has no Sonos group volume. That matches
how the house uses the app today: rooms first, then each room's volume. On
a group, "turn the music down" is one volume command per member. The model
decides which speakers the person meant, the question M3 already answers.

### M9. "Turn it up" is a direction; code picks the number

"Turn it up" is the most common thing anyone says to a speaker. Today it asks
the model for arithmetic: read 30%, decide 40%. That breaks "the model
never does arithmetic" as surely as a setpoint would.

`speaker_nudge_volume(device, direction)` takes `up` or `down`. The agent
moves its own `volume_percent` by a fixed step, clamps it to 0–100, and emits
`volume_set`. The step is type knowledge held in the agent: **10 points**,
unless Greg picks otherwise. HA's own `volume_up` steps Sonos by 2, which
nobody hears as "turn it up". A speaker that has not reported a volume
refuses the nudge. It does not guess where it started.

An absolute number ("volume 25") still goes through `speaker_set_volume`.

### M10. What stays out, and where it goes

- **Announcements**: `announce: true`, TTS and doorbell chimes. Sonos plays
  them over a WebSocket API that exists only on S2, and they change no
  state, so the command has nothing to confirm against. They belong with
  the voice work in TK-028.
- **Next and previous track** are in scope as `speaker_skip(device,
  direction)`. The echo is `media_content_id` moving.
- **Queue editing**, such as "play this next", is out. Sonos ignores
  `enqueue` for favorites and playlists. No house has asked.
- **Repeat, sleep timer, alarms, snapshot and restore** wait until a house
  asks.
- **The local music library** waits until a house has one worth searching.

### M11. "Play some chill music" hands Dobby the choice, and it chooses from the favorites

"Play Summer 26" names one thing, so code must find exactly that thing, and
ask when several match (M2). "Play some chill music" names no thing. It
hands Dobby the choice. **Guessing which thing somebody meant is forbidden.
Choosing when somebody asked Dobby to choose is allowed.** The doctrine gains
a line that says this, and the play tool's description repeats it.

How the choice is made:

1. The model reads the speaker's sources through `speaker_get_status`. Each
   source has its title, its kind (M1), and the house's description of it,
   if there is one.
2. It chooses one favorite that fits the request.
3. It plays that favorite by its exact title through `speaker_play_music`,
   which is an exact match under M2.
4. It says which one it chose: "Putting on Sunday Morning in the kitchen."
   The thread line names it too, so "no, something else" is one sentence
   away.

The model can choose only from the speaker's own list. A choice it makes is
a title it read, never a title it made up.

**The house describes its favorites in its own words.** Titles alone do not
carry mood: "Dinner Jazz" suggests chill, and "Summer 26" says nothing about
it. The house file gains a `music` block under `house`:

```yaml
house:
  music:
    shuffle: playlists          # M12. Absent means never.
    favorites:
      Summer 26: upbeat, summer, good for a party
      Dinner Jazz: chill, dinner
      Sunday Morning: chill, quiet, coffee
```

- A description is context for the model. Code never interprets it.
- Keys match favorite titles by M2's normalization.
- A description for a favorite that no longer exists is ignored and flagged
  on `/admin`, so drift is visible rather than silent.
- A favorite with no description is chosen on its title alone.
- Dobby cannot see what is inside a playlist, so a description is the only
  way to tell it.

The block lives under `house` because Sonos Favorites belong to the whole
household, not to one speaker. It is written, like the rest of the house
file, only through `Dobby.HomeConfig.Writer`. The first build reads it; an
editor on `/house` can come later.

Sources and their descriptions stay out of the house block the model sees on
every turn. A household can have fifty favorites, and TK-032 already counts
what that block costs. The model reads them on the turns that need them.

### M12. Playlists shuffle when the house says so

The house shuffles playlists out of habit. `music.shuffle: playlists` makes
that the default. A spoken "in order" or "on shuffle" overrides it through
the play tool's optional `shuffle` argument.

The default applies only to sources whose kind is `playlist`. Shuffling a
station fails silently on Sonos, with UPnP 712 and no echo, so a shuffle
sent to a station would only ever read NOT KNOWN. A source whose kind is
unknown plays in order.

A shuffled play is **two HA calls from one action**: `select_source`, then
`shuffle_set`. They leave in order from the agent's directive drain, and
`select_source` returns only after Sonos has loaded the queue. So the
shuffle lands on the new queue. Each call needs its own expectation:

- `HACall` gains an optional `command` field. `ha_call.ex` builds the
  expectation from it when present, and from `last_command` as today when
  absent.
- The shuffle's command gets its own ref, derived from the play's ref.
  Its echo is `shuffle == true`.
- `Interventions.reading/1` renders it as "Shuffle on", so a shuffle that
  never arrives reads `NOT KNOWN Shuffle on` beneath the play's line.

This is one action rather than two tool calls, unlike M8, for two reasons.
Cards and schedules fire exactly one action, and the default must hold on
every path. `shuffle_set` is also fast, where `join` can block for 30 s.

One difference from the Sonos app: a shuffled play starts on the playlist's
first track, because HA starts the new queue at position 0. The rest plays
in random order. TK-041 can decide whether that matters.

## The tool surface

The closed set after the first build. New tools are marked ✚, and changed
tools are marked △.

| Tool | Arguments | HA call | Echo |
|---|---|---|---|
| `speaker_get_status` △ | device | none | none. Adds `sources` (title, kind, description) and `group`. |
| `speaker_play` | device | `media_play` | `:playing` |
| `speaker_pause` | device | `media_pause` | `:paused` |
| `speaker_play_music` ✚ | device, what, kind?, shuffle? | `select_source`, then `shuffle_set` when shuffling | playing, and media moved (M5); `shuffle` true |
| `speaker_set_volume` | device, volume_percent | `volume_set` | exact percent |
| `speaker_nudge_volume` ✚ | device, direction | `volume_set` | exact percent |
| `speaker_skip` ✚ | device, direction | `media_next_track` / `media_previous_track` | content id moved |
| `speaker_group` ✚ | device, with | `join` | `group` ⊇ requested |
| `speaker_ungroup` ✚ | device | `unjoin` | `group` of one |

`kind` is a closed enum: `playlist`, `station`, `album`, `track`, `podcast`.
M4 would add `artist` and `album` arguments. They are left out until then,
so the schema does not promise what the house cannot do.

Each new tool is one `Jido.Action` added to the literal `tools:` list in
`Dobby.DobbyAgent`. The MCP door gets the same set.

## What the house needs

1. **Home Assistant on the LAN.** Sonos is `local_push`: the speakers call
   HA back on TCP 1400, which Docker on macOS cannot receive. This is the
   Proxmox HAOS VM (design §12, Phase B).
2. **The playlists the house plays, added to Sonos Favorites.** In the app,
   use the "…" menu on the playlist. Do this once per playlist. A new
   playlist is not playable by name until it is favorited.
3. **Descriptions, optionally**, in `house.music.favorites`, for the
   favorites whose titles do not say what they are.

**Try this first, before any build.** The one thing the source cannot
prove is whether HA can start a YouTube Music playlist favorite on an S1
speaker. The code path clears the queue, adds the favorite and plays it,
which should work for a service playlist. It has not been seen to.

1. Once HA sees the speakers, open Developer Tools → Actions.
2. Call `media_player.select_source` on one speaker with
   `source: Summer 26`.

If it plays, the first build works for this house as designed. If HA
returns an error, the favorite route fails for this service, and the design
needs another route before any code is written. The error most likely to
appear is UPnP 800, "music service unavailable".

## Tests and fixtures

The Fake must move what a real speaker moves. Otherwise the tests prove the
wrong echo.

- `select_source` sets the speaker playing, with a content id that differs
  from before. It does not set `source`, which a real Sonos leaves alone.
- `shuffle_set` sets `shuffle`. On a source seeded as a station, it
  changes nothing and still returns `:ok`, as a real Sonos does.
- `join` and `unjoin` rewrite `group_members` on every member.
- The rig's speakers seed a `source_list` with two playlists that share a
  word, a station, a Line-in, and two favorites with one title. The Fake
  client seeds their kinds. The real client's background browse is tested
  against `Dobby.HAServer`, like the registry refetch: on connect, and on a
  `source_list` change.

Every new write supplies `arrivals:` triples to `device_agent_contract`.

Replay scenarios, each asserting the thread's lines, not flags:

- a named favorite plays, and the line reads `SET Summer 26`;
- "Summer '26" matches "summer 26";
- two favorites with one title are refused, with the rename reason;
- a containment match is a question, and the exact follow-up plays;
- no favorite matches, and the refusal is recorded with the words asked
  for;
- a playlist shuffles under `shuffle: playlists`, a station does not, and a
  source of unknown kind does not;
- "in order" overrides the default;
- a shuffle that never arrives reads NOT KNOWN beneath the play's line;
- a card tap on a playlist shuffles, and so does a scheduled one;
- a scheduled favorite that was renamed fires HELD;
- group, then play, lands on the leader;
- a cross-platform group is refused;
- a nudge at 95 moves to 100;
- a swallowed UPnP error reads NOT KNOWN;
- a hand volume change writes no line;
- a description for a missing favorite is ignored and flagged.

Eval tier, which needs Greg's go-ahead to spend:

- "Play some chill music" reads the favorites, chooses one described as
  chill, and says which;
- "Play Summer 26" plays that one and never substitutes another;
- "Play the Summer 26 playlist" passes the name alone, with `kind:
  playlist`;
- when the tool returns candidates, the model asks rather than picks;
- the model never names the track that played as if it had observed it.

## Build order

These are layered commits. Each is green on its own with `mix precommit`.

0. **The smoke test above**, on the real house. It is not a commit, but it
   comes first.
1. **The speaker learns more.** `sources`, `group`, `media_content_id`,
   `shuffle`, and the capability bits (`SELECT_SOURCE`, `SHUFFLE_SET`,
   `GROUPING`, `NEXT_TRACK`, `PREVIOUS_TRACK`). Also the client's
   background read of favorite kinds, and the status tool. No new writes.
2. **The house file's `music` block.** Parse and validate it, show the
   descriptions in the status tool, and flag stale keys on `/admin`.
3. **Favorites play.** The resolver, the `play_source` action with the
   shuffle default, `HACall`'s per-call command, `speaker_play_music`, the
   M5 and shuffle arrival rules, `:media` and "Shuffle on" in
   `Interventions.reading/1`, and the doctrine line from M11.
4. **Card and schedules.** `controls/1`, `scheduled_actions/0`, and HELD for
   a missing favorite.
5. **Nudge and skip.**
6. **Grouping.**
7. **The guide.** `docs/house.html` gets the speaker, the favorites step,
   and the `music` block. `example.yaml` shows them.
8. **One eval run**, approved first.

Then TK-041 walks the real Sonos: echo latency, the M5 edge, join time,
whether a shuffled start on track one matters, and how often NOT KNOWN
appears after a correct play.

M4 is not in this order. It gets its own build order if the refusal count
earns it.

## Questions for Greg

1. **The nudge step.** Ten points, or another number?
2. **Does HA see the Sonos speakers yet?** If yes, the smoke test takes
   five minutes and settles the one unknown. If no, the Proxmox HAOS VM
   comes first, and nothing else in this design moves before it.

Settled 2026-09-26:

- No Music Assistant; M4 is deferred.
- Favorites are the house's list.
- A per-house default service is not needed, because each favorite carries
  its own.
- Mood requests choose from described favorites (M11).
- Playlists shuffle by default (M12).

## Sources

Home Assistant `2026.9.3`, `homeassistant/components/`:

- `sonos/media_player.py`:
  - feature flags, L121–155
  - state mapping, L208–227
  - `select_source`, L397–411
  - `source_list`, L436–451
  - `play_media`, L495–707
  - `join`, L894–923
- `sonos/media.py`: per-track attributes, L114–182; `source`, L34–39.
- `sonos/favorites.py`, L105–155: the favorites cache, with Sonos playlists
  as `SQ:n`.
- `sonos/media_browser.py`:
  - favorites browse tree, one folder per item class, L485–565
  - root collapse, L372–457
  - `search_media`, local library only (PR #170891, 2026.6), L215–255
- `sonos/speaker.py`:
  - group topology, L1000–1043
  - join wait, L1258–1301
  - offline detection, L381–391 and L686–709
  - polling fallback, L412–423
- `sonos/media_player.py`, L94 (`UPNP_ERRORS_TO_IGNORE`), applied through
  `sonos/helpers.py`'s `soco_error`: UPnP errors 701, 711 and 712 are
  swallowed.
- `media_player/__init__.py`:
  - `play_media` schema, L190–198 and L403–436
  - WebSocket `browse_media`, L1325–1399
  - WebSocket `search_media`, L1402–1468
- `media_player/intent.py`, L278–402: `HassMediaSearchAndPlay` plays
  `results[0]`.
- `music_assistant/media_player.py`, L462–561: `play_media` name resolution
  and its fail-open fallback. See also `services.py`, L88–236, and
  `schemas.py`, L59–152.

Music Assistant `2.10.4`:

- `controllers/music/controller.py`, L3323–3402: `_get_item_by_name`, where
  the first hit wins.
- Provider manifests: `ytmusic` and `plex` are beta.
- <https://music-assistant.io/player-support/sonos/>: S1/S2 limits, and the
  S1 provider alongside HA's Sonos integration.
