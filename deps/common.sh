# Shared helpers for deps/*.sh
#
# cosmocc produces fat (x86_64 + aarch64) binaries by compiling twice under
# the hood and apelink-ing the results. A plain `cosmocc`/`cosmoar` build of
# a static library does NOT reliably produce something both per-arch linkers
# can consume later (see docs/BUILD.md). The robust approach - and the one the
# Cosmopolitan project itself recommends for third-party libs - is to build
# the library once per architecture with the raw per-arch compilers
# (x86_64-linux-cosmo-gcc / aarch64-linux-cosmo-gcc) and install the result
# straight into the toolchain's own arch-specific lib directory, where
# cosmocc already looks by default - no extra -L/-I flags needed anywhere
# else in the build.
COSMOCC=/opt/cosmocc

install_fat_static_lib() {
  # install_fat_static_lib <libname.a> <path-to-x86_64-build> <path-to-aarch64-build>
  local name="$1" x86_build="$2" aarch64_build="$3"
  install -Dv "$x86_build/$name" "$COSMOCC/x86_64-linux-cosmo/lib/$name"
  install -Dv "$aarch64_build/$name" "$COSMOCC/aarch64-linux-cosmo/lib/$name"
}

install_common_headers() {
  # install_common_headers <src-include-dir-or-files...>
  mkdir -p "$COSMOCC/include"
  cp -rv "$@" "$COSMOCC/include/"
}

# fetch <url> <sha256> <output-file>
#
# Downloads <url> to <output-file> and verifies it against <sha256>. When
# DOWNLOAD_CACHE is set (the Dockerfile mounts a BuildKit cache there), a
# previously downloaded file with the right hash is reused instead, so
# rebuilding the image - even with --no-cache - does not download the same
# pinned archives again. Every file is checked against its pinned hash
# whether it came from the cache or the network; a cached file that does
# not match is discarded and fetched again.
fetch() {
  local url="$1" sha="$2" out="$3"
  local cached=""
  if [ -n "${DOWNLOAD_CACHE:-}" ]; then
    mkdir -p "$DOWNLOAD_CACHE"
    cached="$DOWNLOAD_CACHE/$sha"
    if [ -f "$cached" ] && echo "$sha  $cached" | sha256sum -c - >/dev/null 2>&1; then
      cp "$cached" "$out"
      echo "$(basename "$out"): OK (cached)"
      return 0
    fi
  fi
  curl -fsSL --retry 3 -o "$out" "$url"
  echo "$sha  $out" | sha256sum -c -
  if [ -n "$cached" ]; then
    cp "$out" "$cached.tmp.$$" && mv "$cached.tmp.$$" "$cached"
  fi
}
