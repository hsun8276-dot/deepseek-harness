# syntax=docker/dockerfile:1.10
# dsh Web GUI — single-stage image.
#
# Builds the full monorepo (build:lib = tsc + tsdown over host and client
# faces, build:web = the Vite frontend) inside the image, producing the CLI at
# apps/cli/lib/bin.js and the served dist under apps/web/dist.
#
# Runtime: the built checkout stays in place; the bundled CLI resolves
# workspace packages through node_modules (tsdown externalizes workspace deps
# — confirmed by apps/cli/lib/bin.js head showing bare `import ... from
# "@deepseek-ai/dsh-app-boot"`).
#
# Security notes:
#   - No credentials, tokens, or API keys are ever baked into a layer. dsh home
#     and its secret material (settings.yaml, .credentials.yaml, session logs)
#     live exclusively on the mounted volume, read at startup.
#   - The web bundle now binds all network interfaces (--host 0.0.0.0) so the
#     GUI is reachable from other devices through a reverse proxy or an
#     intranet tunnel. External access should still stay behind a reverse
#     proxy that terminates TLS and authenticates before forwarding.
#   - The GUI runs model tool calls inside the container filesystem, which
#     starts empty apart from the mounted dsh home — inherently limited to a
#     dedicated root, never the host's / or /home.

# Build arg is set automatically by docker buildx / compose when the caller
# specifies --platform.  On aarch64 hosts without explicit --platform, the
# default TARGETPLATFORM is linux/arm64, which correctly resolves the ARM64
# variant of the base image.  On x86_64 hosts building for arm64 (cross-build),
# buildx passes linux/arm64 here as well.
ARG TARGETPLATFORM
FROM --platform=${TARGETPLATFORM:-linux/arm64} node:24-bookworm-slim

# Build & runtime toolchain. Git is needed both for build (DSH_CLIENT_COMMIT_HASH
# via `git rev-parse HEAD`) and at runtime (agent git tool). Bash is for the
# agent shell surface. make, g++ and python3 are node-gyp prerequisites:
# the session lock's fs-ext binding compiles via node-gyp at install (the
# native dependency closure on the mounted volume is matched at build time).
RUN apt-get update \
  && apt-get install --no-install-recommends --yes git ca-certificates bash make g++ python3 \
  && rm -rf /var/lib/apt/lists/*

# Repository package manager, pinned to the lockfile's corepack version.
RUN npm install --global --no-fund --no-audit pnpm@11.7.0

WORKDIR /app

# Build context excludes .git, node_modules, build artifacts, and log files
# via .dockerignore; the sources, lockfile, and workspace manifests arrive here.
COPY . .

# CI=true skips the root postinstall (install-lefthook.mjs writes git hooks to
# .git/config — developer convenience, not needed in a build image). It does NOT
# affect allowBuilds scripts (esbuild, node-pty, koffi, subprocess-local
# spawn-helper) which still run.
ENV CI=true

# Overridable at build time for network-restricted mirrors
# (--build-arg NPM_REGISTRY=https://registry.npmmirror.com).
ARG NPM_REGISTRY=https://registry.npmjs.org
RUN pnpm install --frozen-lockfile --registry "$NPM_REGISTRY"

# Complete repository build: tsc host — tsdown host — tsc client — tsdown client
# — Vite web frontend.
RUN pnpm run build

# The build consumed .git only for DSH_CLIENT_COMMIT_HASH / dirty metadata;
# neither the CLI nor the GUI reads it at runtime. Removing it keeps the final
# image free of the repository's full history.
RUN rm -rf .git

# Image provenance — labels only, never credentials.
ARG DSH_IMAGE_VERSION=0.1.2-alpha.2
LABEL org.opencontainers.image.source="https://github.com/deepseek-ai/deepseek-harness" \
      org.opencontainers.image.description="dsh Web GUI — DeepSeek Harness browser interface" \
      org.opencontainers.image.version="${DSH_IMAGE_VERSION}" \
      org.opencontainers.image.licenses="MIT"

# dsh home lives on the mounted volume. /data holds settings.yaml,
# .credentials.yaml, session logs, and user agent presets; created and seeded
# by dsh on first startup.
ENV DSH_HOME=/data

# The bundled CLI entry produced by the build.
ENTRYPOINT ["node", "/app/apps/cli/lib/bin.js"]
# dsh web binds all network interfaces by default so other devices can reach
# the GUI through a reverse proxy or intranet tunnel. Override through docker
# compose `command` to change the port or add --trusted-host.
CMD ["web", "--host", "0.0.0.0", "--port", "3080", "--no-open"]

EXPOSE 3080
