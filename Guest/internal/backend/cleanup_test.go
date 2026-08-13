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

func TestOrderedCleanupBarrierSerializesAndPropagatesFailure(t *testing.T) {
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
	if err := barrier.wait(context.Background()); !errors.Is(err, want) {
		t.Fatalf("got %v, want %v", err, want)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(order) != 2 || order[0] != 1 || order[1] != 2 {
		t.Fatalf("cleanup order = %v", order)
	}
}
