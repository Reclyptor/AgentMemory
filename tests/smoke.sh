#!/usr/bin/env bash
# Runs an image against the iii engine it was built for and checks what the
# cluster depends on: the worker comes up, memories are saved, keyword and
# semantic search both answer, and the vector index survives a restart without
# re-embedding.
#
# Usage: tests/smoke.sh <image>
set -euo pipefail

image="${1:?usage: tests/smoke.sh <image>}"
pkg=/usr/local/lib/node_modules/@agentmemory/agentmemory
secret=smoke
engine=agentmemory-smoke-engine
app=agentmemory-smoke-app
tmp="$(cd "$(dirname "$0")" && pwd)/.tmp"

cleanup() {
  docker rm -f "$engine" "$app" >/dev/null 2>&1 || true
  # The engine writes as 65532, so remove its files from inside a container.
  if [ -d "$tmp" ]; then
    docker run --rm -v "$tmp:/t" --entrypoint sh "$image" -c 'rm -rf /t/*' >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; docker logs "$app" 2>&1 | tail -30 >&2; exit 1; }

cleanup
mkdir -p "$tmp/data"
chmod 777 "$tmp/data"

# The worker speaks the wire protocol of the iii-sdk it ships with, so the
# engine version comes from the image, as does upstream's engine config.
iii_version="$(docker run --rm --entrypoint node "$image" -p "require('$pkg/node_modules/iii-sdk/package.json').version")"
docker run --rm --entrypoint cat "$image" "$pkg/iii-config.docker.yaml" > "$tmp/config.yaml"
echo "image $image against iiidev/iii:$iii_version"

docker run -d --name "$engine" \
  -v "$tmp/config.yaml:/app/config.yaml:ro" -v "$tmp/data:/data" \
  -e III_TELEMETRY_ENABLED=false \
  "iiidev/iii:$iii_version" --config /app/config.yaml --no-update-check >/dev/null

start_app() {
  docker run -d --name "$app" --network "container:$engine" \
    -e HOME=/tmp -e EMBEDDING_PROVIDER=local -e AGENTMEMORY_SECRET="$secret" \
    "$image" --no-engine >/dev/null
  for _ in $(seq 60); do
    if docker exec "$app" node -e 'fetch("http://127.0.0.1:3111/agentmemory/livez").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))' 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  fail "worker never became live"
}

# Calls the REST API from inside the app container and prints the JSON body.
api() {
  docker exec "$app" node -e '
    const [method, path, body] = process.argv.slice(1);
    fetch("http://127.0.0.1:3111/agentmemory" + path, {
      method,
      headers: { Authorization: "Bearer '"$secret"'", "Content-Type": "application/json" },
      body: body || undefined,
    }).then(async (r) => {
      const text = await r.text();
      if (!r.ok) { console.error(r.status, text); process.exit(1); }
      console.log(text);
    });' "$@"
}
status() { api GET /status | node -e 'const s=JSON.parse(require("fs").readFileSync(0));console.log(s.index.vectorDocuments, s.index.pendingVectorBackfill)'; }

start_app
api POST /remember '{"title":"ZFS padding","content":"The flashstor pool filled up because RAIDZ2 padded every 4K block","type":"fact"}' >/dev/null
api POST /remember '{"title":"Factorio restart","content":"The Factorio server was restarted after a config change","type":"fact"}' >/dev/null

api POST /search '{"query":"RAIDZ2 padded","limit":5}' | grep -q 'flashstor' || fail "keyword search missed the saved memory"
top="$(api POST /smart-search '{"query":"disk running out of space","limit":1}' | node -e 'console.log(JSON.parse(require("fs").readFileSync(0)).results[0]?.title ?? "")')"
case "$top" in *flashstor*) ;; *) fail "semantic search ranked '$top' first" ;; esac

expect_vectors() {
  local vectors pending
  read -r vectors pending < <(status)
  if [ "$vectors" != 2 ] || [ "$pending" != 0 ]; then
    fail "$1: expected 2 vectors and none pending, got $vectors/$pending"
  fi
}
expect_vectors "after saving"

# A clean shutdown must persist the index; the next boot loads it as is.
docker stop -t 30 "$app" >/dev/null
docker rm "$app" >/dev/null
start_app
expect_vectors "after restart"
docker logs "$app" 2>&1 | grep -q 'Re-embedding' && fail "restart re-embedded instead of loading the saved index"

echo "smoke test passed"
