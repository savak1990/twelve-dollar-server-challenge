package main

import "testing"

func TestParseID(t *testing.T) {
	cases := []struct {
		in string
		id int64
		ok bool
	}{
		{"1", 1, true},
		{"500000", 500000, true},
		{"999999999", 999999999, true},
		{"9223372036854775807", 9223372036854775807, true},
		{"0", 0, false},
		{"-1", 0, false},
		{"abc", 0, false},
		{"1.5", 0, false},
		{"", 0, false},
		{"01", 1, true},
		{"9223372036854775808", 0, false}, // overflow
		{"1e3", 0, false},
		{"0x10", 0, false},
	}
	for _, c := range cases {
		id, ok := parseID([]byte(c.in))
		if ok != c.ok || id != c.id {
			t.Errorf("parseID(%q) = (%d, %v), want (%d, %v)", c.in, id, ok, c.id, c.ok)
		}
	}
}
