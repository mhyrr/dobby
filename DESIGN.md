---
name: Dobby
description: A household instrument — the house says what it is doing, and who asked for it.
colors:
  board: "#0B1713"
  board-raised: "#101E19"
  flap: "#16241E"
  flap-edge: "#08110E"
  brass: "#B08A46"
  brass-dim: "#6E5A31"
  ink: "#E8E2D2"
  ink-quiet: "#9AABA1"
  ink-faint: "#8A9C92"
  rule: "#1C2E27"
  st-set: "#E0A33C"
  st-acting: "#7BB86A"
  st-refused: "#D2604A"
  st-silent: "#7C8B85"
  st-expected: "#E8E2D2"
  seam-light: "rgba(255, 255, 255, .045)"
typography:
  display:
    fontFamily: "Barlow, ui-sans-serif, system-ui, -apple-system, sans-serif"
    fontSize: "1.12rem"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "normal"
  headline:
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.86rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.16em"
  title:
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.05rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "normal"
  body:
    fontFamily: "Barlow, ui-sans-serif, system-ui, -apple-system, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "normal"
  label:
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.94rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.06em"
  label-small:
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.74rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.07em"
  label-medium:
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.86rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.07em"
rounded:
  none: "0"
  hairline: "1px"
spacing:
  xs: "0.28rem"
  sm: "0.5rem"
  md: "0.9rem"
  lg: "1.05rem"
  xl: "1.4rem"
components:
  flap:
    backgroundColor: "{colors.flap}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.none}"
    padding: "0.16rem 0.5rem 0.18rem"
    height: "1.55rem"
  flap-set:
    textColor: "{colors.st-set}"
  flap-acting:
    textColor: "{colors.st-acting}"
  flap-refused:
    textColor: "{colors.st-refused}"
  flap-silent:
    textColor: "{colors.st-silent}"
  flap-expected:
    textColor: "{colors.st-expected}"
  utterance:
    textColor: "{colors.ink}"
    typography: "{typography.display}"
    width: "62ch"
  step:
    textColor: "{colors.ink-quiet}"
    typography: "{typography.label-small}"
  system-line:
    textColor: "{colors.ink}"
    typography: "{typography.label-small}"
    padding: "0.28rem 0"
  set-line-input:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.none}"
    padding: "0.85rem 0.9rem"
  card:
    borderTopColor: "{colors.rule}"
    padding: "0.7rem 0 0.8rem"
    gap: "{spacing.sm}"
    maxWidth: "34rem"
  fader-groove:
    backgroundColor: "{colors.flap}"
    borderTopColor: "{colors.flap-edge}"
    borderBottomColor: "{colors.seam-light}"
    height: "4px"
  fader-thumb:
    backgroundColor: "{colors.brass}"
    rounded: "{rounded.none}"
    width: "10px"
    height: "1.35rem"
  fader-asking:
    textColor: "{colors.st-set}"
    fontFamily: "Barlow Condensed, Avenir Next Condensed, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.86rem"
    fontWeight: 600
    letterSpacing: "0.05em"
  quiet-button:
    backgroundColor: "transparent"
    textColor: "{colors.brass}"
    borderBottomColor: "{colors.brass-dim}"
    typography: "{typography.label-small}"
    rounded: "{rounded.none}"
    textTransform: "none"
  undo-line:
    textColor: "{colors.ink-faint}"
    typography: "{typography.label-small}"
    gap: "{spacing.sm}"
  schedule-input:
    backgroundColor: "{colors.flap}"
    textColor: "{colors.ink}"
    borderBottomColor: "{colors.brass-dim}"
    typography: "{typography.body}"
    rounded: "{rounded.none}"
    padding: "0.4rem 0.5rem"
  feed-entry:
    textColor: "{colors.ink-quiet}"
    typography: "{typography.label-small}"
    gridTemplateColumns: "5.5rem 6.5rem minmax(0, 1fr) 7rem 3.5rem"
    padding: "0.18rem 0"
---

# Design System: Dobby

## Overview

**Creative North Star: "The Departure Board"**

A split-flap board can only display what it was set to. It cannot show a state
nobody commanded. That mechanical fact is the whole system: Dobby is forbidden
to claim a room got warm when all that happened was a command being accepted,
and the surface enforces the same honesty in its materials rather than in a
paragraph of prose. Every state on this board is a word on a flap, and a word
had to be set by somebody.

