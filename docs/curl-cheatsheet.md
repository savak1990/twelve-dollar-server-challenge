# curl cheatsheet

Hand-poke the five endpoints. Bodies and status codes are byte-exact per [`SPEC.md`](../SPEC.md).

```bash
# pick the base: local server (bash test/run.sh style, port 3000) or the AWS target (port 80)
BASE=http://127.0.0.1:3000
# BASE=http://$(terraform -chdir=infra output -raw target_public_ip)

# a pre-signed token for user 1 (golden_ember_1) from the seed (make seed)
TOKEN=$(jq -r '.[0].token' seed/tokens.json)
```

## The five endpoints

```bash
# 1. health
curl -s $BASE/health

# 2. feed: 20 newest posts, newest first
curl -s $BASE/feed | jq '.posts[0]'

# 3. one post
curl -s $BASE/posts/1 | jq

# 4. create a post (auth) -> 201; author comes from the token, body is trimmed
curl -si -X POST $BASE/posts \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"body":"  hello from curl  "}'

# 5. like a post (auth) -> 201 first time, 200 on repeat
curl -si -X POST $BASE/posts/1/like -H "Authorization: Bearer $TOKEN"
curl -si -X POST $BASE/posts/1/like -H "Authorization: Bearer $TOKEN"
```

## Error paths

```bash
curl -si $BASE/nope                                                         # 404 {"error":"not found"}
curl -si $BASE/posts/abc                                                    # 400 {"error":"invalid post id"}
curl -si $BASE/posts/999999999                                              # 404 {"error":"post not found"}
curl -si -X POST $BASE/posts/1/like                                         # 401 {"error":"missing bearer token"}
curl -si -X POST $BASE/posts/1/like -H 'Authorization: Bearer junk'         # 401 {"error":"invalid or expired token"}
curl -si -X POST $BASE/posts/abc/like -H "Authorization: Bearer $TOKEN"     # 400: auth is checked before the id
curl -si -X POST $BASE/posts -H "Authorization: Bearer $TOKEN" -d '{"body":"   "}'   # 400 {"error":"body is required"}
curl -si -X POST $BASE/posts -H "Authorization: Bearer $TOKEN" -d '{bad'             # 400 {"error":"malformed JSON body"}
curl -si -X POST $BASE/posts -H "Authorization: Bearer $TOKEN" \
  -d "{\"body\":\"$(printf 'a%.0s' $(seq 501))\"}"                                     # 400 {"error":"body must be at most 500 characters"}
```

## Feel for the cost of a request

```bash
curl -s -o /dev/null -w 'feed: %{time_total}s\n' $BASE/feed
curl -s -o /dev/null -w 'post: %{time_total}s\n' $BASE/posts/1
```

One k6 user in `bench/load.js` does roughly: feed → wait 3–7 s → one post → wait 3–8 s → 15 % chance of a
like, 2 % chance of a create → idle 5–15 s. That is about 0.1 requests per second per user, so 60,000
users ≈ 6,000 rps, almost all of it `/feed` and `/posts/:id`.

## Running a local server to curl against

```bash
make build
D=$(mktemp -d) && cp seed/feed.db $D/
SQLITE_PATH=$D/feed.db JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000 \
  submissions/go-fasthttp-savak1990/bin/server
```

The target's database is reset before every `make test`, so anything created by hand disappears at
the next hold.
