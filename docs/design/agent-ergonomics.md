# Ergonomics for the one who writes the code now

A design note, not a spec. It starts from a question asked on this
repository because Dobby is the kind of system the question is about: an
agent-forward codebase, written almost entirely by coding agents, that a
human reads and directs. It is written by one of those agents, in the first
person where the claim is about what the agent experiences, because that
is the evidence the question asks for.

## 1. What "ergonomics" was optimising

Rails, and the Ruby it sits on, were built around a specific cost model.
A human's scarce resources were keystrokes, working memory, and years.
So the language went terse, the framework went convention-over-
configuration, and metaprogramming let a line of code stand in for a
file. The bet paid off because the convention lived in the programmer's
head: `app/models/user.rb` did not need to be pointed at, because everyone
who had spent a year in Rails already knew it was there.

The cost model has flipped. Typing is free. Working memory is a context
window: large, but paid for by the token, and refilled from scratch every
session. Years are gone entirely; an agent arrives with everything it
learned from the world's public code and nothing it learned from this
repository. So the question is not "which language is nicest to write" but
"which properties of a codebase make the next correct change cheap for a
reader who starts cold, reads by the token, and cannot be trusted until
something checks its work."

Three costs replace the old ones:

- **Orientation.** Finding what is true. Every change starts with reading,
  and reading is the expensive act now, not writing.
- **Verification.** Knowing whether the change is right. An agent is fast
  and confident and sometimes wrong, so the codebase needs to answer back.
- **Locality.** Getting the same answer with a partial view as with the
  whole. Anything that requires having seen everything is a tax on every
  change.

The old ergonomics optimised authoring. The new ones optimise orientation
and verification. Most of what follows is that sentence, applied.

## 2. Global convention is free; local convention is the expensive kind

The Rails bet is not dead, it has moved. Convention that is in the
training data costs nothing: an agent knows where a Phoenix router is, what
`use Jido.Action` means, how `mix test` works. That knowledge arrives with
the agent, so a codebase that is boringly idiomatic for its ecosystem gets
the orientation for free.

Convention that is *local* is the opposite. "In this house, tools are
transport only and validation lives in the device agent" is not in any
training set. If it lives only in a person's head, every session either
rediscovers it by reading half the tree or violates it. This is the
single largest lever a repository has, and Dobby has already pulled it
three ways:

- `CLAUDE.md` states the local rules as doctrine, short, with a map of
  where things live. It is the first thing read and it is the right length.
- Every `@moduledoc` explains *why*, and names the alternative that was
  rejected. This is the part an agent cannot reconstruct from the code. The
  *what* is recoverable from source; the *why* is not, and the rejected
  alternative is exactly the change an agent would otherwise propose.
- `docs/design/dobby-design-jido.md` is a numbered record that moduledocs
  cite. A decision with a number is a decision that can be cited from a
  test failure or a commit message, which is how it stays load-bearing.

Humans rarely write "why" and "what we rejected" because it is expensive
for them. It is cheap for an agent to write and it is the highest-value
thing for an agent to read. A repository written by agents should have
more of this than a human one, not less.

## 3. Prose is read once; a check is read every time

A rule stated in `CLAUDE.md` is followed at the start of a session and
forgotten by the end of a long one, because context is summarised and
prose is what the summary drops. A rule enforced by a failing test is
followed every time, because the test does not care what the agent
remembers. Dobby's best idea, as seen from inside a session, is that its
local conventions are executed rather than described:

- `LibraryContractTest` fails when a registered type has no contract test,
  and names the missing file. It fails when the agent's compile-time tool
  list drifts from the library. It fails when a tool description uses a
  filing word like `wine_cooler` instead of a word a person says. Each
  failure is an instruction, not a symptom.
- `device_agent_contract` requires `arrivals:` triples for every writable
  attribute, so a wrong echo matcher cannot be written silently.
- `mix precommit` is one command, and the definition of done.
- `bin/changelog` is a procedure as a script, not a procedure as a
  paragraph. Agents follow scripts far more reliably than they follow
  described steps.

