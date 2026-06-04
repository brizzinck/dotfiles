# go-architect examples

Reference templates showing the project's canonical patterns. They are **illustrative, not
compilable** — the module path is the placeholder `app/...` and some referenced types
(`domain.Order`, `models.OrderRow`, `repositories.Order`) are stubs. Read them as shape
guides; substitute the real module path and types when applying.

- **`order_module.go`** — the canonical fx-wired, batched PostgreSQL repository: named
  module const, `var _ repositories.Order = &Order{}` compile-time check, `fx.Provide` +
  `variable.ReturnAlias` interface aliasing, `fx.Invoke(RegisterOrder)` for the batcher
  lifecycle, ctx-first/log-last method signatures, `cockroachdb/errors` wrapping, and a
  `FlushFn` that re-queues only failed rows. The shape every new repository follows.

- **`order_cache.go`** — a lock-free hot-path reference cache (in-memory fallback repo)
  wrapping the real repository with `refreshmap.RefreshMap`: whole-map reload on a ticker
  into an `atomic.Pointer`, lock-free `Get`, aliased to a distinct `OrderFallback`
  interface so the application layer can prefer the cache and fall back to the DB.

Full copy-paste source of every shared `pkg/` primitive these examples use (batcher,
refreshmap, variable.ReturnAlias, postgres.Pooler, logger, …) is in the APPENDIX of the
`go-architect` agent definition.
