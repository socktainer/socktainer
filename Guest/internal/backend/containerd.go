package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	runcoptions "github.com/containerd/containerd/api/types/runc/options"
	containerd "github.com/containerd/containerd/v2/client"
	containerrecords "github.com/containerd/containerd/v2/core/containers"
	"github.com/containerd/containerd/v2/core/content"
	containerimages "github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/containerd/containerd/v2/pkg/namespaces"
	"github.com/containerd/containerd/v2/pkg/oci"
	"github.com/containerd/errdefs"
	registryreference "github.com/distribution/reference"
	imagespec "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/opencontainers/runtime-spec/specs-go"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const runtimeMetadataLabel = "io.glassdock.runtime-metadata"
const maxConcurrentTaskCreations = 1
const execCleanupAttempts = 5
const execCleanupAttemptTimeout = 2 * time.Second
const networkCleanupAttempts = 5
const daemonLostExitCode uint32 = 255

func encodeRuntimeMetadata(metadata api.ContainerMetadata) (string, error) {
	data, err := json.Marshal(metadata)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func decodeRuntimeMetadata(labels map[string]string) api.ContainerMetadata {
	var metadata api.ContainerMetadata
	if value := labels[runtimeMetadataLabel]; value != "" {
		_ = json.Unmarshal([]byte(value), &metadata)
	}
	return metadata
}

type Backend struct {
	client        *containerd.Client
	namespace     string
	snapshotter   string
	runtime       string
	runtimeBinary string
	logsDir       string
	logCaptures   sync.Map
	containers    sync.Map
	createMu      sync.Mutex
	metadataMu    sync.Mutex
	network       *NetworkManager
	taskCreates   chan struct{}
	cleanups      orderedCleanupBarrier
	bindMount     bindMountConfiguration
}

type bindMountConfiguration struct {
	hostSource         string
	guestRoot          string
	excludedHostSource string
}

func (b *Backend) ConfigureBindMount(hostSource, guestRoot, excludedHostSource string) {
	b.bindMount = bindMountConfiguration{
		hostSource:         filepath.Clean(hostSource),
		guestRoot:          filepath.Clean(guestRoot),
		excludedHostSource: filepath.Clean(excludedHostSource),
	}
}

func pathContains(parent, child string) bool {
	relative, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(child))
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func resolveBindSource(source string, configuration bindMountConfiguration) (string, error) {
	cleanSource := filepath.Clean(source)
	if pathContains(cleanSource, configuration.excludedHostSource) ||
		pathContains(configuration.excludedHostSource, cleanSource) {
		return "", fmt.Errorf("bind source %q overlaps excluded engine state %q", source, configuration.excludedHostSource)
	}
	relative, err := filepath.Rel(configuration.hostSource, cleanSource)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("bind source %q is outside host bind source %q", source, configuration.hostSource)
	}
	resolvedRoot, err := filepath.EvalSymlinks(configuration.guestRoot)
	if err != nil {
		return "", fmt.Errorf("resolve guest bind root %q: %w", configuration.guestRoot, err)
	}
	guestSource := filepath.Join(resolvedRoot, relative)
	resolvedSource, err := filepath.EvalSymlinks(guestSource)
	if err != nil {
		return "", fmt.Errorf("resolve guest bind source %q: %w", guestSource, err)
	}
	resolvedRelative, err := filepath.Rel(resolvedRoot, resolvedSource)
	if err != nil || resolvedRelative == ".." || strings.HasPrefix(resolvedRelative, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("bind source %q escapes guest bind root %q", source, configuration.guestRoot)
	}
	resolvedHostSource := filepath.Join(configuration.hostSource, resolvedRelative)
	if pathContains(resolvedHostSource, configuration.excludedHostSource) ||
		pathContains(configuration.excludedHostSource, resolvedHostSource) {
		return "", fmt.Errorf("bind source %q resolves into excluded engine state %q", source, configuration.excludedHostSource)
	}
	return resolvedSource, nil
}

type orderedCleanupBarrier struct {
	mu   sync.Mutex
	tail *cleanupResult
}

type cleanupResult struct {
	done chan struct{}
	err  error
}

func (b *orderedCleanupBarrier) enqueue(cleanup func() error) {
	b.mu.Lock()
	prior := b.tail
	result := &cleanupResult{done: make(chan struct{})}
	b.tail = result
	b.mu.Unlock()
	go func() {
		if prior != nil {
			<-prior.done
		}
		for attempt := 0; attempt < networkCleanupAttempts; attempt++ {
			result.err = cleanup()
			if result.err == nil {
				break
			}
			if attempt+1 < networkCleanupAttempts {
				time.Sleep(50 * time.Millisecond)
			}
		}
		close(result.done)
	}()
}

func (b *orderedCleanupBarrier) wait(ctx context.Context) error {
	b.mu.Lock()
	tail := b.tail
	b.mu.Unlock()
	if tail == nil {
		return nil
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-tail.done:
		if tail.err != nil {
			b.mu.Lock()
			if b.tail == tail {
				b.tail = nil
			}
			b.mu.Unlock()
		}
		return tail.err
	}
}