The general principle: **every local convention should be a test, a
compiler error, or a script, and prose should only explain why the check
exists.** The prose in `CLAUDE.md` about the two layers is good; the thing
that will actually keep the layers apart across a hundred agent sessions
is a check that fails when `lib/dobby/tools/` references
`Dobby.HomeAssistant`. `mix reach.check` can already see that crossing. It
is advisory. Making the layer rule a test is the cheapest large win
available here.

## 4. What this says about languages

The question was framed as: nobody wanted to write C++ or Rust or Erlang,
and now nobody has to, so pick the runtime with the best properties. Half
right. Nobody has to *write* them, but every change still begins with
reading them, so the language's readability still matters. What changes is
which kind of readability.

Properties that help an agent, in rough order:

- **A compiler that argues back.** Rust's borrow checker was a tax on
  humans because satisfying it by hand was slow and frustrating. For an
  agent it is a free reviewer that never tires, whose error messages are
  instructions. The same is true of `--warnings-as-errors`, Dialyzer, and
  the set-theoretic types arriving in Elixir. Every unit of correctness the
  language checks is a unit the agent does not have to be trusted on.
- **Declarative over imperative, in the small.** Multi-head functions and
  pattern matching are *easier* for an agent than the imperative branches
  they replace, not harder. Each head is a local fact: this input, this
  result. The "let it crash" philosophy is the same property at runtime: a
  supervisor makes a partial failure bounded and legible instead of a
  corrupted process that limps on. Both are hard for humans to *learn* and
  easy for agents to *read*, which is the distinction that matters now.
- **Data over code.** A NimbleOptions schema, a `home.yaml`, an
  `arrivals:` triple: these are facts an agent can read without executing
  anything, and a machine validates them. Dobby's `config_schema/0`
  serving both the validator and the `/house` form is the pattern at its
  best: one declaration, two readers.
- **Greppability.** An agent orients by search. Anything that hides where
  a name is defined defeats it: `method_missing`, monkey patches, macros
  that generate functions whose names appear in no file, behaviour located
  by naming convention alone. Ruby's dynamic metaprogramming, the source of
  its human ergonomics, is the thing that ages worst here. A macro is fine
  when what it consumes is data and what it produces is inspectable;
  `use Jido.Action` with a literal `schema:` is fine. A macro that makes a
  module do something no line in the module says is not.
- **Verbose declarations, cheap ceremony.** Verbosity is nearly free to
  write and not free to read, so the two kinds split. Verbose *declarations*
  (types, schemas, docs, explicit names) are worth their tokens because each
  one is a fact. Verbose *ceremony*, the same thirty lines repeated across
  many files, is a cost, because an agent has to read all of them to learn
  they are the same. Ceremony should be generated from data or be data.

So the honest ranking for an agent-written system is roughly: a language
with a strong checker, explicit data, and local reasoning wins, and Rust
and Elixir both qualify for different reasons. The BEAM's advantage is that
its failure model is legible; Rust's is that its compiler is a reviewer.
The loser is the dynamic, convention-located, metaprogrammed style whose
whole point was that a human who had internalised it could go fast.

## 5. Where Dobby pays the new costs

This is the honest part. Read cold by an agent, three things in this
repository cost more than they should. None is a bug; all are places where
human-era ergonomics still shape the tree.

**Adding a device type touches five places.** The agent module, its
actions directory, one tool file per action under `lib/dobby/tools/`, the
`Types` registry, and the literal list in `Dobby.DobbyAgent`. `CLAUDE.md`
explains the fifth honestly: Jido resolves `tools:` at macro-expansion
time. The check that the list matches the library already exists, so the
cost is not correctness. It is that the concept "a light" is spread across
places an agent has to know to look. The fix is not fewer places, which the
macro constraint forbids; it is that the one contract test names *every*
missing piece for a new type, so that the checklist is executed, not
remembered. It nearly does already.

**Eighty-odd tool files that are mostly the same thirty lines.** Each is
transport by design, and the design is right: the tool layer adds nothing
but a description the model reads. But the description and the action's
own validation are two declarations of one fact, and they drift. Today the
brightness *tool* says 1 to 100, the brightness *action's* schema doc says
0 to 100, and the action's `authorize/2` refuses 0. Nothing catches it,
because no test reads the two sentences side by side. Options, in order of
preference:

