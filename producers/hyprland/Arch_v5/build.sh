#!/usr/bin/env bash
# Arch Linux ARM, native aarch64. No build invokes startup.sh.
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
WORKDIR=${WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-hyprland-arch-v5}
ARTIFACTS=${ARTIFACTS:-$SCRIPT_DIR/artifacts}
JOBS=${JOBS:-4}
die() { printf 'hyprland-build: %s\n' "$*" >&2; exit 1; }
run() { "$@" || die "failed: $*"; }
[[ $# == 0 ]] || die 'use environment variables, not positional arguments'
[[ $(id -u) != 0 ]] || die 'makepkg must run as an ordinary user'
[[ $(uname -m) == aarch64 && -f /etc/arch-release ]] || die 'native Arch Linux ARM aarch64 required'
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
for flag in ANLAND_INSTALL ANLAND_WITH_DEPS ANLAND_OFFLINE; do
    [[ ${!flag:-0} =~ ^[01]$ ]] || die "$flag must be 0 or 1"
done
[[ ${ANLAND_OFFLINE:-0} != 1 || ${ANLAND_WITH_DEPS:-0} != 1 ]] || die 'offline dependency installation is not supported'
for tool in python3 flock makepkg pacman tar sha256sum bsdtar gpg; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
run mkdir -p "$WORKDIR" "$(dirname -- "$ARTIFACTS")"
[[ ! -L $ARTIFACTS ]] || die 'ARTIFACTS must not be a symlink'
WORKDIR=$(realpath "$WORKDIR") || die 'WORKDIR'; ARTIFACTS=$(realpath -m "$ARTIFACTS") || die 'ARTIFACTS'
[[ ! -e $ARTIFACTS || -d $ARTIFACTS ]] || die 'ARTIFACTS must be a directory'
[[ $SCRIPT_DIR != "$ARTIFACTS" && $SCRIPT_DIR != "$ARTIFACTS/"* &&
   $WORKDIR != "$ARTIFACTS" && $WORKDIR != "$ARTIFACTS/"* ]] || die 'ARTIFACTS must not contain the source or cache'
exec 8>"$WORKDIR/build.lock" || die 'cannot open build lock'
flock -n 8 || die 'WORKDIR is already in use'
# This lock must stay outside the directory exchanged during publication.
lockdir="$(dirname -- "$ARTIFACTS")/.cache/anland-artifacts-locks"
run mkdir -p "$lockdir"
exec 9>"$lockdir/${ARTIFACTS##*/}.lock" || die 'cannot open artifacts lock'
flock -n 9 || die 'artifacts are already in use'
# Stage a complete signed delivery beside ARTIFACTS, on the same filesystem.
# Neither failed builds nor cancelled signing may modify the previous delivery.
STAGING=
cleanup() { [[ -z $STAGING ]] || rm -rf -- "$STAGING"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
STAGING=$(mktemp -d "$(dirname -- "$ARTIFACTS")/.${ARTIFACTS##*/}.staging.XXXXXXXX") || die 'cannot create artifact staging'
run chmod 755 "$STAGING"
# Fingerprint includes lock, recipes, patch bytes, backend and public sources.
# Input preparation stays in this entrypoint; no companion Python file.
python3 - "$SCRIPT_DIR" "$WORKDIR" <<'PY_INPUTS' || die 'input preparation failed'
from pathlib import Path
import sys, json, hashlib, shutil, subprocess, tarfile
here, work = map(Path, sys.argv[1:])
root = here.parents[2]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
lock = json.loads((here/'dependencies.lock').read_text())
for name, expected in lock['patches'].items():
    if name != 'xwayland.patch' and sha(here/name) != expected:
        raise SystemExit('patch checksum mismatch: '+name)
for name, key in [('xwayland.patch','patch_sha256'), ('xorg-xwayland.PKGBUILD','recipe_sha256')]:
    if sha(here/name) != lock['xwayland'][key]:
        raise SystemExit('Xwayland checksum mismatch: '+name)
folders = [root/'common', root/'libdisplay_producer', here.parent/'anland_backend']
files = [root/'LICENSE'] + [p for p in here.iterdir() if p.is_file()]
for folder in folders:
    files.extend(p for p in folder.rglob('*') if p.is_file())
inputs = {str(p.relative_to(root)): sha(p) for p in sorted(files)}
identity = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
context = work/('inputs-'+identity)
if not context.exists():
    context.mkdir(); dst = context/'wm'; dst.mkdir(); (context/'xwayland').mkdir()
    with tarfile.open(dst/'anland-inputs.tar.gz', 'w:gz', dereference=True) as archive:
        for folder in folders:
            archive.add(folder, arcname='anland-inputs/'+('backend' if folder.name=='anland_backend' else folder.name))
        for p in here.glob('*.patch'):
            if p.name!='xwayland.patch': archive.add(p, arcname='anland-inputs/patches/'+p.name)
        for name in ('startup.sh','dependencies.lock'):
            archive.add(here/name, arcname='anland-inputs/'+name)
        archive.add(root/'LICENSE', arcname='anland-inputs/LICENSE')
    (dst/'PKGBUILD').write_text((here/'PKGBUILD').read_text().replace('@INPUT_SHA256@', sha(dst/'anland-inputs.tar.gz')))
    shutil.copyfile(here/'xorg-xwayland.PKGBUILD', context/'xwayland/PKGBUILD')
    shutil.copyfile(here/'xwayland.patch', context/'xwayland/xwayland.patch')
    revision = subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
    (context/'build-inputs.json').write_text(json.dumps({'input_identity':identity,'anland_revision':revision,'file_sha256':inputs,'lock':lock},indent=2)+'\n')
if not (context/'build-inputs.json').is_file():
    raise SystemExit('incomplete cached inputs: '+str(context))
(work/'input-id').write_text(identity+'\n')
print('Prepared makepkg inputs: '+str(context))
PY_INPUTS
input_id=$(cat "$WORKDIR/input-id") || die 'input identity unavailable'
BUILDROOT="$WORKDIR/inputs-$input_id"
export JOBS MAKEFLAGS="-j$JOBS"
export SRCDEST="$WORKDIR/downloads" PKGDEST="$BUILDROOT/packages"
run mkdir -p "$SRCDEST" "$PKGDEST"
# Keep Xwayland isolated from the WM build staging environment.
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CMAKE_PREFIX_PATH LD_LIBRARY_PATH DESTDIR
flags=(--force --cleanbuild --noconfirm)
[[ ${ANLAND_WITH_DEPS:-0} != 1 ]] || flags+=(--syncdeps)
[[ ${ANLAND_OFFLINE:-0} != 1 ]] || flags+=(--holdver)
packages=()
for recipe in wm xwayland; do
    cwd="$BUILDROOT/$recipe"
    if [[ ${ANLAND_OFFLINE:-0} == 1 ]]; then
        # makepkg can otherwise fetch absent archives even with --holdver.
        (cd "$cwd" && bash -c 'source ./PKGBUILD; for item in "${source[@]}"; do
            if [[ $item == *git+* ]]; then file=${item%%::*};
            elif [[ $item == *::* ]]; then file=${item%%::*};
            else file=${item##*/}; fi
            [[ -e $file || -e $SRCDEST/$file ]] || { echo "offline source missing: $file" >&2; exit 1; }
        done') || die 'offline source preflight failed'
    fi
    printf '\n==> makepkg %s (input %s)\n' "$recipe" "$input_id"
    (cd "$cwd" && makepkg "${flags[@]}") || die "makepkg $recipe failed"
    (cd "$cwd" && makepkg --packagelist) > "$BUILDROOT/$recipe.packagelist" || die 'cannot query package list'
    while IFS= read -r file; do
        [[ -s $file ]] || die "expected package missing: $file"
        metadata=$(bsdtar -xOf "$file" .PKGINFO) || die "cannot read package metadata"
        [[ $metadata == *"arch = aarch64"* ]] || die "wrong package architecture: $file"
        run pacman -Qip "$file"
        run bsdtar -tf "$file" > "$file.contents"
        pkgname=$(awk -F' = ' '$1 == "pkgname" {print $2; exit}' <<<"$metadata") || die 'cannot read package name'
        [[ -n $pkgname ]] || die "package name missing in metadata: $file"
        run cp -p "$file" "$STAGING/"
        packages+=("${file##*/}")
    done < "$BUILDROOT/$recipe.packagelist"
done
[[ ${#packages[@]} -ge 3 ]] || die 'incomplete package set (Hyprland, hyprpm, Xwayland)'
# Publish only a complete, verified, signed delivery. Linux RENAME_EXCHANGE
# switches the entire directory at once, including same-version rebuilds.
# The previous delivery then lives at STAGING until the EXIT cleanup removes it.
_publish() {
    local name
    for name in "${packages[@]}"; do
        [[ -s $STAGING/$name && -s $STAGING/$name.sig ]] || die "staged package/signature missing: $name"
    done
    run cp "$BUILDROOT/build-inputs.json" "$STAGING/build-inputs.json"
    printf '%s\n' "${packages[@]}" > "$STAGING/packages.list" || die 'cannot write package list'
    (cd "$STAGING" && sha256sum "${packages[@]}" "${packages[@]/%/.sig}" \
        packages.list build-inputs.json anland-local-signing-key.asc > SHA256SUMS && \
        sha256sum -c SHA256SUMS) || die 'staged artifact checksums failed'
    python3 - "$STAGING" "$ARTIFACTS" <<'PY_PUBLISH' || die 'atomic artifact publication failed'
import ctypes, os, sys
stage, destination = sys.argv[1:]
if os.path.lexists(destination):
    if os.path.islink(destination) or not os.path.isdir(destination):
        raise SystemExit('artifact destination is no longer an ordinary directory')
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 2):
        raise OSError(ctypes.get_errno(), 'RENAME_EXCHANGE failed; previous delivery unchanged')
else:
    os.rename(stage, destination)
print('Published complete artifact set: '+destination)
PY_PUBLISH
    (cd "$ARTIFACTS" && sha256sum -c SHA256SUMS) || die 'artifact checksums failed'
}
# Persistent machine-local signing identity; keep pacman's signature policy intact.
keyhome=${ANLAND_SIGNING_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/anland-arch/signing}
[[ ! -L $keyhome ]] || die 'signing home must not be a symlink'
run install -dm700 "$keyhome"
gpg=(gpg --no-options --homedir "$keyhome" --batch --yes)
uid='Anland Arch local packages <anland-local@localhost>'
if ! "${gpg[@]}" --list-secret-keys "$uid" >/dev/null 2>&1; then
    run "${gpg[@]}" --pinentry-mode loopback --passphrase '' --quick-generate-key "$uid" ed25519 sign 0
fi
fingerprint=$("${gpg[@]}" --with-colons --list-secret-keys "$uid" | awk -F: '$1 == "fpr" {print $10; exit}') || die 'signing fingerprint'
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || die 'invalid signing fingerprint'
run "${gpg[@]}" --armor --output "$STAGING/anland-local-signing-key.asc" --export "$fingerprint"
for file in "${packages[@]}"; do
    run "${gpg[@]}" --local-user "$fingerprint" --detach-sign --output "$STAGING/$file.sig" "$STAGING/$file"
    run "${gpg[@]}" --verify "$STAGING/$file.sig" "$STAGING/$file"
done
_publish
if [[ ${ANLAND_INSTALL:-0} == 1 ]]; then
    printf '\nInstalling the standard Hyprland SDK/runtime, hyprpm, and patched xorg-xwayland; no session/service restart.\n'
    run sudo pacman-key --add "$ARTIFACTS/anland-local-signing-key.asc"
    run sudo pacman-key --lsign-key "$fingerprint"
    paths=(); for file in "${packages[@]}"; do paths+=("$ARTIFACTS/$file"); done
    run sudo pacman --noconfirm -U "${paths[@]}"
fi
printf '\nPackages: %s\nBuild/package completed; graphical validation NOT performed.\n' "$ARTIFACTS"