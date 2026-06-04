// Example: a lock-free hot-path reference cache for rarely-changing data, wrapping
// the real repository. Reloads the whole map on a ticker into an atomic.Pointer, so
// per-request Get costs no lock and no DB round-trip. Anonymized: module path `app/...`.
//
// This is an in-memory FALLBACK repo: it consumes the real repositories.Order and is
// itself exposed under a distinct interface (repositories.OrderFallback) so the
// application layer can prefer the cache and fall back to the DB on a miss.
package inmemory

import (
	"context"

	"app/internal/entities/domain"
	"app/internal/entities/repositories"
	"app/pkg/logger"
	"app/pkg/utils/refreshmap"
	"app/pkg/utils/variable"

	"github.com/cockroachdb/errors"
	"go.uber.org/fx"
)

const OrderCacheModuleName = "OrderInMemoryCache"

var _ repositories.OrderFallback = &OrderCache{}

// OrderCacheOption: provide the constructor and alias it to the fallback interface.
// No fx.Invoke — the RefreshMap starts its own worker in refreshmap.New(ctx, ...).
var OrderCacheOption = fx.Module(
	OrderCacheModuleName,
	fx.Provide(
		NewOrderCache,
		fx.Annotate(variable.ReturnAlias[*OrderCache, repositories.OrderFallback]),
	),
)

type Config struct {
	CacheReloadInterval int64 // injected sub-config; use time.Duration in real code
}

type OrderCache struct {
	rm *refreshmap.RefreshMap[int, domain.Order]
}

// NewOrderCache builds the RefreshMap. The refresh closure loads everything once per
// interval; the returned map is swapped in atomically.
func NewOrderCache(
	ctx context.Context,
	source repositories.Order, // the real repo, injected as its interface
	cfg *Config,
	log logger.Logger,
) *OrderCache {
	log = log.WithField(logger.ModuleField, OrderCacheModuleName)

	rm := refreshmap.New(
		ctx,
		variable.Second30, // reload cadence (use the configured interval in real code)
		func(ctx context.Context, log logger.Logger) (map[int]domain.Order, error) {
			all, err := source.List(ctx, log)
			if err != nil {
				return nil, errors.Wrap(err, "OrderCache.refresh")
			}

			out := make(map[int]domain.Order, len(all)) // pre-size
			for _, o := range all {
				out[o.ID] = o
			}

			return out, nil
		},
		log,
	)

	return &OrderCache{rm: rm}
}

// GetByID is lock-free: no mutex, no DB. Returns ok=false on a miss so the caller
// can fall through to the real repository.
func (c *OrderCache) GetByID(_ context.Context, id int, _ logger.Logger) (domain.Order, bool) {
	return c.rm.Get(id)
}
