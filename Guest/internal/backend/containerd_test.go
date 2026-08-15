package backend

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	containerrecords "github.com/containerd/containerd/v2/core/containers"
	"github.com/glassdock/glassdock/guest/internal/api"
)

func TestExecCleanupRetriesUntilSuccess(t *testing.T) {
	t.Parallel()
	attempts := 0
	pauses := 0
	runExecCleanup(func(context.Context) error {
		attempts++
		if attempts < 3 {
			return errors.New("not ready")
		}
		return nil
	}, func(time.Duration) {
		pauses++
	})
	if attempts != 3 {
		t.Fatalf("got %d cleanup attempts, want 3", attempts)
	}
	if pauses != 2 {
		t.Fatalf("got %d retry pauses, want 2", pauses)
	}
}

func TestExecCleanupStopsAfterBoundedAttempts(t *testing.T) {
	t.Parallel()
	attempts := 0
	runExecCleanup(func(context.Context) error {
		attempts++
		return errors.New("persistent failure")
	}, func(time.Duration) {})
	if attempts != execCleanupAttempts {
		t.Fatalf("got %d cleanup attempts, want %d", attempts, execCleanupAttempts)
	}
}

func TestExecCleanupSchedulingDoesNotWaitForDelete(t *testing.T) {
	t.Parallel()
	started := make(chan struct{})
	release := make(chan struct{})
	done := scheduleExecCleanup(func(context.Context) error {
		close(started)
		<-release
		return nil
	})
	<-started
	select {
	case <-done:
		t.Fatal("cleanup completed before delete was released")
	default:
	}
	close(release)
	<-done
}

func TestTaskCreationQueueBoundsConcurrentRuncWork(t *testing.T) {
	t.Parallel()
	backend := &Backend{taskCreates: make(chan struct{}, maxConcurrentTaskCreations)}
	if err := backend.acquireTaskCreation(context.Background()); err != nil {
		t.Fatal(err)
	}
	acquired := make(chan struct{})
	go func() {
		_ = backend.acquireTaskCreation(context.Background())
		close(acquired)
	}()
	select {
	case <-acquired:
		t.Fatal("second runc create bypassed the queue")
	default:
	}
	backend.releaseTaskCreation()
	<-acquired
	backend.releaseTaskCreation()
}

func TestTaskCreationTimeoutStartsAfterQueue(t *testing.T) {
	t.Parallel()
	backend := &Backend{taskCreates: make(chan struct{}, maxConcurrentTaskCreations)}
	if err := backend.acquireTaskCreation(context.Background()); err != nil {
		t.Fatal(err)
	}
	waiting := make(chan error, 1)
	go func() {
		waiting <- backend.acquireTaskCreation(context.Background())
	}()
	select {
	case err := <-waiting:
		t.Fatalf("queued create completed early: %v", err)
	default:
	}
	backend.releaseTaskCreation()
	if err := <-waiting; err != nil {
		t.Fatal(err)
	}
	backend.releaseTaskCreation()
}

func TestContainerRecordCoordinatesTaskReaping(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginTaskReap() {
		t.Fatal("first reaper must own task deletion")
	}
	if record.beginTaskReap() {
		t.Fatal("second reaper must not own task deletion")
	}
	_, reaped, waiting := record.taskState()
	if reaped || waiting == nil {
		t.Fatal("task must report an active reap")
	}
	record.finishTaskReap(true)
	select {
	case <-waiting:
	default:
		t.Fatal("task reap waiters were not released")
	}
	_, reaped, waiting = record.taskState()
	if !reaped || waiting != nil {
		t.Fatal("task must report a completed reap")
	}
}

func TestContainerRecordAllowsReapRetryAfterFailure(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginTaskReap() {
		t.Fatal("first reaper must own task deletion")
	}
	record.finishTaskReap(false)
	if !record.beginTaskReap() {
		t.Fatal("failed task deletion must permit a retry")
	}
}

func TestToOCIMountsRejectsUnsupportedType(t *testing.T) {
	t.Parallel()
	_, err := toOCIMounts([]api.Mount{{Type: "volume", Target: "/data"}})
	if err == nil {
		t.Fatal("expected unsupported mount type error")
	}
}

func TestToOCIMountsRequiresAbsoluteBindPaths(t *testing.T) {
	t.Parallel()
	for _, mount := range []api.Mount{
		{Type: "bind", Source: "relative", Target: "/data"},
		{Type: "bind", Source: "/source", Target: "relative"},
	} {
		if _, err := toOCIMounts([]api.Mount{mount}); err == nil {
			t.Fatalf("expected path validation error for %#v", mount)
		}
	}
}

