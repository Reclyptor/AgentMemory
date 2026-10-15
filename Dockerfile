# agentmemory built from an upstream commit, for the cluster's agentmemory pod.
#
# The pin is v0.9.30 plus #1507, which fixes 0.9.30 marking a session complete
# on its first Stop (issue #745) and is in no npm release yet. Move to the
# first release that contains it once one ships.
#
# patches/ holds open upstream PRs applied on top of the pin, named
# <PR number>-<slug>.patch. Drop each one once a release contains its PR.
#
# The image carries everything the pod used to install at startup, including
# the local embedding model, so the pod needs no npm, GitHub or Hugging Face
# egress.

ARG AGENTMEMORY_COMMIT=df3d4a83b966d8d415cb9180d5a4724b07f729dc

FROM node:22-slim AS build
ARG AGENTMEMORY_COMMIT
# The test suite shells out to these, as upstream's CI runner provides them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git zip unzip python3 \
 && rm -rf /var/lib/apt/lists/*
ADD https://codeload.github.com/rohitg00/agentmemory/tar.gz/${AGENTMEMORY_COMMIT} /tmp/src.tar.gz
WORKDIR /src
COPY patches/ /tmp/patches/
# Upstream's release steps (.github/workflows/publish.yml): the repo carries no
# lockfile, so it resolves one and installs from it. Then pack the same files a
# release would publish.
RUN tar xzf /tmp/src.tar.gz --strip-components=1 \
 && for p in /tmp/patches/*.patch; do [ -e "$p" ] || continue; git apply --verbose "$p"; done \
 && npm install --package-lock-only --legacy-peer-deps --no-audit --no-fund \
 && npm ci --legacy-peer-deps --no-audit --no-fund \
 && npm run build \
 && npm test \
 && npm pack --pack-destination /tmp

FROM node:22-slim
ARG AGENTMEMORY_COMMIT
# image.source links the ghcr package to this repo; image.url and the upstream
# commit label name what was built.
LABEL org.opencontainers.image.title="agentmemory" \
      org.opencontainers.image.description="agentmemory worker built from upstream commit ${AGENTMEMORY_COMMIT}" \
      org.opencontainers.image.source="https://github.com/Reclyptor/AgentMemory" \
      org.opencontainers.image.url="https://github.com/rohitg00/agentmemory" \
      io.github.rohitg00.agentmemory.commit="${AGENTMEMORY_COMMIT}"

COPY --from=build /tmp/agentmemory-agentmemory-*.tgz /tmp/
# onnxruntime-node's postinstall would also fetch CUDA binaries. When that
# fails, npm drops @huggingface/transformers (an optional dependency) without
# an error, and local embeddings quietly stop working, so skip it and check
# the import below.
RUN ONNXRUNTIME_NODE_INSTALL=skip npm install -g --no-fund --no-audit /tmp/agentmemory-agentmemory-*.tgz \
 && rm /tmp/agentmemory-agentmemory-*.tgz \
 && npm cache clean --force

# Load the model agentmemory's local provider uses, with the same options, so
# its files land in the package's cache, and prove an embedding works.
WORKDIR /usr/local/lib/node_modules/@agentmemory/agentmemory
RUN node --input-type=module -e ' \
      const { pipeline } = await import("@huggingface/transformers"); \
      const extract = await pipeline("feature-extraction", "Xenova/all-MiniLM-L6-v2", { dtype: "q8" }); \
      const out = await extract("warm the cache", { pooling: "mean", normalize: true }); \
      if (out.dims.at(-1) !== 384) throw new Error(`unexpected embedding size ${out.dims}`); \
      console.log("embedding ok", out.dims);'

WORKDIR /
ENTRYPOINT ["agentmemory"]
