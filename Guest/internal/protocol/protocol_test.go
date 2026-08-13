package protocol

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	payload, err := NewPayload(struct {
		Name string `json:"name"`
	}{Name: "demo"})
	if err != nil {
		t.Fatal(err)
	}
	want := Envelope{ID: 7, Kind: KindRequest, Method: "container.inspect", Payload: payload}
	var buffer bytes.Buffer
	if err := NewWriter(&buffer).Write(want); err != nil {
		t.Fatal(err)
	}
	got, err := NewReader(&buffer).Read()
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != want.ID || got.Kind != want.Kind || got.Method != want.Method || string(got.Payload) != string(want.Payload) {
		t.Fatalf("got %#v, want %#v", got, want)
	}
}

func TestWireLengthIsBigEndian(t *testing.T) {
	var buffer bytes.Buffer
	if err := NewWriter(&buffer).Write(Envelope{ID: 1, Kind: KindRequest, Method: "ping"}); err != nil {
		t.Fatal(err)
	}
	b := buffer.Bytes()
	if int(binary.BigEndian.Uint32(b[:4])) != len(b)-4 {
		t.Fatalf("length prefix is not big-endian frame size")
	}
}

func TestRejectsOversizeWithoutAllocating(t *testing.T) {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], MaxFrameSize+1)
	_, err := NewReader(bytes.NewReader(header[:])).Read()
	if err == nil || !strings.Contains(err.Error(), "invalid frame length") {
		t.Fatalf("got %v", err)
	}
}

func TestPayloadMustBeObject(t *testing.T) {
	if _, err := NewPayload([]string{"not", "an", "object"}); err == nil {
		t.Fatal("expected error")
	}
}