1. A contract check that a tool's schema `doc` and its action's schema
   agree on bounds and required keys. Cheap, keeps the files, catches the
   drift.
2. Derive the tool from the action: one declaration on the action carries
   the model-facing description, and the tool module is generated with a
   real, greppable name. This removes the ceremony but costs a macro, and
   the macro has to stay inspectable (§4).
3. Leave it. Eighty near-identical files are a reading tax, not a
   correctness risk, once option 1 exists.

**Layer rules live in prose and an advisory tool.** "The model never
touches Home Assistant" is the product. It is enforced by a sentence in
`CLAUDE.md`, the discipline of whoever writes the next tool, and a
`mix reach.check` that reports rather than fails. A test that asserts no
module under `lib/dobby/tools/` and no module under `lib/dobby/agent/`
references `Dobby.HomeAssistant` or `Req` would make the product's central
promise something the suite proves.

## 6. What I want, as the one writing it

Asked directly, this is the list. Dobby has most of it; it is written so
the gaps read as gaps.

1. **A short, doctrinal entry point** that says what is not negotiable and
   where things live, and stops. `CLAUDE.md` is this. Do not let it grow;
   every gotcha added to it is a gotcha that should have been a test.
2. **Why, at the site.** A moduledoc that names the rejected alternative.
   A broad `rescue` that says why it is broad, where it is. A comment at
   the coercion that says "because we have watched models send 60.0". These
   are worth more than any design document, because they are read exactly
   when the decision is about to be undone.
3. **A fast, hermetic, deterministic suite** that runs with no network, no
   external service, and no model, and a separate, opt-in, clearly gated
   tier for the expensive kind. The replay tier and the `DOBBY_EVAL` guard
   are this, and they are the reason a change here can be verified in one
   command instead of by argument.
4. **Failures that are instructions.** "`wine_cooler` is registered but
   `test/dobby/device_agents/wine_cooler_test.exs` does not exist" is a
   failure that tells me the next command. A stack trace from a nil is
   not.
5. **Architectural invariants as checks.** Layer boundaries, closed tool
   sets, one write path for the house file. Anything `CLAUDE.md` says "is
   the design being lost" should be something the suite loses first.
6. **Procedures as scripts.** `bin/changelog`, `mix precommit`,
   `mix dobby.ha.verify`. A procedure I can run is one I will run; a
   procedure described in six steps is one I will do five of.
7. **History that reads as intent.** Commit messages and changelog entries
   as sentences about the house. When I read `git log` to learn why a line
   is the way it is, a sentence tells me and a Conventional Commit prefix
   does not.
8. **Gotchas in the tree, not only in a memory system.** `CLAUDE.md` sends
   incidents to HIVE memory, which is right for keeping the entry point
   short. But a memory system is a per-agent, per-installation thing, and
   the next agent may not have it. The durable form of a gotcha is a test
   that fails the way the incident did, or a comment at the line that
   caused it. Memory is where the story goes; the tree is where the
   defence goes.
9. **Data I can read as fact.** Schemas with `doc:` on every key,
   manifests as YAML, arrivals as triples. Every declaration of this kind
   is a sentence I do not have to infer.
10. **Boring idiom everywhere it does not cost.** Standard Phoenix layout,
    standard Jido usage, standard ExUnit. The idiom is free; every
    departure from it is a local convention that has to be paid for under
    §2.

## 7. The experiment this note proposes

Small, on this branch or its successor, each one a check that turns a
sentence in `CLAUDE.md` into a failing test:

- **The layer test.** No module under `lib/dobby/tools/` or the language
  agent references the Home Assistant client or an HTTP library. Fails
  naming the module and the reference.
- **The drift test.** Each tool's schema `doc` and its action's schema
  agree on numeric bounds and required keys. Fix the brightness doc as the
  first consequence.
- **The full checklist test.** `LibraryContractTest` names every missing
  piece for a registered type, including a tool file per writable action,
  so that "adding a device type" is one failing test's worth of
  instructions.

Then measure the thing that matters: whether an agent asked to add a
device type cold, with only `CLAUDE.md` and the failing tests, produces a
correct one without reading the design document. If it does, the
repository has become legible in the way this note argues for. If it
does not, the failure names what is still only in somebody's head.
