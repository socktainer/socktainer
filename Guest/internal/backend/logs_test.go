package backend

import (
	"bytes"
	"os"
	"testing"

	"github.com/socktainer/socktainer/guest/internal/api"
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
