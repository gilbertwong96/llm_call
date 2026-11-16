# VibeKit quality gate

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

- Use the pi-elixir semantic tools to refactor Elixir source: `elixir_ast_search`
  to find the shapes, `elixir_ast_replace` to rewrite them, and `elixir_eval`
  (project target) to confirm what the compiler and Dialyzer see. Do not reach
  for `sed`, Python, or other one-off rewrite scripts first.
- `elixir_ast_replace` patterns are valid Elixir: lowercase variables capture,
  `_` is a wildcard, and `...` matches the rest. Never use ast-grep `$NAME`
  metavariables.
- Exact token replacement is acceptable for exactly one case: a pure identifier
  rename (an app atom or module prefix). Follow it with the full `mix ci` and a
  grep for the old name.
- A blind global replace of an API or field rename is forbidden. If the semantic
  tools cannot express a change, stop and record why in the commit message.
- After any refactor, `mix ci` is the gate and it must be green on both supported
  toolchains: ExDNA reports no duplication at its default threshold, Dialyzer
  and Credo report nothing, and the suite passes.
