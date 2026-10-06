#!/usr/bin/env bash
# Debian 13 arm64: pinned Mango + wlroots/SceneFX, private libraries, .deb.
# Usage: ./build.sh [--with-deps|--sources-only|--check|--package-only|--install-only]
# WORKDIR (or MANGO_CACHE) selects the persistent cache; JOBS=2 by default.
# INSTALL=1 and MANGO_CONFIRM_INSTALL=1 authorize installation. Never starts a WM.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
ROOT=$(cd -- "$HERE/../../.." && pwd -P) || exit 1
BACKEND="$HERE/mango"
WORKDIR=${WORKDIR:-${MANGO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-mango}}
MODE=${1:-all}
INSTALL=${ANLAND_INSTALL:-${INSTALL:-0}}
export JOBS=${JOBS:-2} LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'mango-build: %s\n' "$*" >&2; exit 1; }
run() { "$@" || die "failed: $*"; }
[[ "$MODE" != --help && "$MODE" != -h ]] || { sed -n '2,5p' "$0"; exit 0; }
[[ $# -le 1 ]] || die 'only one build mode is accepted'
case "$MODE" in all|--with-deps|--sources-only|--check|--package-only|--install-only) ;; *) die "unsupported mode: $MODE" ;; esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ && "$INSTALL" =~ ^[01]$ ]] || die 'invalid JOBS or INSTALL'
[[ $(id -u) != 0 && $(dpkg --print-architecture) == arm64 ]] || die 'requires an unprivileged Debian arm64 user'
if [[ "$INSTALL" == 1 || "$MODE" == --install-only ]]; then
    [[ ${MANGO_CONFIRM_INSTALL:-0} == 1 ]] || die 'set MANGO_CONFIRM_INSTALL=1 to authorize installation'