type containerRecord struct {
	container     containerd.Container
	snapshotter   string
	snapshotKey   string
	mu            sync.Mutex
	task          containerd.Task
	taskReaped    bool
	taskReaping   chan struct{}
	spec          *specs.Spec
	persistedExit bool
	persistedCode uint32
}

func (r *containerRecord) setTask(task containerd.Task) {
	r.mu.Lock()
	r.task = task
	r.taskReaped = false
	r.taskReaping = nil
	r.mu.Unlock()
}

func (r *containerRecord) taskState() (containerd.Task, bool, <-chan struct{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.task, r.taskReaped, r.taskReaping
}

func (r *containerRecord) beginTaskReap() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.taskReaped || r.taskReaping != nil {
		return false
	}
	r.taskReaping = make(chan struct{})
	return true
}

func (r *containerRecord) finishTaskReap(reaped bool) {
	r.mu.Lock()
	if reaped {
		r.taskReaped = true
		r.task = nil
	}
	if r.taskReaping != nil {
		close(r.taskReaping)
		r.taskReaping = nil
	}
	r.mu.Unlock()
}

func (r *containerRecord) cachedSpec() *specs.Spec {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.spec
}

func (r *containerRecord) setSpec(spec *specs.Spec) {
	r.mu.Lock()
	r.spec = spec
	r.mu.Unlock()
}

func (r *containerRecord) hasPersistedExit() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persistedExit
}

func (r *containerRecord) persistedExitResult() (uint32, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.persistedCode, r.persistedExit
}

func (r *containerRecord) setPersistedExit(value bool, code uint32) {
	r.mu.Lock()
	r.persistedExit = value
	r.persistedCode = code
	r.mu.Unlock()
}

func New(address, namespace, snapshotter, runtimeName, runtimeBinary string) (*Backend, error) {
	client, err := containerd.New(address)
	if err != nil {
		return nil, err
	}
	return &Backend{
		client: client, namespace: namespace, snapshotter: snapshotter,
		runtime: runtimeName, runtimeBinary: runtimeBinary,
		logsDir: "/var/lib/containerd/io.glassdock.logs",
		network: NewNetworkManager(commandRunner{}), taskCreates: make(chan struct{}, maxConcurrentTaskCreations),
	}, nil
}

func (b *Backend) Close() error             { return b.client.Close() }
func (b *Backend) InitializeNetwork() error { return b.network.Initialize() }

