package protocol

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

const MaxFrameSize = 16 << 20

type Kind string

const (
	KindRequest  Kind = "request"
	KindResponse Kind = "response"
	KindEvent    Kind = "event"
	KindStream   Kind = "stream"
	KindEnd      Kind = "end"
)

type Stream string

const (
	StreamStdout Stream = "stdout"
	StreamStderr Stream = "stderr"
)

// Envelope is the complete wire schema. Data contains base64 in JSON, as required
// by encoding/json for []byte. Payload must contain a JSON object when present.
type Envelope struct {
	ID       uint64          `json:"id"`
	Kind     Kind            `json:"kind"`
	Method   string          `json:"method,omitempty"`
	Payload  json.RawMessage `json:"payload,omitempty"`
	Stream   Stream          `json:"stream,omitempty"`
	Data     []byte          `json:"data,omitempty"`
	Error    *Error          `json:"error,omitempty"`
	ExitCode *int32          `json:"exitCode,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Envelope) Validate() error {
	switch e.Kind {
	case KindRequest:
		if e.ID == 0 || e.Method == "" {
			return errors.New("request requires nonzero id and method")
		}
	case KindResponse, KindStream, KindEnd:
		if e.ID == 0 {
			return fmt.Errorf("%s requires nonzero id", e.Kind)
		}
	case KindEvent:
		if e.ID != 0 || e.Method == "" {
			return errors.New("event requires id=0 and method")
		}
	default:
		return fmt.Errorf("unknown kind %q", e.Kind)
	}
	if e.Stream != "" && e.Stream != StreamStdout && e.Stream != StreamStderr {
		return fmt.Errorf("unknown stream %q", e.Stream)
	}
	if len(e.Payload) > 0 {
		var object map[string]json.RawMessage
		if err := json.Unmarshal(e.Payload, &object); err != nil {
			return errors.New("payload must be a JSON object")
		}
	}
	return nil
}

func NewPayload(value any) (json.RawMessage, error) {
	b, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(b, &object); err != nil {
		return nil, errors.New("payload must encode as a JSON object")
	}
	return b, nil
}

type Reader struct{ r io.Reader }

func NewReader(r io.Reader) *Reader { return &Reader{r: r} }

func (r *Reader) Read() (Envelope, error) {
	var length [4]byte
	if _, err := io.ReadFull(r.r, length[:]); err != nil {
		return Envelope{}, err
	}
	n := binary.BigEndian.Uint32(length[:])
	if n == 0 || n > MaxFrameSize {
		return Envelope{}, fmt.Errorf("invalid frame length %d", n)
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r.r, b); err != nil {
		return Envelope{}, err
	}
	var envelope Envelope
	if err := json.Unmarshal(b, &envelope); err != nil {
		return Envelope{}, fmt.Errorf("decode frame: %w", err)
	}
	if err := envelope.Validate(); err != nil {
		return Envelope{}, err
	}
	return envelope, nil
}

type Writer struct {
	w  io.Writer
	mu sync.Mutex
}

func NewWriter(w io.Writer) *Writer { return &Writer{w: w} }

func (w *Writer) Write(envelope Envelope) error {
	if err := envelope.Validate(); err != nil {
		return err
	}
	b, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	if len(b) > MaxFrameSize {
		return fmt.Errorf("frame size %d exceeds maximum %d", len(b), MaxFrameSize)
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(b)))
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := writeAll(w.w, length[:]); err != nil {
		return err
	}
	return writeAll(w.w, b)
}

func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}

// Base64 is documented here for implementations that do not use encoding/json.
func Base64(data []byte) string { return base64.StdEncoding.EncodeToString(data) }
