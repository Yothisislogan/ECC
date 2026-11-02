# Sandboxed coding agent: Claude Code pointed at the local llama.cpp server.
# Everything is pinned: base images by digest, Claude Code by exact version.
FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da AS node

FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG AGENT_UID=1000
ARG AGENT_GID=1000
# "stable" channel on npm when this kit was written. Bump deliberately.
ARG CLAUDE_CODE_VERSION=2.1.309

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less openssl procps python3 ripgrep \
 && rm -rf /var/lib/apt/lists/*

# Optional build secret "build_ca": only needed when your network inspects TLS
# (for example Cloudflare Gateway with TLS decryption). Never stored in the image.
RUN --mount=type=secret,id=build_ca,required=false \
    if [ -s /run/secrets/build_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/build_ca; fi \
 && npm install -g --no-audit --no-fund "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

# Policy the user cannot override from inside the sandbox.
COPY managed-settings.json /etc/claude-code/managed-settings.json

# Unprivileged user whose UID matches the host account that owns the workspace.
RUN if id ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
 && groupadd --gid "${AGENT_GID}" agent \
 && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --home-dir /home/agent --shell /bin/bash agent \
 && mkdir -p /home/agent/.claude /workspace \
 && chown -R "${AGENT_UID}:${AGENT_GID}" /home/agent /workspace
COPY --chown=${AGENT_UID}:${AGENT_GID} sandbox-notes.md /home/agent/.claude/CLAUDE.md

USER agent
WORKDIR /workspace
ENV HOME=/home/agent
CMD ["bash"]
