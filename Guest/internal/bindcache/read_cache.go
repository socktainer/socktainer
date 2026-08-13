package bindcache

import (
	"container/list"
	"errors"
	"sync"
)

const maximumReadCacheBytes int64 = 512 << 20

var errReadCacheEntryTooLarge = errors.New("file exceeds the read cache capacity")

type readCacheEntry struct {
	path string
	data []byte
	gen  uint64
	all  uint64
}

type readCache struct {
	loadMu      sync.Mutex
	mu          sync.Mutex
	capacity    int64
	used        int64
	all         uint64
	generations map[string]uint64
	entries     map[string]*list.Element
	writers     map[string]int
	lru         list.List
}

func newReadCache(capacity int64) *readCache {
	return &readCache{
		capacity: capacity, generations: make(map[string]uint64), entries: make(map[string]*list.Element), writers: make(map[string]int),
	}
}

func (c *readCache) load(path string, size int64, loader func() ([]byte, error)) error {
	if size < 0 || size > c.capacity {
		return errReadCacheEntryTooLarge
	}
	c.loadMu.Lock()
	defer c.loadMu.Unlock()
	c.mu.Lock()
	if c.writers[path] != 0 {
		c.mu.Unlock()
		return nil
	}
	if element := c.entries[path]; element != nil {
		c.lru.MoveToFront(element)
		c.mu.Unlock()
		return nil
	}
	gen, all := c.generations[path], c.all
	for c.used+size > c.capacity && c.lru.Len() > 0 {
		c.remove(c.lru.Back())
	}
	c.mu.Unlock()

	data, err := loader()
	if err != nil {
		return err
	}
	if int64(len(data)) > size || int64(len(data)) > c.capacity {
		return errReadCacheEntryTooLarge
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.generations[path] != gen || c.all != all {
		return nil
	}
	if element := c.entries[path]; element != nil {
		c.lru.MoveToFront(element)
		return nil
	}
	entry := &readCacheEntry{path: path, data: data, gen: gen, all: all}
	c.entries[path] = c.lru.PushFront(entry)
	c.used += int64(len(data))
	return nil
}

func (c *readCache) beginWrite(path string) {
	c.mu.Lock()
	c.writers[path]++
	c.generations[path]++
	if element := c.entries[path]; element != nil {
		c.remove(element)
	}
	c.mu.Unlock()
}

func (c *readCache) endWrite(path string) {
	c.mu.Lock()
	if c.writers[path] > 1 {
		c.writers[path]--
	} else {
		delete(c.writers, path)
	}
	c.generations[path]++
	if element := c.entries[path]; element != nil {
		c.remove(element)
	}
	c.mu.Unlock()
}

func (c *readCache) read(path string, offset int64, size int) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element := c.entries[path]
	if element == nil {
		return nil, false
	}
	entry := element.Value.(*readCacheEntry)
	if entry.gen != c.generations[path] || entry.all != c.all {
		c.remove(element)
		return nil, false
	}
	c.lru.MoveToFront(element)
	if offset < 0 || offset >= int64(len(entry.data)) {
		return []byte{}, true
	}
	end := offset + int64(size)
	if end > int64(len(entry.data)) {
		end = int64(len(entry.data))
	}
	return entry.data[offset:end], true
}

func (c *readCache) invalidate(path string) {
	c.mu.Lock()
	c.generations[path]++
	if element := c.entries[path]; element != nil {
		c.remove(element)
	}
	c.mu.Unlock()
}

func (c *readCache) invalidateAll() {
	c.mu.Lock()
	c.all++
	c.entries = make(map[string]*list.Element)
	c.lru.Init()
	c.used = 0
	c.mu.Unlock()
}

func (c *readCache) remove(element *list.Element) {
	entry := element.Value.(*readCacheEntry)
	delete(c.entries, entry.path)
	c.lru.Remove(element)
	c.used -= int64(len(entry.data))
}