func TestToOCIMountsPreservesOptionsAndReadonly(t *testing.T) {
	t.Parallel()
	mounts, err := toOCIMounts([]api.Mount{{
		Type:     "bind",
		Source:   "/source",
		Target:   "/data",
		Readonly: true,
		Options:  []string{"rbind"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if len(mounts) != 1 || mounts[0].Source != "/source" || mounts[0].Destination != "/data" {
		t.Fatalf("unexpected mount: %#v", mounts)
	}
	if len(mounts[0].Options) != 2 || mounts[0].Options[0] != "rbind" || mounts[0].Options[1] != "ro" {
		t.Fatalf("unexpected options: %#v", mounts[0].Options)
	}
}

func TestRuntimeMetadataRoundTripPreservesDockerIdentity(t *testing.T) {
	t.Parallel()
	hostPort := uint16(8080)
	exitCode := uint32(17)
	want := api.ContainerMetadata{
		Name:       "web",
		Args:       []string{"nginx", "-g", "daemon off;"},
		Labels:     map[string]string{"com.docker.compose.service": "web"},
		Terminal:   true,
		AutoRemove: true,
		PortBindings: []api.DockerPortBinding{{
			ContainerPort: 80, Protocol: "tcp", HostIP: "127.0.0.1", HostPort: &hostPort,
		}},
		PublishedPorts: []api.PublishedPort{{ContainerPort: 80, GuestPort: 20080, Protocol: "tcp"}},
		LifecycleState: "exited",
		LastExitCode:   &exitCode,
	}
	encoded, err := encodeRuntimeMetadata(want)
	if err != nil {
		t.Fatal(err)
	}
	got := decodeRuntimeMetadata(map[string]string{runtimeMetadataLabel: encoded})
	if got.Name != want.Name || len(got.Args) != len(want.Args) || got.Labels["com.docker.compose.service"] != "web" {
		t.Fatalf("identity metadata was not preserved: %#v", got)
	}
	if !got.Terminal || !got.AutoRemove || len(got.PortBindings) != 1 || got.PortBindings[0].HostPort == nil || *got.PortBindings[0].HostPort != 8080 {
		t.Fatalf("runtime metadata was not preserved: %#v", got)
	}
	if len(got.PublishedPorts) != 1 || got.PublishedPorts[0].GuestPort != 20080 {
		t.Fatalf("published ports were not preserved: %#v", got)
	}
	if got.LifecycleState != "exited" || got.LastExitCode == nil || *got.LastExitCode != exitCode {
		t.Fatalf("exit state was not preserved: %#v", got)
	}
}

func TestRuntimeMetadataDecodeIgnoresMissingAndMalformedLabels(t *testing.T) {
	t.Parallel()
	for _, labels := range []map[string]string{nil, {}, {runtimeMetadataLabel: "{"}} {
		got := decodeRuntimeMetadata(labels)
		if got.Name != "" || len(got.Args) != 0 || len(got.PortBindings) != 0 {
			t.Fatalf("unexpected metadata from %#v: %#v", labels, got)
		}
	}
}

func TestRegistryCredentialsAreScopedToTheRequestedRegistry(t *testing.T) {
	t.Parallel()
	if !sameRegistryHost("docker.io", "registry-1.docker.io") {
		t.Fatal("Docker Hub aliases must match")
	}
	if sameRegistryHost("registry.example.com", "attacker.example") {
		t.Fatal("credentials must not be shared with another registry")
	}
}

func TestResolveImageProcessArgsUsesDockerOverrideRules(t *testing.T) {
	t.Parallel()
	imageEntrypoint := []string{"/image-entrypoint"}
	imageCmd := []string{"image-arg"}
	overrideEntrypoint := []string{"/override-entrypoint"}
	overrideCmd := []string{"override-arg"}
	empty := []string{}
	tests := []struct {
		name       string
		entrypoint *[]string
		cmd        *[]string
		want       []string
	}{
		{name: "image defaults", want: []string{"/image-entrypoint", "image-arg"}},
		{name: "command only", cmd: &overrideCmd, want: []string{"/image-entrypoint", "override-arg"}},
		{name: "entrypoint only", entrypoint: &overrideEntrypoint, want: []string{"/override-entrypoint", "image-arg"}},
		{name: "both", entrypoint: &overrideEntrypoint, cmd: &overrideCmd, want: []string{"/override-entrypoint", "override-arg"}},
		{name: "clear entrypoint", entrypoint: &empty, want: []string{"image-arg"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := resolveImageProcessArgs(imageEntrypoint, imageCmd, test.entrypoint, test.cmd)
			if !slices.Equal(got, test.want) {
				t.Fatalf("got %v, want %v", got, test.want)
			}
		})
	}
}

func TestResolveBindSourceKeepsSharedPath(t *testing.T) {
	guestRoot := t.TempDir()
	project := filepath.Join(guestRoot, "project")
	if err := os.Mkdir(project, 0o755); err != nil {
		t.Fatal(err)
	}
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          guestRoot,
		excludedHostSource: "/Users/test/.glassdock/engine",
	}
	got, err := resolveBindSource("/Users/test/project", configuration)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(project)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("unexpected path %q", got)
	}
}

func TestResolveBindSourceRejectsOutsideRoot(t *testing.T) {
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          t.TempDir(),
		excludedHostSource: "/Users/test/.glassdock/engine",
	}
	if _, err := resolveBindSource("/private/tmp", configuration); err == nil {
		t.Fatal("expected path escape rejection")
	}
}

func TestResolveBindSourceRejectsSymlinkEscape(t *testing.T) {
	guestRoot := t.TempDir()
	escape := filepath.Join(guestRoot, "escape")
	if err := os.Symlink(os.TempDir(), escape); err != nil {
		t.Fatal(err)
	}
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          guestRoot,
		excludedHostSource: "/Users/test/.glassdock/engine",
	}
	if _, err := resolveBindSource("/Users/test/escape", configuration); err == nil {
		t.Fatal("expected symlink escape rejection")
	}
}