func (b *Backend) acquireTaskCreation(ctx context.Context) error {
	select {
	case b.taskCreates <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (b *Backend) releaseTaskCreation() { <-b.taskCreates }

func (b *Backend) ctx(ctx context.Context) context.Context {
	return namespaces.WithNamespace(ctx, b.namespace)
}

func (b *Backend) Version(ctx context.Context) (string, error) {
	v, err := b.client.Version(b.ctx(ctx))
	if err != nil {
		return "", err
	}
	return v.Version, nil
}

func (b *Backend) Pull(ctx context.Context, request api.ImagePullRequest) (api.ImageResponse, error) {
	if request.Reference == "" {
		return api.ImageResponse{}, errors.New("image reference is required")
	}
	if (request.Username == "") != (request.Secret == "") {
		return api.ImageResponse{}, errors.New("username and secret must be specified together")
	}
	snapshotter := request.Snapshotter
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	resolverOptions := docker.ResolverOptions{}
	if request.Username != "" {
		named, err := registryreference.ParseNormalizedNamed(request.Reference)
		if err != nil {
			return api.ImageResponse{}, fmt.Errorf("parse image reference: %w", err)
		}
		registryHost := registryreference.Domain(named)
		resolverOptions.Credentials = func(host string) (string, string, error) {
			if !sameRegistryHost(registryHost, host) {
				return "", "", nil
			}
			return request.Username, request.Secret, nil
		}
	}
	pullOptions := []containerd.RemoteOpt{
		containerd.WithResolver(docker.NewResolver(resolverOptions)),
		containerd.WithPullSnapshotter(snapshotter),
		containerd.WithPullUnpack,
	}
	if request.Platform != "" {
		pullOptions = append(pullOptions, containerd.WithPlatform(request.Platform))
	}
	image, err := b.client.Pull(b.ctx(ctx), request.Reference, pullOptions...)
	if err != nil {
		return api.ImageResponse{}, err
	}
	return api.ImageResponse{Name: image.Name(), Digest: image.Target().Digest.String()}, nil
}

func sameRegistryHost(expected, challenged string) bool {
	if expected == challenged {
		return true
	}
	dockerHub := map[string]bool{"docker.io": true, "registry-1.docker.io": true, "index.docker.io": true}
	return dockerHub[expected] && dockerHub[challenged]
}

func (b *Backend) Images(ctx context.Context) ([]api.Image, error) {
	ctx = b.ctx(ctx)
	records, err := b.client.ListImages(ctx)
	if err != nil {
		return nil, err
	}
	grouped := make(map[string]*api.Image)
	for _, record := range records {
		config, err := record.Config(ctx)
		if err != nil {
			return nil, err
		}
		id := config.Digest.String()
		item := grouped[id]
		if item == nil {
			size, err := record.Size(ctx)
			if err != nil {
				return nil, err
			}
			spec, err := record.Spec(ctx)
			if err != nil {
				return nil, err
			}
			created := record.Metadata().CreatedAt
			if spec.Created != nil {
				created = *spec.Created
			}
			layers := make([]string, 0, len(spec.RootFS.DiffIDs))
			for _, layer := range spec.RootFS.DiffIDs {
				layers = append(layers, layer.String())
			}
			item = &api.Image{ID: id, Digest: record.Target().Digest.String(), CreatedAt: created, Size: size, Labels: record.Labels(), RootFSLayers: layers}
			grouped[id] = item
		}
		item.References = append(item.References, record.Name())
	}
	out := make([]api.Image, 0, len(grouped))
	for _, item := range grouped {
		sort.Strings(item.References)
		out = append(out, *item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	return out, nil
}

func (b *Backend) Image(ctx context.Context, reference string) (api.Image, error) {
	images, err := b.Images(ctx)
	if err != nil {
		return api.Image{}, err
	}
	var matches []api.Image
	for _, image := range images {
		matched := image.ID == reference || image.Digest == reference || strings.HasPrefix(image.ID, reference) || strings.HasPrefix(strings.TrimPrefix(image.ID, "sha256:"), strings.TrimPrefix(reference, "sha256:"))
		for _, name := range image.References {
			matched = matched || name == reference
		}
		if matched {
			matches = append(matches, image)
		}
	}
	if len(matches) != 1 {
		return api.Image{}, fmt.Errorf("image %s not found or ambiguous", reference)
	}
	return matches[0], nil
}

func (b *Backend) DeleteImage(ctx context.Context, request api.ImageDeleteRequest) (api.ImageDeleteResponse, error) {
	ctx = b.ctx(ctx)
	image, err := b.Image(ctx, request.Reference)
	if err != nil {
		return api.ImageDeleteResponse{}, err
	}
	if !request.Force {
		containers, err := b.client.Containers(ctx)
		if err != nil {
			return api.ImageDeleteResponse{}, err
		}
		for _, container := range containers {
			info, err := container.Info(ctx)
			if err == nil && contains(image.References, info.Image) {
				return api.ImageDeleteResponse{}, fmt.Errorf("image is used by container %s", container.ID())
			}
		}
	}
	name := request.Reference
	if !contains(image.References, name) {
		if len(image.References) != 1 {
			return api.ImageDeleteResponse{}, fmt.Errorf("image ID is referenced by multiple tags")
		}
		name = image.References[0]
	}
	if err := b.client.ImageService().Delete(ctx, name, containerimages.SynchronousDelete()); err != nil {
		return api.ImageDeleteResponse{}, err
	}
	result := api.ImageDeleteResponse{Untagged: []string{name}}
	remaining, err := b.Images(ctx)
	if err == nil {
		stillPresent := false
		for _, candidate := range remaining {
			stillPresent = stillPresent || candidate.ID == image.ID
		}
		if !stillPresent {
			result.Deleted = []string{image.ID}
			result.Reclaimed = image.Size
		}
	}
	return result, nil
}

func (b *Backend) PruneImages(ctx context.Context, request api.ImagePruneRequest) (api.ImageDeleteResponse, error) {
	images, err := b.Images(ctx)
	if err != nil {
		return api.ImageDeleteResponse{}, err
	}
	result := api.ImageDeleteResponse{}
	if !request.All {
		return result, nil
	}
	for _, image := range images {
		for _, reference := range append([]string(nil), image.References...) {
			deleted, err := b.DeleteImage(ctx, api.ImageDeleteRequest{Reference: reference})
			if err != nil {
				if strings.Contains(err.Error(), "image is used by container") {
					continue
				}
				return result, fmt.Errorf("prune image %s: %w", reference, err)
			}
			result.Deleted = append(result.Deleted, deleted.Deleted...)
			result.Untagged = append(result.Untagged, deleted.Untagged...)
			result.Reclaimed += deleted.Reclaimed
		}
	}
	return result, nil
}

func (b *Backend) TagImage(ctx context.Context, request api.ImageTagRequest) (api.ImageResponse, error) {
	ctx = b.ctx(ctx)
	image, err := b.Image(ctx, request.Source)
	if err != nil {
		return api.ImageResponse{}, err
	}
	source, err := b.client.GetImage(ctx, image.References[0])
	if err != nil {
		return api.ImageResponse{}, err
	}
	created, err := b.client.ImageService().Create(ctx, containerimages.Image{Name: request.Target, Target: source.Target()})
	if err != nil {
		if !errdefs.IsAlreadyExists(err) {
			return api.ImageResponse{}, err
		}
		created, err = b.client.ImageService().Get(ctx, request.Target)
		if err != nil || created.Target.Digest != source.Target().Digest {
			return api.ImageResponse{}, fmt.Errorf("target image already exists")
		}
	}
	return api.ImageResponse{Name: created.Name, Digest: image.ID}, nil
}

func contains(items []string, value string) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

func (b *Backend) List(ctx context.Context) ([]api.Container, error) {
	containers, err := b.client.Containers(b.ctx(ctx))
	if err != nil {
		return nil, err
	}
	out := make([]api.Container, 0, len(containers))
	for _, container := range containers {
		item, err := b.inspect(ctx, container)
		if err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, nil
}

func (b *Backend) Inspect(ctx context.Context, id string) (api.Container, error) {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return api.Container{}, err
	}
	return b.inspect(ctx, container)
}

func (b *Backend) inspect(ctx context.Context, container containerd.Container) (api.Container, error) {
	ctx = b.ctx(ctx)
	info, err := container.Info(ctx)
	if err != nil {
		return api.Container{}, err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	result := api.Container{ID: container.ID(), Image: info.Image, Status: "created", CreatedAt: info.CreatedAt, Metadata: metadata}
	task, err := container.Task(ctx, nil)
	if err != nil {
		applyPersistedLifecycle(&result, metadata)
		return result, nil
	}
	status, err := task.Status(ctx)
	if err != nil {
		if errdefs.IsNotFound(err) {
			applyPersistedLifecycle(&result, metadata)
			return result, nil
		}
		return api.Container{}, err
	}
	result.Status, result.PID = string(status.Status), task.Pid()
	if status.Status == containerd.Stopped {
		code := status.ExitStatus
		result.ExitCode = &code
	}
	return result, nil
}

func applyPersistedLifecycle(result *api.Container, metadata api.ContainerMetadata) {
	if metadata.LifecycleState == "running" {
		result.Status = "exited"
		code := daemonLostExitCode
		result.ExitCode = &code
		return
	}
	if metadata.LifecycleState != "exited" || metadata.LastExitCode == nil {
		return
	}
	result.Status = "exited"
	code := *metadata.LastExitCode
	result.ExitCode = &code
}

func (b *Backend) Create(ctx context.Context, request api.ContainerCreateRequest) (api.Container, error) {
	if request.ID == "" || request.Image == "" {
		return api.Container{}, errors.New("id and image are required")
	}
	if err := b.cleanups.wait(ctx); err != nil {
		return api.Container{}, fmt.Errorf("wait for private network cleanup: %w", err)
	}
	var privateNetwork bool
	switch request.Network.Mode {
	case "host":
	case "", "private":
		privateNetwork = true
	case "path":
		if request.Network.Path == "" {
			return api.Container{}, errors.New("network.path is required for path mode")
		}
	default:
		return api.Container{}, fmt.Errorf("unsupported network mode %q", request.Network.Mode)
	}
	ctx = b.ctx(ctx)
	image, err := b.client.GetImage(ctx, request.Image)
	if err != nil {
		return api.Container{}, fmt.Errorf("image must already exist: %w", err)
	}
	snapshotter := request.Snapshotter
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	runtimeName := request.Runtime
	if runtimeName == "" {
		runtimeName = b.runtime
	}
	runtimeBinary := request.RuntimeBinary
	if runtimeBinary == "" {
		runtimeBinary = b.runtimeBinary
	}
	specOpts := []oci.SpecOpts{oci.WithImageConfig(image)}
	if request.Entrypoint != nil || request.Cmd != nil {
		args, err := resolveProcessArgs(ctx, image, request.Entrypoint, request.Cmd)
		if err != nil {
			return api.Container{}, err
		}
		if len(args) == 0 {
			return api.Container{}, errors.New("container command is empty")
		}
		specOpts = append(specOpts, oci.WithProcessArgs(args...))
	} else if len(request.Args) > 0 {
		specOpts = append(specOpts, oci.WithProcessArgs(request.Args...))
	}
	if len(request.Env) > 0 {
		specOpts = append(specOpts, oci.WithEnv(request.Env))
	}
	if request.Cwd != "" {
		specOpts = append(specOpts, oci.WithProcessCwd(request.Cwd))
	}
	if request.User != "" {
		specOpts = append(specOpts, oci.WithUser(request.User))
	}
	if request.Hostname != "" {
		specOpts = append(specOpts, oci.WithHostname(request.Hostname))
	}
	if request.ReadonlyRootfs {
		specOpts = append(specOpts, oci.WithRootFSReadonly())
	}
	mounts, err := toOCIMounts(request.Mounts)
	if err != nil {
		return api.Container{}, err
	}
	for index := range mounts {
		if mounts[index].Type != "bind" {
			continue
		}
		if b.bindMount.hostSource == "" || b.bindMount.guestRoot == "" || b.bindMount.excludedHostSource == "" {
			return api.Container{}, errors.New("bind mount translation is not configured")
		}
		mounts[index].Source, err = resolveBindSource(mounts[index].Source, b.bindMount)
		if err != nil {
			return api.Container{}, err
		}
	}
	if len(mounts) > 0 {
		specOpts = append(specOpts, oci.WithMounts(mounts))
	}
	switch request.Network.Mode {
	case "host":
		specOpts = append(specOpts, oci.WithHostNamespace(specs.NetworkNamespace))
	case "", "private":
		networkPath := b.network.Path(request.ID)
		specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: networkPath}))
	case "path":
		specOpts = append(specOpts, oci.WithLinuxNamespace(specs.LinuxNamespace{Type: specs.NetworkNamespace, Path: request.Network.Path}))
	}
	b.createMu.Lock()
	defer b.createMu.Unlock()
	labels := make(map[string]string, len(request.Labels)+1)
	for key, value := range request.Labels {
		labels[key] = value
	}
	if request.AutoRemove {
		labels["com.glassdock.auto-remove"] = "true"
	}
	metadata := request.Metadata
	if metadata.Name == "" {
		metadata.Name = request.ID
	}
	if metadata.Args == nil {
		metadata.Args = request.Args
	}
	if metadata.Labels == nil {
		metadata.Labels = request.Labels
	}
	metadata.AutoRemove = metadata.AutoRemove || request.AutoRemove
	if privateNetwork {
		// Docker create establishes durable container metadata. The network
		// namespace is only required when runc creates the task, so prepare it
		// after the create response instead of delaying this transaction.
		metadata.PublishedPorts = append([]api.PublishedPort(nil), request.PublishedPorts...)
	}
	encodedMetadata, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return api.Container{}, fmt.Errorf("encode runtime metadata: %w", err)
	}
	labels[runtimeMetadataLabel] = encodedMetadata
	snapshotCreated := false
	newSnapshot := containerd.WithNewSnapshot(request.ID, image)
	trackedSnapshot := func(ctx context.Context, client *containerd.Client, record *containerrecords.Container) error {
		if err := newSnapshot(ctx, client, record); err != nil {
			return err
		}
		snapshotCreated = true
		return nil
	}
	opts := []containerd.NewContainerOpts{containerd.WithImage(image), containerd.WithSnapshotter(snapshotter), trackedSnapshot, containerd.WithNewSpec(specOpts...), containerd.WithContainerLabels(labels)}
	if runtimeName != "" {
		var runtimeOptions any
		if runtimeBinary != "" {
			runtimeOptions = &runcoptions.Options{BinaryName: runtimeBinary}
		}
		opts = append(opts, containerd.WithRuntime(runtimeName, runtimeOptions))
	}
	container, err := b.client.NewContainer(ctx, request.ID, opts...)
	if err != nil {
		if snapshotCreated {
			_ = b.client.SnapshotService(snapshotter).Remove(ctx, request.ID)
		}
		return api.Container{}, err
	}
	record := &containerRecord{
		container: container, snapshotter: snapshotter, snapshotKey: request.ID,
	}
	b.containers.Store(request.ID, record)
	info, err := container.Info(ctx)
	if err != nil {
		return api.Container{}, err
	}
	return api.Container{
		ID: container.ID(), Image: info.Image, Status: "created", CreatedAt: info.CreatedAt, Metadata: metadata,
	}, nil
}

func resolveProcessArgs(ctx context.Context, image containerd.Image, entrypoint, cmd *[]string) ([]string, error) {
	descriptor, err := image.Config(ctx)
	if err != nil {
		return nil, err
	}
	if !containerimages.IsConfigType(descriptor.MediaType) {
		return nil, fmt.Errorf("unknown image config media type %s", descriptor.MediaType)
	}
	data, err := content.ReadBlob(ctx, image.ContentStore(), descriptor)
	if err != nil {
		return nil, err
	}
	var imageConfig imagespec.Image
	if err := json.Unmarshal(data, &imageConfig); err != nil {
		return nil, err
	}
	return resolveImageProcessArgs(
		imageConfig.Config.Entrypoint, imageConfig.Config.Cmd, entrypoint, cmd,
	), nil
}

func resolveImageProcessArgs(imageEntrypoint, imageCmd []string, entrypoint, cmd *[]string) []string {
	resolvedEntrypoint := imageEntrypoint
	resolvedCmd := imageCmd
	if entrypoint != nil {
		resolvedEntrypoint = *entrypoint
	}
	if cmd != nil {
		resolvedCmd = *cmd
	}
	return append(append([]string(nil), resolvedEntrypoint...), resolvedCmd...)
}

func (b *Backend) persistRunningState(ctx context.Context, container containerd.Container, published []api.PublishedPort) error {
	return b.updateRuntimeMetadata(ctx, container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "running"
		metadata.LastExitCode = nil
		metadata.PublishedPorts = published
	})
}