The world is a magical household instrument — enamel ground, brass rules,
painted lettering — not a wizard. It is alive and honest rather than ornate.
Register was pinned as fun, hearted and magical, and then narrowed: the magic
is that the object is alive, not that it talks like a spellbook. Nothing in
the copy uses wizarding diction, and no trademarked franchise asset appears
anywhere.

Density is low and deliberate. The board carries two or three device rows and
then gets out of the way; the conversation below it is set at reading scale
because what a person said is the material this product is made of. The
record-keeping — steps, timings, system lines — is what gets small.

Confirmed anti-references: the dark card grid with a circular dial, which
shows a number and tells you nothing about who set it or whether it took;
parchment, wax-seal and filigree pastiche; any trademarked franchise mark.

**Key Characteristics:**

- Words on flaps, never icons and never bare numbers
- Five reserved state colours and no sixth
- Square corners everywhere; the only curve is the drawing of Dobby himself
- Two hue families — a green-black enamel ground and warm brass-and-cream ink
- Flat by default; one shadow in the entire system
- Fixed-pitch columns and tabular figures, so a changing number does not shift

## Colors

Two families and nothing else: a cool green-black enamel ground (every neutral
sits between hue 166° and 172°) and a warm brass-and-cream ink (hue 76°–90°)
that everything readable is painted in. The state colours are the only
saturation on the board.

### Primary

- **Brass** (`brass`): the rules, the plate heading, the send arrow, the
  speaker's name in the thread. The metal the board is bound in — it marks
  structure and attribution, never state.
- **Brass, Dim** (`brass-dim`): the two structural rules that hold the board
  together, under the header and over the set line. Also scrollbar thumbs and
  the disclosure caret.

### Secondary — the five reserved state colours

Each means exactly one thing. Together they are the only place saturation is
allowed.

- **Commanded Amber** (`st-set`): `SET` and the caret in the composer. A value
  somebody asked for.
- **Acting Green** (`st-acting`): `WARMING`, `COOLING`, `AWAKE`, `LISTENING`.
  The device is doing it, or answering.
- **Declined Rust** (`st-refused`): `HELD`, and the reason beside it. The
  device said no. Deliberately quiet rather than alarming — a refusal is a
  fact about the device, not a failure of Dobby's.
- **Silent Sage** (`st-silent`): `QUIET` and `NOT KNOWN`. The desaturated one,
  because absence should not compete with presence.
- **Expected Cream** (`st-expected`): `READY` — set for later, not yet fired.
  Identical in value to `ink`, and that is the point: a schedule waiting is
  not a state the house is *in*, so it is painted in plain lettering.

### Neutral

- **Enamel** (`board`): the ground. The page, and the thread behind it.
- **Enamel, Raised** (`board-raised`): the header and the set line — the two
  fixed rails the scrolling thread runs between.
- **Flap Face** (`flap`): the card a word is painted on. One step lighter than
  the ground, which is all the separation a word needs.
- **Split** (`flap-edge`): the fold across each flap card.
- **Ink** (`ink`): painted lettering. What a person said, and every reading.
- **Ink, Quiet** (`ink-quiet`): device names, steps, system lines — the
  record-keeping voice.
- **Ink, Faint** (`ink-faint`): timestamps, durations, placeholder text. The
  floor for small type at 4.5:1 on the enamel; nothing goes below it.
- **Rule** (`rule`): hairline dividers inside the board.

### Where a state colour appears off a flap

Four sanctioned sites, and the list is closed:

- **Commanded amber on a caret** — the set line's input and the admin form's.
  The caret is where a command is being typed.
- **Commanded amber on the focus ring** — a 2px outline, the one global
  interactive state in the system.
- **Commanded amber on the fader's asking label**, and only while a finger is
  down.
- **Declined rust on a reason** — a held step, a held card, a system line's
  refusal, a blocked schedule, a rejected form, and the health note naming
  enabled schedules that have no timer. In every one of these it is the
  sentence saying why something did not or will not happen. Never a fill,
  never a badge.

### Named Rules

