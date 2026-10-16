#!/usr/bin/env bash
# Fedora 44 aarch64: Niri/Smithay + satellite + patched Xwayland native RPMs.
# ANLAND_STAGE=check|prepare|build ANLAND_WITH_DEPS=1 JOBS=4 ANLAND_INSTALL=0
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# Fedora build/package functions are local to this WM recipe.
fedora_die() { printf 'fedora-build: %s\n' "$*" >&2; exit 1; }

fedora_run() { "$@" || fedora_die "failed: $*"; }

fedora_preflight() {
    local ID VERSION_ID
    source /etc/os-release || fedora_die 'cannot identify distribution'
    [[ $ID == fedora && $VERSION_ID == 44 && $(uname -m) == aarch64 ]] ||
        fedora_die 'requires native Fedora 44 aarch64'
    [[ $(id -u) != 0 ]] || fedora_die 'compile as an ordinary user'
    JOBS=${JOBS:-4}
    [[ $JOBS =~ ^[1-9][0-9]*$ ]] || fedora_die 'JOBS must be a positive integer'
    local flag
    for flag in ANLAND_INSTALL ANLAND_WITH_DEPS ANLAND_OFFLINE; do
        printf -v "$flag" '%s' "${!flag:-0}"
        [[ ${!flag} =~ ^[01]$ ]] || fedora_die "$flag must be 0 or 1"
    done
    ANLAND_STAGE=${ANLAND_STAGE:-build}
    case $ANLAND_STAGE in check|prepare|build) ;; *) fedora_die 'ANLAND_STAGE must be check, prepare or build' ;; esac
    [[ $ANLAND_OFFLINE != 1 || $ANLAND_WITH_DEPS != 1 ]] || fedora_die 'offline dependency installation is not supported'
    [[ $ANLAND_STAGE == build || $ANLAND_INSTALL == 0 ]] || fedora_die 'installation requires the build stage'
}

fedora_initialize() {
    fedora_preflight
    ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd -P) || fedora_die 'repository root'
    WORKDIR=$(realpath -m -- "${WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-$1-fedora44}") || fedora_die 'cache path'
    ARTIFACTS_DIR=$(realpath -m -- "${ARTIFACTS_DIR:-${ARTIFACTS:-$SCRIPT_DIR/artifacts}}") || fedora_die 'artifact path'
    [[ $WORKDIR != / && $WORKDIR != "$HOME" && $WORKDIR != "$ROOT" && $WORKDIR != "$ROOT/"* ]] || fedora_die 'WORKDIR must be a separate cache'
    [[ $ARTIFACTS_DIR != / && $ARTIFACTS_DIR != "$HOME" && $ARTIFACTS_DIR != "$ROOT" && $ARTIFACTS_DIR != "$WORKDIR" ]] || fedora_die 'unsafe artifact directory'
    [[ ! -L $ARTIFACTS_DIR ]] || fedora_die 'artifacts must not be a symlink'
    fedora_run mkdir -p "$WORKDIR" "$ARTIFACTS_DIR"
    exec 7>"$WORKDIR/fedora-build.lock" || fedora_die 'cache lock'
    flock -n 7 || fedora_die 'cache already in use'
    exec 6>"$ARTIFACTS_DIR/.fedora-build.lock" || fedora_die 'artifact lock'
    flock -n 6 || fedora_die 'artifacts already in use'
    export LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
    export CCACHE_DIR="$WORKDIR/ccache" CCACHE_BASEDIR="$WORKDIR"
    # Do not inherit another WM's staged libraries or SDK.
    unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH LD_LIBRARY_PATH DESTDIR
    FEDORA_INPUT_ID=$(python3 - "$ROOT" "$SCRIPT_DIR" <<'PY'
import hashlib, pathlib, sys
root, recipe = map(pathlib.Path, sys.argv[1:])
h = hashlib.sha256()
paths = [recipe/'build.sh']
for folder in (recipe, recipe.parent/'anland_backend', root/'libdisplay_producer', root/'common'):
    paths += [p for p in folder.rglob('*') if p.is_file() and 'artifacts' not in p.parts]
for p in sorted(set(paths)):
    h.update(str(p.relative_to(root)).encode()+b'\0'+p.read_bytes())
print(h.hexdigest())
PY
    ) || fedora_die 'input fingerprint'
    packages=()
}

