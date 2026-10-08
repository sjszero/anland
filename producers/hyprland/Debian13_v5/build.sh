#!/bin/bash
# Debian 13 arm64: build Hyprland + Aquamarine + Hyprgrass + patched Xwayland .debs.
# Usage: [ANLAND_INSTALL=1] [WORKDIR=...] [JOBS=4] bash build.sh
# Patch overrides: HYPRLAND_PATCH, AQUAMARINE_PATCH, HYPRGRASS_PATCH, XWAYLAND_PATCH.
# Intentional overrides require matching lock-file checksums.
# Prepared trees without .anland-source-identity need an explicit refresh; never auto-delete.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKEND="$SCRIPT_DIR/../anland_backend"
WORKDIR="${WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-hyprland}"
JOBS="${JOBS:-4}"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
SYSROOT="$WORKDIR/sysroot"
LIBDIR="$SYSROOT/usr/lib/$ARCH"
ARTIFACTS="$SCRIPT_DIR/artifacts"
[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo"
export DEB_BUILD_OPTIONS="nocheck nodwz parallel=$JOBS"
export CCACHE_DIR="$WORKDIR/ccache" CCACHE_BASEDIR="$WORKDIR"
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH LD_LIBRARY_PATH DESTDIR
export PKG_CONFIG_DISABLE_UNINSTALLED=1
export PKG_CONFIG_LIBDIR="/usr/lib/$ARCH/pkgconfig:/usr/share/pkgconfig"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'hyprland-build: %s\n' "$*" >&2; exit 1; }
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
build_env() {
    env PKG_CONFIG_PATH="$LIBDIR/pkgconfig" CMAKE_PREFIX_PATH="$SYSROOT/usr" \
        LD_LIBRARY_PATH="$LIBDIR" "$@"
}

# Keep cached development trees intact. Refuse stale/incomplete preparation
# rather than silently ignoring changed patches or overwriting local edits.
source_identity() {
    python3 - "$SCRIPT_DIR/dependencies.lock" "$ROOT" "$BACKEND" "$1" "${2:-}" <<'PY'
import hashlib, json, pathlib, sys
lock_path, root, backend, name, patch = sys.argv[1:]
lock = json.loads(pathlib.Path(lock_path).read_text())
h = hashlib.sha256()
entry = lock['plugins'] if name == 'hyprgrass' else lock['sources']
h.update(json.dumps(entry[name] if name != 'xwayland' else lock['xwayland'], sort_keys=True).encode())
if name == 'hyprgrass':
    h.update(json.dumps(lock['plugins']['wf-touch'], sort_keys=True).encode())
if patch:
    h.update(pathlib.Path(patch).read_bytes())
folders = []
if name in ('aquamarine', 'hyprland'):
    folders.append(pathlib.Path(backend) / name)
if name == 'aquamarine':
    folders.extend(pathlib.Path(root) / p for p in ('libdisplay_producer', 'common'))
for folder in folders:
    for p in sorted(folder.rglob('*')):
        if p.is_file():
            h.update(str(p.relative_to(folder)).encode() + b'\0')
            h.update(p.read_bytes())
print(h.hexdigest())
PY
}
reuse_source() {
    local tree="$1" identity="$2"
    [ -f "$tree/.anland-source-identity" ] &&
        [ "$(cat "$tree/.anland-source-identity")" = "$identity" ] ||
        die "stale or untracked prepared source: $tree; refresh explicitly (local edits are preserved)"
}