**The Palette Law.** Five reserved state colours, each meaning exactly one
thing, used decoratively nowhere. A sixth state colour is a design change, not
a CSS change. Audit test: search the stylesheet for a state colour outside a
`[data-st]` selector, a tick, a refusal reason, or one of the four sanctioned
sites listed below — there should be none.

**The Edges Rule.** State colour lives on ink, rules, ticks and flap edges —
never as a tint behind readable text.

**The Night Kitchen Rule.** A screen left on in a kitchen must not light the
room at 11pm. Audit test: open the board in a dark room. If it reads as a lamp
rather than a sign, the saturation is wrong.

## Typography

**Display Font:** Barlow Condensed (with Avenir Next Condensed, then the
platform sans)
**Body Font:** Barlow (with the platform sans)

Both are served from the box itself, from `priv/static/fonts`, never from a
CDN: the house has no internet, so a webfont hosted anywhere else is a
dependency that fails exactly when it is needed. Three faces are vendored
because three are used — Barlow Regular, Barlow Condensed Regular, Barlow
Condensed SemiBold — and the rest of both families were deleted rather than
carried. TTF rather than WOFF2, because the files travel a few metres of LAN
to three devices and the difference there is not worth a build dependency.

The platform fallbacks stay in the stack for the moment before the font
arrives and for anything that fails to load it. A fourth weight is a design
decision: the ramp is 400 and 600, and nothing on this board is italic.

**Character:** A condensed grotesque doing the board's job — uppercase,
letter-spaced, fixed-pitch — against an unhurried humanist sans for anything a
person actually said. The two never blur: if it is set in the condensed face
it is the instrument talking, and if it is set in Barlow it is a human being.

### Hierarchy

- **Display** (400, 1.12rem, 1.35): what somebody said, and what Dobby
  answered. Capped at 62ch.
- **Headline** (600, 0.86rem, +0.16em, uppercase): the plate — the board's
  own nameplate. Small on purpose; it is a label riveted to an instrument, not
  a page title. It is the same size as Label, Medium and is told apart by
  tracking alone — twice the letter-spacing, because a nameplate is spaced and
  a device name is not.
- **Title** (600, 1.05rem, tabular): device readings. The number on the board.
- **Body** (400, 1rem, 1.45): the composer, and any running prose.
- **Label** (600, 0.94rem, +0.06em, uppercase): the flap. Every state word.
- **Label, Medium** (600, 0.86rem, +0.07em, uppercase): device names on the
  board, and the set line's placeholder.
- **Label, Small** (600, 0.74rem, +0.05–0.09em, uppercase): attribution,
  timestamps, steps, system lines. The record-keeping voice.

Six steps, and that is the whole ramp. It was ten when this file was first
written — four of them inside six hundredths of a rem of each other, which is
accretion rather than a scale. Adding a seventh needs a role that none of
these six can carry.

### Named Rules

**Language Is The Material.** What a person said gets board-scale type, not
chat-bubble type in 14px grey. The record-keeping around it is what gets
small. Audit test: in any thread screenshot, the largest text should be
somebody's sentence.

**The Legibility Floor.** Type is sized by reading distance and never shrinks
to fit. Content reflows or truncates; type does not scale down. There is no
responsive font-size anywhere in the system and adding one is a change to this
rule, not to a component.

**The Instrument Voice Rule.** The condensed face is only ever the board
speaking about itself — states, names, times, steps. Dobby's own words are
never set in it.

## Layout

Three fixed bands on every viewport: the board header, the thread, and the set
line. The page itself never scrolls — `height: 100dvh` with the thread as the
only scrolling region — because the header is the part of a board that must
never leave. A short thread sits down on the set line rather than floating at
the top of an empty board.

The board header is a three-column grid: device name, reading, state
(`1fr auto 9.5rem`), capped at 34rem so the flap column stays a fixed pitch
however wide the screen gets. The state column is a fixed field and the flap
card hugs its word inside it.

Phone is the primary viewport and everything adapts up from it. At 820px the
thread becomes a two-column grid — a 7.5rem speaker column and the body — and
system lines indent to the body column so the record aligns with what it is
describing. Edge padding goes from 0.9rem to 1.4rem. Nothing else changes;
there is one composition, not two.

Rhythm comes from the content, not from an abstract scale: 0.28rem between
steps, 0.5rem across a row, 1.05rem between messages.

### The Three Routes

