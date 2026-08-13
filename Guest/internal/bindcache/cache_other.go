//go:build !linux

package bindcache

import (
	"errors"
	"time"
)

type Cache struct{}

func Mount(_, _ string, _ time.Duration) (*Cache, error) {
	return nil, errors.New("bind cache requires Linux")
}
func (c *Cache) SetBarrierEmitter(func(WriteBarrier) error)            {}
func (c *Cache) InstallBarrierEmitter(func(WriteBarrier) error) func() { return func() {} }
func (c *Cache) Invalidate([]string, bool, uint64)                     {}
func (c *Cache) Close() error                                          { return nil }
