// Example: the canonical fx-wired, batched PostgreSQL repository — the shape every
// new repository module should follow. Anonymized: module path `app/...`, entity `Order`.
// Layers shown together for reference; in the real tree each block is its own file.
package postgres

import (
	"context"
	"time"

	"app/internal/entities/domain"
	"app/internal/entities/mapper"
	"app/internal/entities/models"
	"app/internal/entities/repositories"
	"app/pkg/database/postgres"
	"app/pkg/logger"
	"app/pkg/utils/batcher"
	"app/pkg/utils/database"
	"app/pkg/utils/variable"

	"github.com/cockroachdb/errors"
	"github.com/jackc/pgx/v5"
	"go.uber.org/fx"
)

// ─── internal/entities/repositories/order.go : the contract (NO `I` prefix) ───
//
//	type Order interface {
//	    GetByID(ctx context.Context, id int, log logger.Logger) (*models.OrderRow, error)
//	    Insert(ctx context.Context, row models.OrderRow, log logger.Logger)
//	}

const OrderModuleName = "OrderPostgresRepository"

// Compile-time proof the concrete type satisfies the interface. Always present.
var _ repositories.Order = &Order{}

// OrderModule wires the repo: provide the constructor, expose *Order AS
// repositories.Order via ReturnAlias, and Invoke RegisterOrder for the batcher lifecycle.
var OrderModule = fx.Module(
	OrderModuleName,
	fx.Provide(
		NewOrder,
		fx.Annotate(variable.ReturnAlias[*Order, repositories.Order]),
	),
	fx.Invoke(RegisterOrder), // present ONLY because there is a background worker
)

type Order struct {
	pool    postgres.Pooler
	batcher *batcher.Batcher[models.OrderRow]
	logger  logger.Logger
}

// NewOrder accepts interfaces (Pooler) + config + logger and returns the concrete type.
func NewOrder(pool postgres.Pooler, config *postgres.Config, log logger.Logger) *Order {
	log = log.WithField(logger.ModuleField, OrderModuleName) // scope the logger once

	repo := &Order{pool: pool, logger: log}

	repo.batcher = batcher.New(
		batcher.NewConfig(config.BatchSize, config.BatchMaxFlushSize, batcher.DefaultPeriodicFlushTimeout),
		time.NewTicker(config.BatchInterval),
		repo.insertBatch,
		log,
	)

	return repo
}

// RegisterOrder attaches the batcher's OnStart/OnStop to the fx lifecycle.
func RegisterOrder(lc fx.Lifecycle, repo *Order) {
	batcher.RegisterWorker(lc, repo.batcher)
}

// Insert is non-blocking on the hot path: it only buffers. The worker flushes.
func (r *Order) Insert(_ context.Context, row models.OrderRow, _ logger.Logger) {
	r.batcher.Add(row)
}

func (r *Order) GetByID(ctx context.Context, id int, log logger.Logger) (*models.OrderRow, error) {
	log.Debug("get order by id", logger.Int("order_id", id))

	const query = `SELECT id, status, amount FROM orders WHERE id = $1`

	var row models.OrderRow
	if err := r.pool.QueryRow(ctx, query, id).Scan(&row.ID, &row.Status, &row.Amount); err != nil {
		if database.IsNoPgxRows(err) {
			return nil, errors.Wrapf(domain.ErrOrderNotFound, "OrderRepo.GetByID id=%d", id)
		}

		return nil, errors.Wrap(err, "OrderRepo.GetByID")
	}

	return &row, nil
}

// insertBatch is the FlushFn: it MUST return the subset that FAILED so the
// batcher re-queues only those. Total failure → return the whole input slice.
func (r *Order) insertBatch(ctx context.Context, rows []models.OrderRow) ([]models.OrderRow, error) {
	batch := &pgx.Batch{}
	for _, row := range rows {
		batch.Queue(
			`INSERT INTO orders (status, amount) VALUES ($1, $2)`,
			row.Status, row.Amount,
		)
	}

	if err := r.pool.SendBatch(ctx, batch).Close(); err != nil {
		return rows, errors.Wrap(err, "OrderRepo.insertBatch") // all re-queued
	}

	return nil, nil
}

// ─── used above; shown for completeness ───
var _ = mapper.FromOrderRow // mapper.ToOrderRow / FromOrderRow live in entities/mapper
