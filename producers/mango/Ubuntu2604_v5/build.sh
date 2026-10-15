#!/bin/bash
# Ubuntu 26.04 arm64: build Mango + wlroots/SceneFX runtime .deb and patched Xwayland.
# Usage: [ANLAND_WITH_DEPS=1] [ANLAND_INSTALL=1] [WORKDIR=...] [JOBS=2] bash build.sh
# Patch overrides: MANGO_PATCH, WLROOTS_PATCH, SCENEFX_PATCH, XWAYLAND_PATCH.
# Xwayland overrides require the matching checksum in dependencies.lock.
# Untracked/stale Xwayland caches are preserved and require an explicit refresh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKEND="$SCRIPT_DIR/mango"
WORKDIR="${WORKDIR:-${MANGO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-mango-ubuntu2604}}"
JOBS="${JOBS:-2}"
PREFIX="$WORKDIR/prefix"
ARTIFACTS_DIR=${ARTIFACTS_DIR:-$SCRIPT_DIR/artifacts}
PACKAGES="$ARTIFACTS_DIR"
DEB="$PACKAGES/mango-anland_0.17.5+anland5_arm64.deb"
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
export PATH="$PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

ubuntu_preflight() {
    local ID VERSION_ID
    source /etc/os-release || die 'cannot identify distribution'
    [[ $ID == ubuntu && $VERSION_ID == 26.04 && $(dpkg --print-architecture) == arm64 ]] || die 'requires Ubuntu 26.04 ARM64'
    [[ $(id -u) != 0 ]] || die 'compile as an ordinary user'
    [[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
    for flag in ANLAND_INSTALL ANLAND_WITH_DEPS ANLAND_OFFLINE; do
        [[ ${!flag:-0} == 0 || ${!flag:-0} == 1 ]] || die "$flag must be 0 or 1"
    done
}
ubuntu_dependencies() {
    [[ ${ANLAND_WITH_DEPS:-0} == 1 ]] || return 0
    [[ ${ANLAND_OFFLINE:-0} == 0 ]] || die 'dependency installation requires network'
    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        run sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
    fi
    run sudo apt-get update
    run sudo apt-get install -y --no-install-recommends "${build_deps[@]}"
    local version
    version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$SCRIPT_DIR/xwayland.lock") || die 'cannot read Xwayland version'
    run sudo apt-get build-dep -y --no-install-recommends "xwayland=$version"
}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'mango-build: %s\n' "$*" >&2; exit 1; }
run() { "$@" || die "failed: $*"; }
find_patch() {
    local name="$1" file="${2:-}"
    if [ -n "$file" ]; then
        [ -f "$file" ] || die "patch not found: $file"
        realpath "$file"; return
    fi
    for file in "$SCRIPT_DIR/$name.patch" "$PWD/$name.patch" "$SCRIPT_DIR/../$name.patch" \
        "$ROOT/producers/kde/Debian13_v5/$name.patch"; do
        [ ! -f "$file" ] || { realpath "$file"; return; }
    done
    die "$name.patch not found (set ${name^^}_PATCH)"
}
declare -a components=() dependencies=() xwayland_sources=()
declare -A revision url checksum options patch_file xwayland_checksum
XWAYLAND_VERSION="" XWAYLAND_PATCH_SHA256="" XWAYLAND_DSC=""
load_lock() {
    local kind name pin source rest var
    while read -r kind name pin source rest; do
        [ -n "$kind" ] && [ "${kind#\#}" = "$kind" ] || continue
        url[$name]=$source
        case "$kind" in
            git) components+=("$name"); revision[$name]=$pin
                 var="${name^^}_PATCH"
                 patch_file[$name]="$(find_patch "$name" "${!var:-}")" || die "cannot select $name patch" ;;
            tar) dependencies+=("$name"); checksum[$name]=$pin; options[$name]=$rest ;;
            deb) [ "$name" = xwayland ] || die "unknown Debian source: $name"
                 [ -z "$XWAYLAND_VERSION" ] || die 'duplicate Xwayland source'
                 XWAYLAND_VERSION=$pin; XWAYLAND_PATCH_SHA256=$rest ;;
            file) [[ "$name" =~ ^xwayland_[A-Za-z0-9.+~-]+\.(dsc|orig\.tar\.xz|orig\.tar\.xz\.asc|debian\.tar\.xz)$ ]] ||
                      die "invalid Xwayland source filename: $name"
                  [ -z "${xwayland_checksum[$name]:-}" ] || die "duplicate Xwayland source file: $name"
                  [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || die "invalid Xwayland source checksum: $name"
                  xwayland_sources+=("$name"); xwayland_checksum[$name]=$pin
                  if [[ "$name" = *.dsc ]]; then
                      [ -z "$XWAYLAND_DSC" ] || die 'multiple Xwayland dsc files'
                      XWAYLAND_DSC=$name
                  fi ;;
            *) die "unknown source kind: $kind" ;;
        esac
    done < "$SCRIPT_DIR/dependencies.lock"
    [ $? -eq 0 ] || die 'cannot read dependencies.lock'
    [[ "$XWAYLAND_VERSION" =~ ^([0-9]+:)?[0-9][A-Za-z0-9.+~]*-[A-Za-z0-9.+~]+$ ]] || die 'invalid/missing Xwayland version'
    [[ "$XWAYLAND_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid/missing Xwayland patch checksum'
    [ "${#xwayland_sources[@]}" -eq 4 ] && [ -n "$XWAYLAND_DSC" ] || die 'incomplete Xwayland source lock'
}
source_identity() {
    {
        cat "$SCRIPT_DIR/dependencies.lock" "${patch_file[$1]}"
        if [[ $1 == mango ]]; then
            find -L "$BACKEND" -type f -print0 | sort -z | xargs -0 sha256sum
            cat "$SCRIPT_DIR/startup.sh"
        fi
    } | sha256sum | awk '{print $1}'
}
prepare_source() {
    local name="$1" tree="$WORKDIR/src/$1" seed
    local identity
    identity=$(source_identity "$name") || die "cannot identify source: $name"
    if [ -d "$tree" ]; then
        [ -f "$tree/.anland-source-identity" ] && [ "$(cat "$tree/.anland-source-identity")" = "$identity" ] || die "stale/untracked source preserved: $tree"
        log "Reuse $name"; return
    fi
    log "Fetch $name"
    run git init -q "$tree"
    if ! git -C "$tree" fetch -q --depth=1 "${url[$name]}" "${revision[$name]}"; then
        seed="$ROOT/../$name-anland5"
        run git -C "$tree" fetch -q "$seed" "${revision[$name]}"
    fi
    run git -C "$tree" checkout -q FETCH_HEAD
    run git -C "$tree" apply --whitespace=nowarn "${patch_file[$name]}"
    if [ "$name" = mango ]; then
        run mkdir -p "$tree/anland_backend"
        run cp "$BACKEND/"*.[ch] "$tree/anland_backend/"
        run install -m755 "$SCRIPT_DIR/startup.sh" "$tree/scripts/mango-anland"
    fi
    printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record source identity'
}
meson_build() {
    local source=$1 build=$2; shift 2
    local -a setup=()
    [[ ! -f "$build/meson-private/coredata.dat" ]] || setup+=(--reconfigure)
    run meson setup "${setup[@]}" "$build" "$source" --prefix="$PREFIX" --libdir=lib --buildtype=release --wrap-mode=nodownload "$@"
    run meson compile -C "$build" -j "$JOBS"
    run meson install -C "$build" --no-rebuild
}
bootstrap() {
    local name archive tree
    run mkdir -p "$WORKDIR/depcache" "$WORKDIR/deps-src"
    for name in "${dependencies[@]}"; do
        archive="$WORKDIR/depcache/${url[$name]##*/}"
        if [ ! -f "$archive" ]; then
            run curl -fL --retry 3 -o "$archive.part" "${url[$name]}"
            printf '%s  %s\n' "${checksum[$name]}" "$archive.part" | sha256sum -c - || die "checksum: $name"
            run mv "$archive.part" "$archive"
        fi
        printf '%s  %s\n' "${checksum[$name]}" "$archive" | sha256sum -c --status - || die "checksum: $name"
        tree="$WORKDIR/deps-src/$name"
        if [ ! -d "$tree" ]; then
            run mkdir -p "$tree"
            run tar -xf "$archive" -C "$tree" --strip-components=1
        fi
        local -a flags=(); read -r -a flags <<< "${options[$name]}"
        meson_build "$tree" "$WORKDIR/deps-build/$name" "${flags[@]}"
    done
}
package_deb() {
    local stage private file depends marker
    stage=$(mktemp -d "$WORKDIR/package.XXXXXX") || die 'cannot create package stage'
    private="$stage/usr/lib/mango-anland"
    log 'Package mango-anland'
    run mkdir -p "$private/bin" "$private/lib" "$stage/etc/mango-anland" \
        "$stage/usr/bin" "$stage/DEBIAN" "$stage/usr/share/doc/mango-anland" "$PACKAGES"
    run cp "$PREFIX/bin/mango" "$PREFIX/bin/mmsg" "$private/bin/"
    run install -m755 "$SCRIPT_DIR/startup.sh" "$private/bin/mango-anland"
    run cp -a "$PREFIX/lib/"*.so* "$private/lib/"
    run cp "$PREFIX/etc/mango/config.conf" "$stage/etc/mango-anland/config.conf"
    for file in mango mmsg; do
        cat > "$stage/usr/bin/$file" <<EOF
#!/bin/sh
export MANGO_ANLAND_MANAGE_SESSION=\${MANGO_ANLAND_MANAGE_SESSION:-0}
if [ "$file" = mango ] && [ ! -f "\$HOME/.config/mango/config.conf" ]; then
    set -- -c "\${MANGO_ANLAND_CONFIG:-/etc/mango-anland/config.conf}" "\$@"
fi
exec /usr/lib/mango-anland/bin/$file "\$@"
EOF
        [ $? -eq 0 ] || die 'cannot write launcher'
    done
    run ln -s ../lib/mango-anland/bin/mango-anland "$stage/usr/bin/mango-anland"
    run ln -s mango-anland "$stage/usr/bin/mango-anland-start"
    local -a roots=("$WORKDIR/src")
    [ ! -d "$WORKDIR/deps-src" ] || roots+=("$WORKDIR/deps-src")
    find "${roots[@]}" -mindepth 2 -maxdepth 2 -type f \
        \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'COPYRIGHT*' \) \
        -exec cat {} + > "$stage/usr/share/doc/mango-anland/copyright" || die 'license collection failed'
    run cat "$ROOT/LICENSE" >> "$stage/usr/share/doc/mango-anland/copyright"
    local -a shlibargs=()
    while IFS= read -r -d '' file; do
        [[ $(head -c4 "$file") == $'\x7fELF' ]] || continue
        case "$file" in
            "$private/bin/"*) run patchelf --set-rpath '$ORIGIN/../lib' "$file" ;;
            "$private/lib/"*) run patchelf --set-rpath '$ORIGIN' "$file" ;;
        esac
        run strip --strip-unneeded "$file"
        shlibargs+=("-e$file")
    done < <(find "$private" -type f -print0)
    run mkdir -p "$stage/metadata/debian"
    printf 'Source: mango-anland\nSection: x11\nPriority: optional\nMaintainer: Anland <build@localhost>\n\nPackage: mango-anland\nArchitecture: arm64\nDescription: Mango Anland compositor\n' \
        > "$stage/metadata/debian/control" || die 'cannot write dependency metadata'
    depends=$(cd "$stage/metadata" && dpkg-shlibdeps --ignore-missing-info -O "-l$private/lib" "${shlibargs[@]}") \
        || die 'dependency inference failed'
    depends=${depends#shlibs:Depends=}
    [ -n "$depends" ] || die 'empty runtime dependencies'
    cat > "$stage/DEBIAN/control" <<EOF
Package: mango-anland
Version: 0.17.5+anland5
Architecture: arm64
Section: x11
Priority: optional
Maintainer: Anland <build@localhost>
Depends: $depends, bash, procps, util-linux, xwayland, xkb-data, hwdata, libegl-mesa0, libgl1-mesa-dri
Description: Mango compositor with Anland v5 backend
 Private graphics dependencies; no automatic session or service changes.
EOF
    [ $? -eq 0 ] || die 'cannot write package control'
    printf '/etc/mango-anland/config.conf\n' > "$stage/DEBIAN/conffiles" || die 'cannot write conffiles'
    run rm -r "$stage/metadata"
    run find "$stage" -type d -exec chmod 755 {} +
    run find "$stage" -type f -exec chmod 644 {} +
    run chmod 755 "$private/bin/"* "$stage/usr/bin/mango" "$stage/usr/bin/mmsg"
    marker=$(mktemp "$WORKDIR/.package-start.XXXXXX") || die 'cannot create package marker'
    run dpkg-deb --root-owner-group -Zxz --build "$stage" "$DEB"
    [[ -s $DEB && $DEB -nt $marker &&
       $(dpkg-deb -f "$DEB" Package) == mango-anland &&
       $(dpkg-deb -f "$DEB" Version) == 0.17.5+anland5 &&
       $(dpkg-deb -f "$DEB" Architecture) == arm64 ]] || die 'invalid or stale Mango package'
    run rm -f -- "$marker"
    run rm -r "$stage"
}
build_xwayland() {
    local out="$WORKDIR/xwayland" lock="$SCRIPT_DIR/xwayland.lock" patch="$SCRIPT_DIR/xwayland.patch"
    local version identity name sha url file tree arch changes marker listing package_arch found=0
    run mkdir -p "$out/downloads" "$ARTIFACTS_DIR"
    version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$lock") || die 'cannot read Xwayland version'
    sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["patch_sha256"])' "$lock") || die 'cannot read Xwayland patch checksum'
    printf '%s  %s\n' "$sha" "$patch" | sha256sum -c --status - || die 'Xwayland patch checksum'
    identity=$(cat "$lock" "$patch" | sha256sum) || die 'Xwayland preparation identity'
    identity=${identity%% *}
    tree="$out/xwayland-${version#*:}"
    tree=${tree%-*}
    if [[ -d $tree ]]; then
        [[ -f $tree/.anland-source-identity && $(cat "$tree/.anland-source-identity") == "$identity" ]] || die "stale/unmanaged Xwayland source preserved: $tree"
    else
        python3 - "$lock" > "$out/sources.tsv" <<'PY_XWAYLAND'
