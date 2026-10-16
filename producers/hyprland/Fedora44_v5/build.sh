#!/usr/bin/env bash
# Fedora 44 aarch64: locked Lua5.4 Hyprland stack and Hyprgrass, private RPM.
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
fedora_initialize hyprland
fedora_dependencies pipewire-devel cairo-devel pango-devel libdrm-devel libxkbcommon-devel libuuid-devel \
    libglvnd-devel mesa-libgbm-devel libinput-devel libseat-devel libdisplay-info-devel systemd-devel \
    libxcb-devel xcb-util-wm-devel xcb-util-errors-devel libXcursor-devel libXcomposite-devel \
    libXfixes-devel libXrender-devel libX11-devel wayland-devel wayland-protocols-devel \
    libevdev-devel libei-devel lcms2-devel lua-devel muParser-devel pixman-devel re2-devel \
    tomlplusplus-devel openssl-devel udis86-devel hwdata-devel \
    glslang-devel glm-devel libjpeg-turbo-devel libwebp-devel file-devel libspng-devel \
    librsvg2-devel libjxl-devel libheif-devel libzip-devel patchelf pugixml-devel xxd
if [[ $ANLAND_STAGE == check ]]; then
    printf 'FEDORA44_RECIPE_OK hyprland (private Lua5.4 stack; no compilation)\n'; exit 0
fi
fedora_run mkdir -p "$WORKDIR/src" "$WORKDIR/downloads" "$WORKDIR/build"
python3 - "$SCRIPT_DIR/dependencies.lock" > "$WORKDIR/sources.tsv" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for name,e in v['sources'].items(): print(name,e['archive'],e['sha256'],e['url'],sep='\t')
for name in ('hyprgrass','wf-touch'):
    e=v['plugins'][name];print(name,e['archive'],e['sha256'],e['url'],sep='\t')
e=v['sources']['hyprland']['debian'];print('hyprland-debian',e['archive'],e['sha256'],e['url'],sep='\t')
PY
[[ $? == 0 ]] || fedora_die 'source lock'
while IFS=$'\t' read -r name archive checksum url; do
    fedora_download "$WORKDIR/downloads/$archive" "$checksum" "$url"
