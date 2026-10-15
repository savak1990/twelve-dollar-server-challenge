package main

import (
	"strings"
	"testing"
)

func TestParseBody(t *testing.T) {
	cases := []struct {
		name string
		in   string
		body string
		err  bodyError
	}{
		{"plain", `{"body":"hello"}`, "hello", bodyOK},
		{"trimmed", `{"body":"  hi there  "}`, "hi there", bodyOK},
		{"js trim set", "{\"body\":\"\\u00a0\\t hi \\u3000\\n\"}", "hi", bodyOK},
		{"escapes", `{"body":"test: <b>&amp;<\/b> \"quoted\" \/ café ✓"}`, `test: <b>&amp;</b> "quoted" / café ✓`, bodyOK},
		{"unicode escape", `{"body":"café ✓"}`, "café ✓", bodyOK},
		{"surrogate pair", `{"body":"😀"}`, "😀", bodyOK},
		{"other keys first", `{"x":1,"y":[1,{"body":"nope"}],"body":"real"}`, "real", bodyOK},
		{"other keys after", `{"body":"real","x":{"body":"nope"}}`, "real", bodyOK},
		{"whitespace around", " \n{ \"body\" : \"ok\" }\n", "ok", bodyOK},
		{"exactly 500", `{"body":"` + strings.Repeat("b", 500) + `"}`, strings.Repeat("b", 500), bodyOK},
		{"500 after trim", `{"body":"  ` + strings.Repeat("b", 500) + ` "}`, strings.Repeat("b", 500), bodyOK},
		{"500 runes multibyte", `{"body":"` + strings.Repeat("é", 500) + `"}`, strings.Repeat("é", 500), bodyOK},
		{"501", `{"body":"` + strings.Repeat("a", 501) + `"}`, "", bodyTooLong},
		{"501 runes multibyte", `{"body":"` + strings.Repeat("é", 501) + `"}`, "", bodyTooLong},
		{"empty", `{"body":""}`, "", bodyRequired},
		{"whitespace only", `{"body":"   "}`, "", bodyRequired},
		{"number", `{"body":123}`, "", bodyRequired},
		{"null", `{"body":null}`, "", bodyRequired},
		{"missing", `{}`, "", bodyRequired},
		{"missing with others", `{"text":"x"}`, "", bodyRequired},
		{"malformed", `{bad json`, "", bodyMalformed},
		{"empty input", ``, "", bodyMalformed},
		{"not an object", `[1,2]`, "", bodyMalformed},
		{"unterminated string", `{"body":"abc`, "", bodyMalformed},
		{"trailing garbage", `{"body":"abc"} x`, "", bodyMalformed},
		{"bad escape", `{"body":"\q"}`, "", bodyMalformed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out := make([]byte, 0, 1024)
			body, err := parseBody([]byte(c.in), &out)
			if err != c.err {
				t.Fatalf("err = %v, want %v", err, c.err)
			}
			if err == bodyOK && string(body) != c.body {
				t.Fatalf("body = %q, want %q", body, c.body)
			}
		})
	}
}

func TestParseBodyNoAlloc(t *testing.T) {
	in := []byte(`{"body":"  quiet_otter_42 says hi at 2026-10-15T10:00:00.000Z (VU 42, iter 3)  "}`)
	out := make([]byte, 0, 1024)
	allocs := testing.AllocsPerRun(1000, func() {
		if _, err := parseBody(in, &out); err != bodyOK {
			t.Fatal(err)
		}
	})
	if allocs > 0 {
		t.Fatalf("parseBody allocates %.1f times per call, want 0", allocs)
	}
}