Three pages and one instrument: `/` the thread, `/house` the cards, `/admin`
the maintainer's page. They share the plate, the flap, the row and the 34rem
pitch, because they are the same board seen from a different side rather than
three applications.

There is no navigation bar. The nameplate is the way back — on `/` it is plain
lettering, because you are already home, and on the other two it becomes a link
with a brass-dim `·` and the section name after it (`The House · Devices`). The
band of flap rows in the thread's header is the way in to `/house`, where the
same rows have controls on them; it carries no underline and no hover lift,
because a board that behaved like a hyperlink would stop reading as one. The
only way in to `/admin` is a small brass-dim link at the foot of `/house` — it
is laptop-shaped and rarely visited, so it does not earn permanent header space
on the surface a phone opens first.

`/house` and `/admin` scroll the same way the thread does: the page itself never
scrolls, and the main region is the only scrolling thing on it.

Admin is the one page with enough on it to want columns. At 980px it becomes
`minmax(0, 22rem) minmax(0, 1fr)` — health and schedules on the left because
they are short and they are where the changing happens, the feed on the right
because it is the long one. That is the system's second breakpoint and its only
two-column layout; 820px still does everything else, and both are content
breakpoints rather than device sizes.

### Named Rules

**The Shared Document Rule.** Nothing is ever aligned or positioned by author.
The thread is a household record, and positioning a message by who is holding
the phone means two people reading the same conversation see two different
documents. Audit test: two browsers, two names, one screenshot each — the
messages must land in the same place.

**The No Nav Rule.** Navigation is carried by things that already exist — the
nameplate, the band of rows, one quiet link at the foot of a page. A shell of
links around this would be a second visual language arguing with the first.
Audit test: no route may introduce a nav element; a new page earns its way in
from a surface that already leads somewhere.

## Elevation & Depth

Flat, with one exception. Depth is tonal: the ground, the raised rails, and
the flap face are three steps of the same green-black, and that is the entire
elevation model. There are no cards, no floating panels, no hover lifts.

The exception is the flap itself, which carries `0 1px 2px rgba(0,0,0,.45)` —
the one shadow in the system. It exists because a flap card is a physical
object sitting proud of the board, and removing it makes the words look
printed on rather than set into place.

A single radial gradient sits behind the whole page
(`ellipse 120% 80% at 50% -10%`, `#12211B` to transparent), which reads as
uneven enamel under a light. It is material, not decoration.

### Named Rules

**The One Shadow Rule.** The flap has the only `box-shadow` in the system.
Anything else that wants depth gets a tonal step or a brass rule instead.

## Shapes

Square. There is no border-radius anywhere in the layout — not on the flap,
the input, the button, the header, or the thread. The scale has exactly two
steps and one of them is zero: `none` (0) for every surface, and `hairline`
(1px) for the focus ring alone, so the outline does not look chipped. The only
other rounded things are the scrollbar thumb and Dobby himself, who is drawn
entirely in curves and is the only organic form in the world.

Borders are hairlines: a 1px `rule` inside the board, and two 2px `brass-dim`
rules where the structure actually changes — under the header and over the set
line. Weight marks importance; colour never does.

The signature form is **the fold**: a hairline split across the middle of each
flap card, built as a background gradient with `seam-light` above the seam and
`flap-edge` below it. That pair is the system's one way of cutting an edge into
the enamel, and the fader's groove is built from the same two lines — a dark
edge on top, a lit one under it. It is not a colour in the palette's sense; it
is the light side of an edge, and nothing readable is ever painted in it.

### Named Rules

**The Fold Rule.** The fold is drawn *behind* the lettering, never across it.
A seam over the glyphs reads as a strikethrough, and a struck word means
cancelled — which would be a lie about every state on this board.

## Components

### The Flap

The system's atom. A word on a card: `flap` face, uppercase condensed
lettering, the fold behind it, one shadow under it.

- **Shape:** square (0), 1.55rem minimum height, padding `0.16rem 0.5rem 0.18rem`
- **Colour:** the word takes the state colour; the card face never does
- **States:** `set` amber, `acting` green, `refused` rust, `silent` sage,
  `expected` cream
- **Behaviour:** `white-space: nowrap`. A flap never wraps — the field around
  it reflows instead

### Board Row

