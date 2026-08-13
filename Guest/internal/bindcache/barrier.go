package bindcache

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"
)

var ErrBarrierUnavailable = errors.New("bind write barrier host is unavailable")
var ErrBarrierTimeout = errors.New("bind write barrier timed out")

type WriteBarrier struct {
	BarrierID uint64   `json:"barrierId"`
	Paths     []string `json:"paths"`
}

type BarrierCoordinator struct {
	next    atomic.Uint64
	timeout time.Duration
	mu      sync.Mutex
	emit    func(WriteBarrier) error
	emitter uint64
	pending map[uint64]chan struct{}
}

func NewBarrierCoordinator(timeout time.Duration) *BarrierCoordinator {
	return &BarrierCoordinator{timeout: timeout, pending: make(map[uint64]chan struct{})}
}

func (b *BarrierCoordinator) SetEmitter(emit func(WriteBarrier) error) {
	b.mu.Lock()
	b.emitter++
	b.emit = emit
	b.mu.Unlock()
}

// InstallEmitter makes emit current and returns a cleanup function that only
// removes that emitter. This prevents an old connection from clearing the
// emitter installed by a newer connection when the old connection closes.
func (b *BarrierCoordinator) InstallEmitter(emit func(WriteBarrier) error) func() {
	b.mu.Lock()
	b.emitter++
	generation := b.emitter
	b.emit = emit
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		if b.emitter == generation {
			b.emit = nil
		}
		b.mu.Unlock()
	}
}

func (b *BarrierCoordinator) Wait(ctx context.Context, path string) error {
	id := b.next.Add(1)
	done := make(chan struct{})
	b.mu.Lock()
	emit := b.emit
	if emit != nil {
		b.pending[id] = done
	}
	b.mu.Unlock()
	if emit == nil {
		return ErrBarrierUnavailable
	}
	if err := emit(WriteBarrier{BarrierID: id, Paths: []string{path}}); err != nil {
		b.remove(id)
		return err
	}
	timer := time.NewTimer(b.timeout)
	defer timer.Stop()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		b.remove(id)
		return ctx.Err()
	case <-timer.C:
		b.remove(id)
		return ErrBarrierTimeout
	}
}

func (b *BarrierCoordinator) Acknowledge(id uint64) {
	b.mu.Lock()
	done := b.pending[id]
	delete(b.pending, id)
	b.mu.Unlock()
	if done != nil {
		close(done)
	}
}

func (b *BarrierCoordinator) remove(id uint64) {
	b.mu.Lock()
	delete(b.pending, id)
	b.mu.Unlock()
}