fedora_dependencies() {
    [[ $ANLAND_WITH_DEPS == 1 && $ANLAND_STAGE != check ]] || return 0
    # Preserve Mesa/package holds. Do not enable COPR or change global DNF config.
    fedora_run sudo dnf --setopt=install_weak_deps=False install -y \
        gcc gcc-c++ make cmake meson ninja-build pkgconf-pkg-config ccache python3 \
        git-core curl ca-certificates patch tar xz unzip zip file binutils \
        rpm-build rpmdevtools dnf5-plugins cpio util-linux findutils diffutils "$@"
}

fedora_download() {
    local file=$1 sha=$2 url=$3
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || fedora_die "invalid checksum: $file"
    if printf '%s  %s\n' "$sha" "$file" | sha256sum -c --status - 2>/dev/null; then return; fi
    [[ $ANLAND_OFFLINE == 0 ]] || fedora_die "offline source absent or corrupt: $file"
    fedora_run mkdir -p "$(dirname -- "$file")"
    fedora_run curl -fL --retry 3 --connect-timeout 30 -o "$file.part" "$url"
    printf '%s  %s\n' "$sha" "$file.part" | sha256sum -c - || fedora_die "source checksum: $file"
    fedora_run mv -- "$file.part" "$file"
}

fedora_reuse() {
    [[ -d $1 ]] || return 1
    [[ -f $1/.anland-source-identity && $(cat "$1/.anland-source-identity") == "$FEDORA_INPUT_ID" ]] ||
        fedora_die "stale/unmanaged source preserved: $1; refresh it explicitly"
}

fedora_seal() { printf '%s\n' "$FEDORA_INPUT_ID" > "$1/.anland-source-identity" || fedora_die 'cannot record source identity'; }

fedora_patch() {
    printf '%s  %s\n' "$2" "$3" | sha256sum -c --status - || fedora_die "patch checksum: $3"
    fedora_run patch --batch --forward --fuzz=0 -p1 -d "$1" -i "$3"
}

fedora_stage_rpm() {
    local name=$1 version=$2 license=$3 stage=$4 requires=${5:-} top spec marker file found=0
    [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9+._-]*$ && $version =~ ^[a-zA-Z0-9][a-zA-Z0-9+._~]*$ ]] || fedora_die 'unsafe RPM identity'
    top="$WORKDIR/rpm/$name"
    fedora_run mkdir -p "$top"/{SPECS,SOURCES,BUILD,BUILDROOT,RPMS,SRPMS}
    fedora_run tar -cJf "$top/SOURCES/runtime.tar.xz" -C "$stage" .
    python3 - "$stage" "$top/SOURCES/files.list" <<'PY' || fedora_die 'RPM file list'
from pathlib import Path
import sys
stage, output = map(Path, sys.argv[1:])
standard = {'/', '/etc', '/etc/xdg', '/usr', '/usr/bin', '/usr/lib', '/usr/lib64', '/usr/share', '/usr/share/doc', '/usr/share/licenses', '/usr/share/applications', '/usr/share/wayland-sessions', '/usr/share/dbus-1', '/usr/share/dbus-1/services', '/usr/lib/systemd', '/usr/lib/systemd/user', '/usr/share/xdg-desktop-portal', '/usr/share/xdg-desktop-portal/portals'}
lines = []
for p in sorted(stage.rglob('*')):
    path = '/' + p.relative_to(stage).as_posix()
    if any(c in path for c in '\n\r%"'):
        raise SystemExit('unsafe RPM path: '+path)
    if p.is_symlink() or p.is_file():
        tag = '%config(noreplace) ' if path.startswith('/etc/') and not p.is_symlink() else ''
        if path.startswith('/usr/share/licenses/') and not p.is_symlink(): tag = '%license '
        lines.append(tag+'"'+path+'"')
    elif p.is_dir() and path not in standard:
        lines.append('%dir "'+path+'"')