- **Structure:** name (quiet ink, condensed, truncates with ellipsis) ·
  reading (ink, condensed, tabular) · flap
- **Grid:** `1fr auto 9.5rem`, capped at 34rem
- **Behaviour:** on the thread's band, most-recently-changed leads. On `/house`
  it is manifest order instead: the band is a watch list and reorders itself,
  and a page whose cards moved under a finger would be worse than one that did
  not
- **Reuse:** the same row is the atom of the header band, of a device card, of
  an admin health row and of a schedule row. Admin's health rows demote the
  middle column to 0.74rem faint ink, because it names which process a row is
  about and a process name is record-keeping rather than a reading

### The Plate

The board's nameplate, worn by every route: a baseline-aligned row ruled
underneath with a hairline. The name on the left; on the right, who is speaking,
the mark, and a `LISTENING` / `QUIET` flap.

- **Section:** absent on `/`. Elsewhere the name becomes a link, followed by a
  brass-dim separator and the section in quiet ink, all on the headline step
- **Speaking as:** the speaker's name in quiet ink, a hairline, then a `switch`
  button in brass-dim that goes brass on hover. The hairline is the same
  separator the set line puts before its send arrow — without it "GREG SWITCH"
  reads at a glance as two words of one name
- **Lower case, stated:** `switch` is a verb, and everything set in capitals on
  this board is a label — a state, a name, a time. The system's one other
  verb-shaped string, a refusal's reason, is set the same way
- **A form, not a link:** switching identity is a write. It is also why the
  small word is the tappable thing rather than the name — a household tablet
  that changed who was speaking because somebody brushed the header would be
  worse than typing a name again
- **Reduced flap:** 0.74rem lettering on a 1.2rem card. The plate, the system
  line and a held card share this smaller flap; the board row does not

### The Card

A board row that grew a control. Same three columns, same vocabulary, same
34rem pitch — what a card adds is the room underneath the row.

- **Structure:** the row · a detail line in the record voice (`Room 68°`, or
  `Since 4:12 PM`) · the control, when the device can take one · what happened
  after the last release
- **Separation:** a hairline `rule` on top and 0.7/0.8rem of padding; the first
  card has none. A card is not a panel — no border, no fill, no shadow
- **One column on every viewport.** The column stays 34rem and never becomes a
  grid of tiles. The confirmed anti-reference is a dark card grid of dials, and
  the pitch is what keeps a card reading as a row
- **The second number is a different fact.** The row carries the setpoint,
  because the setpoint is what somebody asked for; the detail line carries what
  the room actually reads. The same number is never said twice

### The Fader

The setpoint control, and the only place in this house where a fat finger
actuates something. A fader rather than a dial — the dial is the category
default this surface is a refusal of — and rather than a stepper, which turns
"make it warmer" into six taps.

- **Groove:** 4px of `flap`, a `flap-edge` line on top and a `seam-light` line
  under it. The same construction as the flap's fold, for the same reason:
  without the pair, a track one tonal step from the ground disappears
- **Thumb:** 10px × 1.35rem of solid brass, square, radius explicitly zeroed
  against the browser's default. Brass is where a hand goes
- **Ends:** the device's own minimum and maximum in faint ink. The control is
  drawn only once the device has said what it will accept — a fader that
  reaches 85° in a house capped at 76 is a control that exists to be refused
- **Commits on release, not on drag.** The value rides the thumb locally while
  a finger is down; only the release reaches the house
- **The asking label:** the value under the thumb, in commanded amber, riding
  the thumb and visible **only** while a finger is down. It is deliberately not
  written into the card's own reading — that number is a value somebody
  commanded, and putting an uncommanded one in its place would be the board
  claiming a state it was never set to

### The Undo Line

The system's alternative to a confirm dialog: do it, then offer a way back for
eight seconds. Dialogs train people to dismiss dialogs, and a household that has
learned to dismiss them is worse off than one that never had them. The card and
the admin's schedule delete use the same line, unchanged.

- **Style:** the record voice in faint ink — `undo · back to 70°`, or
  `undo · put back "weeknight heat"`
- **The button:** transparent, no border but a 1px `brass-dim` underline, brass
  lettering, lower case. That is the system's quiet control, and the same
  treatment carries `pause`, `resume`, `delete` and the form's `Add`