declare -A directory version runtime dsc plugin patch_file
declare -a PROJECTS=(hyprutils hyprlang hyprgraphics aquamarine hyprland) packages=()
fetch_sources() {
    local kind name a b c d file
    run mkdir -p "$WORKDIR/downloads" "$WORKDIR/src" "$ARTIFACTS"
    python3 - "$SCRIPT_DIR/dependencies.lock" > "$WORKDIR/sources.tsv" <<'PY'
import json, sys
with open(sys.argv[1]) as f: lock = json.load(f)
for name, e in lock['sources'].items():
    print('source', name, e['directory'], e['version'], lock['runtime_packages'][name], next(f for f in e['files'] if f.endswith('.dsc')), sep='\t')
    for file, sha in e['files'].items(): print('download', file, sha, e['url'] + file, sep='\t')
for name in ('hyprgrass', 'wf-touch'):
    e = lock['plugins'][name]
    print('plugin', name, e['archive'], sep='\t')
    print('download', e['archive'], e['sha256'], e['url'], sep='\t')
PY
    [ $? -eq 0 ] || die 'cannot read dependencies.lock'
    while IFS=$'\t' read -r kind name a b c d; do
        case "$kind" in
            source) directory[$name]=$a; version[$name]=$b; runtime[$name]=$c; dsc[$name]=$d
                    packages+=("${c}_${b}+anland5_arm64.deb") ;;
            plugin) plugin[$name]=$a ;;
            download)
                file="$WORKDIR/downloads/$name"
                if [ -f "$file" ] && printf '%s  %s\n' "$a" "$file" | sha256sum -c --status -; then continue; fi
                log "Download $name"
                run curl -fL --retry 3 -o "$file.part" "$b"
                printf '%s  %s\n' "$a" "$file.part" | sha256sum -c - || die "checksum: $name"
                run mv "$file.part" "$file" ;;
        esac
    done < "$WORKDIR/sources.tsv"
    for name in aquamarine hyprland hyprgrass; do
        local var="${name^^}_PATCH"
        patch_file[$name]="$(find_patch "$name" "${!var:-}")" || die "cannot select $name patch"
        verify_patch "$name" "${patch_file[$name]}"
    done
}
verify_patch() {
    local expected
    expected=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["patches"][sys.argv[2]+".patch"])' \
        "$SCRIPT_DIR/dependencies.lock" "$1") || die 'cannot read patch checksum'
    printf '%s  %s\n' "$expected" "$2" | sha256sum -c --status - || die "checksum: $1.patch (update lock for an intentional override)"
}
prepare_source() {
    local name="$1" tree="$WORKDIR/src/${directory[$1]}" identity
    identity=$(source_identity "$name" "${patch_file[$name]:-}") || die "source identity: $name"
    if [ -d "$tree" ]; then reuse_source "$tree" "$identity"; log "Reuse $name"; return; fi
    log "Prepare $name"
    run dpkg-source -x "$WORKDIR/downloads/${dsc[$name]}" "$tree"
    if [ "$name" = aquamarine ] || [ "$name" = hyprland ]; then
        run cp -aL "$BACKEND/$name/." "$tree/"
        if [ "$name" = aquamarine ]; then
            run mkdir -p "$tree/src/backend/anland/public"
            run cp -aL "$ROOT/libdisplay_producer" "$ROOT/common" "$tree/src/backend/anland/public/"
        fi
        run mkdir -p "$tree/debian/patches"
        run cp "${patch_file[$name]}" "$tree/debian/patches/anland-$name.patch"
        printf '\nanland-%s.patch\n' "$name" >> "$tree/debian/patches/series" || die 'cannot update patch series'
        (cd "$tree" && QUILT_PATCHES=debian/patches quilt push -a) || die "quilt: $name"
    fi
    { printf '%s (%s+anland5) UNRELEASED; urgency=medium\n\n  * Anland v5 backend.\n\n -- Anland <build@localhost>  Wed, 07 Oct 2026 00:00:00 +0000\n\n' "$name" "${version[$name]}"
      cat "$tree/debian/changelog"; } > "$tree/debian/changelog.new" || die 'cannot write changelog'
    run mv "$tree/debian/changelog.new" "$tree/debian/changelog"
    printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record prepared source'
}
cmake_build() {
    local name="$1" folder="$WORKDIR/build/$1" module
    log "Build $name"
    local -a args=(-U 'pkgcfg_lib_*' -U '__pkg_config_checked_*'
        -S "$WORKDIR/src/${directory[$name]}" -B "$folder" -G Ninja
        -DCMAKE_BUILD_TYPE=Release -DFETCHCONTENT_FULLY_DISCONNECTED=ON
        -DCMAKE_INSTALL_PREFIX=/usr "-DCMAKE_INSTALL_LIBDIR=lib/$ARCH")
    if command -v ccache >/dev/null; then
        args+=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
    fi
    if [ "$name" != hyprutils ]; then
        args+=("-DCMAKE_CXX_FLAGS=-I$SYSROOT/usr/include" "-Dpkgcfg_lib_deps_hyprutils=$LIBDIR/libhyprutils.so")
    fi
    if [ "$name" = hyprland ]; then
        args+=(-DBUILD_TESTING=OFF -DBUILD_HYPRTESTER=OFF -DNO_HYPRPM=OFF "-DCMAKE_INSTALL_INCLUDEDIR=include/$ARCH")
        for module in hyprutils_dep hyprctl_deps hyprpm_deps starthyprland_deps; do
            args+=("-Dpkgcfg_lib_${module}_hyprutils=$LIBDIR/libhyprutils.so")
        done
        for module in hyprlang hyprgraphics; do args+=("-Dpkgcfg_lib_${module}_dep_$module=$LIBDIR/lib$module.so"); done
    fi
    run build_env cmake "${args[@]}"
    run build_env cmake --build "$folder" --parallel "$JOBS"
    if [ "$name" != hyprland ]; then
        run build_env env DESTDIR="$SYSROOT" cmake --install "$folder"
        run sed -i -e "s|^prefix=/usr$|prefix=$SYSROOT/usr|" \
            -e 's|includedir=/usr/include|includedir=${prefix}/include|' \
            -e 's|libdir=/usr/lib/|libdir=${prefix}/lib/|' "$LIBDIR/pkgconfig/$name.pc"
    fi
}
build_hyprgrass() {
    local tree="$WORKDIR/src/hyprgrass" folder="$WORKDIR/build/hyprgrass" pc="$WORKDIR/plugin-pkgconfig" identity
    identity=$(source_identity hyprgrass "${patch_file[hyprgrass]}") || die 'source identity: hyprgrass'
    if [ -d "$tree" ]; then
        reuse_source "$tree" "$identity"
    else
        run mkdir -p "$tree"
        run tar -xf "$WORKDIR/downloads/${plugin[hyprgrass]}" -C "$tree" --strip-components=1
        run mkdir -p "$tree/subprojects/wf-touch"
        run tar -xf "$WORKDIR/downloads/${plugin[wf-touch]}" -C "$tree/subprojects/wf-touch" --strip-components=1
        (cd "$tree" && patch --batch --fuzz=0 -p1 -i "${patch_file[hyprgrass]}") || die 'hyprgrass patch failed'
        printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record prepared plugin'
    fi
    log 'Build hyprgrass'
    run build_env env DESTDIR="$WORKDIR/plugin-sdk" cmake --install "$WORKDIR/build/hyprland"
    run mkdir -p "$pc"
    run sed "s|prefix=/usr/include/$ARCH|prefix=$WORKDIR/plugin-sdk/usr/include/$ARCH|" \
        "$WORKDIR/build/hyprland/hyprland.pc" > "$pc/hyprland.pc"
    local -a opts=()
    [ ! -f "$folder/meson-private/coredata.dat" ] || opts+=(--reconfigure)
    run build_env env PKG_CONFIG_PATH="$pc:$LIBDIR/pkgconfig" CXXFLAGS="-I$SYSROOT/usr/include" \
        meson setup "${opts[@]}" "$folder" "$tree" --prefix=/usr \
        "--libdir=lib/$ARCH/hyprland/plugins" --wrap-mode=nodownload -Dtests=disabled
    run build_env env PKG_CONFIG_PATH="$pc:$LIBDIR/pkgconfig" CXXFLAGS="-I$SYSROOT/usr/include" \
        meson compile -C "$folder" -j "$JOBS"
}
package_deb() {
    local name="$1" tree="$WORKDIR/src/${directory[$1]}" dep soname
    local produced="$WORKDIR/src/${runtime[$name]}_${version[$name]}+anland5_arm64.deb"
    log "Package $name"
    : > "$tree/debian/shlibs.local" || die 'cannot write shlibs.local'
    for dep in hyprutils hyprlang hyprgraphics aquamarine; do
        case "$dep" in hyprutils) soname=12 ;; hyprlang) soname=2 ;; hyprgraphics) soname=4 ;; aquamarine) soname=14 ;; esac
        printf 'lib%s %s %s (= %s+anland5)\n' "$dep" "$soname" "${runtime[$dep]}" "${version[$dep]}" \
            >> "$tree/debian/shlibs.local" || die 'cannot write shlibs.local'
    done
    cat > "$tree/debian/rules" <<EOF