if not lines: raise SystemExit('empty runtime stage')
output.write_text('\n'.join(lines)+'\n')
PY
    spec="$top/SPECS/$name.spec"
    # Package an already compiled DESTDIR. No binary conversion from .deb/pacman.
    cat > "$spec" <<EOF
%global debug_package %{nil}
%global _build_id_links none
%global __strip /usr/bin/true
%global __provides_exclude_from ^/usr/lib(64)?/(denial-anland|mango-anland|niri-anland|hyprland-anland)/.*$
Name: $name
Version: $version
Release: 1.anland%{?dist}
Summary: $name with the Anland v5 backend
License: $license
URL: https://github.com/sjszero/anland
Source0: runtime.tar.xz
Source1: files.list
ExclusiveArch: aarch64
BuildRequires: tar, xz, coreutils
EOF
    [[ -z $requires ]] || printf 'Requires: %s\n' "$requires" >> "$spec" || fedora_die 'RPM requirements'
    # Private SONAME dependencies are satisfied by this same package. Do not
    # export them globally, or require nonexistent Fedora packages for them.
    local sonames
    sonames=$(find "$stage" -type f -name '*.so*' -exec readelf -d {} \; 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' | sort -u | sed 's/[.]/\\./g' | paste -sd '|') || fedora_die 'private SONAME list'
    [[ -z $sonames ]] || printf '%%global __requires_exclude ^(%s)(\\(.*\\))?$\n' "$sonames" >> "$spec" || fedora_die 'private RPM dependencies'
    cat >> "$spec" <<'EOF'
%description
Native Fedora 44 runtime built from locked sources. Installing this package
does not enable, stop or restart graphical sessions or desktop services.
%prep
%build
%install
mkdir -p %{buildroot}
tar -xJf %{SOURCE0} -C %{buildroot}
%files -f %{SOURCE1}
%defattr(-,root,root,-)
EOF
    marker=$(mktemp "$top/build-start.XXXXXX") || fedora_die 'RPM marker'
    fedora_run rpmbuild -bb --define "_topdir $top" --define "_smp_build_ncpus $JOBS" "$spec"
    while IFS= read -r file; do
        [[ $(rpm -qp --qf '%{NAME}|%{VERSION}|%{ARCH}' "$file") == "$name|$version|aarch64" ]] || fedora_die "RPM identity: $file"
        fedora_publish_rpm "$file"
        found=$((found + 1))
    done < <(find "$top/RPMS" -type f -name '*.rpm' ! -name '*debug*' -newer "$marker")
    [[ $found == 1 ]] || fedora_die "expected one current RPM: $name"
    fedora_run rm -f -- "$marker"
}

fedora_publish_rpm() {
    local file=$1 destination="$ARTIFACTS_DIR/${1##*/}" architecture
    architecture=$(rpm -qp --qf '%{ARCH}' "$file") || fedora_die 'RPM architecture'
    [[ $architecture == aarch64 || $architecture == noarch ]] || fedora_die "wrong architecture: $file"
    fedora_run rpm -K "$file"
    fedora_run rpm -qpl "$file" >/dev/null
    [[ ! -e $destination.sig && ! -L $destination.sig ]] || cmp -s "$file" "$destination" || fedora_die "existing signature preserved: $destination.sig"
    fedora_run cp -p -- "$file" "$destination"
    packages+=("$destination")
}

