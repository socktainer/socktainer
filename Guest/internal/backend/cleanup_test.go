package backend

import (
	"context"
	"errors"
	"sync"
	"testing"
)

func TestOrderedCleanupBarrierWaitsForPriorCleanup(t *testing.T) {
	var barrier orderedCleanupBarrier
	release := make(chan struct{})
	barrier.enqueue(func() error {
		<-release
		return nil
	})
	waited := make(chan error, 1)
	go func() { waited <- barrier.wait(context.Background()) }()
	select {
	case <-waited:
		t.Fatal("wait returned before cleanup completed")
	default:
	}
	close(release)
	if err := <-waited; err != nil {
		t.Fatal(err)
	}
}

func TestOrderedCleanupBarrierSerializesAndClearsPriorFailure(t *testing.T) {
	var barrier orderedCleanupBarrier
	want := errors.New("cleanup failed")
	var mu sync.Mutex
	order := []int{}
	barrier.enqueue(func() error {
		mu.Lock()
		order = append(order, 1)
		mu.Unlock()
		return want
	})
	barrier.enqueue(func() error {
		mu.Lock()
		order = append(order, 2)
		mu.Unlock()
		return nil
	})
	if err := barrier.wait(context.Background()); err != nil {
		t.Fatalf("later successful cleanup remained poisoned by %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(order) != networkCleanupAttempts+1 || order[len(order)-1] != 2 {
		t.Fatalf("cleanup order = %v", order)
	}
}

func TestOrderedCleanupBarrierRetriesAndDoesNotPoisonFutureCreates(t *testing.T) {
	var barrier orderedCleanupBarrier
	attempts := 0
	barrier.enqueue(func() error {
		attempts++
		return errors.New("cleanup failed")
	})
	if err := barrier.wait(context.Background()); err == nil {
		t.Fatal("expected the bounded cleanup failure")
	}
	if attempts != networkCleanupAttempts {
		t.Fatalf("cleanup attempts = %d, want %d", attempts, networkCleanupAttempts)
	}
	if err := barrier.wait(context.Background()); err != nil {
		t.Fatalf("reported cleanup failure poisoned future creates: %v", err)
	}
}
