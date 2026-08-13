//go:build linux

package bindcache

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

type Cache struct {
	server   *fuse.Server
	root     *cacheNode
	barriers *BarrierCoordinator
	reads    *readCache
	source   string
	mu       sync.RWMutex
	nodes    map[string]*cacheNode
}

type cacheNode struct {
	fs.LoopbackNode
	cache *Cache
}

func Mount(source, target string, barrierTimeout time.Duration) (*Cache, error) {
	if source == "" || target == "" {
		return nil, errors.New("bind cache source and target are required")
	}
	if _, err := os.Stat("/dev/fuse"); err != nil {
		return nil, errors.New("guest FUSE device is unavailable: " + err.Error())
	}
	if err := os.MkdirAll(target, 0o755); err != nil {
		return nil, err
	}
	loopback, err := fs.NewLoopbackRoot(source)
	if err != nil {
		return nil, err
	}
	data := loopback.(*fs.LoopbackNode).RootData
	cache := &Cache{
		barriers: NewBarrierCoordinator(barrierTimeout),
		nodes:    make(map[string]*cacheNode),
		reads:    newReadCache(maximumReadCacheBytes),
		source:   filepath.Clean(source),
	}
	data.NewNode = func(root *fs.LoopbackRoot, _ *fs.Inode, _ string, _ *syscall.Stat_t) fs.InodeEmbedder {
		return &cacheNode{LoopbackNode: fs.LoopbackNode{RootData: root}, cache: cache}
	}
	root := &cacheNode{LoopbackNode: fs.LoopbackNode{RootData: data}, cache: cache}
	data.RootNode = root
	cache.root = root
	cache.nodes[""] = root
	oneSecond := time.Second
	server, err := fs.Mount(target, root, &fs.Options{
		MountOptions: fuse.MountOptions{
			Name: "socktainer-bind-cache", FsName: source,
			MaxWrite: 1 << 20, MaxBackground: 64,
		},
		EntryTimeout:    &oneSecond,
		AttrTimeout:     &oneSecond,
		NegativeTimeout: &oneSecond,
	})
	if err != nil {
		return nil, err
	}
	cache.server = server
	return cache, nil
}

func (c *Cache) SetBarrierEmitter(emit func(WriteBarrier) error) { c.barriers.SetEmitter(emit) }

func (c *Cache) InstallBarrierEmitter(emit func(WriteBarrier) error) func() {
	return c.barriers.InstallEmitter(emit)
}

func (c *Cache) Invalidate(paths []string, all bool, barrierID uint64) {
	if all {
		c.reads.invalidateAll()
	} else {
		for _, input := range paths {
			c.reads.invalidate(cleanRelative(input))
		}
	}
	c.mu.RLock()
	if all {
		paths = make([]string, 0, len(c.nodes))
		for path := range c.nodes {
			paths = append(paths, path)
		}
	}
	type invalidation struct {
		node   *cacheNode
		parent *cacheNode
		name   string
	}
	invalidations := make([]invalidation, 0, len(paths))
	for _, input := range paths {
		path := cleanRelative(input)
		invalidations = append(invalidations, invalidation{
			node: c.nodes[path], parent: c.nodes[cleanRelative(filepath.Dir(path))], name: filepath.Base(path),
		})
	}
	c.mu.RUnlock()
	// A barrier originates inside a FUSE mutation. Release that mutation after
	// the in-process read cache is invalidated, before advisory kernel
	// notifications. NotifyContent or NotifyEntry can wait for the same in-flight
	// operation and would otherwise create a circular wait that returns EIO even
	// though the backing rename or fsync already succeeded.
	if barrierID != 0 {
		c.barriers.Acknowledge(barrierID)
	}
	for _, item := range invalidations {
		if item.node != nil {
			_ = item.node.EmbeddedInode().NotifyContent(0, -1)
		}
		if item.parent != nil && item.name != "." {
			_ = item.parent.EmbeddedInode().NotifyEntry(item.name)
		}
	}
}

func (c *Cache) Close() error { return c.server.Unmount() }

func (n *cacheNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	path := n.cache.track(n)
	readOnly := flags&syscall.O_ACCMODE == syscall.O_RDONLY
	if !readOnly {
		n.cache.reads.beginWrite(path)
	}
	handle, _, errno := n.LoopbackNode.Open(ctx, flags)
	if errno != 0 {
		if !readOnly {
			n.cache.reads.endWrite(path)
		}
		return nil, 0, errno
	}
	if !readOnly {
		// The second generation change closes the window around O_TRUNC and
		// prevents a concurrent eager load from committing pre-truncate bytes.
		n.cache.reads.invalidate(path)
	}
	barrier := &barrierFile{FileHandle: handle, path: path, barriers: n.cache.barriers, reads: n.cache.reads, writer: !readOnly}
	if !readOnly {
		return barrier, fuse.FOPEN_KEEP_CACHE, 0
	}
	_ = n.cache.loadReadFile(path)
	return &cachedReadFile{barrierFile: barrier}, fuse.FOPEN_DIRECT_IO, 0
}