fedora_srpm_prepare() {
    # $1=name, $2=lock JSON, $3=patch, $4=overlay directory or empty,
    # $5=overlay destination relative to upstream source root, $6=Meson options.
    local name=$1 lock=$2 patch=$3 overlay=${4:-} destination=${5:-} options=${6:-}
    local version release archive sha url expected_patch top spec
    IFS=$'\t' read -r version release archive sha url expected_patch < <(python3 - "$lock" <<'PY'
import json, sys
v=json.load(open(sys.argv[1])); print(*(v[k] for k in ('version','release','archive','sha256','url','patch_sha256')),sep='\t')
PY
    )
    [[ -n $version && -n $url && $archive == "${archive##*/}" ]] || fedora_die "invalid SRPM lock: $lock"
    fedora_download "$WORKDIR/downloads/$archive" "$sha" "$url"
    printf '%s  %s\n' "$expected_patch" "$patch" | sha256sum -c --status - || fedora_die "SRPM patch checksum: $patch"
    top="$WORKDIR/srpm-$name"
    FEDORA_SRPM_TOP=$top
    FEDORA_SRPM_SPEC="$top/SPECS/$name.spec"
    if fedora_reuse "$top"; then return; fi
    fedora_run mkdir -p "$top"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
    # SRPM headers retain the build host's ARCH (e.g. i686), not "src".
    [[ $(rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}|%{SOURCEPACKAGE}' "$WORKDIR/downloads/$archive") == "$name|$version|$release|1" ]] || fedora_die 'SRPM identity differs from lock'
    fedora_run rpm -K "$WORKDIR/downloads/$archive"
    fedora_run rpm -ivh --define "_topdir $top" "$WORKDIR/downloads/$archive"
    spec=$FEDORA_SRPM_SPEC
    fedora_run cp "$patch" "$top/SOURCES/anland.patch"
    if [[ -n $overlay ]]; then fedora_run tar -chf "$top/SOURCES/anland-overlay.tar" -C "$overlay" .; fi
    python3 - "$spec" "$overlay" "$destination" "$options" <<'PY' || fedora_die 'unsupported Fedora SRPM recipe'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); overlay,destination,options=sys.argv[2:]
s=p.read_text()
if len(re.findall(r'^%autosetup[^\n]*$',s,re.M)) != 1: raise SystemExit('expected one autosetup')
used=[int(n or 0) for n in re.findall(r'^Source(\d*)\s*:',s,re.M)]
n=max(used,default=0)+1
sources=f'Source{n}: anland.patch\n'
prep=f'\npatch --batch --forward --fuzz=0 -p1 < %{{SOURCE{n}}}'
if overlay:
    if not re.fullmatch(r'[a-zA-Z0-9_./-]+',destination) or '..' in destination.split('/'):
        raise SystemExit('invalid overlay path')
    sources+=f'Source{n+1}: anland-overlay.tar\n'
    prep+=f'\nmkdir -p {destination}\ntar xf %{{SOURCE{n+1}}} -C {destination}'
# Source tags belong to the package preamble, not to the tests description.
s=re.sub(r'^(%description(?:[^\n]*))$',lambda m:sources+'\n'+m[0],s,count=1,flags=re.M)
s=re.sub(r'^(%autosetup[^\n]*)$',lambda m:m[0]+prep,s,count=1,flags=re.M)
s=re.sub(r'^Release:[^\n]*$', 'Release: 1.anland%{?dist}',s,count=1,flags=re.M)
if options:
    if len(re.findall(r'^%meson(?:\s|$)',s,re.M)) != 1: raise SystemExit('expected one meson invocation')
    s=re.sub(r'^%meson(?=\s|$)',lambda m:'%meson '+options,s,count=1,flags=re.M)
p.write_text(s)
PY
    fedora_run rpmbuild -bp --nodeps --define "_topdir $top" "$spec"
    fedora_seal "$top"
}

fedora_srpm_build() {
    local top=$FEDORA_SRPM_TOP spec=$FEDORA_SRPM_SPEC marker file found=0
    if [[ $ANLAND_WITH_DEPS == 1 ]]; then
        fedora_run sudo dnf --setopt=install_weak_deps=False builddep -y "$spec"
    fi
    marker=$(mktemp "$top/build-start.XXXXXX") || fedora_die 'SRPM build marker'
    # Keep Xwayland/Mutter isolated from the other WM's private SDK.
    fedora_run env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR -u CMAKE_PREFIX_PATH \
        -u LD_LIBRARY_PATH -u DESTDIR -u CFLAGS -u CXXFLAGS -u LDFLAGS \
        rpmbuild -bb --define "_topdir $top" --define "_smp_build_ncpus $JOBS" "$spec"
    while IFS= read -r file; do fedora_publish_rpm "$file"; found=$((found + 1));
    done < <(find "$top/RPMS" -type f -name '*.rpm' ! -name '*debug*' ! -name '*-tests-*' -newer "$marker")
    [[ $found -gt 0 ]] || fedora_die 'no current SRPM build output'
    fedora_run rm -f -- "$marker"
}

fedora_xwayland() {
    # Every WM keeps its Xwayland inputs alongside its own distro recipe.
    fedora_srpm_prepare xorg-x11-server-Xwayland "$SCRIPT_DIR/xwayland.lock" "$SCRIPT_DIR/xwayland.patch"
    [[ $ANLAND_STAGE != build ]] || fedora_srpm_build
}

fedora_finish() {
    [[ ${#packages[@]} -gt 0 ]] || fedora_die 'empty Fedora package set'
    printf '%s\n' "${packages[@]##*/}" > "$WORKDIR/packages.list" || fedora_die 'package list'
    (cd "$ARTIFACTS_DIR" && sha256sum -- "${packages[@]##*/}" > "$WORKDIR/SHA256SUMS" && sha256sum -c "$WORKDIR/SHA256SUMS") || fedora_die 'package checksums'
    python3 - "$ROOT" "$FEDORA_INPUT_ID" "$WORKDIR/build-inputs.json" <<'PY' || fedora_die 'build record'
import json,subprocess,sys
root,identity,out=sys.argv[1:]
record={'distribution':'fedora44','architecture':'aarch64','input_sha256':identity,
 'anland_revision':subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip(),
 'graphical_test':False}
open(out,'w').write(json.dumps(record,indent=2)+'\n')
PY
    if [[ $ANLAND_INSTALL == 1 ]]; then
        # Scoped only to this requested transaction; never rewrite dnf.conf.
        fedora_run sudo dnf --setopt=excludepkgs= install -y "${packages[@]}"
    fi
    printf '\nFedora RPMs: %s\nNo desktop/session was started or restarted. Graphical validation NOT performed.\n' "$ARTIFACTS_DIR"
}

[[ $# == 0 ]] || fedora_die 'use environment variables, not arguments'
fedora_initialize niri
fedora_dependencies cargo rust clang-devel pipewire-devel libinput-devel systemd-devel \
    libseat-devel libdisplay-info-devel libglvnd-devel mesa-libgbm-devel libdrm-devel libxkbcommon-devel \
    wayland-devel wayland-protocols-devel pango-devel cairo-devel cairo-gobject-devel pixman-devel \
    fontconfig-devel libxcb-devel xcb-util-cursor-devel libX11-devel
if [[ $ANLAND_STAGE == check ]]; then
    printf 'FEDORA44_RECIPE_OK niri (no compilation or graphical test)\n'; exit 0
fi
fedora_run mkdir -p "$WORKDIR/src" "$WORKDIR/downloads"
export CARGO_HOME="$WORKDIR/cargo-home" CARGO_TARGET_DIR="$WORKDIR/cargo-target"
export ANLAND_NIRI_BRIDGE_BUILD="$WORKDIR/bridge"
python3 - "$SCRIPT_DIR/dependencies.lock" > "$WORKDIR/sources.tsv" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for name in ('niri','smithay','satellite'):
    e=v[name];print(name,e['directory'],e['archive'],e['sha256'],e['url'],v['patches'].get(name+'.patch','-'),sep='\t')
PY
[[ $? == 0 ]] || fedora_die 'source lock'
while IFS=$'\t' read -r name directory archive checksum url patchsha; do
    fedora_download "$WORKDIR/downloads/$archive" "$checksum" "$url"
    tree="$WORKDIR/src/$directory"
    if ! fedora_reuse "$tree"; then
        if [[ $archive == *.zip ]]; then fedora_run unzip -q "$WORKDIR/downloads/$archive" -d "$WORKDIR/src";
        else fedora_run tar -xf "$WORKDIR/downloads/$archive" -C "$WORKDIR/src"; fi
        [[ $patchsha == - ]] || fedora_patch "$tree" "$patchsha" "$SCRIPT_DIR/$name.patch"
        if [[ $name == niri ]]; then
            fedora_run mkdir -p "$tree/src/backend/anland"
            fedora_run cp -aL "$SCRIPT_DIR/niri/"*.rs "$tree/src/backend/anland/"
        fi
        fedora_seal "$tree"
    fi
done < "$WORKDIR/sources.tsv"
if [[ $ANLAND_STAGE == prepare ]]; then fedora_xwayland; printf 'FEDORA44_PREPARED niri\n'; exit 0; fi
niri="$WORKDIR/src/niri-26.04"; satellite="$WORKDIR/src/xwayland-satellite-0.8.3"
fetch=(--locked --target aarch64-unknown-linux-gnu)
[[ $ANLAND_OFFLINE == 0 ]] || fetch+=(--offline)
for tree in "$niri" "$satellite"; do (cd "$tree" && cargo fetch "${fetch[@]}") || fedora_die 'locked Cargo fetch'; done
fedora_run cmake -S "$ROOT/producers/niri/anland_backend" -B "$WORKDIR/bridge" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON '-DCMAKE_INSTALL_RPATH=$ORIGIN'
fedora_run cmake --build "$WORKDIR/bridge" --target anland_niri_bridge --parallel "$JOBS"
(cd "$niri" && RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-rpath,\$ORIGIN/../lib64/niri-anland" \
    cargo build --release --locked --offline --jobs "$JOBS") || fedora_die 'Niri build'
(cd "$satellite" && cargo build --release --locked --offline --features systemd --jobs "$JOBS") || fedora_die 'satellite build'
stage="$WORKDIR/runtime/niri"
fedora_run install -Dm755 "$CARGO_TARGET_DIR/release/niri" "$stage/usr/bin/niri-anland"
fedora_run install -Dm755 "$SCRIPT_DIR/startup.sh" "$stage/usr/bin/niri-anland-start"
fedora_run install -Dm755 "$WORKDIR/bridge/libanland_niri_bridge.so" "$stage/usr/lib64/niri-anland/libanland_niri_bridge.so"
fedora_run install -Dm755 "$WORKDIR/bridge/common/libdisplay_producer/libdisplay_producer.so" "$stage/usr/lib64/niri-anland/libdisplay_producer.so"
fedora_run install -Dm644 "$niri/resources/default-config.kdl" "$stage/usr/share/doc/niri-anland/default-config.kdl"
fedora_run install -Dm644 "$niri/LICENSE" "$stage/usr/share/licenses/niri-anland/LICENSE"
fedora_run install -Dm644 "$ROOT/LICENSE" "$stage/usr/share/licenses/niri-anland/anland-LICENSE"
for file in "$stage/usr/bin/niri-anland" "$stage/usr/lib64/niri-anland/"*.so; do
    linkage=$(env LD_LIBRARY_PATH="$stage/usr/lib64/niri-anland" ldd "$file") || fedora_die 'Niri ELF check'
    [[ $linkage != *'not found'* ]] || fedora_die "$linkage"
done
fedora_run env LD_LIBRARY_PATH="$stage/usr/lib64/niri-anland" "$stage/usr/bin/niri-anland" --version
fedora_stage_rpm niri-anland 26.4.0 'GPL-3.0-or-later' "$stage" \
    'bash, procps-ng, util-linux, dbus, xwayland-satellite >= 0.8.3, xorg-x11-server-Xwayland, xkeyboard-config'
stage="$WORKDIR/runtime/satellite"
fedora_run install -Dm755 "$CARGO_TARGET_DIR/release/xwayland-satellite" "$stage/usr/bin/xwayland-satellite"
fedora_run install -Dm644 "$satellite/LICENSE" "$stage/usr/share/licenses/xwayland-satellite/LICENSE"
fedora_stage_rpm xwayland-satellite 0.8.3 'MPL-2.0' "$stage" 'xorg-x11-server-Xwayland'
fedora_xwayland
fedora_finish