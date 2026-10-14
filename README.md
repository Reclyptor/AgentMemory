# AgentMemory

The container image for the cluster's [agentmemory](https://github.com/rohitg00/agentmemory)
worker, built from a pinned upstream commit and published to
`ghcr.io/reclyptor/agentmemory`.

Deployed by Flux from [`Reclyptor/Kubernetes`](https://github.com/Reclyptor/Kubernetes)
as `infra/agentmemory`. The pod runs it next to an `iiidev/iii` engine container,
whose version has to match the image's bundled `iii-sdk`.

## What the image carries

- agentmemory, built from `AGENTMEMORY_COMMIT` in the [`Dockerfile`](Dockerfile)
  using upstream's own release steps, with its test suite run during the build.
- The local embedding model (`Xenova/all-MiniLM-L6-v2`), so the pod never
  downloads anything at startup.

The current pin is v0.9.30 plus upstream #1507, which fixes 0.9.30 completing a
session at its first Stop (upstream issue #745). Move to the first npm release
that contains it once one ships.

## Tags

- `<version>-<upstream commit>` (for example `0.9.30-df3d4a8`) is the pin the
  cluster references.
- `<version>-<upstream commit>-<timestamp>-<repo commit>` is immutable per
  build.

## Testing

```bash
docker build -t agentmemory:local .
tests/smoke.sh agentmemory:local
```

The smoke test runs the image against the matching iii engine and checks
saving, keyword and semantic search, and that the vector index survives a
restart. CI runs the same script before anything is pushed.

## Bumping

1. Change `AGENTMEMORY_COMMIT` in the `Dockerfile`.
2. Push to `master`. CI builds, tests and publishes.
3. In the same change set, update the image tag (and the engine version if the
   bundled `iii-sdk` moved) in `Reclyptor/Kubernetes` `infra/agentmemory`, and
   the client pin in `modules/home/agentmemory.nix` in the nixos repo.
