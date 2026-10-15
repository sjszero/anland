#!/usr/bin/env bash
# Fedora 43 aarch64: rebuild the Fedora Mutter49 SRPM; retain the GNOME49 ABI.
# ANLAND_STAGE=check|prepare|build ANLAND_WITH_DEPS=1 JOBS=4 ANLAND_INSTALL=0
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# Fedora build/package functions are local to this WM recipe.
fedora_die() { printf 'fedora-build: %s\n' "$*" >&2; exit 1; }

fedora_run() { "$@" || fedora_die "failed: $*"; }

fedora_preflight() {
    local ID VERSION_ID
    source /etc/os-release || fedora_die 'cannot identify distribution'
    [[ $ID == fedora && $VERSION_ID == 43 && $(uname -m) == aarch64 ]] ||
        fedora_die 'requires native Fedora 43 aarch64'
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
    WORKDIR=$(realpath -m -- "${WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-$1-fedora43}") || fedora_die 'cache path'
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
        rpm-build rpmdevtools cpio util-linux findutils diffutils "$@"
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
    printf '%s\n' "${packages[@]##*/}" > "$ARTIFACTS_DIR/packages.list" || fedora_die 'package list'
    (cd "$ARTIFACTS_DIR" && sha256sum -- "${packages[@]##*/}" > SHA256SUMS && sha256sum -c SHA256SUMS) || fedora_die 'package checksums'
    python3 - "$ROOT" "$FEDORA_INPUT_ID" "$ARTIFACTS_DIR/build-inputs.json" <<'PY' || fedora_die 'build record'
import json,subprocess,sys
root,identity,out=sys.argv[1:]
record={'distribution':'fedora43','architecture':'aarch64','input_sha256':identity,
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
fedora_initialize gnome
fedora_dependencies pipewire-devel
if [[ $ANLAND_STAGE == check ]]; then
    printf 'FEDORA43_RECIPE_OK gnome (Mutter49; no compilation or graphical test)\n'; exit 0
fi
fedora_srpm_prepare mutter "$SCRIPT_DIR/dependencies.lock" "$SCRIPT_DIR/mutter.patch" \
    "$SCRIPT_DIR/mutter" . '-Danland=enabled'
if [[ $ANLAND_STAGE == prepare ]]; then
    fedora_xwayland
    printf 'FEDORA43_PREPARED gnome\n'; exit 0
fi
# The upstream distro spec retains its introspection/data/runtime packages.
# No GNOME Shell ABI spoofing, cross-major replacement or service manipulation.
python3 - "$FEDORA_SRPM_SPEC" <<'PY' || fedora_die 'cannot add Fedora launcher'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if 'Source99: anland-startup.sh' not in s:
    if 'Source99:' in s: raise SystemExit('Source99 collision')
    s=s.replace('%description\n','Source99: anland-startup.sh\n\n%description\n',1)
    s=s.replace('%meson_install\n','%meson_install\ninstall -Dm755 %{SOURCE99} %{buildroot}%{_bindir}/gnome-anland\n',1)
    s=s.replace('%files -f %{name}.lang\n','%files -f %{name}.lang\n%{_bindir}/gnome-anland\n',1)
    # Complete session components come from Fedora's matching GNOME49 packages.
    s=s.replace('Requires: dbus\n','Requires: dbus\nRequires: gnome-shell >= 49, gnome-shell < 50, gnome-session, bash, procps-ng, util-linux\n',1)
    p.write_text(s)
PY
fedora_run cp "$SCRIPT_DIR/startup.sh" "$FEDORA_SRPM_TOP/SOURCES/anland-startup.sh"
fedora_srpm_build
fedora_xwayland
fedora_finish