func (b *Backend) updateRuntimeMetadata(ctx context.Context, container containerd.Container, update func(*api.ContainerMetadata)) error {
	b.metadataMu.Lock()
	defer b.metadataMu.Unlock()
	ctx = b.ctx(ctx)
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	update(&metadata)
	encoded, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return err
	}
	if info.Labels == nil {
		info.Labels = make(map[string]string)
	}
	info.Labels[runtimeMetadataLabel] = encoded
	return container.Update(ctx, func(_ context.Context, _ *containerd.Client, record *containerrecords.Container) error {
		record.Labels = info.Labels
		return nil
	})
}

func (b *Backend) prepareNetwork(id string, publishedPorts []api.PublishedPort) ([]api.PublishedPort, error) {
	if _, err := b.network.Create(id); err != nil {
		return nil, err
	}
	published, err := b.network.Publish(id, publishedPorts)
	if err != nil {
		_ = b.network.Delete(id)
		return nil, err
	}
	return published, nil
}

func (b *Backend) persistExitState(ctx context.Context, record *containerRecord, code uint32) error {
	err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = "exited"
		metadata.LastExitCode = &code
	})
	if err == nil {
		record.setPersistedExit(true, code)
	}
	return err
}

func (b *Backend) clearExitState(ctx context.Context, record *containerRecord) error {
	if !record.hasPersistedExit() {
		return nil
	}
	err := b.updateRuntimeMetadata(ctx, record.container, func(metadata *api.ContainerMetadata) {
		metadata.LifecycleState = ""
		metadata.LastExitCode = nil
	})
	if err == nil {
		record.setPersistedExit(false, 0)
	}
	return err
}

