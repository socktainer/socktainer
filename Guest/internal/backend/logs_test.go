package backend

import (
	"bytes"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/glassdock/glassdock/guest/internal/api"
)

func TestBoundedLogWriterConsumesWithoutExceedingLimit(t *testing.T) {
	t.Parallel()
	file, err := os.CreateTemp(t.TempDir(), "log")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	input := bytes.Repeat([]byte("x"), int(maxLogBytes)+17)
	written, err := writer.Write(input)
	if err != nil {
		t.Fatal(err)
	}
	if written != len(input) {
		t.Fatalf("reported %d bytes consumed, want %d", written, len(input))
	}
	info, err := file.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() != maxLogBytes || !writer.truncated {
		t.Fatalf("size=%d truncated=%v", info.Size(), writer.truncated)
	}
}

func TestLogsReturnsSelectedStreams(t *testing.T) {
	t.Parallel()
	backend := &Backend{logsDir: t.TempDir()}
	id := "container/with/unsafe/path"
	if err := os.WriteFile(backend.logPath(id, "stdout"), []byte("out"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(backend.logPath(id, "stderr"), []byte("err"), 0o600); err != nil {
		t.Fatal(err)
	}
	response, err := backend.Logs(api.ContainerLogsRequest{ID: id, Stdout: true})
	if err != nil {
		t.Fatal(err)
	}
	if string(response.Stdout) != "out" || response.Stderr != nil {
		t.Fatalf("unexpected response: %#v", response)
	}
}

func TestLogsRequiresASelectedStream(t *testing.T) {
	t.Parallel()
	backend := &Backend{logsDir: t.TempDir()}
	if _, err := backend.Logs(api.ContainerLogsRequest{ID: "demo"}); err == nil {
		t.Fatal("expected stream selection error")
	}
}

func TestBoundedLogSubscriberReceivesExistingAndLiveBytes(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	if _, err := writer.Write([]byte("before")); err != nil {
		t.Fatal(err)
	}
	var received []byte
	var receivedMu sync.Mutex
	complete := make(chan struct{})
	unsubscribe, err := writer.subscribe(func(data []byte) error {
		receivedMu.Lock()
		received = append(received, data...)
		if string(received) == "before-after" {
			select {
			case <-complete:
			default:
				close(complete)
			}
		}
		receivedMu.Unlock()
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("-after")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-complete:
	case <-time.After(time.Second):
		t.Fatal("subscriber did not receive live output")
	}
	unsubscribe()
	if _, err := writer.Write([]byte("-ignored")); err != nil {
		t.Fatal(err)
	}
	receivedMu.Lock()
	defer receivedMu.Unlock()
	if string(received) != "before-after" {
		t.Fatalf("received %q", received)
	}
}

func TestSlowLogSubscriberDoesNotBlockContainerOutput(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file}
	release := make(chan struct{})
	_, err = writer.subscribe(func([]byte) error {
		<-release
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 100 {
			_, _ = writer.Write([]byte("output"))
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("slow attach subscriber blocked log capture")
	}
	close(release)
}

func TestLiveLogStreamContinuesAfterRetentionLimit(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "stream")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	writer := &boundedLogWriter{file: file, written: maxLogBytes}
	received := make(chan string, 1)
	_, err = writer.subscribe(func(data []byte) error {
		received <- string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("live")); err != nil {
		t.Fatal(err)
	}
	select {
	case got := <-received:
		if got != "live" {
			t.Fatalf("got %q, want live", got)
		}
	case <-time.After(time.Second):
		t.Fatal("live output stopped at the retention limit")
	}
}
