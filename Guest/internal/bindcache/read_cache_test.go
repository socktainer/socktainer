package bindcache

import (
	"bytes"
	"sync"
	"testing"
)

func TestReadCacheEnforcesBoundAndEvictsLRU(t *testing.T) {
	t.Parallel()
	cache := newReadCache(8)
	load := func(value string) func() ([]byte, error) {
		return func() ([]byte, error) { return []byte(value), nil }
	}
	if err := cache.load("one", 4, load("1111")); err != nil {
		t.Fatal(err)
	}
	if err := cache.load("two", 4, load("2222")); err != nil {
		t.Fatal(err)
	}
	_, _ = cache.read("one", 0, 1)
	if err := cache.load("three", 4, load("3333")); err != nil {
		t.Fatal(err)
	}
	if _, ok := cache.read("two", 0, 1); ok {
		t.Fatal("least recently used entry was not evicted")
	}
	if cache.used > cache.capacity {
		t.Fatalf("cache uses %d bytes with %d-byte capacity", cache.used, cache.capacity)
	}
}

func TestReadCacheRejectsOversizeEntry(t *testing.T) {
	t.Parallel()
	cache := newReadCache(4)
	err := cache.load("large", 5, func() ([]byte, error) { return make([]byte, 5), nil })
	if err != errReadCacheEntryTooLarge {
		t.Fatalf("got %v, want oversize error", err)
	}
}

func TestReadCacheInvalidatesPathAndAll(t *testing.T) {
	t.Parallel()
	cache := newReadCache(8)
	for _, path := range []string{"one", "two"} {
		if err := cache.load(path, int64(len(path)), func() ([]byte, error) { return []byte(path), nil }); err != nil {
			t.Fatal(err)
		}
	}
	cache.invalidate("one")
	if _, ok := cache.read("one", 0, 8); ok {
		t.Fatal("path invalidation retained an entry")
	}
	if _, ok := cache.read("two", 0, 8); !ok {
		t.Fatal("path invalidation removed an unrelated entry")
	}
	cache.invalidateAll()
	if _, ok := cache.read("two", 0, 8); ok {
		t.Fatal("full invalidation retained an entry")
	}
}

func TestReadCacheDoesNotLoadWhileWriterIsOpen(t *testing.T) {
	t.Parallel()
	cache := newReadCache(8)
	cache.beginWrite("file")
	called := false
	if err := cache.load("file", 4, func() ([]byte, error) {
		called = true
		return []byte("data"), nil
	}); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("cache loaded a file while a writer was open")
	}
	cache.endWrite("file")
	if err := cache.load("file", 4, func() ([]byte, error) { return []byte("data"), nil }); err != nil {
		t.Fatal(err)
	}
	if data, ok := cache.read("file", 0, 4); !ok || string(data) != "data" {
		t.Fatalf("cache did not load after the writer closed: %q, %v", data, ok)
	}
}

func TestReadCacheInvalidationWinsConcurrentLoad(t *testing.T) {
	t.Parallel()
	cache := newReadCache(16)
	loading := make(chan struct{})
	finish := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- cache.load("file", 5, func() ([]byte, error) {
			close(loading)
			<-finish
			return []byte("stale"), nil
		})
	}()
	<-loading
	cache.invalidate("file")
	close(finish)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, ok := cache.read("file", 0, 16); ok {
		t.Fatal("load committed data from before invalidation")
	}
}

func TestReadCacheFullInvalidationWinsConcurrentLoad(t *testing.T) {
	t.Parallel()
	cache := newReadCache(16)
	loading := make(chan struct{})
	finish := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- cache.load("file", 5, func() ([]byte, error) {
			close(loading)
			<-finish
			return []byte("stale"), nil
		})
	}()
	<-loading
	cache.invalidateAll()
	close(finish)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, ok := cache.read("file", 0, 16); ok {
		t.Fatal("load committed data from before full invalidation")
	}
}

func TestReadCacheConcurrentReadsAndWritesAreRaceSafe(t *testing.T) {
	t.Parallel()
	cache := newReadCache(64)
	var group sync.WaitGroup
	for index := 0; index < 32; index++ {
		group.Add(2)
		go func() {
			defer group.Done()
			_ = cache.load("file", 32, func() ([]byte, error) { return bytes.Repeat([]byte("x"), 32), nil })
			_, _ = cache.read("file", 0, 32)
		}()
		go func() {
			defer group.Done()
			cache.invalidate("file")
		}()
	}
	group.Wait()
}