func (b *Backend) UpdateContainerMetadata(ctx context.Context, request api.ContainerMetadataUpdateRequest) error {
	b.metadataMu.Lock()
	defer b.metadataMu.Unlock()
	ctx = b.ctx(ctx)
	container, err := b.client.LoadContainer(ctx, request.ID)
	if err != nil {
		return err
	}
	info, err := container.Info(ctx)
	if err != nil {
		return err
	}
	metadata := decodeRuntimeMetadata(info.Labels)
	metadata.PortBindings = request.PortBindings
	encoded, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		return err
	}
	info.Labels[runtimeMetadataLabel] = encoded
	return container.Update(ctx, func(_ context.Context, _ *containerd.Client, record *containerrecords.Container) error {
		record.Labels = info.Labels
		return nil
	})
}

func toOCIMounts(input []api.Mount) ([]specs.Mount, error) {
	result := make([]specs.Mount, 0, len(input))
	for _, mount := range input {
		if mount.Target == "" || !filepath.IsAbs(mount.Target) {
			return nil, errors.New("mount target must be absolute")
		}
		switch mount.Type {
		case "bind", "tmpfs", "proc", "sysfs", "devpts", "mqueue":
		default:
			return nil, fmt.Errorf("unsupported mount type %q", mount.Type)
		}
		if mount.Type == "bind" && (mount.Source == "" || !filepath.IsAbs(mount.Source)) {
			return nil, errors.New("bind mount source must be absolute")
		}
		options := append([]string(nil), mount.Options...)
		if mount.Type == "bind" {
			hasBind := false
			for _, option := range options {
				if option == "bind" || option == "rbind" {
					hasBind = true
					break
				}
			}
			if !hasBind {
				options = append(options, "rbind")
			}
		}
		if mount.Readonly {
			options = append(options, "ro")
		}
		source := mount.Source
		if source == "" {
			source = mount.Type
		}
		result = append(result, specs.Mount{Source: source, Destination: mount.Target, Type: mount.Type, Options: options})
	}
	return result, nil
}

