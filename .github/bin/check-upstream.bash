#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Forestay contributors (Fred Cooke)
#
# check-upstream.bash - preTaggingTests hook for forestay-base-image
#
# Two jobs:
#   fail  if the pinned immutable tag no longer resolves to the pinned digest,
#         which would mean someone re-pushed a tag that names one build
#   warn  how far behind the moving :nonroot tag we are, with dates
#
# Distroless zeroes every timestamp in the image for reproducibility, so the
# dates come from the GCR registry API rather than the image.
#
# Must run on bash 3.2.57: no associative arrays, no mapfile, no ${var,,}.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

DOCKERFILE="src/docker/Dockerfile"
REGISTRY="gcr.io"
REPOSITORY="distroless/static"
MOVING_TAG="nonroot"

log() { printf '%s\n' "$*"; }
die() { printf '[FAILED] %s\n' "$*" >&2; exit 1; }

# Parse "FROM repo:tag@sha256:..." so the Dockerfile stays the single source
# of truth. A second copy of the pin somewhere else would be a second thing to
# forget to bump.
read_pin() {
  local from
  from=$(grep -m1 '^FROM ' "${DOCKERFILE}") || die "no FROM line in ${DOCKERFILE}"
  PINNED_TAG=$(printf '%s' "${from}" | sed -n 's,^FROM [^:]*:\([^@]*\)@.*$,\1,p')
  PINNED_DIGEST=$(printf '%s' "${from}" | sed -n 's,^.*@\(sha256:[0-9a-f]*\)$,\1,p')
  [ -n "${PINNED_TAG}" ] || die "could not read a tag from: ${from}"
  [ -n "${PINNED_DIGEST}" ] || die "could not read a digest from: ${from}"
}

resolve() {
  skopeo inspect --raw "docker://${REGISTRY}/${REPOSITORY}:$1" 2>/dev/null \
    | shasum -a 256 | cut -d' ' -f1
}

# GCR reports timeUploadedMs per digest. Empty output means unknown, which is
# reported rather than guessed at.
uploaded() {
  curl -fsSL "https://${REGISTRY}/v2/${REPOSITORY}/tags/list" 2>/dev/null \
    | PIN="$1" python3 -c '
import json, os, sys, datetime
pin = os.environ["PIN"]
entry = json.load(sys.stdin).get("manifest", {}).get(pin)
if not entry:
    sys.exit(0)
ms = int(entry["timeUploadedMs"])
print(datetime.datetime.utcfromtimestamp(ms / 1000).strftime("%Y-%m-%d"))
'
}

main() {
  command -v skopeo >/dev/null 2>&1 || die "skopeo not found on PATH"

  read_pin
  log "Pinned tag:    ${PINNED_TAG}"
  log "Pinned digest: ${PINNED_DIGEST}"

  local resolved
  resolved="sha256:$(resolve "${PINNED_TAG}")"
  if [ "${resolved}" != "sha256:" ] && [ "${resolved}" = "${PINNED_DIGEST}" ]; then
    log "[ok] immutable tag still resolves to the pinned digest"
  else
    printf '[FAILED] %s\n' "immutable tag moved" >&2
    printf '  tag %s\n' "${PINNED_TAG}" >&2
    printf '  expected %s\n' "${PINNED_DIGEST}" >&2
    printf '  resolved %s\n' "${resolved}" >&2
    printf '  A commit suffixed tag names one build. If this differs, upstream\n' >&2
    printf '  re-pushed it and the pin can no longer be trusted.\n' >&2
    exit 1
  fi

  # Staleness is reported, never enforced. Bumping the base is a deliberate
  # commit, not something a build does on your behalf.
  local head_digest pinned_date head_date
  head_digest="sha256:$(resolve "${MOVING_TAG}")"
  pinned_date=$(uploaded "${PINNED_DIGEST}")
  head_date=$(uploaded "${head_digest}")

  log ""
  log "Pinned  ${PINNED_DIGEST}  uploaded ${pinned_date:-unknown}"
  log "Current ${head_digest}  uploaded ${head_date:-unknown}  (:${MOVING_TAG})"

  if [ "${head_digest}" = "${PINNED_DIGEST}" ]; then
    log "[ok] pin is current"
  else
    log ""
    log "NOTE: :${MOVING_TAG} has moved ahead of the pin."
    log "  To bump, take the matching immutable tag and digest:"
    log "    curl -fsSL https://${REGISTRY}/v2/${REPOSITORY}/tags/list \\"
    log "      | python3 -m json.tool | grep -B5 '\"${MOVING_TAG}\"'"
  fi
}

main "$@"
