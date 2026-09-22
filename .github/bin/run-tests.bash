#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Forestay contributors (Fred Cooke)
#
# run-tests.bash - postDockerTests hook for forestay-base-image
#
# Asserts the built runtime base actually carries what every Forestay
# controller relies on, and nothing more. The image has no shell, so every
# check runs from outside: image config for identity, exported filesystem for
# contents.
#
# Available context (set by the Kaptain CI wrapper):
#   DOCKER_TARGET_IMAGE_FULL_URI - base image URI, per-arch images are this
#                                  plus a "-linux-amd64" style suffix
#   DOCKER_PLATFORM              - comma separated platform list
#
# Must run on bash 3.2.57: no associative arrays, no mapfile, no ${var,,}.

set -euo pipefail

FAILURES=0

log() {
  echo "$@"
}

fail() {
  echo "[FAILED] $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  echo "[ok] $*"
}

find_container_cli() {
  if [[ -n "${CONTAINER_CLI:-}" ]]; then
    echo "${CONTAINER_CLI}"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    echo "docker"
    return 0
  fi
  if command -v podman >/dev/null 2>&1; then
    echo "podman"
    return 0
  fi
  return 1
}

# Lists the image filesystem, one path per line, without a leading "./".
# The placeholder command is never run, but docker will not create without one.
export_paths() {
  local cli="$1"
  local image="$2"
  local container
  if ! container=$("${cli}" create "${image}" /nonexistent-never-run); then
    return 1
  fi
  if [[ -z "${container}" ]]; then
    return 1
  fi
  "${cli}" export "${container}" | tar -t 2>/dev/null | sed -e 's,^\./,,'
  "${cli}" rm -f "${container}" >/dev/null 2>&1 || true
}

assert_present() {
  local paths="$1"
  local wanted="$2"
  local label="$3"
  if grep -q -x -F "${wanted}" <<< "${paths}"; then
    pass "${label} present (${wanted})"
  else
    fail "${label} missing (${wanted})"
  fi
}

assert_absent() {
  local paths="$1"
  local unwanted="$2"
  local label="$3"
  if grep -q -x -F "${unwanted}" <<< "${paths}"; then
    fail "${label} present and must not be (${unwanted})"
  else
    pass "${label} absent (${unwanted})"
  fi
}

test_image() {
  local cli="$1"
  local image="$2"
  local paths user

  log ""
  log "--- ${image} ---"

  if ! "${cli}" image inspect "${image}" >/dev/null 2>&1; then
    fail "image not present locally: ${image}"
    return
  fi

  # Expected id comes from the image, so it is stated once in the Dockerfile.
  # Must also be numeric: the kubelet cannot verify runAsNonRoot from a name.
  local want
  want=$("${cli}" image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${image}" 2>/dev/null \
    | sed -n 's/^FORESTAY_USER_ID=//p')
  if [[ -z "${want}" ]]; then
    fail "FORESTAY_USER_ID is not set in the image"
    return
  fi

  user=$("${cli}" image inspect --format '{{.Config.User}}' "${image}" 2>/dev/null || echo "")
  case "${user}" in
    "")
      fail "no User set, image would run as root"
      ;;
    "${want}"|"${want}:${want}")
      pass "runs as numeric uid ${want} (User=${user})"
      ;;
    *[!0-9:]*)
      fail "User '${user}' is not numeric, runAsNonRoot cannot be verified and the pod will not start"
      ;;
    *)
      fail "User '${user}' is numeric but not ${want}"
      ;;
  esac

  if ! paths=$(export_paths "${cli}" "${image}"); then
    fail "could not export filesystem for ${image}"
    return
  fi

  # Outbound TLS to every cloud API depends on this bundle.
  assert_present "${paths}" "etc/ssl/certs/ca-certificates.crt" "CA bundle"

  # Timestamps in status, events and logs are useless without zone data.
  assert_present "${paths}" "usr/share/zoneinfo/UTC" "tzdata"

  # /etc/passwd carries the nonroot entry the runtime resolves.
  assert_present "${paths}" "etc/passwd" "passwd database"

  # No shell is the whole point of a static distroless base. Anything that
  # can execute a command string widens the blast radius of an RCE.
  assert_absent "${paths}" "bin/sh" "shell"
  assert_absent "${paths}" "bin/bash" "bash"
  assert_absent "${paths}" "bin/busybox" "busybox"
}

main() {
  local cli platform suffix image tested

  if ! cli=$(find_container_cli); then
    echo "[FAILED] no container CLI found, set CONTAINER_CLI or install docker or podman" >&2
    exit 1
  fi
  log "Using container CLI: ${cli}"

  if [[ -z "${DOCKER_TARGET_IMAGE_FULL_URI:-}" ]]; then
    echo "[FAILED] DOCKER_TARGET_IMAGE_FULL_URI is not set" >&2
    exit 1
  fi

  tested=0

  # Derive the per-architecture image names the same way the build does:
  # platform with slashes turned into hyphens, appended to the base URI.
  if [[ "${DOCKER_PLATFORM:-}" == *,* ]]; then
    local platforms
    IFS=',' read -r -a platforms <<< "${DOCKER_PLATFORM}"
    for platform in "${platforms[@]}"; do
      suffix=$(echo "${platform}" | tr '/' '-')
      image="${DOCKER_TARGET_IMAGE_FULL_URI}-${suffix}"
      test_image "${cli}" "${image}"
      tested=$((tested + 1))
    done
  else
    test_image "${cli}" "${DOCKER_TARGET_IMAGE_FULL_URI}"
    tested=$((tested + 1))
  fi

  log ""
  if [[ ${FAILURES} -gt 0 ]]; then
    echo "[FAILED] ${FAILURES} check(s) failed across ${tested} image(s)" >&2
    exit 1
  fi
  log "All checks passed across ${tested} image(s)"
}

main "$@"