fi
for tool in git curl sha256sum flock cmake meson ninja pkg-config python3 dpkg-deb dpkg-shlibdeps strip ldd; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ -f "$BACKEND/anland.c" && -f "$HERE/dependencies.lock" ]] || die 'missing backend or dependency lock'
[[ "$WORKDIR" == /* ]] || die 'WORKDIR must be absolute'
WORKDIR=$(realpath -m -- "$WORKDIR") || die 'cannot resolve WORKDIR'
[[ "$WORKDIR" != / && "$WORKDIR" != "$ROOT" && "$WORKDIR" != "$ROOT/"* && "$ROOT" != "$WORKDIR/"* ]] || die 'WORKDIR must be outside the repository'
for path in src git build deps-src deps-build depcache prefix common; do
    [[ ! -L "$WORKDIR/$path" ]] || die "symlink cache directory: $path"
done
PREFIX="$WORKDIR/prefix"
PACKAGES="$HERE/artifacts"
DEB="$PACKAGES/mango-anland_0.17.5+anland5_arm64.deb"
export PATH="$PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
run mkdir -p "$WORKDIR"
exec 9>"$WORKDIR/build.lock" || die 'cannot open cache lock'
flock -n 9 || die 'another Mango build or installation owns this cache'

# One small text lock, like Gamescope. Never evaluate its contents as shell code.
declare -a components=() dependencies=()
declare -A revision url checksum options
while read -r kind name pin source rest; do
    [[ -n "$kind" && "$kind" != \#* ]] || continue
    [[ "$name" =~ ^[a-z0-9-]+$ && -z ${url[$name]:-} && "$source" == https://* ]] || die 'invalid dependency row'
    url[$name]=$source
    case "$kind" in
        git)
            [[ "$pin" =~ ^[a-f0-9]{40}$ && "$rest" =~ ^[a-f0-9]{64}$ ]] || die 'invalid Git pin'
            components+=("$name"); revision[$name]=$pin
            printf '%s  %s\n' "$rest" "$HERE/$name.patch" | sha256sum -c - || die 'patch checksum mismatch' ;;
        tar)
            [[ "$pin" =~ ^[a-f0-9]{64}$ ]] || die 'invalid archive checksum'
            dependencies+=("$name"); checksum[$name]=$pin; options[$name]=$rest ;;
        *) die "unknown source kind: $kind" ;;
    esac
done < "$HERE/dependencies.lock"
[[ "${components[*]}" == 'mango wlroots scenefx' && ${#dependencies[@]} == 5 ]] || die 'incomplete source lock'

# Git owns cache edit detection; patch/overlay changes produce a new local baseline.
prepare_source() {
    local name=$1 tree="$WORKDIR/src/$1" objects="$WORKDIR/git/$1" key old seed
    [[ ! -L "$tree" && ! -L "$objects" && ! -L "$WORKDIR/build/$name" ]] || die 'symlink source cache'
    key=$({ sha256sum "$HERE/$name.patch" || exit 1; printf '%s\n' "${revision[$name]}";
        if [[ "$name" == mango ]]; then sha256sum "$BACKEND/"*.[ch] "$HERE/startup.sh" || exit 1; fi; } | cut -d' ' -f1 | sha256sum) || die 'source fingerprint failed'
    if [[ ! -d "$objects" ]]; then run git init -q --bare "$objects"; fi
    if ! git --git-dir="$objects" cat-file -e "${revision[$name]}^{commit}" 2>/dev/null; then
        seed="$ROOT/../$name-anland5"
        if [[ -d "$seed/.git" ]]; then run git --git-dir="$objects" fetch -q "$seed" "${revision[$name]}";
        else run git --git-dir="$objects" fetch -q --depth=1 "${url[$name]}" "${revision[$name]}"; fi
    fi
    if [[ ! -d "$tree" ]]; then
        run mkdir -p "$tree"
        run git -C "$tree" init -q
        run touch "$tree/.git/anland-managed"
    fi
    [[ ! -L "$tree/.git" && -f "$tree/.git/anland-managed" ]] || die "unmanaged source: $tree"
    old=$(git -C "$tree" status --porcelain --untracked-files=all --ignored) || die 'source status failed'
    [[ -z "$old" ]] || die "edited source cache (preserved): $tree"
    if [[ -f "$tree/.git/anland-inputs" && $(cat "$tree/.git/anland-inputs") == "$key" ]]; then return; fi
    run git -C "$tree" fetch -q --update-shallow "$objects" "${revision[$name]}"
    run git -C "$tree" reset -q --hard "${revision[$name]}"
    run git -C "$tree" apply --whitespace=nowarn "$HERE/$name.patch"
    if [[ "$name" == mango ]]; then
        run mkdir -p "$tree/anland_backend"
        run cp "$BACKEND/"*.[ch] "$tree/anland_backend/"
        run install -m755 "$HERE/startup.sh" "$tree/scripts/mango-anland"
    fi
    run git -C "$tree" add -f .
    run git -C "$tree" -c user.name=Anland -c user.email=build@localhost commit -qm 'Anland patch and backend overlay'
    printf '%s\n' "$key" > "$tree/.git/anland-inputs" || die 'cannot record source inputs'
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
        if [[ ! -f "$archive" ]]; then
            run curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 -o "$archive.part" "${url[$name]}"
            printf '%s  %s\n' "${checksum[$name]}" "$archive.part" | sha256sum -c - || die 'download checksum mismatch'
            run mv "$archive.part" "$archive"
        fi
        printf '%s  %s\n' "${checksum[$name]}" "$archive" | sha256sum -c - || die 'cached archive checksum mismatch'
    done
    for name in "${dependencies[@]}"; do
        archive="$WORKDIR/depcache/${url[$name]##*/}"; tree="$WORKDIR/deps-src/$name"
        [[ ! -L "$tree" && ! -L "$WORKDIR/deps-build/$name" ]] || die "symlink dependency cache"
        if [[ ! -d "$tree" ]]; then
            # Python data filter rejects archive traversal and unsafe link targets.
            run python3 - "$archive" "$tree" <<'PY'
import pathlib, sys, tarfile
archive,tree=map(pathlib.Path,sys.argv[1:]); stage=tree.with_suffix('.unpack'); stage.mkdir()
with tarfile.open(archive) as tar: tar.extractall(stage,filter='data')
entries=list(stage.iterdir())
if len(entries)!=1 or not entries[0].is_dir(): raise SystemExit('unexpected archive root')
entries[0].rename(tree); stage.rmdir()
PY
            printf '%s\n' "${checksum[$name]}" > "$tree/.anland-source-sha256" || die 'cannot record dependency revision'
        fi
        [[ ! -L "$tree" && $(cat "$tree/.anland-source-sha256") == "${checksum[$name]}" ]] || die "dependency cache mismatch: $name"
        local -a flags=(); read -r -a flags <<< "${options[$name]}"
        meson_build "$tree" "$WORKDIR/deps-build/$name" "${flags[@]}"
    done
}
input_hash() {
    { sha256sum "$HERE/build.sh" "$HERE/startup.sh" "$HERE/dependencies.lock" "$HERE/"*.patch "$BACKEND/"*.[ch] || exit 1;
      find "$ROOT/libdisplay_producer" "$ROOT/common" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum || exit 1;
      sha256sum "$ROOT/CMakeLists.txt" || exit 1; } | cut -d' ' -f1 | sha256sum
}
package_deb() {
    local stage private file depends
    [[ -f "$WORKDIR/build.inputs" && $(cat "$WORKDIR/build.inputs") == "$(input_hash)" ]] || die 'inputs changed; rebuild before packaging'
    stage=$(mktemp -d "$WORKDIR/package.XXXXXX") || die 'cannot create package stage'
    private="$stage/usr/lib/mango-anland"
    run mkdir -p "$private/bin" "$private/lib" "$stage/etc/mango-anland" "$stage/usr/bin" "$stage/DEBIAN" "$stage/usr/share/doc/mango-anland" "$PACKAGES"
    run cp "$PREFIX/bin/mango" "$PREFIX/bin/mmsg" "$HERE/startup.sh" "$private/bin/"
    run mv "$private/bin/startup.sh" "$private/bin/mango-anland"
    for file in "$PREFIX/lib/"*.so*; do
        if [[ -L "$file" ]]; then
            [[ $(readlink "$file") != /* && $(realpath "$file") == "$PREFIX/lib/"* ]] || die "unsafe library link: $file"
        fi
        run cp -a "$file" "$private/lib/"
    done
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
    done
    run ln -s ../lib/mango-anland/bin/mango-anland "$stage/usr/bin/mango-anland"
    run ln -s mango-anland "$stage/usr/bin/mango-anland-start"
    run cp "$HERE/dependencies.lock" "$stage/usr/share/doc/mango-anland/"
    find "$WORKDIR/src" "$WORKDIR/deps-src" -mindepth 2 -maxdepth 2 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'COPYRIGHT*' \) -exec cat {} + > "$stage/usr/share/doc/mango-anland/copyright" || die 'license collection failed'
    [[ -s "$stage/usr/share/doc/mango-anland/copyright" ]] || die "missing source licenses"
    run cat "$ROOT/LICENSE" >> "$stage/usr/share/doc/mango-anland/copyright"
    local -a elfs=() shlibargs=()
    while IFS= read -r -d '' file; do
        [[ $(head -c4 "$file") == $'\x7fELF' ]] || continue
        run strip --strip-unneeded "$file"
        elfs+=("$file"); shlibargs+=("-e$file")
        run env LD_LIBRARY_PATH="$private/lib" ldd "$file" > "$stage/linkage"
        if grep -Fq 'not found' "$stage/linkage"; then die "invalid runtime linkage: $file"; fi
        if grep -Fq "$PREFIX/" "$stage/linkage"; then die "cache runtime linkage: $file"; fi
    done < <(find "$private" -type f -print0)
    [[ ${#elfs[@]} -gt 0 ]] || die 'no runtime ELFs'
    run mkdir -p "$stage/metadata/debian"
    printf 'Source: mango-anland\nSection: x11\nPriority: optional\nMaintainer: Anland <build@localhost>\n\nPackage: mango-anland\nArchitecture: arm64\nDescription: Mango Anland compositor\n' > "$stage/metadata/debian/control"
    depends=$(cd "$stage/metadata" && dpkg-shlibdeps --ignore-missing-info -O "-l$private/lib" "${shlibargs[@]}") || die 'dependency inference failed'
    depends=${depends#shlibs:Depends=}
    [[ -n "$depends" && "$depends" != *$'\n'* ]] || die 'invalid package dependencies'
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
    printf '/etc/mango-anland/config.conf\n' > "$stage/DEBIAN/conffiles"
    run rm -r "$stage/metadata" "$stage/linkage"
    run find "$stage" -type d -exec chmod 755 {} +
    run find "$stage" -type f -exec chmod 644 {} +
    run chmod 755 "$private/bin/"* "$stage/usr/bin/mango" "$stage/usr/bin/mmsg"
    run dpkg-deb --root-owner-group -Zxz --build "$stage" "$DEB.part"
    run dpkg-deb --info "$DEB.part"
    run mv "$DEB.part" "$DEB"
    (cd "$PACKAGES" && sha256sum "${DEB##*/}" > SHA256SUMS && sha256sum -c SHA256SUMS) || die 'package checksum failed'
    run rm -r "$stage"
    log "MANGO_DEB_OK $DEB"
}
check_install_paths() {
    local target path owner list
    for target in /usr/bin/mango /usr/bin/mmsg /usr/bin/mango-anland /usr/bin/mango-anland-start /usr/lib/mango-anland /etc/mango-anland; do
        if [[ -e "$target" || -L "$target" ]]; then
            owner=$(dpkg-query -S "$target" 2>/dev/null) || die "unmanaged install target: $target"
            [[ "$owner" == "mango-anland: $target" ]] || die "foreign install target: $target"
            [[ ! -L "$target" || "$target" == /usr/bin/* ]] || die "symlink install directory: $target"
        fi
        if [[ -d "$target" && ! -L "$target" ]]; then
            list=$(mktemp "$WORKDIR/install-paths.XXXXXX") || die 'cannot inspect installation paths'
            run find "$target" -mindepth 1 -print0 > "$list"
            while IFS= read -r -d '' path; do
                owner=$(dpkg-query -S "$path" 2>/dev/null) || die "unmanaged install target: $path"
                [[ "$owner" == "mango-anland: $path" ]] || die "foreign install target: $path"
            done < "$list"
            run rm "$list"
        fi
    done
}
install_package() {
    [[ ${MANGO_CONFIRM_INSTALL:-0} == 1 ]] || die 'installation not authorized'
    (cd "$PACKAGES" && sha256sum -c SHA256SUMS) || die 'package checksum failed'
    [[ $(dpkg-deb -f "$DEB" Package) == mango-anland && $(dpkg-deb -f "$DEB" Architecture) == arm64 ]] || die 'wrong package'
    check_install_paths
    local simulation
    simulation=$(sudo -n apt-get -s --no-remove install "$DEB") || die 'installation simulation failed'
    printf '%s\n' "$simulation"
    printf '%s\n' "$simulation" | awk '$1=="Remv" || ($1=="Inst" && $2!="mango-anland") {bad=1} END {exit bad}' || die 'installation would change other packages'
    run sudo -n dpkg -i "$DEB"
}

# Build -> package -> optional installation. Startup always stays separate.
if [[ "$MODE" == --install-only ]]; then install_package; exit 0; fi
if [[ "$MODE" == --with-deps ]]; then bootstrap; fi
for name in "${components[@]}"; do prepare_source "$name"; done
[[ "$MODE" != --sources-only ]] || { log 'MANGO_SOURCES_OK'; exit 0; }
for dependency in 'libpipewire-0.3' 'wayland-server >= 1.24.0' 'wayland-client >= 1.24.0' 'libdrm >= 2.4.129' 'wayland-protocols >= 1.47' 'xkbcommon >= 1.8.0' 'pixman-1 >= 0.46.0'; do
    pkg-config --exists "$dependency" || die "missing $dependency (use --with-deps or install development packages)"
done
[[ "$MODE" != --check ]] || { log 'MANGO_PREFLIGHT_OK'; exit 0; }
if [[ "$MODE" != --package-only ]]; then
    run cmake -S "$ROOT" -B "$WORKDIR/common" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
    run cmake --build "$WORKDIR/common" --target display_producer --parallel "$JOBS"
    run cmake --install "$WORKDIR/common/libdisplay_producer"
    meson_build "$WORKDIR/src/wlroots" "$WORKDIR/build/wlroots" -Dexamples=false -Dbackends=drm,libinput -Drenderers=gles2 -Dallocators=gbm -Dsession=enabled -Dlibliftoff=disabled -Dxwayland=enabled -Dcolor-management=disabled
    meson_build "$WORKDIR/src/scenefx" "$WORKDIR/build/scenefx" -Dexamples=false -Dcolor-management=disabled
    meson_build "$WORKDIR/src/mango" "$WORKDIR/build/mango" --sysconfdir="$PREFIX/etc" -Danland=enabled -Dxwayland=enabled
    run "$PREFIX/bin/mango" -v
    input_hash > "$WORKDIR/build.inputs.part" || die 'cannot record build inputs'
    run mv "$WORKDIR/build.inputs.part" "$WORKDIR/build.inputs"
fi
package_deb
if [[ "$INSTALL" == 1 ]]; then install_package; fi
log "Build finished (INSTALL=$INSTALL). Packages: $PACKAGES"