import json, sys
lock = json.load(open(sys.argv[1]))
for name, sha in lock['files'].items():
    print(name, sha, lock['url'] + name, sep='\t')
PY_XWAYLAND
        [[ $? == 0 ]] || die 'cannot enumerate Xwayland sources'
        while IFS=$'\t' read -r name sha url; do
            file="$out/downloads/$name"
            if ! printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status - 2>/dev/null; then
                [[ ${ANLAND_OFFLINE:-0} != 1 ]] || die "offline Xwayland source missing: $name"
                run curl -fL --retry 3 -o "$file.part" "$url"
                printf '%s  %s\n' "$sha" "$file.part" | sha256sum -c - || die "Xwayland source checksum: $name"
                run mv "$file.part" "$file"
            fi
        done < "$out/sources.tsv"
        run dpkg-source -x "$out/downloads/xwayland_${version#*:}.dsc" "$tree"
        run patch --batch --forward --fuzz=0 -p1 -d "$tree" -i "$patch"
        printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record Xwayland preparation'
    fi
    [[ $(dpkg-parsechangelog -l "$tree/debian/changelog" -S Version) == "$version" ]] || die 'Xwayland changelog does not match lock'
    arch=$(dpkg --print-architecture) || die 'cannot read build architecture'
    changes="$out/xwayland_${version#*:}_${arch}.changes"
    marker=$(mktemp "$out/.build-start.XXXXXX") || die 'cannot create Xwayland marker'
    # The distro Xwayland must never inherit the WM's private SDK/library paths.
    (cd "$tree" && env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u CMAKE_PREFIX_PATH \
        -u LD_LIBRARY_PATH -u DESTDIR -u CFLAGS -u CXXFLAGS -u LDFLAGS \
        PATH=/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        DEB_BUILD_OPTIONS="nocheck nodwz noautodbgsym parallel=$JOBS" \
        dpkg-buildpackage -b -uc -us) || die 'Xwayland build failed'
    [[ -s $changes && $changes -nt $marker ]] || die "missing or stale changes: $changes"
    listing=$(awk '/^Files:/ {in_files=1; next} in_files && /^[^ ]/ {exit} in_files && $5 ~ /\.deb$/ {print $5}' "$changes") || die 'cannot read Xwayland package list'
    xwayland_debs=()
    while IFS= read -r file; do
        [[ $file == *.deb && $file != */* ]] || die "invalid package filename: $file"
        file="$out/$file"
        [[ -s $file && $file -nt $marker ]] || die "missing or stale package: $file"
        name=$(dpkg-deb -f "$file" Package) || die "cannot read package name: $file"
        [[ -n $name ]] || die "missing package name: $file"
        case $name in *-debug|*-dbg|*-dbgsym) continue ;; esac
        package_arch=$(dpkg-deb -f "$file" Architecture) || die "cannot read package architecture: $file"
        [[ $package_arch == "$arch" || $package_arch == all ]] || die "wrong package architecture: $file"
        [[ $(dpkg-deb -f "$file" Version) == "$version" ]] || die "wrong package version: $file"
        run dpkg-deb --contents "$file" >/dev/null
        run cp -p "$file" "$ARTIFACTS_DIR/"
        xwayland_debs+=("$ARTIFACTS_DIR/${file##*/}")
        [[ $name != xwayland ]] || found=1
    done <<<"$listing"
    [[ $found == 1 ]] || die 'no Xwayland runtime package produced'
    run rm -f -- "$marker"
}

