* **Use `struct` and `enum` by default:** Avoid `class` entirely unless shared mutable identity or explicit mutex gating is strictly required. Never use inheritance, `super`, or class hierarchies; make any rare `class` explicitly `final`.

* **Zero invisible code execution:** Do not use `willSet`/`didSet`, `@autoclosure`, property wrappers, result builders, or macros. Assignment (`=`) must be a pure memory write, never a function call.

* **No computed properties that do work:** If a property calculates anything non-trivial or allocates memory, write it as an explicit method `func name() -> Type` so the parentheses signal computational cost at the call site.

* **No method or operator overloading:** Give distinct methods distinct, descriptive names. Do not overload by argument type, and never define custom operators.

* **Keep error handling explicit and visible:** Use standard `throws` and mark every call site with explicit `try`. Never use `try!` or `try?` to silently swallow errors. Never use optional chaining deeper than one level (`a?.b`).

* **Keep generics shallow:** Use concrete types until duplication forces abstraction. When using generics, use a single type parameter with simple constraints. Do not write complex `where` clauses, recursive constraints, or phantom types.

* **Use small, explicit protocols:** Design protocols like `io.Reader` (one or two focused methods). Always use explicit `any` for existentials and `some` for opaque types so dispatch costs are visible.

* **Simplify access control:** Restrict yourself to `private` (implementation details) and `internal` (package/module default). Avoid `fileprivate`, and use `public` only at hard module boundaries.

* **Use extensions only for local organization:** Use extensions solely to group methods on types you own or to conform to a small protocol. Never retroactively extend types you do not own.

* **Reserve comments for the rare unintuitive line:** Readability comes from architecture, scope, and names, not from prose. If code seems to need a descriptive comment, first try a better name, a smaller scope, or a split; a comment is the fallback when the reason is genuinely invisible in the code (an external constraint, a non-obvious invariant, a deliberate tradeoff). Never write comments that restate what the code does.
