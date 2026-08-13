package backend

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/containerd/containerd/v2/pkg/cio"
	"github.com/socktainer/socktainer/guest/internal/api"
)

const maxLogBytes int64 = 4 << 20

type boundedLogWriter struct {
	mu        sync.Mutex
	file      *os.File
	written   int64
	truncated bool
}

func (w *boundedLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	originalLength := len(p)
	remaining := maxLogBytes - w.written
	if remaining <= 0 {
		w.truncated = w.truncated || originalLength > 0
		return originalLength, nil
	}
	if int64(len(p)) > remaining {
		p = p[:remaining]
		w.truncated = true
	}
	written, err := w.file.Write(p)
	w.written += int64(written)
	if err != nil {
		return written, err
	}
	// Report the full input as consumed. Once the limit is reached, logs must not
	// apply backpressure to the container process.
	return originalLength, nil
}

type logCapture struct {
	stdout *boundedLogWriter
	stderr *boundedLogWriter
	io     cio.IO
	once   sync.Once
}

func logKey(id string) string {
	digest := sha256.Sum256([]byte(id))
	return hex.EncodeToString(digest[:])
}

func (b *Backend) logPath(id, stream string) string {
	return filepath.Join(b.logsDir, logKey(id)+"."+stream)
}

func (b *Backend) createLogCapture(id string) (*logCapture, error) {
	if err := os.MkdirAll(b.logsDir, 0o700); err != nil {
		return nil, err
	}
	open := func(stream string) (*boundedLogWriter, error) {
		file, err := os.OpenFile(b.logPath(id, stream), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
		if err != nil {
			return nil, err
		}
		return &boundedLogWriter{file: file}, nil
	}
	stdout, err := open("stdout")
	if err != nil {
		return nil, err
	}
	stderr, err := open("stderr")
	if err != nil {
		_ = stdout.file.Close()
		_ = os.Remove(b.logPath(id, "stdout"))
		return nil, err
	}
	return &logCapture{stdout: stdout, stderr: stderr}, nil
}

func (capture *logCapture) close() {
	capture.once.Do(func() {
		if capture.io != nil {
			capture.io.Wait()
			_ = capture.io.Close()
		}
		_ = capture.stdout.file.Close()
		_ = capture.stderr.file.Close()
	})
}

func (b *Backend) finishLogCapture(id string) {
	value, ok := b.logCaptures.Load(id)
	if !ok {
		return
	}
	value.(*logCapture).close()
}

func (b *Backend) removeLogs(id string) {
	if value, ok := b.logCaptures.LoadAndDelete(id); ok {
		value.(*logCapture).close()
	}
	_ = os.Remove(b.logPath(id, "stdout"))
	_ = os.Remove(b.logPath(id, "stderr"))
}

func (b *Backend) Logs(request api.ContainerLogsRequest) (api.ContainerLogsResponse, error) {
	if request.ID == "" {
		return api.ContainerLogsResponse{}, errors.New("id is required")
	}
	if !request.Stdout && !request.Stderr {
		return api.ContainerLogsResponse{}, errors.New("stdout or stderr must be requested")
	}
	response := api.ContainerLogsResponse{}
	read := func(stream string) ([]byte, error) {
		data, err := os.ReadFile(b.logPath(request.ID, stream))
		if errors.Is(err, os.ErrNotExist) {
			return []byte{}, nil
		}
		return data, err
	}
	var err error
	if request.Stdout {
		response.Stdout, err = read("stdout")
		if err != nil {
			return api.ContainerLogsResponse{}, err
		}
	}
	if request.Stderr {
		response.Stderr, err = read("stderr")
		if err != nil {
			return api.ContainerLogsResponse{}, err
		}
	}
	if value, ok := b.logCaptures.Load(request.ID); ok {
		capture := value.(*logCapture)
		capture.stdout.mu.Lock()
		stdoutTruncated := capture.stdout.truncated
		capture.stdout.mu.Unlock()
		capture.stderr.mu.Lock()
		stderrTruncated := capture.stderr.truncated
		capture.stderr.mu.Unlock()
		response.Truncated = stdoutTruncated || stderrTruncated
	} else {
		for _, data := range [][]byte{response.Stdout, response.Stderr} {
			if int64(len(data)) >= maxLogBytes {
				response.Truncated = true
			}
		}
	}
	return response, nil
}

var _ io.Writer = (*boundedLogWriter)(nil)