func (n *cacheNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	inode, handle, _, errno := n.LoopbackNode.Create(ctx, name, flags, mode, out)
	if errno != 0 {
		return nil, nil, 0, errno
	}
	path := filepath.Join(n.cache.track(n), name)
	path = cleanRelative(path)
	n.cache.reads.beginWrite(path)
	if child, ok := inode.Operations().(*cacheNode); ok {
		n.cache.track(child)
	}
	return inode, &barrierFile{FileHandle: handle, path: path, barriers: n.cache.barriers, reads: n.cache.reads, writer: true}, fuse.FOPEN_KEEP_CACHE, 0
}

func (n *cacheNode) mutationPath(name string) string {
	return cleanRelative(filepath.Join(n.cache.track(n), name))
}

func (n *cacheNode) finishNamespaceMutation(ctx context.Context, paths ...string) syscall.Errno {
	n.cache.reads.invalidateAll()
	for _, path := range paths {
		if err := n.cache.barriers.Wait(ctx, path); err != nil {
			return syscall.EIO
		}
	}
	return 0
}

func (n *cacheNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	inode, errno := n.LoopbackNode.Mkdir(ctx, name, mode, out)
	if errno == 0 {
		errno = n.finishNamespaceMutation(ctx, n.mutationPath(name))
	}
	return inode, errno
}

func (n *cacheNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	if errno := n.LoopbackNode.Rmdir(ctx, name); errno != 0 {
		return errno
	}
	return n.finishNamespaceMutation(ctx, n.mutationPath(name))
}

func (n *cacheNode) Unlink(ctx context.Context, name string) syscall.Errno {
	if errno := n.LoopbackNode.Unlink(ctx, name); errno != 0 {
		return errno
	}
	return n.finishNamespaceMutation(ctx, n.mutationPath(name))
}

func (n *cacheNode) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	newNode, ok := newParent.(*cacheNode)
	if !ok {
		return syscall.EXDEV
	}
	oldPath := n.mutationPath(name)
	newPath := newNode.mutationPath(newName)
	if errno := n.LoopbackNode.Rename(ctx, name, &newNode.LoopbackNode, newName, flags); errno != 0 {
		return errno
	}
	return n.finishNamespaceMutation(ctx, oldPath, newPath)
}

func (n *cacheNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	inode, errno := n.LoopbackNode.Symlink(ctx, target, name, out)
	if errno == 0 {
		errno = n.finishNamespaceMutation(ctx, n.mutationPath(name))
	}
	return inode, errno
}

func (n *cacheNode) Link(ctx context.Context, target fs.InodeEmbedder, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	inode, errno := n.LoopbackNode.Link(ctx, target, name, out)
	if errno == 0 {
		errno = n.finishNamespaceMutation(ctx, n.mutationPath(name))
	}
	return inode, errno
}

func (c *Cache) loadReadFile(path string) error {
	file, err := os.Open(filepath.Join(c.source, path))
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > maximumReadCacheBytes {
		return errReadCacheEntryTooLarge
	}
	return c.reads.load(path, info.Size(), func() ([]byte, error) {
		data := make([]byte, info.Size())
		_, err := io.ReadFull(file, data)
		if errors.Is(err, io.EOF) && len(data) == 0 {
			err = nil
		}
		if err == nil {
			after, statErr := file.Stat()
			if statErr != nil {
				return nil, statErr
			}
			if after.Size() != info.Size() || !after.ModTime().Equal(info.ModTime()) {
				return nil, errors.New("bind file changed while loading the read cache")
			}
		}
		return data, err
	})
}

func (n *cacheNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	child, errno := n.LoopbackNode.Lookup(ctx, name, out)
	if errno == 0 {
		if node, ok := child.Operations().(*cacheNode); ok {
			n.cache.track(node)
		}
	}
	return child, errno
}

func safeSymlinkTarget(nodePath, target string) bool {
	if filepath.IsAbs(target) {
		return false
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(cleanRelative(nodePath)), target))
	return resolved != ".." && !strings.HasPrefix(resolved, ".."+string(filepath.Separator))
}

// Readlink enforces containment at the FUSE boundary. This check happens when
// the kernel follows the link, so a host-side replacement after bind-source
// validation cannot redirect an OCI mount into guest control paths.
func (n *cacheNode) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	target, errno := n.LoopbackNode.Readlink(ctx)
	if errno != 0 {
		return nil, errno
	}
	if !safeSymlinkTarget(n.cache.track(n), string(target)) {
		return nil, syscall.EPERM
	}
	return target, 0
}