- **One step, not a stack.** Undoing does not offer its own undo
- **A refusal is not an undo.** `HELD` and its reason stay until the next
  attempt rather than expiring with the window: an undo is an offer and goes
  stale, a refusal is an answer to a question somebody just asked

### Utterance

- **Character:** the largest text on the surface, and the only thing set in
  Barlow at reading scale
- **Attribution:** speaker in brass condensed uppercase, time in faint ink,
  inline above on phone and a fixed 7.5rem column at 820px
- **Never aligned by author**

### Steps

The board showing its work while Dobby is working — one row per tool call, in
device language ("setting the main thermostat"), never in Dobby's voice.

- **Tick:** an 8px square. Outlined while running (and pulsing), filled acting
  green when done, filled declined rust when the device refused
- **Reason:** when a step is held, the reason gets its own line beneath it, in
  sentence case and declined rust — a sentence set beside a label in board
  type squeezes both
- **After the reply:** collapses to one disclosure row (`2 steps · 3.8 s`)

### System Line

The intervention record: what changed in the house, by whatever path.

- **Style:** ruled above and below with hairlines, condensed uppercase. The
  device name is in full ink because it is the content of the line; the `via`
  half — who or what did it — is in faint ink
- **Two shapes, told apart by whether the line carries a state word.** A
  failure is a sentence, because "Dobby couldn't answer that" is not a reading
  of anything. An intervention is a board row inside the ruled band: device
  name, the flap, the value at 0.86rem, then the `via`
- **The word is always `SET`.** An intervention *is* a commanded value, so
  there is no per-device vocabulary question on this line — that question
  belongs to what a device currently reads. `HELD` is the other half, for a
  device that declined
- **A refusal's reason takes its own line**, in sentence case and declined
  rust, the same way a step's does
- **Indents to the body column at 820px**

### The Set Line

- **Style:** the composer as the board's set line — a transparent input on the
  raised rail, no border, a 2px brass rule above it, a brass send arrow behind
  a hairline divider
- **Placeholder:** condensed uppercase, deliberately a label rather than a
  sentence
- **Focus:** the caret is commanded amber; focus-visible draws a 2px amber ring

### Admin

Same board, same words; what changes is that a maintainer is reading it. Three
panels, and the order is an argument: health first because it is three lines and
it changes what the other two mean, schedules next because they are the only
thing on the page you can change, the feed last because you scroll to a log
rather than being handed it.

- **Panel heading:** the headline step in brass over a hairline — the plate's
  type, used as a section rule
- **Health rows:** board rows whose middle column is demoted to 0.74rem faint
  ink. Empty is the healthy answer for the note beneath them, and it says so in
  words rather than showing nothing
- **Schedule rows:** a row (label · cron · flap), a detail line, a reason line
  when there is one, and the actions. `READY` in expected cream for one waiting
  for its time; `HELD` for one that can no longer reach its device — nothing
  declined it, but the shape is the same and so is the treatment
- **Paused:** no flap at all, and the name, value and detail drop to faint ink.
  See The Absent Word Rule
- **The form:** the only form inputs in the system. A filled `flap` ground, a
  1px `brass-dim` underline and no other border, no radius, a commanded-amber
  caret, and the field's name above it in the record voice. The input itself is
  1rem Barlow, the same as the set line's, because what you type is language.
  An error is declined rust under the field it came from
- **The feed:** a fixed five-column grid,
  `5.5rem 6.5rem minmax(0, 1fr) 7rem 3.5rem` — time, kind, what, who, took —
  hairline-ruled between entries, in the record voice. Fixed pitch so a
  streaming log does not shift its columns under a reader; `what` and `who`
  truncate rather than wrap, and `took` is right-aligned

### The Mark

Dobby drawn as a line figure — round head, two swept ears, closed smiling eyes
— painted in ink (stroke `currentColor`, fill the ground behind it) rather
than filled white, so he reads as drawn onto the enamel rather than stuck onto
it. He lives in the plate at 44px.

- **Attending:** rotated −15°, in full ink. He leans in
- **Quiet:** upright, in faint ink
- **Never below 40px.** The face collapses into a smear at thread scale, and
  the ears alone read as leaves without the head

### The State Vocabulary (signature)