main() {
    [ $# -eq 0 ] || die 'use environment variables, not arguments'
    ubuntu_preflight
    ubuntu_dependencies
    run mkdir -p "$WORKDIR/src" "$WORKDIR/build" "$PREFIX" "$PACKAGES"
    exec 8>"$WORKDIR/build.lock" || die 'cannot open build lock'
    flock -n 8 || die 'another builder owns WORKDIR'
    exec 9>"$PACKAGES/.build.lock" || die 'cannot open artifact lock'
    flock -n 9 || die 'another builder owns artifacts'
    load_lock
    # Ubuntu Wayland/libdrm are older than the locked wlroots ABI; build privately.
    bootstrap
    local name
    for name in "${components[@]}"; do prepare_source "$name"; done
    log 'Build display_producer'
    run cmake -S "$ROOT" -B "$WORKDIR/common" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
    run cmake --build "$WORKDIR/common" --target display_producer --parallel "$JOBS"
    run cmake --install "$WORKDIR/common/libdisplay_producer"
    meson_build "$WORKDIR/src/wlroots" "$WORKDIR/build/wlroots" \
        -Dexamples=false -Dbackends=drm,libinput -Drenderers=gles2 -Dallocators=gbm \
        -Dsession=enabled -Dlibliftoff=disabled -Dxwayland=enabled -Dcolor-management=disabled
    meson_build "$WORKDIR/src/scenefx" "$WORKDIR/build/scenefx" -Dexamples=false -Dcolor-management=disabled
    meson_build "$WORKDIR/src/mango" "$WORKDIR/build/mango" --sysconfdir="$PREFIX/etc" -Danland=enabled -Dxwayland=enabled
    package_deb
    build_xwayland
    run sha256sum "$DEB" "${xwayland_debs[@]}"
    if [ "${ANLAND_INSTALL:-0}" = 1 ]; then run $SUDO dpkg -i "$DEB" "${xwayland_debs[@]}"; fi
    log "Done. Packages: $PACKAGES (Mango + Xwayland)"
}
build_deps=(build-essential cmake meson ninja-build pkgconf ccache python3 curl ca-certificates git dpkg-dev debhelper fakeroot quilt patch xz-utils unzip zip file binutils libpipewire-0.3-dev libinput-dev libudev-dev libseat-dev libdisplay-info-dev libgbm-dev libegl-dev libgles-dev libvulkan-dev glslang-tools libpcre2-dev libcjson-dev libpango1.0-dev libpixman-1-dev libwayland-dev libdrm-dev libxkbcommon-dev libffi-dev libexpat1-dev libxml2-dev bison libxcb1-dev libxcb-render0-dev libxcb-randr0-dev libxcb-xfixes0-dev libxcb-icccm4-dev libxcb-composite0-dev libxcb-errors-dev libxcb-ewmh-dev libxcb-res0-dev libxcb-shape0-dev libxcb-shm0-dev xkb-data hwdata wayland-protocols patchelf xwayland)
xwayland_debs=()
main "$@"