func (b *Backend) AutoRemove(ctx context.Context, id string) bool {
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return false
	}
	labels, err := container.Labels(b.ctx(ctx))
	return err == nil && labels["com.glassdock.auto-remove"] == "true"
}

func (b *Backend) Start(ctx context.Context, request api.ContainerStartRequest) (api.Container, error) {
	ctx = b.ctx(ctx)
	id := request.ID
	record, ok := b.loadRecord(id)
	var container containerd.Container
	if ok {
		container = record.container
	} else {
		var err error
		container, err = b.client.LoadContainer(ctx, id)
		if err != nil {
			return api.Container{}, err
		}
		record, err = b.record(ctx, id, container)
		if err != nil {
			return api.Container{}, err
		}
	}
	published, err := b.prepareNetwork(id, request.PublishedPorts)
	if err != nil {
		return api.Container{}, err
	}
	rollbackNetwork := func() { _ = b.network.Delete(id) }
	task, _, _ := record.taskState()
	if err := b.clearExitState(ctx, record); err != nil {
		rollbackNetwork()
		return api.Container{}, err
	}
	if task == nil {
		if err := b.acquireTaskCreation(ctx); err != nil {
			rollbackNetwork()
			return api.Container{}, err
		}
		defer b.releaseTaskCreation()
		capture, err := b.createLogCapture(id)
		if err != nil {
			rollbackNetwork()
			return api.Container{}, err
		}
		task, err = container.NewTask(
			ctx,
			cio.NewCreator(cio.WithStreams(nil, capture.stdout, capture.stderr)),
		)
		if err != nil {
			capture.close()
			b.removeLogs(id)
			rollbackNetwork()
			return api.Container{}, err
		}
		capture.io = task.IO()
		b.logCaptures.Store(id, capture)
	}
	if err := task.Start(ctx); err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
		_, _ = task.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		record.setTask(nil)
		b.removeLogs(id)
		rollbackNetwork()
		return api.Container{}, err
	}
	record.setTask(task)
	if err := b.persistRunningState(ctx, container, published); err != nil {
		_ = task.Kill(b.ctx(context.Background()), syscall.SIGKILL)
		_, _ = task.Delete(b.ctx(context.Background()), containerd.WithProcessKill)
		record.setTask(nil)
		rollbackNetwork()
		return api.Container{}, err
	}
	info, _ := container.Info(ctx)
	metadata := decodeRuntimeMetadata(info.Labels)
	if len(published) == 0 {
		published = metadata.PublishedPorts
	}
	return api.Container{
		ID: id, Status: string(containerd.Running), PID: task.Pid(),
		PublishedPorts: published, Metadata: metadata,
	}, nil
}

