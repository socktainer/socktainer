package backend

import (
	"context"
	"errors"
	"testing"
	"time"

	containerrecords "github.com/containerd/containerd/v2/core/containers"
	"github.com/socktainer/socktainer/guest/internal/api"
)

func TestContainerRecordPreparationCompletesOnce(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginPreparation() {
		t.Fatal("first preparation must start")
	}
	if record.beginPreparation() {
		t.Fatal("second preparation must not start")
	}
	record.finishPreparation(nil, nil)
	if err := record.waitPreparation(context.Background()); err != nil {
		t.Fatalf("wait for successful preparation: %v", err)
	}
}

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

func TestContainerRecordDeleteCancelsBeforeTaskCreation(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginPreparation() {
		t.Fatal("preparation must start")
	}
	if !record.cancelPreparation() {
		t.Fatal("delete must cancel before task creation")
	}
	if record.beginTaskCreation() {
		t.Fatal("canceled preparation must not create a task")
	}
	record.finishPreparation(nil, nil)
	if err := record.waitPreparation(context.Background()); err != nil {
		t.Fatalf("wait for canceled preparation: %v", err)
	}
}

func TestContainerRecordCancellationSerializesTaskCreation(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginPreparation() {
		t.Fatal("preparation must start")
	}
	cancelOwnsTransition := make(chan struct{})
	allowCancel := make(chan struct{})
	canceled := make(chan bool, 1)
	go func() {
		canceled <- record.cancelPreparationTransition(func() {
			close(cancelOwnsTransition)
			<-allowCancel
		})
	}()
	<-cancelOwnsTransition
	created := make(chan bool, 1)
	go func() { created <- record.beginTaskCreation() }()
	select {
	case <-created:
		t.Fatal("task creation crossed an incomplete cancellation transition")
	default:
	}
	close(allowCancel)
	if !<-canceled {
		t.Fatal("cancellation did not win the transition")
	}
	if <-created {
		t.Fatal("task creation committed after cancellation won")
	}
}

func TestSpeculativePreparationKeepsImmediateDeleteWindow(t *testing.T) {
	t.Parallel()
	if speculativeTaskPreparationDelay < 100*time.Millisecond {
		t.Fatalf("preparation delay %s is too short for immediate Docker rm", speculativeTaskPreparationDelay)
	}
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

func TestQueuedTaskPreparationCanBeCanceled(t *testing.T) {
	t.Parallel()
	backend := &Backend{taskCreates: make(chan struct{}, maxConcurrentTaskCreations)}
	if err := backend.acquireTaskCreation(context.Background()); err != nil {
		t.Fatal(err)
	}
	canceled := make(chan struct{})
	result := make(chan bool, 1)
	go func() {
		acquired, _ := backend.acquireTaskPreparation(context.Background(), canceled)
		result <- acquired
	}()
	close(canceled)
	if <-result {
		t.Fatal("canceled preparation acquired the runc-create slot")
	}
	backend.releaseTaskCreation()
}

func TestContainerRecordStartRequestsSinglePreparation(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	if !record.beginPreparation() {
		t.Fatal("preparation must start")
	}
	record.requestPreparation()
	record.requestPreparation()
	select {
	case <-record.prepareNow:
	default:
		t.Fatal("start did not release the preparation delay")
	}
	if !record.beginTaskCreation() {
		t.Fatal("start must permit task creation")
	}
	if record.cancelPreparation() {
		t.Fatal("delete cannot cancel after task creation begins")
	}
	record.finishPreparation(nil, nil)
	if err := record.waitPreparation(context.Background()); err != nil {
		t.Fatalf("wait for requested preparation: %v", err)
	}
}

func TestContainerRecordPreparationPropagatesError(t *testing.T) {
	t.Parallel()
	record := &containerRecord{}
	record.beginPreparation()
	want := errors.New("prepare failed")
	record.finishPreparation(nil, want)
	if err := record.waitPreparation(context.Background()); !errors.Is(err, want) {
		t.Fatalf("got %v, want %v", err, want)
	}
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

func TestRewriteBindSourceRoutesThroughCache(t *testing.T) {
	got, err := rewriteBindSource("/Users/person/project", "/Users/person", "/run/bind-cache")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/run/bind-cache/project" {
		t.Fatalf("unexpected path %q", got)
	}
}

func TestRewriteBindSourceRejectsOutsideRoot(t *testing.T) {
	if _, err := rewriteBindSource("/private/tmp", "/Users/person", "/run/bind-cache"); err == nil {
		t.Fatal("expected path escape rejection")
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
