package calc

import "testing"

func TestDouble(t *testing.T) {
	if Double(2) != 4 {
		t.Fatalf("Double(2) = %d", Double(2))
	}
}