func (b *Backend) Wait(ctx context.Context, id string) (uint32, time.Time, error) {
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(id)
	var task containerd.Task
	if ok {
		if code, exited := record.persistedExitResult(); exited {
			return code, time.Time{}, nil
		}
		task, _, _ = record.taskState()
	}
	if task == nil {
		container, err := b.client.LoadContainer(ctx, id)
		if err != nil {
			return 0, time.Time{}, err
		}
		record, err = b.record(ctx, id, container)
		if err != nil {
			return 0, time.Time{}, err
		}
		if code, exited := record.persistedExitResult(); exited {
			return code, time.Time{}, nil
		}
		task, err = container.Task(ctx, nil)
		if err != nil {
			info, infoErr := container.Info(ctx)
			if infoErr == nil && decodeRuntimeMetadata(info.Labels).LifecycleState == "running" {
				persistCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				persistErr := b.persistExitState(persistCtx, record, daemonLostExitCode)
				cancel()
				if persistErr == nil {
					return daemonLostExitCode, time.Time{}, nil
				}
			}
			return 0, time.Time{}, err
		}
		record.setTask(task)
	}
	status, err := task.Wait(ctx)
	if err != nil {
		return 0, time.Time{}, err
	}
	exit := <-status
	code, exitedAt, err := exit.Result()
	b.finishLogCapture(id)
	if err == nil {
		persistCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		persistErr := b.persistExitState(persistCtx, record, code)
		cancel()
		if persistErr == nil {
			go b.reapTask(record, task)
		}
	}
	return code, exitedAt, err
}

func (b *Backend) reapTask(record *containerRecord, task containerd.Task) {
	if !record.beginTaskReap() {
		return
	}
	ctx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
	defer cancel()
	_, err := task.Delete(ctx)
	record.finishTaskReap(err == nil || errdefs.IsNotFound(err))
}

func (b *Backend) Kill(ctx context.Context, id string, signal uint32) error {
	if signal == 0 {
		signal = uint32(syscall.SIGTERM)
	}
	container, err := b.client.LoadContainer(b.ctx(ctx), id)
	if err != nil {
		return err
	}
	task, err := container.Task(b.ctx(ctx), nil)
	if err != nil {
		return err
	}
	return task.Kill(b.ctx(ctx), syscall.Signal(signal))
}

func (b *Backend) Delete(ctx context.Context, request api.ContainerDeleteRequest) error {
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(request.ID)
	if !ok {
		container, err := b.client.LoadContainer(ctx, request.ID)
		if err != nil {
			return err
		}
		info, err := container.Info(ctx)
		if err != nil {
			return err
		}
		record = &containerRecord{
			container: container, snapshotter: info.Snapshotter, snapshotKey: info.SnapshotKey,
		}
	}
	task, reaped, reaping := record.taskState()
	if reaping != nil {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-reaping:
		}
		task, reaped, _ = record.taskState()
	}
	if task != nil && !reaped {
		if !request.Force {
			status, err := task.Status(ctx)
			if err != nil {
				return err
			}
			if err := validateTaskRemoval(false, string(status.Status)); err != nil {
				return err
			}
		}
		if request.Force {
			_ = task.Kill(ctx, syscall.SIGKILL)
		}
		deleteOptions := []containerd.ProcessDeleteOpts{}
		if request.Force {
			deleteOptions = append(deleteOptions, containerd.WithProcessKill)
		}
		if _, err := task.Delete(ctx, deleteOptions...); err != nil && !errdefs.IsNotFound(err) {
			return err
		}
		record.finishTaskReap(true)
	} else if !ok {
		if task, taskErr := record.container.Task(ctx, nil); taskErr == nil {
			if !request.Force {
				status, err := task.Status(ctx)
				if err != nil {
					return err
				}
				if err := validateTaskRemoval(false, string(status.Status)); err != nil {
					return err
				}
			}
			if request.Force {
				_ = task.Kill(ctx, syscall.SIGKILL)
			}
			deleteOptions := []containerd.ProcessDeleteOpts{}
			if request.Force {
				deleteOptions = append(deleteOptions, containerd.WithProcessKill)
			}
			if _, err := task.Delete(ctx, deleteOptions...); err != nil && !errdefs.IsNotFound(err) {
				return err
			}
		}
	}
	if err := record.container.Delete(ctx); err != nil {
		return err
	}
	b.containers.Delete(request.ID)
	if request.Snapshot && record.snapshotKey != "" {
		go b.removeSnapshot(record.snapshotter, record.snapshotKey)
	}
	b.removeLogs(request.ID)
	b.cleanups.enqueue(func() error { return b.network.Delete(request.ID) })
	return nil
}

func validateTaskRemoval(force bool, status string) error {
	if !force && status != string(containerd.Stopped) {
		return errors.New("cannot remove a running container without force")
	}
	return nil
}

func (b *Backend) loadRecord(id string) (*containerRecord, bool) {
	value, ok := b.containers.Load(id)
	if !ok {
		return nil, false
	}
	return value.(*containerRecord), true
}

func newRestoredContainerRecord(container containerd.Container, info containerrecords.Container) *containerRecord {
	metadata := decodeRuntimeMetadata(info.Labels)
	var persistedCode uint32
	if metadata.LastExitCode != nil {
		persistedCode = *metadata.LastExitCode
	}
	return &containerRecord{
		container:     container,
		snapshotter:   info.Snapshotter,
		snapshotKey:   info.SnapshotKey,
		persistedExit: metadata.LifecycleState == "exited" && metadata.LastExitCode != nil,
		persistedCode: persistedCode,
	}
}

