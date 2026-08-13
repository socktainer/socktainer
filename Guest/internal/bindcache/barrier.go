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
	next     atomic.Uint64
	timeout  time.Duration
	mu       sync.Mutex
	emitter  uint64
	emitters map[uint64]func(WriteBarrier) error
	pending  map[uint64]chan struct{}
}

func NewBarrierCoordinator(timeout time.Duration) *BarrierCoordinator {
	return &BarrierCoordinator{
		timeout: timeout, emitters: make(map[uint64]func(WriteBarrier) error),
		pending: make(map[uint64]chan struct{}),
	}
}

func (b *BarrierCoordinator) SetEmitter(emit func(WriteBarrier) error) {
	b.mu.Lock()
	b.emitter++
	b.emitters = map[uint64]func(WriteBarrier) error{b.emitter: emit}
	b.mu.Unlock()
}

// InstallEmitter makes emit current and returns a cleanup function that only
// removes that emitter. This prevents an old connection from clearing the
// emitter installed by a newer connection when the old connection closes.
func (b *BarrierCoordinator) InstallEmitter(emit func(WriteBarrier) error) func() {
	b.mu.Lock()
	b.emitter++
	generation := b.emitter
	b.emitters[generation] = emit
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		delete(b.emitters, generation)
		b.mu.Unlock()
	}
}

func (b *BarrierCoordinator) Wait(ctx context.Context, path string) error {
	id := b.next.Add(1)
	done := make(chan struct{})
	b.mu.Lock()
	emitters := make([]func(WriteBarrier) error, 0, len(b.emitters))
	for _, emit := range b.emitters {
		emitters = append(emitters, emit)
	}
	if len(emitters) != 0 {
		b.pending[id] = done
	}
	b.mu.Unlock()
	if len(emitters) == 0 {
		return ErrBarrierUnavailable
	}
	barrier := WriteBarrier{BarrierID: id, Paths: []string{path}}
	var lastError error
	sent := false
	for _, emit := range emitters {
		if err := emit(barrier); err != nil {
			lastError = err
		} else {
			sent = true
		}
	}
	if !sent {
		b.remove(id)
		return lastError
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
