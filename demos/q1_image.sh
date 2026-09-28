#!/usr/bin/env bash
# Q1: build the image and prove `claude --version` works (with read-only root + tmpfs HOME).
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -q -t troupe-claude:spike image/
docker images troupe-claude:spike --format 'reported size: {{.Size}}'
docker history troupe-claude:spike --format '{{.Size}}\t{{.CreatedBy}}' | cut -c1-80
docker run --rm --read-only --tmpfs /home/actor:uid=1000,gid=1000 --tmpfs /tmp troupe-claude:spike claude --version
