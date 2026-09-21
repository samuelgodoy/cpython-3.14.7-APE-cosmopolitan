# syntax=docker/dockerfile:1
#
# Builder image for cpython-cosmo.
#
# Everything that goes into the image is pinned so that rebuilding it later
# produces the same toolchain and the same third-party libraries:
#
#   - the base image by digest (not by the moving ubuntu:22.04 tag)
#   - apt packages through a dated snapshot.ubuntu.com mirror
#   - the Cosmopolitan toolchain (cosmocc) by version and sha256
#   - every third-party source, by version and sha256 (deps/*.sh)
#
# Only host build tools come from apt. Nothing apt installs is linked into
# the final binary; all C libraries are compiled from source with cosmocc.
#
# Caching:
#   - Each dependency is its own layer, ordered from the most stable to the
#     most frequently edited, so changing e.g. the psycopg patch rebuilds
#     only the last two layers instead of OpenSSL and libpq for both
#     architectures.
#   - Downloads go through a BuildKit cache mount (DOWNLOAD_CACHE), keyed by
#     sha256. It survives `docker compose build --no-cache`, so a full
#     rebuild recompiles everything but downloads nothing it already has.
#     Every file is still checked against its pinned hash.

# ubuntu:22.04 (multi-arch index digest)
ARG UBUNTU_DIGEST=sha256:b8b6ee6aa931ecd9d0d952abc34dc0e5f7c6a30c6bb71b079fe399fde0329c02
FROM ubuntu@${UBUNTU_DIGEST}

ARG APT_SNAPSHOT=20260915T000000Z
# APT_SNAPSHOT as a Unix timestamp, used as SOURCE_DATE_EPOCH while the
# third-party libraries are built, so nothing they embed depends on when the
# image was built. OpenSSL, for one, bakes a "built on: <date>" string into
# libcrypto, which then ends up in both halves of the final binary.
# (scripts/build.sh sets its own SOURCE_DATE_EPOCH for the CPython build.)
ARG DEPS_SOURCE_DATE_EPOCH=1789430400
ARG COSMOCC_VERSION=4.0.2
ARG COSMOCC_SHA256=85b8c37a406d862e656ad4ec14be9f6ce474c1b436b9615e91a55208aced3f44

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# The snapshot mirror serves a frozen view of the archive. The first
# update runs before ca-certificates exists, so TLS peer verification is
# off for this bootstrap only; package integrity does not depend on TLS -
# apt verifies every index against the archive's GPG-signed InRelease.
RUN set -eux; \
    S="http://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}"; \
    printf 'deb %s jammy main universe\ndeb %s jammy-updates main universe\ndeb %s jammy-security main universe\n' \
      "$S" "$S" "$S" > /etc/apt/sources.list; \
    rm -f /etc/apt/sources.list.d/*; \
    apt-get -o Acquire::https::Verify-Peer=false update; \
    apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
      build-essential autoconf automake pkg-config \
      zip unzip bison flex patch file \
      curl ca-certificates git; \
    rm -rf /var/lib/apt/lists/*

# Cosmopolitan cross toolchain (~440 MB). GitHub releases is tried first
# (usually the faster mirror), cosmo.zip as fallback; both serve the same
# file, checked against the pinned hash either way.
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    set -eux; \
    f="/var/cache/downloads/${COSMOCC_SHA256}"; \
    if ! echo "${COSMOCC_SHA256}  $f" | sha256sum -c - >/dev/null 2>&1; then \
      rm -f "$f"; \
      curl -fsSL --retry 3 -o "$f.part" "https://github.com/jart/cosmopolitan/releases/download/${COSMOCC_VERSION}/cosmocc-${COSMOCC_VERSION}.zip" \
        || curl -fsSL --retry 3 -o "$f.part" "https://cosmo.zip/pub/cosmocc/cosmocc-${COSMOCC_VERSION}.zip"; \
      mv "$f.part" "$f"; \
    fi; \
    echo "${COSMOCC_SHA256}  $f" | sha256sum -c -; \
    mkdir -p /opt/cosmocc; \
    unzip -q "$f" -d /opt/cosmocc

ENV PATH="/opt/cosmocc/bin:${PATH}" \
    COSMOCC=/opt/cosmocc \
    DOWNLOAD_CACHE=/var/cache/downloads \
    SOURCE_DATE_EPOCH=${DEPS_SOURCE_DATE_EPOCH}

# Third-party sources, one layer each (see "Caching" above). 01-07 build C
# libraries once per architecture and install them into the toolchain;
# 08 and 09 fetch sources that the CPython build compiles later, with this
# project's patches applied. Changing anything under deps/ or the patches
# a step uses invalidates that step and the ones after it; run
# `docker compose build` afterwards.
COPY deps/common.sh /opt/deps/common.sh

COPY deps/01-zlib.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/01-zlib.sh && rm -rf /work/build/deps-src

COPY deps/02-bzip2.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/02-bzip2.sh && rm -rf /work/build/deps-src

COPY deps/03-xz.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/03-xz.sh && rm -rf /work/build/deps-src

COPY deps/04-libffi.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/04-libffi.sh && rm -rf /work/build/deps-src

COPY deps/05-sqlite3.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/05-sqlite3.sh && rm -rf /work/build/deps-src

COPY deps/06-openssl.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/06-openssl.sh && rm -rf /work/build/deps-src

COPY deps/07-libpq.sh /opt/deps/
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/07-libpq.sh && rm -rf /work/build/deps-src

COPY deps/08-psycopg.sh /opt/deps/
COPY patches/psycopg-c /opt/patches/psycopg-c
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/08-psycopg.sh && rm -rf /tmp/deps-src

COPY deps/09-cosmopolitan-libc.sh /opt/deps/
COPY patches/cosmopolitan /opt/patches/cosmopolitan
RUN --mount=type=cache,id=cpython-cosmo-downloads,target=/var/cache/downloads,sharing=locked \
    bash /opt/deps/09-cosmopolitan-libc.sh && touch /opt/cosmocc/.deps-built

WORKDIR /work

ENTRYPOINT ["/work/scripts/build.sh"]