#!/usr/bin/make -f
include /usr/share/dpkg/architecture.mk
export DH_OPTIONS = -p${runtime[$name]}
%:
	dh \$@ -p${runtime[$name]} --buildsystem=cmake --builddirectory=$WORKDIR/build/$name
override_dh_auto_configure override_dh_auto_build override_dh_auto_test override_dh_dwz override_dh_missing:
	:
override_dh_strip:
	dh_strip --no-automatic-dbgsym
override_dh_shlibdeps:
	dh_shlibdeps -l$LIBDIR
override_dh_auto_install:
	DESTDIR=\$(CURDIR)/debian/tmp cmake --install $WORKDIR/build/$name
EOF
    [ $? -eq 0 ] || die 'cannot write Debian rules'
    if [ "$name" = hyprland ]; then
        cat >> "$tree/debian/rules" <<EOF
	install -m755 $SCRIPT_DIR/startup.sh debian/tmp/usr/bin/hyprland-anland
	DESTDIR=\$(CURDIR)/debian/tmp meson install -C $WORKDIR/build/hyprgrass --no-rebuild
	rm -f debian/tmp/usr/lib/$ARCH/hyprland/plugins/libwftouch.a
override_dh_install:
	dh_install
	install -d debian/hyprland/usr/share/doc/hyprland/hyprgrass
	install -m644 $WORKDIR/src/hyprgrass/LICENSE debian/hyprland/usr/share/doc/hyprland/hyprgrass/hyprgrass-LICENSE
	install -m644 $WORKDIR/src/hyprgrass/LICENSE.aosp debian/hyprland/usr/share/doc/hyprland/hyprgrass/hyprgrass-LICENSE.aosp
	install -m644 $WORKDIR/src/hyprgrass/subprojects/wf-touch/LICENSE debian/hyprland/usr/share/doc/hyprland/hyprgrass/wf-touch-LICENSE