The system's real component is its eight words. States are words on flaps,
never icons and never bare numbers.

| Word | Means | Colour |
|---|---|---|
| `SET` | a commanded value — not "the room is warm" | Commanded Amber |
| `WARMING` / `COOLING` | the device is acting on it | Acting Green |
| `READY` | a schedule waiting for its time | Expected Cream |
| `AWAKE` | an endpoint that answers | Acting Green |
| `LISTENING` | Dobby is attending | Acting Green |
| `QUIET` | an endpoint that has stopped answering | Silent Sage |
| `HELD` | the device declined, with the reason beside it | Declined Rust |
| `NOT KNOWN` | nobody has told us yet | Silent Sage |

Still eight, and two new pages did not add a ninth. `SET`, `HELD`, `READY`,
`QUIET` and `NOT KNOWN` all appear on `/house` and `/admin` with exactly the
meanings above; nothing was widened to cover a new case, and one case was left
wordless instead.

### Named Rules

**The Words Rule.** A state is a word. Adding an icon, a dot, a badge or a
bare number to say what a word already says is a regression, not a refinement.

**The Commanded-Not-Observed Rule.** `SET` means a value was commanded.
`WARMING` means the house reported the device acting on it. The board never
infers a state from a reading alone, because that is precisely the lie Dobby
is forbidden to tell.

**The Affirmative Loud Rule.** The affirmative states are the loud ones.
Refusal is `HELD`, quietly, with its reason beside it — never a punchline in
the reserved red. A design that leads with refusal is selling the wrong
product.

**The Absent Word Rule.** When no word in the vocabulary is true of a row, the
row gets no flap. A paused schedule shows none: nothing among the eight means
"somebody switched this off" — `QUIET` is an endpoint that stopped answering and
`HELD` is a device declining — and bending either to fit would put a word on the
board that means two things. The row goes faint and its button says `resume`,
which says it without a word. A ninth word is a design decision, not a CSS
change.

**The Uncommanded Value Rule.** A value somebody is still choosing is never
written into a reading. It may sit beside the control, in commanded amber, for
as long as the hand is on it, and it leaves the board the moment the board takes
over. Audit test: release the fader with the house slow to answer — nothing on
the card should show the new number until the house has confirmed it.

## Do's and Don'ts

### Do:

- **Do** say a state in a word from the vocabulary above, on a flap.
- **Do** give a new state a new word before giving it a new colour. Five
  reserved colours, and a sixth is a design decision.
- **Do** put state colour on ink, ticks, rules and edges.
- **Do** set anything a person said in Barlow at 1.12rem, and everything the
  instrument says about itself in Barlow Condensed uppercase.
- **Do** keep corners square. The only curves in the world are Dobby.
- **Do** use tabular figures for every number, so a changing reading does not
  shift the column beside it.
- **Do** draw the fold behind the lettering.
- **Do** distinguish "not answering" from "not yet known". They are different
  facts and the vocabulary has a word for each.
- **Do** leave the flap off entirely when none of the eight words is true.
  Silence is a legitimate answer; a bent word is not.
- **Do** answer a destructive action with an undo line for a few seconds,
  instead of a confirm dialog.
- **Do** commit a drag on release, and show what is being asked for beside the
  control rather than in the reading.

### Don't:

- **Don't** put a tint behind readable text, in any colour.
- **Don't** add a `border-radius` to a flap, an input, a button, or a panel.
- **Don't** add a second `box-shadow`. Depth is tonal.
- **Don't** align, indent or colour a message by who said it.
- **Don't** shrink type to make content fit. Reflow or truncate instead.
- **Don't** render the mark below 40px, and don't use the ears without the
  head.
- **Don't** phrase a step as Dobby speaking ("Let me just check the
  thermostat…"). Steps are labels in device language, and the soul bans
  process narration in his voice.
- **Don't** use wizarding diction, franchise assets, or parchment-and-
  wax-seal pastiche. The magic is that the object is alive and honest.
- **Don't** add a navigation bar. The nameplate, the band and one quiet link
  are the navigation.
- **Don't** write a value a person is still choosing into a device's reading.
- **Don't** widen an existing state word to cover a new case. Add a word, or
  leave the flap off.
- **Don't** turn the cards page into a grid of tiles. One 34rem column, on
  every viewport.