done < "$WORKDIR/sources.tsv"
# Source preparation is all-or-nothing with respect to the input identity.
# Failed preparation is preserved, not silently reset or marked current.
for name in hyprwayland-scanner hyprland-protocols hyprutils hyprlang hyprgraphics hyprwire hyprcursor glaze aquamarine hyprland hyprgrass wf-touch; do
    tree="$WORKDIR/src/$name"
    if fedora_reuse "$tree"; then continue; fi
    archive=$(awk -F '\t' -v n="$name" '$1==n {print $2}' "$WORKDIR/sources.tsv") || fedora_die 'source archive'
    fedora_run mkdir -p "$tree"
    fedora_run tar -xf "$WORKDIR/downloads/$archive" -C "$tree" --strip-components=1
    if [[ $name == hyprland ]]; then
        archive=$(awk -F '\t' '$1=="hyprland-debian" {print $2}' "$WORKDIR/sources.tsv") || fedora_die 'Debian compatibility archive'
        fedora_run tar -xf "$WORKDIR/downloads/$archive" -C "$tree"
        # Retain the same locked compiler/source fixes as the tested Lua5.4 stack.
        # They are version patches, not a second Debian build or binary conversion.
        while IFS= read -r patchname rest; do
            [[ -n $patchname && $patchname != \#* ]] || continue
            [[ $patchname != */* ]] || fedora_die 'unsafe upstream compatibility patch'
            fedora_run patch --batch --forward --fuzz=0 -p1 -d "$tree" -i "$tree/debian/patches/$patchname"
        done < "$tree/debian/patches/series"
    fi
    if [[ $name == aquamarine || $name == hyprland ]]; then
        fedora_run cp -aL "$SCRIPT_DIR/../anland_backend/$name/." "$tree/"
        if [[ $name == aquamarine ]]; then
            fedora_run mkdir -p "$tree/src/backend/anland/public"
            fedora_run cp -aL "$ROOT/common" "$ROOT/libdisplay_producer" "$tree/src/backend/anland/public/"
        fi
    fi
    if [[ $name == aquamarine || $name == hyprland || $name == hyprgrass ]]; then
        patchsha=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["patches"][sys.argv[2]+".patch"])' "$SCRIPT_DIR/dependencies.lock" "$name") || fedora_die 'patch lock'
        fedora_patch "$tree" "$patchsha" "$SCRIPT_DIR/$name.patch"
    fi
    fedora_seal "$tree"
done
if [[ ! -f $WORKDIR/src/hyprgrass/.anland-wf-touch ]]; then
    fedora_run mkdir -p "$WORKDIR/src/hyprgrass/subprojects/wf-touch"
    fedora_run cp -a "$WORKDIR/src/wf-touch/." "$WORKDIR/src/hyprgrass/subprojects/wf-touch/"
    printf '%s\n' "$FEDORA_INPUT_ID" > "$WORKDIR/src/hyprgrass/.anland-wf-touch" || fedora_die 'plugin source receipt'
fi
if [[ $ANLAND_STAGE == prepare ]]; then fedora_xwayland; printf 'FEDORA44_PREPARED hyprland\n'; exit 0; fi
PREFIX=/usr/lib64/hyprland-anland
STAGE="$WORKDIR/stage"
TOOLS="$WORKDIR/tools"
fedora_run mkdir -p "$STAGE" "$TOOLS"
export PATH="$TOOLS/bin:$STAGE$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$TOOLS/lib/pkgconfig:$TOOLS/share/pkgconfig:$STAGE$PREFIX/lib/pkgconfig:$STAGE$PREFIX/share/pkgconfig"
export CMAKE_PREFIX_PATH="$TOOLS:$STAGE$PREFIX" LD_LIBRARY_PATH="$STAGE$PREFIX/lib"
export GIT_COMMIT_HASH=39d7e209c79d451efab1b21151d5938289da838d GIT_TAG=v0.55.2
# Fedora's 0.4.2 scanner emits empty C++ VTables rejected by GCC 15.
# Build the locked fix as a host tool, outside both the runtime and SDK stages.
scanner_version=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sources"]["hyprwayland-scanner"]["version"])' "$SCRIPT_DIR/dependencies.lock") || fedora_die 'scanner source lock'
fedora_run cmake -S "$WORKDIR/src/hyprwayland-scanner" -B "$WORKDIR/build/hyprwayland-scanner" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLS" -DCMAKE_INSTALL_BINDIR=bin -DCMAKE_INSTALL_LIBDIR=lib
fedora_run cmake --build "$WORKDIR/build/hyprwayland-scanner" --parallel "$JOBS"
fedora_run cmake --install "$WORKDIR/build/hyprwayland-scanner"
[[ $(command -v hyprwayland-scanner) == "$TOOLS/bin/hyprwayland-scanner" ]] || fedora_die 'locked scanner is not first in PATH'
[[ $(hyprwayland-scanner --version) == "$scanner_version" ]] || fedora_die 'unexpected scanner version'
printf 'FEDORA44_BUILD_TOOL hyprwayland-scanner %s (%s)\n' "$scanner_version" "$TOOLS/bin/hyprwayland-scanner"
# The repacked Hyprland source omits this subproject; Fedora only has 0.4.0.
# Keep the locked XML build inputs private, not in the runtime RPM.
fedora_run cmake -S "$WORKDIR/src/hyprland-protocols" -B "$WORKDIR/build/hyprland-protocols" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$TOOLS" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_DATADIR=share
fedora_run cmake --build "$WORKDIR/build/hyprland-protocols" --parallel "$JOBS"
fedora_run cmake --install "$WORKDIR/build/hyprland-protocols"
fedora_run pkg-config --atleast-version=0.6.4 hyprland-protocols
[[ $(pkg-config --variable=pkgdatadir hyprland-protocols) -ef "$TOOLS/share/hyprland-protocols" ]] || fedora_die 'locked protocol data is not first in pkg-config'
printf 'FEDORA44_BUILD_DATA hyprland-protocols %s (%s)\n' "$(pkg-config --modversion hyprland-protocols)" "$TOOLS/share/hyprland-protocols"
stage_pc() {
    local file
    while IFS= read -r -d '' file; do fedora_run sed -i "s|=$PREFIX|=$STAGE$PREFIX|g" "$file";
    done < <(find "$STAGE$PREFIX" -name '*.pc' -print0)
}
for name in hyprutils hyprlang hyprgraphics hyprwire hyprcursor glaze aquamarine hyprland; do
    args=(-S "$WORKDIR/src/$name" -B "$WORKDIR/build/$name" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_INSTALL_INCLUDEDIR=include -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DBUILD_TESTING=OFF "-DCMAKE_INSTALL_RPATH=$PREFIX/lib" "-DCMAKE_BUILD_RPATH=$STAGE$PREFIX/lib")
    # Override a cached system-package location as well as the search prefix.
    if [[ $name == aquamarine || $name == hyprland ]]; then
        args+=("-Dhyprwayland-scanner_DIR=$TOOLS/lib/cmake/hyprwayland-scanner")
    fi
    [[ $name != glaze ]] || args+=(-Dglaze_BUILD_TESTS=OFF -Dglaze_BUILD_EXAMPLES=OFF)
    [[ $name != hyprland ]] || args+=(-DNO_HYPRPM=OFF -DBUILD_HYPRTESTER=OFF -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON)
    fedora_run cmake "${args[@]}"
    fedora_run cmake --build "$WORKDIR/build/$name" --parallel "$JOBS"
    fedora_run env DESTDIR="$STAGE" cmake --install "$WORKDIR/build/$name"
    stage_pc
done
setup=(); [[ ! -f $WORKDIR/build/hyprgrass/meson-private/coredata.dat ]] || setup+=(--reconfigure)
fedora_run meson setup "${setup[@]}" "$WORKDIR/build/hyprgrass" "$WORKDIR/src/hyprgrass" \
    --prefix="$PREFIX" --libdir=lib/hyprland/plugins --buildtype=release --wrap-mode=nodownload -Dtests=disabled
fedora_run meson compile -C "$WORKDIR/build/hyprgrass" -j "$JOBS"
package="$WORKDIR/runtime"
fedora_run mkdir -p "$package"
for name in hyprutils hyprlang hyprgraphics hyprwire hyprcursor glaze aquamarine hyprland; do
    fedora_run env DESTDIR="$package" cmake --install "$WORKDIR/build/$name"
done
fedora_run env DESTDIR="$package" meson install -C "$WORKDIR/build/hyprgrass" --no-rebuild
fedora_run rm -f -- "$package$PREFIX/lib/hyprland/plugins/libwftouch.a" "$package$PREFIX/lib/hyprland/plugins/libwf-touch.a"
fedora_run install -Dm755 "$SCRIPT_DIR/startup.sh" "$package/usr/bin/hyprland-anland"
for name in hyprctl hyprpm; do
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/usr/lib64/hyprland-anland/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\nexec /usr/lib64/hyprland-anland/bin/%s "$@"\n' "$name" > "$package/usr/bin/$name-anland" || fedora_die 'private tool wrapper'
    fedora_run chmod 755 "$package/usr/bin/$name-anland"
done
for name in hyprutils hyprlang hyprgraphics hyprwire hyprcursor glaze aquamarine hyprland hyprgrass wf-touch; do
    while IFS= read -r -d '' file; do fedora_run install -Dm644 "$file" "$package/usr/share/licenses/hyprland-anland/$name/${file##*/}";
    done < <(find "$WORKDIR/src/$name" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) -print0)
done
fedora_run install -Dm644 "$ROOT/LICENSE" "$package/usr/share/licenses/hyprland-anland/anland-LICENSE"
while IFS= read -r -d '' file; do
    [[ $(head -c4 "$file") == $'\x7fELF' ]] || continue
    fedora_run patchelf --set-rpath "$PREFIX/lib" "$file"
    linkage=$(env LD_LIBRARY_PATH="$package$PREFIX/lib" ldd "$file") || fedora_die 'Hyprland runtime linkage'
    [[ $linkage != *'not found'* ]] || fedora_die "$linkage"
done < <(find "$package$PREFIX" -type f -print0)
fedora_stage_rpm hyprland-anland 0.55.2 'BSD-3-Clause AND MIT AND GPL-3.0-or-later' "$package" \
    'bash, procps-ng, util-linux, dbus, xkeyboard-config, xorg-x11-server-Xwayland'
fedora_xwayland
fedora_finish