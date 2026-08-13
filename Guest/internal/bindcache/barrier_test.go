package bindcache

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestBarrierWaitsForAcknowledgement(t *testing.T) {
	t.Parallel()
	barriers := NewBarrierCoordinator(time.Second)
	emitted := make(chan WriteBarrier, 1)
	barriers.SetEmitter(func(event WriteBarrier) error {
		emitted <- event
		return nil
	})
	done := make(chan error, 1)
	go func() { done <- barriers.Wait(context.Background(), "project/data.bin") }()
	event := <-emitted
	select {
	case <-done:
		t.Fatal("barrier completed before invalidation acknowledgement")
	default:
	}
	barriers.Acknowledge(event.BarrierID)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestBarrierOrdersConcurrentWritesIndependently(t *testing.T) {
	t.Parallel()
	barriers := NewBarrierCoordinator(time.Second)
	events := make(chan WriteBarrier, 2)
	barriers.SetEmitter(func(event WriteBarrier) error { events <- event; return nil })
	results := make(chan string, 2)
	for _, path := range []string{"one", "two"} {
		path := path
		go func() {
			if barriers.Wait(context.Background(), path) == nil {
				results <- path
			}
		}()
	}
	first, second := <-events, <-events
	barriers.Acknowledge(second.BarrierID)
	if got := <-results; got != second.Paths[0] {
		t.Fatalf("acknowledged %q but released %q", second.Paths[0], got)
	}
	barriers.Acknowledge(first.BarrierID)
	if got := <-results; got != first.Paths[0] {
		t.Fatalf("acknowledged %q but released %q", first.Paths[0], got)
	}
}

func TestBarrierEmitterFailureAndTimeoutFailClosed(t *testing.T) {
	t.Parallel()
	barriers := NewBarrierCoordinator(time.Millisecond)
	if err := barriers.Wait(context.Background(), "file"); !errors.Is(err, ErrBarrierUnavailable) {
		t.Fatalf("unexpected unavailable result: %v", err)
	}
	barriers.SetEmitter(func(WriteBarrier) error { return errors.New("write failed") })
	if err := barriers.Wait(context.Background(), "file"); err == nil || err.Error() != "write failed" {
		t.Fatalf("unexpected emitter result: %v", err)
	}
	barriers.SetEmitter(func(WriteBarrier) error { return nil })
	if err := barriers.Wait(context.Background(), "file"); !errors.Is(err, ErrBarrierTimeout) {
		t.Fatalf("unexpected timeout result: %v", err)
	}
}

func TestBarrierConcurrentAcknowledgeIsRaceSafe(t *testing.T) {
	t.Parallel()
	barriers := NewBarrierCoordinator(time.Second)
	events := make(chan WriteBarrier, 64)
	barriers.SetEmitter(func(event WriteBarrier) error { events <- event; return nil })
	var group sync.WaitGroup
	for index := 0; index < 64; index++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if err := barriers.Wait(context.Background(), "file"); err != nil {
				t.Errorf("wait: %v", err)
			}
		}()
	}
	for index := 0; index < 64; index++ {
		barriers.Acknowledge((<-events).BarrierID)
	}
	group.Wait()
}

func TestOldEmitterCleanupDoesNotClearNewConnection(t *testing.T) {
	t.Parallel()
	barriers := NewBarrierCoordinator(time.Second)
	removeOld := barriers.InstallEmitter(func(WriteBarrier) error { return errors.New("old emitter used") })
	emitted := make(chan WriteBarrier, 1)
	removeNew := barriers.InstallEmitter(func(event WriteBarrier) error {
		emitted <- event
		return nil
	})
	defer removeNew()
	removeOld()
	done := make(chan error, 1)
	go func() { done <- barriers.Wait(context.Background(), "file") }()
	event := <-emitted
	barriers.Acknowledge(event.BarrierID)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
