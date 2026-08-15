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

### Named Rules

**The Palette Law.** Five reserved state colours, each meaning exactly one
thing, used decoratively nowhere. A sixth state colour is a design change, not
a CSS change. Audit test: search the stylesheet for a state colour outside a
`[data-st]` selector, a tick, or a refusal reason — there should be none.

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

### Named Rules

**The Shared Document Rule.** Nothing is ever aligned or positioned by author.
The thread is a household record, and positioning a message by who is holding
the phone means two people reading the same conversation see two different
documents. Audit test: two browsers, two names, one screenshot each — the
messages must land in the same place.

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
- **Behaviour:** most-recently-changed leads. The row is the atom of the
  header band and, later, of a device card

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
- **Indents to the body column at 820px**

### The Set Line

- **Style:** the composer as the board's set line — a transparent input on the
  raised rail, no border, a 2px brass rule above it, a brass send arrow behind
  a hairline divider
- **Placeholder:** condensed uppercase, deliberately a label rather than a
  sentence
- **Focus:** the caret is commanded amber; focus-visible draws a 2px amber ring

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
