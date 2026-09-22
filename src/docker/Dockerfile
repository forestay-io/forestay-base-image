# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Forestay contributors (Fred Cooke)
#
# Runtime base for every Forestay variant controller.
#
# One of only two places in the project referencing an image from outside the
# org. The commit suffixed tag is immutable, so it names one build forever and
# can be reconciled against the digest; .github/bin/check-upstream.bash does
# that. The digest is the multi-architecture index, correct for both arches.
#
# static:latest runs as root, static:nonroot is uid 65532. Keep the nonroot
# one.
FROM gcr.io/distroless/static:nonroot-c7d8b67bce5a65ae75ba33c4007dc112368949ca@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3

# Supplied by the build system
ARG VERSION
ARG PROJECT_NAME
ARG DOCKER_TAG
ARG DOCKER_IMAGE_NAME

# Leave a trail of breadcrumbs
LABEL description="Forestay - runtime base image"
LABEL base.project.name="${PROJECT_NAME}"
LABEL base.version="${VERSION}"
LABEL base.docker.tag="${DOCKER_TAG}"
LABEL base.docker.image.name="${DOCKER_IMAGE_NAME}"

# Published so consumers and tests read the id from here rather than repeating
# it. Must stay numeric: the deployment sets runAsNonRoot without runAsUser,
# and the kubelet cannot verify a user given by name, so a name would stop
# every pod starting.
ENV FORESTAY_USER_ID=65532

# Upstream already sets this; restated so the tests catch it if that changes.
USER ${FORESTAY_USER_ID}:${FORESTAY_USER_ID}
