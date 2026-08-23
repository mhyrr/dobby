---
version: 1
slug: "docs-index-html"
primary_target: "docs/index.html"
related_targets: ["docs/house.html","docs/running.html","docs/box.html","docs/living.html","docs/growing.html","docs/agents.html","docs/how-it-works.html","docs/developing.html"]
---

# Surface: the user's guide (docs/)

Scope: nine static HTML pages under docs/, served by GitHub Pages from main. Mode: Read.

Audience and job: a person with a working Home Assistant and a weekend. They want to install Dobby, describe their house in home.yaml, talk to it, grow the house, and possibly send their own agent at it over MCP. Laptop first (they are setting up), phone second.

Content and proof: every page is written from a verified walk (TK-018/TK-022 standard). Where something has not been walked (the installed service, the always-on box), the page says so in its own words. Source material: README, docs/setup.md, docs/local-ha.md (all migrated here and deleted), DESIGN.md's vocabulary, CLAUDE.md's rules, the TK-022 live transcript.

Chosen structure: The Ledger of Proofs (seed 8ac72cfd, candidate 6, THE ROLL). Nameplate "Dobby · Guide" and a chapter rail in the admin's composition; one reading column at the pitch; each section that has an observable outcome closes with a "What you should see" card on enamel, the outcome in a state word or the literal line the terminal prints. Sections without an observable outcome carry no card — a decorative one breaks the rule. Prev/next as two quiet links at the foot; "on this page" at 1100px and up.

Memorable moment: the guide proves itself the way the board does — you never take its word for it, you look at the flap.

Constraints: no generator, no toolchain; fonts self-hosted under docs/fonts (the three vendored faces); light and dark follow the system, dark is the board's night face and light is the printed manual on cream enamel with the same five state hues at legible lightness; square corners; no icons; no nav bar beyond the rail; the Identifier Rule (ids, keys, filenames lower-case in the condensed face).

Unresolved: a custom domain; whether /admin should show the LAN address the guide now tells Claude Code users to copy.

## As built (2026-08-22)

- Files: docs/index.html and eight chapter pages, docs/dobby.css, docs/dobby.js, docs/favicon.svg, docs/fonts (the three vendored faces), docs/.nojekyll. Served by GitHub Pages from main:/docs, no build.
- The printed-manual face (light), derived from the board's hue families at paper lightness: board #ede7d6, raised #e4ddc9, lit #f5f0e4, flap #dce5df, flap-edge #b4c2ba, brass #8b6827, brass-dim #c4ad7e, ink #1a1708, ink-quiet #3e4e47, ink-faint #5a6963, rule #d5ccb4; state hues st-set #8a5a0a, st-acting #386f2c, st-refused #a33726, st-silent #566560, st-expected = ink. Dark is DESIGN.md's palette unchanged. The page follows prefers-color-scheme; no toggle.
- The chapter-title ramp the guide adds to the board's six steps: 3rem (index title), 2.4rem (chapter h1; 2rem below 600px), 1.5rem (h2), 1.2rem (contents-sheet titles). Recorded as ignore-values for design-system-font-size in .impeccable/config.json.
- Composition: plate + chapter rail (the admin's rail, rotated from /admin's five to the guide's nine); at ≥900px a 8.6rem gutter column on the left holds "on this page", the reading column takes the whole span (42.6rem) with prose capped at 62ch and code/proofs at the span. Below 900px one column at the edge.
- The proof: `.proof`, an enamel card with a label in the record voice, holding board rows (name · reading · flap), terminal lines (`.line`, pre-wrap mono), or a sentence (`.said`). Flap words carry data-st and the five colours; the flap lands (rotateX, 420ms ease-out) on first intersection; reduced motion shows it at rest.
- The transcript: `.thread`, a 7.5rem speaker column beside what was said, the record voice beneath in the condensed face, sentence case.
- Emphasis is never italic: strong and em both set in the condensed face at 600.
- The note: `.note` for a record-voice aside; `.note.unwalked` marks a section not yet walked, its label in declined rust.
