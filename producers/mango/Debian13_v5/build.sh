#!/bin/bash
# Debian 13 arm64: build Mango + wlroots/SceneFX runtime .deb and patched Xwayland.
# Usage: [ANLAND_WITH_DEPS=1] [ANLAND_INSTALL=1] [WORKDIR=...] [JOBS=2] bash build.sh
# Patch overrides: MANGO_PATCH, WLROOTS_PATCH, SCENEFX_PATCH, XWAYLAND_PATCH.
# Xwayland overrides require the matching checksum in dependencies.lock.
# Untracked/stale Xwayland caches are preserved and require an explicit refresh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKEND="$SCRIPT_DIR/mango"
WORKDIR="${WORKDIR:-${MANGO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-mango}}"
JOBS="${JOBS:-2}"
PREFIX="$WORKDIR/prefix"
PACKAGES="$SCRIPT_DIR/artifacts"
DEB="$PACKAGES/mango-anland_0.17.5+anland5_arm64.deb"
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
export PATH="$PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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
            file) [[ "$name" =~ ^xwayland_[A-Za-z0-9.+~-]+\.(dsc|orig\.tar\.xz|debian\.tar\.xz)$ ]] ||
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
    [ "${#xwayland_sources[@]}" -eq 3 ] && [ -n "$XWAYLAND_DSC" ] || die 'incomplete Xwayland source lock'
}
prepare_source() {
    local name="$1" tree="$WORKDIR/src/$1" seed
    [ ! -d "$tree" ] || { log "Reuse $name"; return; }
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
    local stage private file depends
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
export LD_LIBRARY_PATH="/usr/lib/mango-anland/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
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
    run dpkg-deb --root-owner-group -Zxz --build "$stage" "$DEB"
    run rm -r "$stage"
}
declare -a xwayland_debs=()
build_xwayland() {
    local out="$WORKDIR/xwayland" tree patch file identity upstream
    patch="$(find_patch xwayland "${XWAYLAND_PATCH:-}")" || die 'cannot select Xwayland patch'
    printf '%s  %s\n' "$XWAYLAND_PATCH_SHA256" "$patch" | sha256sum -c --status - ||
        die 'checksum: xwayland.patch (update lock for an intentional override)'
    identity=$({
        printf '%s\n' "$XWAYLAND_VERSION" "$XWAYLAND_PATCH_SHA256"
        for file in "${xwayland_sources[@]}"; do
            printf '%s %s\n' "$file" "${xwayland_checksum[$file]}"
        done
    } | sha256sum) || die 'source identity: xwayland'
    identity=${identity%% *}
    upstream=${XWAYLAND_VERSION#*:}
    tree="$out/xwayland-${upstream%-*}"
    run mkdir -p "$out" "$PACKAGES"
    if [ -d "$tree" ]; then
        [ -f "$tree/.anland-source-identity" ] &&
            [ "$(cat "$tree/.anland-source-identity")" = "$identity" ] ||
            die "stale or untracked prepared source: $tree; refresh explicitly (local edits are preserved)"
        log 'Reuse locked Xwayland source'
    else
        log 'Fetch Xwayland (locked Debian source)'
        (cd "$out" && apt-get source --download-only --only-source "xwayland=$XWAYLAND_VERSION") ||
            die 'apt source: locked xwayland (enable deb-src)'
        for file in "${xwayland_sources[@]}"; do
            printf '%s  %s\n' "${xwayland_checksum[$file]}" "$out/$file" | sha256sum -c --status - ||
                die "Xwayland source checksum: $file"
        done
        run dpkg-source -x "$out/$XWAYLAND_DSC" "$tree"
        (cd "$tree" && patch --batch --fuzz=0 -p1 --forward -i "$patch") || die 'Xwayland patch failed'
        printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record prepared Xwayland'
    fi
    log 'Build Xwayland .deb'
    run rm -f "$out"/xwayland_*.deb
    (cd "$tree" && env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u CMAKE_PREFIX_PATH \
        -u LD_LIBRARY_PATH -u DESTDIR PATH="/usr/lib/ccache:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        DEB_BUILD_OPTIONS="nocheck nodwz parallel=$JOBS" dpkg-buildpackage -b -uc -us) || die 'package: xwayland'
    local -a debs=("$out"/xwayland_*.deb)
    [ -f "${debs[0]}" ] || die 'no Xwayland package produced'
    for file in "${debs[@]}"; do
        run cp -p "$file" "$PACKAGES/"
        xwayland_debs+=("$PACKAGES/${file##*/}")
    done
}
main() {
    [ $# -eq 0 ] || die 'use environment variables, not arguments'
    [ "$(dpkg --print-architecture)" = arm64 ] || die 'requires Debian arm64'
    run mkdir -p "$WORKDIR/src" "$WORKDIR/build" "$PREFIX"
    load_lock
    if [ "${ANLAND_WITH_DEPS:-0}" = 1 ]; then bootstrap; fi
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
    local -a package_names=("${DEB##*/}")
    local file
    for file in "${xwayland_debs[@]}"; do package_names+=("${file##*/}"); done
    (cd "$PACKAGES" && sha256sum "${package_names[@]}" > SHA256SUMS) || die 'cannot write SHA256SUMS'
    if [ "${ANLAND_INSTALL:-0}" = 1 ]; then run $SUDO dpkg -i "$DEB" "${xwayland_debs[@]}"; fi
    log "Done. Packages: $PACKAGES (Mango + Xwayland)"
}
main "$@"