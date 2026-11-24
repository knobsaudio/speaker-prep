# Working with this project

Read `docs/product.md`, `docs/architecture.md`, `docs/swift_rules.md`, and
`docs/issues.md` before touching code. `docs/done/issues.md` is the history of
resolved issues; consult it before reopening a question.

## How we work

- Issues are catalysts, not tickets. Each one is an occasion to ask what the
  best design is for that part of the app, and to inch the whole toward it.
  Closing the issue is a side effect.
- Before proposing a fix, ask what the user should experience. If the answer
  isn't in `product.md` or `architecture.md`, ask the owner rather than infer.
- Propose a plan and wait for approval before editing any file. Flag every
  new type, pattern, or idiom explicitly; the owner decides on names.
- Prefer keeping a design property (e.g. the synchronous state machine) over
  patching around it. If a fix would cost one, say so and stop.
- Minimalist code and docs; bulletproof behavior; readability from names,
  scope, and architecture rather than comments.
- Record decisions in `docs/architecture.md` and status in `docs/issues.md`
  so they aren't relitigated.

## Directives

The owner uses explicit directives to control the phase of work:

- `(DISCUSSION)` — explore the problem, trade-offs, and user experience. Do not
  edit any files.
- `(PROPOSAL)` — present a concrete plan (flagging any new types, patterns,
  idioms, or names) and stop. Do not edit any files; wait for approval.
- `(APPROVED <scope>)` — permission to edit only what falls within `<scope>`.
  Never edit outside the approved scope, and never generate or simulate your own
  approval.
