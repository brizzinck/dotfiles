---
name: go-architect
description: Architecture, fx dependency-injection, error-handling, pkg-primitive, and optimization guidance for this Go backend service. Use to place new code across Clean Architecture layers, wire fx modules, bind/wrap errors, reuse shared pkg/ utilities, scaffold a new entity end-to-end, or review/optimize existing code.
argument-hint: <question, file path, or task — e.g. "where does my new repo go?" or "wire internal/.../order.go into fx">
context: fork
agent: go-architect
---

Delegate the following architecture/DI/optimization task to the `go-architect` agent: $ARGUMENTS

## When to use this skill

Invoke `/go-architect` (or just describe an architecture task) for any of:
- **Placement** — "where does this type/interface/module belong?" across `entities` / `application` / `infrastructure` / `pkg`.
- **fx wiring** — providing vs consuming dependencies, `fx.Module`/`Provide`/`Invoke`/`Annotate`, interface aliasing via `variable.ReturnAlias`, lifecycle hooks, the graceful-shutdown group.
- **Errors** — how to wrap at a boundary with `cockroachdb/errors`, when to use `variable.BindError` with a sentinel, `errors.Is`/`As`.
- **Reusing `pkg/` primitives** — batcher, refreshmap, inmemory/ttlcache, publicsubscriber, datainsertion, channelqueue, encryptor, logger, graceful modules.
- **New entity** — scaffold the domain → model → mapper → repository-interface → implementation → usecase → module → `cmd/main.go` chain.
- **Optimization** — remove a per-request DB round-trip/lock/allocation on the hot path using an existing primitive.
- **Review** — flag layer-boundary violations, leaked concrete types, missing `var _ Iface` checks, style/lint issues.

Do NOT use this for writing tests — that is `/make-go-tests` (the `go-test-writer` agent).

## What the agent does

1. Reads the relevant context: `CLAUDE.md`, `cmd/main.go` (the fx graph), `docs/`, the real `pkg/` source for any primitive it recommends, and a sibling file in the layer being edited. For reusable utilities it carries an APPENDIX in its own definition — the full copy-paste source of every domain-agnostic `pkg/` primitive (variable, batcher, refreshmap, caches, pub-sub, datainsertion, graceful, postgres/clickhouse, logger, …), anonymized for reuse across projects.
2. Applies the project conventions (codebase wins over generic style docs): no `I`-prefix interfaces, `cockroachdb/errors`, `variable.ReturnAlias` for fx binding, ctx-first/log-last signatures, structured logging.
3. Produces the design / refactor / scaffold / review with concrete code matching the canonical module shape.
4. Ends by listing changed files, mentally checking `make run_lint`, and recommending `/make-go-tests <file>` for new/modified production code.

## How to invoke

- Slash form: `/go-architect where should a new OrderRepository live and how do I wire it?`
- Or via the Agent tool directly: `subagent_type: go-architect` with the task in the prompt.
- The skill runs with `context: fork`, so it spawns a fresh agent conversation rather than continuing the current one — pass all needed context (file paths, the goal) in the argument.

## Examples

Reference templates live in `examples/` (illustrative, non-compiling — placeholder `app/...`
module path and stub types). See `examples/README.md` for the index. Two canonical shapes:

- **`examples/order_module.go`** — the fx-wired, batched PostgreSQL repository every new
  repository follows: named module const, `var _ repositories.Order = &Order{}` check,
  `fx.Provide` + `variable.ReturnAlias` aliasing, `fx.Invoke(RegisterOrder)` for the batcher
  lifecycle, ctx-first/log-last signatures, `cockroachdb/errors` wrapping, re-queue-on-failure
  `FlushFn`.
- **`examples/order_cache.go`** — a lock-free hot-path reference cache (in-memory fallback
  repo) wrapping the real repository via `refreshmap.RefreshMap`, aliased to a distinct
  `OrderFallback` interface.

For the full copy-paste source of every shared `pkg/` primitive, see the APPENDIX in the
`go-architect` agent definition (the agent reads it on demand).
