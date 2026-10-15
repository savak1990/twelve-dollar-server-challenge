package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"testing"
)

const testSecret = "twelve-dollar-challenge"

// sign builds an HS256 token the same way test/test.sh does with openssl.
func sign(t *testing.T, header, payload string) []byte {
	t.Helper()
	enc := base64.RawURLEncoding
	h := enc.EncodeToString([]byte(header))
	p := enc.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, []byte(testSecret))
	mac.Write([]byte(h + "." + p))
	return []byte(h + "." + p + "." + enc.EncodeToString(mac.Sum(nil)))
}

const hs256 = `{"alg":"HS256","typ":"JWT"}`

func TestVerifyJWT(t *testing.T) {
	now := int64(1_800_000_000)
	key := newHMACKey([]byte(testSecret))
	valid := fmt.Sprintf(`{"sub":"1","username":"golden_ember_1","iat":%d,"exp":%d}`, now, now+3600)

	cases := []struct {
		name  string
		token []byte
		sub   int64
		user  string
		err   jwtError
	}{
		{"valid", sign(t, hs256, valid), 1, "golden_ember_1", jwtOK},
		{"valid big sub", sign(t, hs256, fmt.Sprintf(`{"sub":"20000","username":"x_y_20000","exp":%d}`, now+1)), 20000, "x_y_20000", jwtOK},
		{"key order independent", sign(t, hs256, fmt.Sprintf(`{"exp":%d,"username":"u","sub":"7"}`, now+10)), 7, "u", jwtOK},
		{"garbage", []byte("abc"), 0, "", jwtInvalid},
		{"two parts", []byte("a.b"), 0, "", jwtInvalid},
		{"bad signature", append(sign(t, hs256, valid)[:len(sign(t, hs256, valid))-5], []byte("AAAAA")...), 0, "", jwtInvalid},
		{"alg none, empty sig", []byte(base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString([]byte(valid)) + "."), 0, "", jwtInvalid},
		{"alg none, valid sig", sign(t, `{"alg":"none","typ":"JWT"}`, valid), 0, "", jwtInvalid},
		{"alg HS512", sign(t, `{"alg":"HS512","typ":"JWT"}`, valid), 0, "", jwtInvalid},
		{"expired", sign(t, hs256, fmt.Sprintf(`{"sub":"1","username":"u","iat":%d,"exp":%d}`, now-7200, now-3600)), 0, "", jwtInvalid},
		{"exp == now", sign(t, hs256, fmt.Sprintf(`{"sub":"1","username":"u","exp":%d}`, now)), 0, "", jwtInvalid},
		{"no exp", sign(t, hs256, `{"sub":"1","username":"u"}`), 0, "", jwtInvalid},
		{"payload not json", sign(t, hs256, `not json`), 0, "", jwtInvalid},
		{"sub not integer", sign(t, hs256, fmt.Sprintf(`{"sub":"abc","username":"u","exp":%d}`, now+1)), 0, "", jwtPayload},
		{"sub zero", sign(t, hs256, fmt.Sprintf(`{"sub":"0","username":"u","exp":%d}`, now+1)), 0, "", jwtPayload},
		{"sub is number", sign(t, hs256, fmt.Sprintf(`{"sub":1,"username":"u","exp":%d}`, now+1)), 0, "", jwtPayload},
		{"no username", sign(t, hs256, fmt.Sprintf(`{"sub":"1","iat":%d,"exp":%d}`, now, now+3600)), 0, "", jwtPayload},
		{"username not string", sign(t, hs256, fmt.Sprintf(`{"sub":"1","username":5,"exp":%d}`, now+1)), 0, "", jwtPayload},
		{"no sub", sign(t, hs256, fmt.Sprintf(`{"username":"u","exp":%d}`, now+1)), 0, "", jwtPayload},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			scratch := make([]byte, 0, 1024)
			sub, user, err := verifyJWT(c.token, key, &scratch, now)
			if err != c.err {
				t.Fatalf("err = %v, want %v", err, c.err)
			}
			if err != jwtOK {
				return
			}
			if sub != c.sub || string(user) != c.user {
				t.Fatalf("got (%d, %q), want (%d, %q)", sub, user, c.sub, c.user)
			}
		})
	}
}

func TestVerifyJWTNoAlloc(t *testing.T) {
	now := int64(1_800_000_000)
	key := newHMACKey([]byte(testSecret))
	tok := sign(t, hs256, fmt.Sprintf(`{"sub":"42","username":"quiet_otter_42","iat":%d,"exp":%d}`, now, now+3600))
	scratch := make([]byte, 0, 1024)
	allocs := testing.AllocsPerRun(1000, func() {
		if _, _, err := verifyJWT(tok, key, &scratch, now); err != jwtOK {
			t.Fatal(err)
		}
	})
	if allocs > 0 {
		t.Fatalf("verifyJWT allocates %.1f times per call, want 0", allocs)
	}
}
