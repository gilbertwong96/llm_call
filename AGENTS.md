# VibeKit quality gate

## Hard rule: refactor Elixir source with pi-elixir, never with scripts

Every change to Elixir source (`lib/`, `test/`, `mix.exs`) goes through the
pi-elixir semantic tools first. This is not a preference; it is the rule for this
repository.

| Intent | Tool |
| --- | --- |
| Find a code shape (call, clause, struct literal, `case`, `with`) | `elixir_ast_search` |
| Rewrite that shape across files or occurrences | `elixir_ast_replace` (dry-run first) |
| Confirm what the compiler/Dialyzer see, without starting the app | `elixir_eval`, target `project` |
| Validate the result | `mix ci` |

Forbidden for Elixir source, without exception:

- `python3 - <<'EOF'` heredoc rewrites, `perl -pi`, `sed -i`, `ruby -e`, `awk`;
- a whole-file `write` that only exists to perform a search-and-replace;
- chained shell edits (`for f in ...; do sed ...; done`) across source files.

Use `edit` (exact, localized text replacement) only for a single small change in
one place. The moment a change repeats, or spans files, it belongs in
`elixir_ast_replace`. `write` is for new files and genuine full rewrites, never
as a batch edit mechanism.

`elixir_ast_replace` patterns are valid Elixir: lowercase variables capture, `_`
is a wildcard, `...` matches the rest. Never use ast-grep `$NAME` metavariables.

Exact token replacement is acceptable for exactly one case: a pure identifier
rename (an app atom or module prefix). Follow it with the full `mix ci` and a grep
for the old name.

A blind global replace of an API or field rename is forbidden. If the semantic
tools cannot express a change, stop and record why in the commit message. An
inability to express the change is a finding, not a licence to script it.

Non-Elixir files (Markdown, `.exs` config that is not a project module, JSON) are
not covered by the tool rule; edit them directly.

## Development

```sh
mix deps.get
mix ci
```

## Conventions

- Use `mix ci` for the full validation suite before finishing changes.
- For Phoenix/web apps, keep Phoenix's generated guidance, but treat this VibeKit section as the final quality gate.
- For non-web Elixir projects, VibeKit is the default project baseline.
- Keep changes small, tested, and formatted.

## Refactoring

- The hard rule above governs the mechanics; this section covers verification.
- After any refactor, `mix ci` is the gate and it must be green on both supported
  toolchains: ExDNA reports no duplication at a zero clone budget, SpecLint
  reports no spec that contradicts the compiler's inferred signature (with
  warnings as errors), Reach passes the architecture policy in `.reach.exs`,
  Dialyzer and Credo report nothing, and the suite passes.