func (n *cacheNode) OnForget() {
	path := cleanRelative(n.Path(n.cache.root.EmbeddedInode()))
	n.cache.mu.Lock()
	if n.cache.nodes[path] == n {
		delete(n.cache.nodes, path)
	}
	n.cache.mu.Unlock()
}

func (c *Cache) track(node *cacheNode) string {
	path := cleanRelative(node.Path(c.root.EmbeddedInode()))
	c.mu.Lock()
	c.nodes[path] = node
	c.mu.Unlock()
	return path
}

func cleanRelative(path string) string {
	path = strings.TrimPrefix(filepath.Clean(path), string(filepath.Separator))
	if path == "." {
		return ""
	}
	return path
}

type barrierFile struct {
	fs.FileHandle
	path     string
	barriers *BarrierCoordinator
	reads    *readCache
	writer   bool
}

type cachedReadFile struct{ *barrierFile }

func (f *cachedReadFile) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if data, ok := f.reads.read(f.path, off, len(dest)); ok {
		return fuse.ReadResultData(data), 0
	}
	return f.barrierFile.Read(ctx, dest, off)
}

func (f *barrierFile) Read(ctx context.Context, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	return f.FileHandle.(fs.FileReader).Read(ctx, dest, off)
}
func (f *barrierFile) Write(ctx context.Context, data []byte, off int64) (uint32, syscall.Errno) {
	f.reads.invalidate(f.path)
	written, errno := f.FileHandle.(fs.FileWriter).Write(ctx, data, off)
	// Bracket the backing write with generations. A load that starts after the
	// first invalidation but before pwrite completes cannot publish old bytes.
	f.reads.invalidate(f.path)
	return written, errno
}
func (f *barrierFile) Flush(ctx context.Context) syscall.Errno {
	return f.FileHandle.(fs.FileFlusher).Flush(ctx)
}
func (f *barrierFile) Release(ctx context.Context) syscall.Errno {
	errno := f.FileHandle.(fs.FileReleaser).Release(ctx)
	if f.writer {
		f.reads.endWrite(f.path)
	}
	return errno
}

func (f *barrierFile) Fsync(ctx context.Context, flags uint32) syscall.Errno {
	if errno := f.FileHandle.(fs.FileFsyncer).Fsync(ctx, flags); errno != 0 {
		return errno
	}
	if err := f.barriers.Wait(ctx, f.path); err != nil {
		return syscall.EIO
	}
	return 0
}

func (f *barrierFile) Getattr(ctx context.Context, out *fuse.AttrOut) syscall.Errno {
	return f.FileHandle.(fs.FileGetattrer).Getattr(ctx, out)
}

func (f *barrierFile) Statx(ctx context.Context, flags uint32, mask uint32, out *fuse.StatxOut) syscall.Errno {
	return f.FileHandle.(fs.FileStatxer).Statx(ctx, flags, mask, out)
}

func (f *barrierFile) Getlk(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32, out *fuse.FileLock) syscall.Errno {
	return f.FileHandle.(fs.FileGetlker).Getlk(ctx, owner, lk, flags, out)
}

func (f *barrierFile) Setlk(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32) syscall.Errno {
	return f.FileHandle.(fs.FileSetlker).Setlk(ctx, owner, lk, flags)
}

func (f *barrierFile) Setlkw(ctx context.Context, owner uint64, lk *fuse.FileLock, flags uint32) syscall.Errno {
	return f.FileHandle.(fs.FileSetlkwer).Setlkw(ctx, owner, lk, flags)
}

func (f *barrierFile) Lseek(ctx context.Context, off uint64, whence uint32) (uint64, syscall.Errno) {
	return f.FileHandle.(fs.FileLseeker).Lseek(ctx, off, whence)
}

func (f *barrierFile) Setattr(ctx context.Context, in *fuse.SetAttrIn, out *fuse.AttrOut) syscall.Errno {
	f.reads.invalidate(f.path)
	errno := f.FileHandle.(fs.FileSetattrer).Setattr(ctx, in, out)
	f.reads.invalidate(f.path)
	return errno
}

func (f *barrierFile) Allocate(ctx context.Context, off uint64, size uint64, mode uint32) syscall.Errno {
	f.reads.invalidate(f.path)
	errno := f.FileHandle.(fs.FileAllocater).Allocate(ctx, off, size, mode)
	f.reads.invalidate(f.path)
	return errno
}

func (f *barrierFile) Ioctl(ctx context.Context, cmd uint32, arg uint64, input []byte, output []byte) (int32, syscall.Errno) {
	return f.FileHandle.(fs.FileIoctler).Ioctl(ctx, cmd, arg, input, output)
}