override_dh_gencontrol:
	. debian/tmp/usr/lib/\${DEB_HOST_MULTIARCH}/hyprland/debian-abi-helper && dh_gencontrol -- "-Vhyprland:Provides=\$\${HYPRLAND_ABI}, \$\${HYPRLAND_API}"
EOF
        [ $? -eq 0 ] || die 'cannot append Debian rules'
    fi
    run chmod +x "$tree/debian/rules"
    run rm -f "$produced"
    (cd "$tree" && build_env fakeroot debian/rules binary) || die "package: $name"
    run cp -p "$produced" "$ARTIFACTS/"
}
build_xwayland() {
    local out="$WORKDIR/xwayland" tree patch file pinned identity
    patch="$(find_patch xwayland "${XWAYLAND_PATCH:-}")" || die 'cannot select Xwayland patch'
    verify_patch xwayland "$patch"
    pinned=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["xwayland"]["version"])' \
        "$SCRIPT_DIR/dependencies.lock") || die 'cannot read Xwayland version'
    identity=$(source_identity xwayland "$patch") || die 'source identity: xwayland'
    run mkdir -p "$out"
    tree=$(find "$out" -mindepth 1 -maxdepth 1 -type d -name 'xwayland-*' -print -quit)
    if [ -n "$tree" ]; then
        reuse_source "$tree" "$identity"
    else
        log 'Fetch Xwayland (locked Debian source)'
        (cd "$out" && apt-get source --only-source "xwayland=$pinned") || die 'apt source: locked xwayland (enable deb-src)'
        python3 - "$SCRIPT_DIR/dependencies.lock" "$out" <<'PY'
import hashlib, json, pathlib, sys
lock = json.loads(pathlib.Path(sys.argv[1]).read_text())
for name, expected in lock['xwayland']['files'].items():
    p = pathlib.Path(sys.argv[2]) / name
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
        raise SystemExit('Xwayland source checksum mismatch: ' + name)
PY
        [ $? -eq 0 ] || die 'Xwayland source checksum failed'
        tree=$(find "$out" -mindepth 1 -maxdepth 1 -type d -name 'xwayland-*' -print -quit)
        [ -n "$tree" ] || die 'Xwayland source tree not found'
        (cd "$tree" && patch --batch --fuzz=0 -p1 --forward -i "$patch") || die 'Xwayland patch failed'
        printf '%s\n' "$identity" > "$tree/.anland-source-identity" || die 'cannot record prepared Xwayland'
    fi
    log 'Build Xwayland .deb'
    run rm -f "$out"/xwayland_*.deb
    (cd "$tree" && env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u CMAKE_PREFIX_PATH \
        -u LD_LIBRARY_PATH -u DESTDIR DEB_BUILD_OPTIONS="nocheck nodwz parallel=$JOBS" \
        dpkg-buildpackage -b -uc -us) || die 'package: xwayland'
    local -a debs=("$out"/xwayland_*.deb)
    [ -f "${debs[0]}" ] || die 'no Xwayland package produced'
    for file in "${debs[@]}"; do
        run cp -p "$file" "$ARTIFACTS/"
        packages+=("${file##*/}")
    done
}
main() {
    [ $# -eq 0 ] || die 'use environment variables, not arguments'
    [ "$(dpkg --print-architecture)" = arm64 ] || die 'requires Debian arm64'
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
    run mkdir -p "$WORKDIR" "$ARTIFACTS"
    exec 8>"$WORKDIR/build.lock" || die 'cannot open build lock'
    flock -n 8 || die 'another build owns WORKDIR'
    exec 9>"$ARTIFACTS/.build.lock" || die 'cannot open artifact lock'
    flock -n 9 || die 'another build owns artifacts'
    fetch_sources
    local name file
    for name in "${PROJECTS[@]}"; do prepare_source "$name"; cmake_build "$name"; done
    build_hyprgrass
    for name in "${PROJECTS[@]}"; do package_deb "$name"; done
    build_xwayland
    (cd "$ARTIFACTS" && sha256sum "${packages[@]}" > SHA256SUMS) || die 'cannot write SHA256SUMS'
    if [ "${ANLAND_INSTALL:-0}" = 1 ]; then
        local -a debs=()
        for file in "${packages[@]}"; do debs+=("$ARTIFACTS/$file"); done
        run $SUDO dpkg -i "${debs[@]}"
    fi
    log "Done. Packages: $ARTIFACTS"
}
main "$@"