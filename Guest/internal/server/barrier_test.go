package server

import (
	"encoding/json"
	"math"
	"testing"

	"github.com/socktainer/socktainer/guest/internal/api"
)

func TestBarrierEventEncodesUInt64AsDecimalString(t *testing.T) {
	t.Parallel()
	data, err := json.Marshal(api.BindWriteBarrierEvent{
		BarrierID: "18446744073709551615",
		Paths:     []string{"project/data"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	if got, ok := object["barrierId"].(string); !ok || got != "18446744073709551615" {
		t.Fatalf("barrier ID lost string precision: %#v", object["barrierId"])
	}
}

func TestParseBarrierIDSupportsFullUInt64Range(t *testing.T) {
	t.Parallel()
	id, err := parseBarrierID("18446744073709551615")
	if err != nil || id != math.MaxUint64 {
		t.Fatalf("parse maximum barrier ID: id=%d err=%v", id, err)
	}
	if id, err := parseBarrierID(""); err != nil || id != 0 {
		t.Fatalf("parse absent barrier ID: id=%d err=%v", id, err)
	}
}

func TestParseBarrierIDRejectsInvalidDecimalStrings(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"0", "-1", "+1", "1.0", "0x10", "18446744073709551616", "word"} {
		if _, err := parseBarrierID(value); err == nil {
			t.Fatalf("accepted invalid barrier ID %q", value)
		}
	}
}
