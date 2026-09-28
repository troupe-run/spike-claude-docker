# Minimal Claude Code actor image (spike).
# Install method: official native installer (https://claude.ai/install.sh), version pinned.
# The native build is a single self-contained binary; a builder stage runs the installer and
# we copy just the binary to /usr/local/bin, so $HOME can be an ephemeral tmpfs at run time
# (read-only root fs) and the installer's download cache never lands in the final image.
ARG CLAUDE_VERSION=2.1.281

FROM debian:bookworm-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git procps \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --uid 1000 --shell /bin/bash actor

FROM base AS installer
ARG CLAUDE_VERSION
USER actor
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_VERSION} \
 && cp -L /home/actor/.local/share/claude/versions/${CLAUDE_VERSION} /home/actor/claude-bin

FROM base
COPY --from=installer --chmod=0755 /home/actor/claude-bin /usr/local/bin/claude
USER actor
ENV CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
WORKDIR /workspace
CMD ["claude", "--version"]
