# Forestay Base Image

Runtime base image for all Forestay controller variants.


## Purposes

Forestay controllers are single static Go binaries. This image gives them the
two things a static binary still needs from a filesystem, a CA bundle for
outbound TLS and zone data for timestamps, plus a non-root identity. It carries
no shell, no package manager and no interpreter.

No image from outside the `forestay-io` org is used directly, at build time or
run time. Every external image enters the project through this repo or through
[`forestay-build-image-aws`](https://github.com/forestay-io/forestay-build-image-aws)
and its per variant siblings. Those are the only places an upstream image
reference appears.

Variant controllers then build on the in-org image:

```dockerfile
FROM <registry>/forestay-io/forestay-base-image:<pinned version>
COPY forestay-aws /forestay-aws
USER 65532:65532
ENTRYPOINT ["/forestay-aws"]
CMD ["run"]
```

The user must stay numeric. The shared deployment sets `runAsNonRoot` without
`runAsUser`, and the kubelet cannot verify a user given by name, so `USER
nonroot` would stop every pod starting. The consuming repo pins the version it
wants and bumps it deliberately.


## Contents

| Item                         | Why                                                |
|------------------------------|----------------------------------------------------|
| CA certificate bundle        | Outbound TLS to cloud provider APIs                |
| Time zone data               | Timestamps in status, events and the log trail     |
| Numeric uid 65532            | Containers never run as root, and it is verifiable |
| No shell, no package manager | Nothing in the image can execute a command string  |

Upstream is `gcr.io/distroless/static`, pinned in `src/docker/Dockerfile` by
both an immutable tag and a digest:

```
gcr.io/distroless/static:nonroot-<commit>@sha256:<digest>
```

The `nonroot-<commit>` tag names one distroless build and never moves, unlike
`:nonroot`, so it can be reconciled against the digest. The digest is the
multi-architecture index, so one line serves both architectures and resolves to
the matching manifest during each per-platform build.

Getting the variant right matters: `static:latest` runs as root and
`static:nonroot` is uid 65532.


## Bumping upstream

Print the `FROM` line for whatever `:nonroot` currently points at:

```bash
curl -fsSL https://gcr.io/v2/distroless/static/tags/list | python3 -c '
import json, sys
for digest, m in json.load(sys.stdin)["manifest"].items():
    tags = m.get("tag") or []
    if "nonroot" in tags:
        pin = sorted(t for t in tags if t.startswith("nonroot-"))[-1]
        print(f"FROM gcr.io/distroless/static:{pin}@{digest}")
'
```

Paste that over the existing `FROM` and state the upstream tag in the commit
message. One digest can carry several `nonroot-<commit>` tags, because
distroless builds reproducibly and a rebuild that changes nothing lands on the
same content.

Distroless zeroes every timestamp in the image for reproducibility, so the
publish date comes from the registry rather than the image itself.

CI runs `.github/bin/check-upstream.bash` on every build, so a bad pin is
caught whether or not you look. You can run it by hand too, which is the
quickest way to confirm a bump before pushing.


## Build

With Kaptain setup locally use `kaptain build` to build the project. It is set
up to build `linux/amd64` and `linux/arm64` from the one Dockerfile in
`src/docker/`, once per architecture into separate build contexts, and then
publish the multi-architecture manifest.

`.github/bin/check-upstream.bash` runs as the `preTaggingTests` hook. It fails
the build if the pinned immutable tag no longer resolves to the pinned digest,
which would mean upstream re-pushed a tag that names one build, and reports how
far behind `:nonroot` the pin has fallen without failing on staleness. Bumping
the base is a deliberate commit, not something a build does on your behalf.

`.github/bin/run-tests.bash` runs as the `postDockerTests` hook. It asserts, per
architecture, that the CA bundle, time zone data and passwd database are
present, that the user is numeric uid 65532, and that no shell, bash or busybox
is present. The image has no shell of its own, so every check runs from outside
using the image config and the exported filesystem.


## Licence

See [LICENSE.md](LICENSE.md).