func (b *Backend) record(ctx context.Context, id string, container containerd.Container) (*containerRecord, error) {
	if record, ok := b.loadRecord(id); ok {
		return record, nil
	}
	info, err := container.Info(ctx)
	if err != nil {
		return nil, err
	}
	record := newRestoredContainerRecord(container, info)
	actual, _ := b.containers.LoadOrStore(id, record)
	return actual.(*containerRecord), nil
}

func (b *Backend) removeSnapshot(snapshotter, key string) {
	if snapshotter == "" {
		snapshotter = b.snapshotter
	}
	service := b.client.SnapshotService(snapshotter)
	for attempt := 0; attempt < 5; attempt++ {
		ctx, cancel := context.WithTimeout(b.ctx(context.Background()), 30*time.Second)
		err := service.Remove(ctx, key)
		cancel()
		if err == nil || errdefs.IsNotFound(err) {
			return
		}
		time.Sleep(time.Duration(1<<attempt) * 10 * time.Millisecond)
	}
}

type StreamFunc func(stream string, data []byte) error

type execCleanupFunc func(context.Context) error

func runExecCleanup(cleanup execCleanupFunc, pause func(time.Duration)) {
	for attempt := 0; attempt < execCleanupAttempts; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), execCleanupAttemptTimeout)
		err := cleanup(ctx)
		cancel()
		if err == nil || errdefs.IsNotFound(err) {
			return
		}
		if attempt+1 < execCleanupAttempts {
			pause(time.Duration(1<<attempt) * 10 * time.Millisecond)
		}
	}
}

func scheduleExecCleanup(cleanup execCleanupFunc) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		defer close(done)
		runExecCleanup(cleanup, time.Sleep)
	}()
	return done
}

type streamWriter struct {
	stream string
	send   StreamFunc
}

func (w streamWriter) Write(p []byte) (int, error) {
	copyOfP := append([]byte(nil), p...)
	if err := w.send(w.stream, copyOfP); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (b *Backend) Exec(ctx context.Context, request api.ContainerExecRequest, stream StreamFunc) (int32, error) {
	if request.ID == "" || request.ExecID == "" || len(request.Args) == 0 {
		return 0, errors.New("id, execId, and args are required")
	}
	ctx = b.ctx(ctx)
	record, ok := b.loadRecord(request.ID)
	var container containerd.Container
	var task containerd.Task
	if ok {
		container = record.container
		task, _, _ = record.taskState()
	} else {
		var err error
		container, err = b.client.LoadContainer(ctx, request.ID)
		if err != nil {
			return 0, err
		}
		record, err = b.record(ctx, request.ID, container)
		if err != nil {
			return 0, err
		}
	}
	if task == nil {
		var err error
		task, err = container.Task(ctx, nil)
		if err != nil {
			return 0, err
		}
		record.setTask(task)
	}
	containerSpec := record.cachedSpec()
	if containerSpec == nil {
		var err error
		containerSpec, err = container.Spec(ctx)
		if err != nil {
			return 0, err
		}
		record.setSpec(containerSpec)
	}
	cwd := request.Cwd
	if cwd == "" {
		cwd = containerSpec.Process.Cwd
	}
	env := append([]string(nil), containerSpec.Process.Env...)
	env = append(env, request.Env...)
	processSpec := &specs.Process{Args: request.Args, Env: env, Cwd: cwd, Terminal: request.Terminal, User: containerSpec.Process.User}
	if request.User != "" {
		info, err := container.Info(ctx)
		if err != nil {
			return 0, err
		}
		specCopy := *containerSpec
		processCopy := *containerSpec.Process
		specCopy.Process = &processCopy
		if err := oci.WithUser(request.User)(ctx, b.client, &info, &specCopy); err != nil {
			return 0, err
		}
		processSpec.User = specCopy.Process.User
	}
	var stdout, stderr io.Writer = streamWriter{"stdout", stream}, streamWriter{"stderr", stream}
	if request.Terminal {
		stderr = bytes.NewBuffer(nil)
	}
	process, err := task.Exec(ctx, request.ExecID, processSpec, cio.NewCreator(cio.WithStreams(nil, stdout, stderr)))
	if err != nil {
		return 0, err
	}
	wait, err := process.Wait(ctx)
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), execCleanupAttemptTimeout)
		_, _ = process.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		return 0, err
	}
	if err := process.Start(ctx); err != nil {
		cleanupCtx, cancel := context.WithTimeout(b.ctx(context.Background()), execCleanupAttemptTimeout)
		_, _ = process.Delete(cleanupCtx, containerd.WithProcessKill)
		cancel()
		return 0, err
	}
	exit := <-wait
	code, _, err := exit.Result()
	if processIO := process.IO(); processIO != nil {
		processIO.Wait()
	}
	scheduleExecCleanup(func(cleanupCtx context.Context) error {
		_, cleanupErr := process.Delete(b.ctx(cleanupCtx))
		return cleanupErr
	})
	if err != nil {
		return 0, err
	}
	return int32(code), nil
}