func TestResolveBindSourceRejectsHomeContainingEngineState(t *testing.T) {
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          t.TempDir(),
		excludedHostSource: "/Users/test/Library/Application Support/Glass Dock/engine",
	}
	if _, err := resolveBindSource("/Users/test", configuration); err == nil {
		t.Fatal("expected home bind rejection because it contains engine state")
	}
}

func TestResolveBindSourceRejectsEngineStateAndDescendants(t *testing.T) {
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          t.TempDir(),
		excludedHostSource: "/Users/test/Library/Application Support/Glass Dock/engine",
	}
	for _, source := range []string{
		configuration.excludedHostSource,
		filepath.Join(configuration.excludedHostSource, "data.ext4"),
	} {
		if _, err := resolveBindSource(source, configuration); err == nil {
			t.Fatalf("expected engine-state bind rejection for %q", source)
		}
	}
}

func TestResolveBindSourceRejectsSymlinkIntoEngineState(t *testing.T) {
	guestRoot := t.TempDir()
	engineState := filepath.Join(guestRoot, "Library/Application Support/Glass Dock/engine")
	if err := os.MkdirAll(engineState, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(engineState, filepath.Join(guestRoot, "engine-link")); err != nil {
		t.Fatal(err)
	}
	configuration := bindMountConfiguration{
		hostSource:         "/Users/test",
		guestRoot:          guestRoot,
		excludedHostSource: "/Users/test/Library/Application Support/Glass Dock/engine",
	}
	if _, err := resolveBindSource("/Users/test/engine-link", configuration); err == nil {
		t.Fatal("expected symlink into engine state to be rejected")
	}
}

func TestRestoredContainerRecordPreservesSnapshotOwnership(t *testing.T) {
	t.Parallel()
	record := newRestoredContainerRecord(nil, containerrecords.Container{
		Snapshotter: "overlayfs",
		SnapshotKey: "persistent-container",
	})
	if record.snapshotter != "overlayfs" || record.snapshotKey != "persistent-container" {
		t.Fatalf("snapshot ownership was not restored: %#v", record)
	}
}

func TestRestartRestoresExitedLifecycle(t *testing.T) {
	t.Parallel()
	exitCode := uint32(23)
	metadata := api.ContainerMetadata{LifecycleState: "exited", LastExitCode: &exitCode}
	result := api.Container{Status: "created"}
	applyPersistedLifecycle(&result, metadata)
	if result.Status != "exited" || result.ExitCode == nil || *result.ExitCode != exitCode {
		t.Fatalf("exited lifecycle was not restored: %#v", result)
	}
	encoded, err := encodeRuntimeMetadata(metadata)
	if err != nil {
		t.Fatal(err)
	}
	record := newRestoredContainerRecord(nil, containerrecords.Container{
		Labels: map[string]string{runtimeMetadataLabel: encoded},
	})
	if !record.hasPersistedExit() {
		t.Fatal("restored record did not track its persisted exit state")
	}
	if code, ok := record.persistedExitResult(); !ok || code != exitCode {
		t.Fatalf("restored wait result was lost: code=%d ok=%v", code, ok)
	}
}

func TestRestartKeepsUnstartedContainerCreated(t *testing.T) {
	t.Parallel()
	result := api.Container{Status: "created"}
	applyPersistedLifecycle(&result, api.ContainerMetadata{})
	if result.Status != "created" || result.ExitCode != nil {
		t.Fatalf("unstarted lifecycle changed during restoration: %#v", result)
	}
	record := newRestoredContainerRecord(nil, containerrecords.Container{})
	if record.hasPersistedExit() {
		t.Fatal("unstarted record was marked exited")
	}
	if _, ok := record.persistedExitResult(); ok {
		t.Fatal("unstarted record exposed a wait result")
	}
}

func TestRestartMarksPreviouslyRunningContainerAsDaemonLost(t *testing.T) {
	t.Parallel()
	result := api.Container{Status: "created"}
	applyPersistedLifecycle(&result, api.ContainerMetadata{LifecycleState: "running"})
	if result.Status != "exited" || result.ExitCode == nil || *result.ExitCode != daemonLostExitCode {
		t.Fatalf("lost running lifecycle was not made explicit: %#v", result)
	}
}

func TestRunningTaskRequiresForceForRemoval(t *testing.T) {
	t.Parallel()
	if err := validateTaskRemoval(false, "running"); err == nil {
		t.Fatal("non-force removal accepted a running task")
	}
	if err := validateTaskRemoval(true, "running"); err != nil {
		t.Fatalf("force removal was rejected: %v", err)
	}
	if err := validateTaskRemoval(false, "stopped"); err != nil {
		t.Fatalf("stopped task removal was rejected: %v", err)
	}
}
