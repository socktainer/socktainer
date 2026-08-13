//go:build linux

package bindcache

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCacheWarmReadInvalidationAndWriteThrough(t *testing.T) {
	if _, err := os.Stat("/dev/fuse"); err != nil {
		t.Skip("/dev/fuse is unavailable")
	}
	source := t.TempDir()
	target := t.TempDir()
	backing := filepath.Join(source, "data.bin")
	cached := filepath.Join(target, "data.bin")
	first := bytes.Repeat([]byte("a"), 1024*1024)
	second := bytes.Repeat([]byte("b"), len(first))
	third := bytes.Repeat([]byte("c"), len(first))
	if err := os.WriteFile(backing, first, 0o600); err != nil {
		t.Fatal(err)
	}
	cache, err := Mount(source, target, time.Second)
	if err != nil {
		t.Skipf("FUSE mount unavailable: %v", err)
	}
	defer cache.Close()
	cache.SetBarrierEmitter(func(event WriteBarrier) error {
		cache.Invalidate(event.Paths, false, event.BarrierID)
		return nil
	})
	if got, err := os.ReadFile(cached); err != nil || !bytes.Equal(got, first) {
		t.Fatalf("warm read: %v", err)
	}
	if err := os.WriteFile(backing, second, 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(cached); err != nil || !bytes.Equal(got, first) {
		t.Fatalf("expected cached first version before invalidation: %v", err)
	}
	cache.Invalidate([]string{"data.bin"}, false, 0)
	if got, err := os.ReadFile(cached); err != nil || !bytes.Equal(got, second) {
		t.Fatalf("expected second version after invalidation: %v", err)
	}
	file, err := os.OpenFile(cached, os.O_WRONLY|os.O_TRUNC, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.Write(third); err != nil {
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(backing); err != nil || !bytes.Equal(got, third) {
		t.Fatalf("write-through backing content: %v", err)
	}
}
