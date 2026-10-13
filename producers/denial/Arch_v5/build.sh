#!/usr/bin/env bash
# Arch Linux ARM: one entry builds/reuses Flutter, then Denial and desktop packages.
# Usage: [ANLAND_WITH_DEPS=1] [ANLAND_ENGINE_MODE=auto|build|prepared] bash build.sh [--noconfirm]
# Cache: WORKDIR / DENIAL_CACHE; packages: ARTIFACTS_DIR (default $WORKDIR/packages).
# auto verifies prepared inputs or builds missing ones; build selects Impeller+Ganesh/Vulkan/no-LTO/no-GTK.
# prepared never compiles an engine; ANLAND_OFFLINE=1 requires synchronized source/dependency caches.
# ANLAND_WITH_DE=0 omits desktop; JOBS=2 limits builds; ANLAND_INSTALL=1 explicitly installs packages.
# Signed packages, packages.list and manifest.env are emitted; no desktop is started/restarted.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    printf 'execute build.sh with bash; do not source it into an interactive shell\n' >&2
    return 1
fi
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)" || exit 1
log() { printf '\n==> %s\n' "$*"; }
die() { printf 'denial-build: %s\n' "$*" >&2; exit 1; }
run() { "$@" || die "failed: $*"; }
in_dir() { local dir=$1; shift; (cd -- "$dir" && "$@") || die "failed in $dir: $*"; }
for argument in "$@"; do
    case $argument in
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        --noconfirm) ;; # Same calling convention as the other Arch_v5 entries.
        *) die "unknown argument: $argument (see --help)" ;;
    esac
done
source "$SCRIPT_DIR/dependencies.lock" || die 'cannot read dependencies.lock'
JOBS=${JOBS:-2}
ANLAND_PKGREL=${ANLAND_PKGREL:-2}
ANLAND_DE_PKGREL=${ANLAND_DE_PKGREL:-2}
ANLAND_WITH_DE=${ANLAND_WITH_DE:-1}
ANLAND_WITH_DEPS=${ANLAND_WITH_DEPS:-0}
ANLAND_OFFLINE=${ANLAND_OFFLINE:-0}
ANLAND_INSTALL=${ANLAND_INSTALL:-0}
ANLAND_ENGINE_MODE=${ANLAND_ENGINE_MODE:-auto}
case $ANLAND_ENGINE_MODE in auto|build|prepared) ;; *) die 'ANLAND_ENGINE_MODE must be auto, build or prepared' ;; esac
LOCKED_ENGINE_SHA256=$ENGINE_SHA256
LOCKED_ENGINE_ICU_SHA256=$ENGINE_ICU_SHA256
LOCKED_ENGINE_VERSION=$ENGINE_VERSION
ENGINE_POLICY='release-arm64-impeller-ganesh-vulkan-nolto-no-gtk-v2'
for flag in ANLAND_WITH_DE ANLAND_WITH_DEPS ANLAND_OFFLINE ANLAND_INSTALL; do
    [[ ${!flag} == 0 || ${!flag} == 1 ]] || die "$flag must be 0 or 1"
done
for number in JOBS ANLAND_PKGREL ANLAND_DE_PKGREL; do
    [[ ${!number} =~ ^[1-9][0-9]*$ ]] || die "$number must be a positive integer"
done
[[ $(id -u) != 0 && $(uname -m) == aarch64 ]] || die 'run as a normal user on Arch Linux ARM/aarch64'
WORKDIR=$(realpath -m -- "${WORKDIR:-${DENIAL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/denial-anland}}") || die 'invalid WORKDIR'
ARTIFACTS_DIR=$(realpath -m -- "${ARTIFACTS_DIR:-$WORKDIR/packages}") || die 'invalid ARTIFACTS_DIR'
[[ $WORKDIR != / && $WORKDIR != "$HOME" && $WORKDIR != "$ROOT" && $WORKDIR != "$ROOT/"* ]] || die 'WORKDIR must be a separate cache directory'
SOURCE="$WORKDIR/src/denial"
BUILD="$WORKDIR/build"
PUBLIC="$WORKDIR/public-overlay/anland"
FLUTTER=$(realpath -m -- "${DENIAL_FLUTTER_ROOT:-$WORKDIR/engine/checkout}") || die 'invalid Flutter path'
ENGINE=$(realpath -m -- "${DENIAL_ENGINE_DIR:-$WORKDIR/engine/build/out/denial_host_release_arm64}") || die 'invalid engine path'
[[ $ARTIFACTS_DIR != "$SOURCE" && $ARTIFACTS_DIR != "$SOURCE/"* ]] || die 'packages must be outside the source tree'
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
export CARGO_HOME="$WORKDIR/cargo-home" CARGO_TARGET_DIR="$WORKDIR/cargo-target"
export PUB_CACHE="$WORKDIR/pub-cache" FLUTTER_ROOT="$FLUTTER" FLUTTER_GIT_URL="$FLUTTER_URL"
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
export ANLAND_DENIAL_LIB_DIR="$BUILD/native/usr/lib"
export ANLAND_PKGREL ANLAND_DE_PKGREL
# All native binaries report the release identity without changing upstream locks.
export DENIAL_BUILD_VERSION="$DENIAL_VERSION"
# Release policy belongs to the recipe, not upstream Cargo manifests.
export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-false}"
run mkdir -p "$WORKDIR" "$BUILD" "$ARTIFACTS_DIR"
exec 9>"$WORKDIR/build.lock" || die 'cannot open build lock'
flock -n 9 || die 'another build owns WORKDIR'
exec 8>"$ARTIFACTS_DIR/.build.lock" || die 'cannot open package lock'
flock -n 8 || die 'another build owns ARTIFACTS_DIR'
network=()
[[ $ANLAND_OFFLINE == 0 ]] || network=(--offline)

checkout() {
    local tree=$1 url=$2 revision=$3 seed=${4:-}
    if [[ ! -e $tree/.git ]]; then
        [[ ! -e $tree ]] || die "untracked source preserved: $tree"
        if [[ -n $seed && -e $seed/.git ]] && git -C "$seed" cat-file -e "$revision^{commit}" 2>/dev/null; then
            run git clone --no-hardlinks --no-checkout "$seed" "$tree"
        else
            [[ $ANLAND_OFFLINE == 0 ]] || die "offline source missing: $tree"
            run git init -q "$tree"
            run git -C "$tree" fetch --depth=1 "$url" "$revision"
        fi
        run git -C "$tree" checkout --detach "$revision"
    fi
    [[ $(git -C "$tree" rev-parse HEAD) == "$revision" ]] ||
        die "cached revision differs: $tree; move it aside before changing upstream version"
}
prepare_sources() {
    log 'Prepare Denial and Anland sources'
    checkout "$SOURCE" "$DENIAL_URL" "$DENIAL_REV" "${DENIAL_SOURCE:-$ROOT/../denial}"
    local patch="$WORKDIR/denial.pending.patch" previous="$WORKDIR/denial.applied.patch" file target
    # Both component patches target the locked Denial tree, not Flutter upstream.
    : > "$patch" || die 'cannot create pending source patch'
    for file in flutter-adapter.patch denial.patch; do
        [[ -s $SCRIPT_DIR/$file ]] || die "missing component patch: $file"
        cat -- "$SCRIPT_DIR/$file" >> "$patch" || die "cannot read component patch: $file"
    done
    if ! git -C "$SOURCE" apply --reverse --check "$patch" 2>/dev/null; then
        if ! git -C "$SOURCE" apply --check "$patch" 2>/dev/null; then
            [[ -f $previous ]] || die 'source has conflicting edits; refusing to overwrite them'
            run git -C "$SOURCE" apply --reverse --check "$previous"
            run git -C "$SOURCE" apply --reverse "$previous"
        fi
        run git -C "$SOURCE" apply --check "$patch"
        run git -C "$SOURCE" apply "$patch"
    fi
    run cp "$patch" "$previous"
    target="$SOURCE/compositor/src/bin/deniald/anland_backend"
    run mkdir -p "$target"
    for file in "$SCRIPT_DIR/denial/"*.rs; do
        # Changed overlays get a fresh mtime so Cargo cannot reuse stale objects.
        local relative=${file#"$SCRIPT_DIR/denial/"}
        cmp -s "$file" "$target/$relative" || run install -m644 "$file" "$target/$relative"
    done
    # Use the canonical public library, not a Denial-specific copy or patch.
    run rm -rf -- "$PUBLIC/common" "$PUBLIC/libdisplay_producer" "$PUBLIC/producers"
    run mkdir -p "$PUBLIC/producers/denial"
    run cp -aL "$ROOT/common" "$ROOT/libdisplay_producer" "$PUBLIC/"
    run cp -aL "$SCRIPT_DIR/denial" "$PUBLIC/producers/denial/anland_backend"
}
check_sha() {
    printf '%s  %s\n' "$1" "$2" | sha256sum -c - || die "artifact checksum: $2"
}
link_cache() {
    local source previous managed
    source=$(realpath -e -- "$1") || die "missing SDK input: $1"
    if [[ -L $2 ]]; then
        previous=$(realpath -m -- "$2") || die "cannot inspect SDK link: $2"
        [[ $previous != "$source" ]] || return 0
        managed=$(realpath -m -- "$WORKDIR/engine/build/out") || die 'invalid managed engine cache'
        [[ $previous == "$managed/"* ]] || die "unmanaged SDK link preserved: $2"
        # Retarget only our existing engine-cache link; never remove SDK directories.
        run ln -sfnT -- "$source" "$2"
    elif [[ -e $2 ]]; then
        [[ $(realpath -e -- "$2") == "$source" ]] || die "unmanaged SDK directory preserved: $2"
    else
        run ln -s -- "$source" "$2"
    fi
}
prepare_engine_sources() (
    # Isolated options/functions; no second build entry is sourced or executed.
    set -euo pipefail
    local SOURCE_LOCK="$SOURCE/prebuilt/flutter-engine/SOURCE_LOCK.json"
    local CACHE_ROOT="$WORKDIR/engine" DEPOT_TOOLS="$WORKDIR/engine/depot_tools"
    local STATE_ROOT="$WORKDIR/engine/state" VPYTHON_CACHE_ROOT="$WORKDIR/engine/vpython"
    local CHECKOUT="$FLUTTER" SKIA_CHECKOUT="$FLUTTER/engine/src/flutter/third_party/skia"
    local DENIAL_ARCH=aarch64 DENIAL_FLUTTER_ENGINE_OFFLINE="$ANLAND_OFFLINE"
    fail() { die "engine source preparation: $*"; }
    lock_value() { jq -er "$1" "$SOURCE_LOCK"; }
    file_sha256() { sha256sum "$1" | awk '{print $1}'; }
    resolve_source_roots() { CHECKOUT="$FLUTTER"; SKIA_CHECKOUT="$CHECKOUT/engine/src/flutter/third_party/skia"; }
    require_clean_checkout() {
      local label="$1"
      local checkout="$2"
      local status

      [[ "$(git -C "$checkout" rev-parse --is-inside-work-tree 2>/dev/null || true)" \
        == true ]] \
        || fail "$label source is not a Git checkout: $checkout"
      git -C "$checkout" diff --quiet --ignore-submodules=all \
        || fail "$label source has tracked modifications: $checkout"
      git -C "$checkout" diff --cached --quiet --ignore-submodules=all \
        || fail "$label source has staged modifications: $checkout"
      status="$(
        git -C "$checkout" status \
          --porcelain=v1 \
          --untracked-files=normal \
          --ignore-submodules=all
      )"
      [[ -z "$status" ]] \
        || fail "$label source has untracked modifications: $checkout"
    }

    ensure_repository() {
      local label="$1"
      local repository="$2"
      local revision="$3"
      local destination="$4"
      local actual_origin

      if [[ ! -e "$destination" ]]; then
        install -d -m 0700 "$(dirname -- "$destination")"
        git init --quiet "$destination"
        git -C "$destination" remote add origin "$repository"
      fi
      require_clean_checkout "$label" "$destination"

      actual_origin="$(git -C "$destination" remote get-url origin)"
      [[ "$actual_origin" == "$repository" ]] \
        || fail "$label cache origin is $actual_origin, expected $repository"

      if ! git -C "$destination" cat-file -e "$revision^{commit}" 2>/dev/null; then
        printf 'Fetching %s %s\n' "$label" "$revision"
        git -C "$destination" fetch \
          --no-tags \
          --depth=1 \
          --filter=blob:none \
          origin \
          "$revision"
      fi
      git -C "$destination" checkout --quiet --detach "$revision"
      [[ "$(git -C "$destination" rev-parse HEAD)" == "$revision" ]] \
        || fail "$label checkout did not reach $revision"
    }

    write_gclient_config() {
      local repository="$1"
      local custom_vars='{}'

      if [[ "$DENIAL_ARCH" == aarch64 ]]; then
        custom_vars='{ "download_fuchsia_deps": False }'
      fi

      {
        printf '%s\n' \
          'solutions = [' \
          '  {' \
          '    "custom_deps": {},' \
          '    "deps_file": "DEPS",' \
          '    "managed": False,' \
          '    "name": ".",' \
          '    "safesync_url": "",'
        printf '    "custom_vars": %s,\n' "$custom_vars"
        printf '    "url": "%s",\n' "$repository"
        printf '%s\n' \
          '  },' \
          ']'
      } >"$CHECKOUT/.gclient"
    }

    sync_managed_checkout() (
      local filtered_deps

      cd "$CHECKOUT"
      if [[ "$DENIAL_ARCH" != aarch64 ]]; then
        PATH="$DEPOT_TOOLS/.cipd_bin:$DEPOT_TOOLS:$PATH" \
          DEPOT_TOOLS_UPDATE=0 \
          VPYTHON_VIRTUALENV_ROOT="$VPYTHON_CACHE_ROOT" \
          gclient sync --no-history --nohooks
        return
      fi

      # Flutter publishes version 21 of its formatting/Android JDK only for
      # linux-amd64. The desktop engine build does not use it, but gclient tries to
      # resolve it unconditionally. Filter that single dependency while syncing,
      # then restore the exact locked DEPS file before hooks and validation run.
      git -c core.hooksPath=/dev/null checkout --quiet -- DEPS
      filtered_deps="$(mktemp -- "$CHECKOUT/.DEPS.arm64.XXXXXX")"
      trap 'git -c core.hooksPath=/dev/null checkout --quiet -- DEPS; rm -f -- "$filtered_deps"' \
        EXIT HUP INT TERM
      if ! awk '
          BEGIN { skipping = 0; blocks = 0 }
          $0 == "  '\''engine/src/flutter/third_party/java/openjdk'\'': {" {
            skipping = 1
            blocks++
            next
          }
          skipping && $0 == "   }," { skipping = 0; next }
          !skipping { print }
          END { if (skipping || blocks != 1) exit 1 }
        ' DEPS >"$filtered_deps"; then
        fail 'could not isolate the Flutter OpenJDK dependency for ARM64 sync'
      fi
      chmod --reference=DEPS "$filtered_deps"
      mv -- "$filtered_deps" DEPS
      PATH="$DEPOT_TOOLS/.cipd_bin:$DEPOT_TOOLS:$PATH" \
        DEPOT_TOOLS_UPDATE=0 \
        VPYTHON_VIRTUALENV_ROOT="$VPYTHON_CACHE_ROOT" \
        gclient sync --no-history --nohooks
    )

    checkout_matches_lock() {
      local flutter_revision="$1"
      local skia_revision="$2"
      local checkout_depot_revision="$3"
      local flutter_repository
      local skia_repository
      local skia_checkout="$SKIA_CHECKOUT"
      local checkout_depot="$CHECKOUT/engine/src/flutter/third_party/depot_tools"

      flutter_repository="$(lock_value '.flutter.repository')"
      skia_repository="$(lock_value '.skia.repository')"
      [[ "$(git -C "$CHECKOUT" rev-parse --is-inside-work-tree 2>/dev/null || true)" \
        == true ]] || return 1
      [[ "$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null || true)" \
        == "$flutter_revision" ]] || return 1
      [[ "$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null || true)" \
        == "$flutter_repository" ]] || return 1
      require_clean_checkout 'Flutter' "$CHECKOUT"
      [[ "$(git -C "$skia_checkout" rev-parse --is-inside-work-tree 2>/dev/null || true)" \
        == true ]] || return 1
      [[ "$(git -C "$skia_checkout" rev-parse HEAD 2>/dev/null || true)" \
        == "$skia_revision" ]] || return 1
      [[ "$(git -C "$skia_checkout" remote get-url origin 2>/dev/null || true)" \
        == "$skia_repository" ]] || return 1
      require_clean_checkout 'Skia' "$skia_checkout"
      [[ "$(git -C "$checkout_depot" rev-parse --is-inside-work-tree 2>/dev/null || true)" \
        == true ]] || return 1
      [[ "$(git -C "$checkout_depot" rev-parse HEAD 2>/dev/null || true)" \
        == "$checkout_depot_revision" ]] || return 1
    }

    prepare_checkout() {
      local source_state="$1"
      local flutter_repository
      local flutter_revision
      local skia_revision
      local depot_repository
      local depot_revision
      local checkout_depot

      resolve_source_roots
      if [[ "$DENIAL_ARCH" == aarch64 ]]; then
        source_state="${source_state}:linux-arm64-sync-v1"
      fi

      flutter_repository="$(lock_value '.flutter.repository')"
      flutter_revision="$(lock_value '.flutter.revision')"
      skia_revision="$(lock_value '.skia.revision')"
      depot_repository="$(lock_value '.depot_tools.repository')"
      depot_revision="$(lock_value '.depot_tools.revision')"
      checkout_depot="$CHECKOUT/engine/src/flutter/third_party/depot_tools"

      if [[ -f "$STATE_ROOT/source-lock.sha256" ]] \
        && [[ "$(<"$STATE_ROOT/source-lock.sha256")" == "$source_state" ]] \
        && checkout_matches_lock \
          "$flutter_revision" "$skia_revision" "$depot_revision"; then
        printf 'Reusing synchronized Flutter/Skia checkout %s\n' \
          "${flutter_revision:0:12}"
        return
      fi

      if [[ "${DENIAL_FLUTTER_ENGINE_OFFLINE:-0}" == 1 ]]; then
        fail 'locked synchronized source cache is missing/stale; populate the source cache with ANLAND_OFFLINE=0 before an offline build'
      fi

      ensure_repository \
        'bootstrap depot_tools' \
        "$depot_repository" \
        "$depot_revision" \
        "$DEPOT_TOOLS"
      # A retained Flutter checkout has source-owned post-checkout hooks. Keep the
      # pinned bootstrap depot_tools available while moving it to a new lock so
      # those hooks resolve vpython3 without depending on the runner's host PATH.
      PATH="$DEPOT_TOOLS/.cipd_bin:$DEPOT_TOOLS:$PATH" \
        DEPOT_TOOLS_UPDATE=0 \
        VPYTHON_VIRTUALENV_ROOT="$VPYTHON_CACHE_ROOT" \
        ensure_repository \
          'Flutter' \
          "$flutter_repository" \
          "$flutter_revision" \
          "$CHECKOUT"
      write_gclient_config "$flutter_repository"

      printf 'Synchronizing Flutter dependencies for %s\n' \
        "${flutter_revision:0:12}"
      install -d -m 0700 "$VPYTHON_CACHE_ROOT"
      sync_managed_checkout

      [[ -x "$checkout_depot/gclient" ]] \
        || fail "synchronized depot_tools is missing: $checkout_depot"
      (
        cd "$CHECKOUT"
        PATH="$checkout_depot/.cipd_bin:$checkout_depot:$PATH" \
          DEPOT_TOOLS_UPDATE=0 \
          VPYTHON_VIRTUALENV_ROOT="$VPYTHON_CACHE_ROOT" \
          gclient runhooks
      )

      checkout_matches_lock \
        "$flutter_revision" "$skia_revision" "$depot_revision" \
        || fail 'synchronized checkout does not match SOURCE_LOCK.json'
      install -d -m 0700 "$STATE_ROOT"
      printf '%s\n' "$source_state" >"$STATE_ROOT/source-lock.sha256"
    }
    install -d -m 0700 "$CACHE_ROOT" "$STATE_ROOT" "$VPYTHON_CACHE_ROOT"
    prepare_checkout "$(file_sha256 "$SOURCE_LOCK")"
)

engine_inputs_ready() {
    local directory=$1 file
    for file in dart-sdk/bin/dart gen_snapshot font-subset impellerc; do
        [[ -x $directory/$file ]] || return 1
    done
    for file in libflutter_engine.so icudtl.dat args.gn gen/dart-pkg/sky_engine/pubspec.yaml \
                flutter_patched_sdk/platform_strong.dill gen/const_finder.dart.snapshot; do
        [[ -s $directory/$file ]] || return 1
    done
}
engine_policy_id() {
    {
        printf '%s\n' "$ENGINE_POLICY" "$FLUTTER_REV"
        sha256sum "$SOURCE/prebuilt/flutter-engine/SOURCE_LOCK.json" | awk '{print $1}'
    } | sha256sum | awk '{print $1}'
}
engine_receipt_ready() {
    local directory=$1 identity
    engine_inputs_ready "$directory" || return 1
    [[ -f $directory/.anland-engine.json && -f $directory/.anland-engine.SHA256SUMS ]] || return 1
    identity=$(engine_policy_id) || return 1
    jq -e --arg identity "$identity" --arg policy "$ENGINE_POLICY" \
        '.schema == 1 and .identity == $identity and .policy == $policy
         and (.package_version | test("^[A-Za-z0-9.+_]+-[0-9]+$"))
         and (.engine_sha256 | test("^[0-9a-f]{64}$"))
         and (.icu_sha256 | test("^[0-9a-f]{64}$"))' \
        "$directory/.anland-engine.json" >/dev/null || return 1
    (cd -- "$directory" && sha256sum --check --status .anland-engine.SHA256SUMS) || return 1
    [[ $(sha256sum "$directory/libflutter_engine.so" | awk '{print $1}') == \
        $(jq -r .engine_sha256 "$directory/.anland-engine.json") ]] || return 1
    [[ $(sha256sum "$directory/icudtl.dat" | awk '{print $1}') == \
        $(jq -r .icu_sha256 "$directory/.anland-engine.json") ]] || return 1
}
legacy_engine_ready() {
    local directory=$1
    engine_inputs_ready "$directory" || return 1
    [[ $(sha256sum "$directory/libflutter_engine.so" | awk '{print $1}') == "$LOCKED_ENGINE_SHA256" ]] || return 1
    [[ $(sha256sum "$directory/icudtl.dat" | awk '{print $1}') == "$LOCKED_ENGINE_ICU_SHA256" ]]
}
use_engine_receipt() {
    ENGINE_VERSION=$(jq -er .package_version "$ENGINE/.anland-engine.json") || die 'missing engine package identity'
    ENGINE_SHA256=$(jq -er .engine_sha256 "$ENGINE/.anland-engine.json") || die 'missing engine hash'
    ENGINE_ICU_SHA256=$(jq -er .icu_sha256 "$ENGINE/.anland-engine.json") || die 'missing engine ICU hash'
    DENIAL_ENGINE_POLICY='Impeller + Ganesh GLES/Vulkan, no-LTO, no-GTK'
}
verify_engine_symbols() {
    local exports symbol
    exports=$(nm -D --defined-only "$ENGINE/libflutter_engine.so") || die 'cannot inspect engine exports'
    for symbol in DenialFlutterEngineRequestFrameForExternalTextures DenialFlutterEngineScheduleFrameForExternalTextures \
                  FlutterEngineGetProcAddresses FlutterEngineRunsAOTCompiledDartCode; do
        grep -Eq "[[:space:]]${symbol}$" <<< "$exports" || die "missing engine API: $symbol"
    done
}
build_flutter_engine() {
    # The locked depot_tools ninja wrapper imports pipes, removed in Python 3.13.
    # Use Arch's native binary, not the Python wrapper selected by the depot PATH.
    local native_ninja=/usr/bin/ninja
    [[ -x $native_ninja ]] || die 'native Ninja missing (install the Arch ninja package)'
    run "$native_ninja" --version
    local identity generated_source="$FLUTTER/engine/src" rc
    local checkout_depot="$FLUTTER/engine/src/flutter/third_party/depot_tools"
    local engine_build="$WORKDIR/engine/build" target=${ENGINE##*/} policy expected actual
    identity=$(engine_policy_id) || die 'cannot identify engine policy'
    [[ $ENGINE == "$engine_build/out/$target" && $target == denial_host_release_arm64_anland_ganesh ]] ||
        die 'compilation uses WORKDIR/engine/build/out/denial_host_release_arm64_anland_ganesh; prepared overrides are read-only'
    if [[ -f $ENGINE/libflutter_engine.so ]]; then
        [[ -f $ENGINE/.anland-engine-policy && $(cat "$ENGINE/.anland-engine-policy") == "$identity" ]] ||
            die 'unrecognized engine output preserved; use a separate WORKDIR rather than overwrite it'
    fi
    log 'Build locked Flutter release engine and AOT tools (Impeller+Ganesh/Vulkan/no-LTO/no-GTK)'
    # This pinned Flutter embedder still compiles the Ganesh Vulkan path. Slimpeller
    # removes ContextType/context options and Ganesh symbols, so keep Ganesh enabled
    # rather than disabling Vulkan or rewriting the locked upstream checkout.
    # Keep this a simple command: an OR-list would disable errexit in its isolated subshell.
    prepare_engine_sources
    rc=$?
    [[ $rc == 0 ]] || die "engine source synchronization failed: rc=$rc"
    run mkdir -p "$ENGINE"
    printf '%s\n' "$identity" > "$ENGINE/.anland-engine-policy" || die 'cannot write engine preparation identity'
    in_dir "$generated_source" env PATH="$checkout_depot/.cipd_bin:$checkout_depot:$PATH" \
        DEPOT_TOOLS_UPDATE=0 VPYTHON_VIRTUALENV_ROOT="$WORKDIR/engine/vpython" \
        ./flutter/tools/gn --linux --linux-cpu=arm64 --runtime-mode=release --enable-fontconfig \
        --no-lto --disable-desktop-embeddings --gn-args=shell_enable_vulkan=true \
        --gn-args=test_enable_vulkan=false --gn-args=skia_use_vulkan=true \
        --gn-args=slimpeller=false --gn-args=skia_enable_ganesh=true --gn-args=skia_enable_graphite=false \
        --out-dir="$engine_build" --target-dir="$target"
    for policy in enable_lto:false enable_desktop_embeddings:false shell_enable_vulkan:true skia_use_vulkan:true \
                  test_enable_vulkan:false slimpeller:false skia_enable_ganesh:true skia_enable_graphite:false host_cpu:arm64; do
        expected=${policy#*:}
        actual=$(awk -v key="${policy%%:*}" '$1 == key && $2 == "=" {value=$3} END {gsub(/"/, "", value); print value}' "$ENGINE/args.gn") ||
            die 'cannot read generated engine configuration'
        [[ $actual == "$expected" ]] || die "engine configuration differs: $policy (actual=$actual)"
    done
    in_dir "$generated_source" env PATH="$checkout_depot/.cipd_bin:$checkout_depot:$PATH" \
        DEPOT_TOOLS_UPDATE=0 VPYTHON_VIRTUALENV_ROOT="$WORKDIR/engine/vpython" \
        ./flutter/third_party/gn/gn gen --check "$ENGINE"
    run env PATH="$checkout_depot/.cipd_bin:$checkout_depot:$PATH" DEPOT_TOOLS_UPDATE=0 \
        VPYTHON_VIRTUALENV_ROOT="$WORKDIR/engine/vpython" "$native_ninja" -C "$ENGINE" -j "$JOBS" \
        libflutter_engine.so dart_sdk flutter/sky/packages/sky_engine:sky_engine \
        flutter_patched_sdk/platform_strong.dill gen_snapshot \
        flutter/tools/const_finder:const_finder flutter/tools/font_subset:font_subset flutter/impeller/compiler:impellerc
    engine_inputs_ready "$ENGINE" || die 'incomplete newly built engine/SDK'
    verify_engine_symbols
    check_elf "$ENGINE/libflutter_engine.so"
    ENGINE_SHA256=$(sha256sum "$ENGINE/libflutter_engine.so" | awk '{print $1}') || die 'cannot hash engine'
    ENGINE_ICU_SHA256=$(sha256sum "$ENGINE/icudtl.dat" | awk '{print $1}') || die 'cannot hash engine ICU'
    ENGINE_VERSION="$FLUTTER_VERSION.r1.g${FLUTTER_REV:0:12}.vknolto.ganesh.h${ENGINE_SHA256:0:12}-1"
    DENIAL_ENGINE_POLICY='Impeller + Ganesh GLES/Vulkan, no-LTO, no-GTK'
    # New policy uses a new package identity, never the locked legacy hash/version.
    in_dir "$ENGINE" sha256sum libflutter_engine.so icudtl.dat args.gn dart-sdk/bin/dart gen_snapshot font-subset impellerc \
        gen/dart-pkg/sky_engine/pubspec.yaml flutter_patched_sdk/platform_strong.dill gen/const_finder.dart.snapshot \
        > "$ENGINE/.anland-engine.SHA256SUMS" || die 'cannot record engine/tool checksums'
    run jq -n --arg identity "$identity" --arg policy "$ENGINE_POLICY" --arg version "$ENGINE_VERSION" \
        --arg engine "$ENGINE_SHA256" --arg icu "$ENGINE_ICU_SHA256" --arg flutter "$FLUTTER_REV" \
        '{schema:1, identity:$identity, policy:$policy, package_version:$version, engine_sha256:$engine, icu_sha256:$icu, flutter_revision:$flutter}' \
        > "$ENGINE/.anland-engine.json" || die 'cannot record engine provenance'
    engine_receipt_ready "$ENGINE" || die 'new engine cache failed verification'
}
prepare_engine() {
    local lock="$SOURCE/prebuilt/flutter-engine/SOURCE_LOCK.json"
    local generated="$WORKDIR/engine/build/out/denial_host_release_arm64_anland_ganesh"
    jq -e --arg flutter "$FLUTTER_REV" --arg repository "$FLUTTER_URL" \
        '.schema_version == 1 and .flutter.revision == $flutter and .flutter.repository == $repository
         and (.skia.revision | test("^[0-9a-f]{40}$"))
         and (.depot_tools.revision | test("^[0-9a-f]{40}$"))' "$lock" >/dev/null || die 'invalid engine source lock'
    git -C "$SOURCE" show "$DENIAL_REV:prebuilt/flutter-engine/SOURCE_LOCK.json" | cmp -s - "$lock" ||
        die 'modified engine source lock preserved; refusing to build unspecified sources'
    run mkdir -p "$WORKDIR/engine"
    exec 7>"$WORKDIR/engine/build.lock" || die 'cannot open engine cache lock'
    flock -n 7 || die 'another builder owns the engine cache'
    if [[ $ANLAND_ENGINE_MODE == build ]]; then
        [[ -z ${DENIAL_ENGINE_DIR:-} || $ENGINE == "$generated" ]] ||
            die 'build mode cannot overwrite a prepared engine override; unset DENIAL_ENGINE_DIR'
        ENGINE=$generated
        build_flutter_engine
    else
        if [[ -z ${DENIAL_ENGINE_DIR:-} && -f $generated/.anland-engine.json ]]; then ENGINE=$generated; fi
        if engine_receipt_ready "$ENGINE"; then
            log 'Reuse verified engine/SDK build receipt'
            use_engine_receipt
        elif legacy_engine_ready "$ENGINE"; then
            log 'Reuse exact legacy GLES/LTO engine from dependencies.lock'
            ENGINE_VERSION=$LOCKED_ENGINE_VERSION
            ENGINE_SHA256=$LOCKED_ENGINE_SHA256
            ENGINE_ICU_SHA256=$LOCKED_ENGINE_ICU_SHA256
            DENIAL_ENGINE_POLICY='Slimpeller GLES-only, LTO (locked legacy cache)'
        else
            [[ $ANLAND_ENGINE_MODE != prepared ]] || die 'prepared engine/SDK absent or invalid; prepared mode never builds it'
            [[ -z ${DENIAL_ENGINE_DIR:-} ]] || die 'unverified engine override preserved; unset DENIAL_ENGINE_DIR to build'
            [[ ! -f $ENGINE/libflutter_engine.so || -f $ENGINE/.anland-engine-policy ]] ||
                die 'unrecognized engine preserved; use build mode for a separate output'
            ENGINE=$generated
            build_flutter_engine
        fi
    fi
    verify_engine_symbols
    # package_all records the selected engine identity in cached inputs only.
}

prepare_flutter_tools() {
    local adapter_identity
    adapter_identity=$(declare -f prepare_flutter_tools | sha256sum | awk '{print $1}') || die 'cannot identify Flutter tool adapter'
    run python3 - --flutter-root "$FLUTTER" \
        --flutter-revision "$FLUTTER_REV" --plugin-kit-script "$SOURCE/tools/prepare-denial-plugin-kit" \
        --output "$FLUTTER_EMBEDDER" --adapter-identity "$adapter_identity" <<'PY'
"""Prepare managed Flutter tool inputs for Denial's non-GTK Linux embedder.

Keep the locked checkout untouched. Only omit desktop runner unpacking: Linux
AOT, asset/shader/font processing and native asset hooks remain upstream targets.
The plugin build kit vendors the same adapted tool sources.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from urllib.parse import urljoin


def digest(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new, label):
    if text.count(old) != 1:
        raise SystemExit(f'unsupported locked {label}; expected exactly one adapter point')
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-root', type=Path, required=True)
    parser.add_argument('--flutter-revision', required=True)
    parser.add_argument('--plugin-kit-script', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--adapter-identity', required=True)
    args = parser.parse_args()
    flutter = args.flutter_root.absolute()
    output = args.output.absolute()
    if (output.is_symlink() or output.resolve().is_relative_to(flutter.resolve()) or
            flutter.resolve().is_relative_to(output.resolve())):
        parser.error('output must be separate from the Flutter checkout')
    tool = flutter / 'packages/flutter_tools'
    config_path = tool / '.dart_tool/package_config.json'
    config_bytes = config_path.read_bytes()
    linux_source = (tool / 'lib/src/build_system/targets/linux.dart').read_text()
    linux = replace_once(
        linux_source, '    UnpackLinux(targetPlatform),',
        '    // Denial supplies its own embedder; do not unpack the GTK runner.',
        'Linux bundle dependency graph')
    kit_source = args.plugin_kit_script.read_text()
    kit = replace_once(
        kit_source,
        "'flutter_patched_sdk', 'flutter_linux', 'libflutter_linux_gtk.so',",
        "'flutter_patched_sdk',", 'plugin kit engine artifact list')
    config = json.loads(config_bytes)
    for package in config['packages']:
        package['rootUri'] = ('../' if package['name'] == 'flutter_tools' else
                              urljoin(config_path.as_uri(), package['rootUri']))
    config.pop('flutterRoot', None)
    config.pop('pubCache', None)
    config_text = json.dumps(config, indent=2) + '\n'
    marker = {
        'schema': 1, 'policy': 'linux-embedder-assets-no-gtk-v1',
        'flutter_root': str(flutter), 'flutter_revision': args.flutter_revision,
        'helper_sha256': args.adapter_identity,
        'source_linux_sha256': digest(linux_source.encode()),
        'source_config_sha256': digest(config_bytes),
        'source_kit_sha256': digest(kit_source.encode()),
    }
    generated = {
        'packages/flutter_tools/lib/src/build_system/targets/linux.dart': linux,
        'packages/flutter_tools/.dart_tool/package_config.json': config_text,
        'prepare-denial-plugin-kit': kit,
    }
    tool_paths = ['bin', 'lib', 'templates', 'static', 'pubspec.yaml', 'pubspec.lock', 'LICENSE']
    copied = {}
    for name in tool_paths:
        source = tool / name
        files = sorted(source.rglob('*')) if source.is_dir() else [source]
        for file in files:
            if file.is_file():
                copied['packages/flutter_tools/' + file.relative_to(tool).as_posix()] = digest(file.read_bytes())
    # Detect missing or modified copied files too, not just the two adapter points.
    marker['generated_sha256'] = {
        **copied, **{name: digest(text.encode()) for name, text in generated.items()},
    }
    receipt = output / '.anland-embedder-tools.json'
    if output.exists():
        if not receipt.is_file():
            parser.error(f'unmanaged output preserved: {output}')
        previous = json.loads(receipt.read_text())
        if previous.get('schema') != 1 or previous.get('policy') != marker['policy']:
            parser.error(f'unrecognized managed output preserved: {output}')
        if previous == marker and all(
                (output / name).is_file() and
                digest((output / name).read_bytes()) == expected
                for name, expected in marker['generated_sha256'].items()):
            print(f'Reuse verified non-GTK Flutter tool adapter: {output}')
            return
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for source in flutter.iterdir():
        if source.name != 'packages':
            (output / source.name).symlink_to(source, target_is_directory=source.is_dir())
    packages = output / 'packages'
    packages.mkdir()
    for source in (flutter / 'packages').iterdir():
        if source.name != 'flutter_tools':
            (packages / source.name).symlink_to(source, target_is_directory=source.is_dir())
    target_tool = packages / 'flutter_tools'
    target_tool.mkdir()
    for name in tool_paths:
        source = tool / name
        destination = target_tool / name
        if source.is_dir():
            shutil.copytree(source, destination)
        elif source.is_file():
            shutil.copy2(source, destination)
    for name, text in generated.items():
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)
    receipt.write_text(json.dumps(marker, indent=2) + '\n')
    print(f'Prepared non-GTK Flutter tools and plugin-kit adapter: {output}')


if __name__ == '__main__':
    main()
PY
}

prepare_flutter() {
    log 'Configure the verified engine/SDK for Denial AOT'
    checkout "$FLUTTER" "$FLUTTER_URL" "$FLUTTER_REV"
    check_sha "$ENGINE_SHA256" "$ENGINE/libflutter_engine.so"
    check_sha "$ENGINE_ICU_SHA256" "$ENGINE/icudtl.dat"
    local file cache="$FLUTTER/bin/cache" tool="$FLUTTER/packages/flutter_tools" engine_revision
    local adapter_identity
    FLUTTER_EMBEDDER="$WORKDIR/engine/flutter-embedder-sdk"
    local tool_identity="$FLUTTER_REV:$ENGINE_SHA256:$ENGINE_ICU_SHA256:${ENGINE##*/}"
    for file in dart-sdk/bin/dart gen_snapshot font-subset impellerc; do
        [[ -x $ENGINE/$file ]] || die "prepared engine tool missing: $ENGINE/$file"
    done
    for file in icudtl.dat gen/dart-pkg/sky_engine/pubspec.yaml flutter_patched_sdk/platform_strong.dill gen/const_finder.dart.snapshot; do
        [[ -f $ENGINE/$file ]] || die "prepared engine input missing: $ENGINE/$file"
    done
    run mkdir -p "$cache/pkg"
    link_cache "$ENGINE/dart-sdk" "$cache/dart-sdk"
    link_cache "$ENGINE/gen/dart-pkg/sky_engine" "$cache/pkg/sky_engine"
    engine_revision=$(cat "$FLUTTER/bin/internal/engine.version") || die 'missing Flutter engine revision'
    for file in engine.stamp engine-dart-sdk.stamp; do
        printf '%s\n' "$engine_revision" > "$cache/$file" || die 'cannot write SDK stamp'
    done
    printf '\n' > "$cache/engine.realm" || die 'cannot write engine realm'
    local_engine=("--local-engine-src-path=$(dirname -- "$(dirname -- "$ENGINE")")"
                  "--local-engine=${ENGINE##*/}" "--local-engine-host=${ENGINE##*/}")
    flutter=("$ENGINE/dart-sdk/bin/dart" "$cache/flutter_tools.snapshot" "${local_engine[@]}" --no-version-check --suppress-analytics)
    if [[ ! -s $tool/.dart_tool/package_config.json || ! -f $cache/flutter_tools.stamp ]] ||
       [[ $(cat "$cache/flutter_tools.stamp") != "$FLUTTER_REV:" ]]; then
        local locked=()
        [[ ! -f $tool/pubspec.lock ]] || locked=(--enforce-lockfile)
        in_dir "$tool" "$ENGINE/dart-sdk/bin/dart" pub get "${network[@]}" "${locked[@]}"
    fi
    # Validate every adapted/copied tool input even when an old snapshot exists.
    # Linux bundle assets need AOT + hooks, not the optional GTK desktop runner.
    prepare_flutter_tools
    adapter_identity=$(sha256sum "$FLUTTER_EMBEDDER/.anland-embedder-tools.json" | awk '{print $1}') || die 'cannot identify prepared Flutter tool inputs'
    tool_identity+=":$adapter_identity"
    if [[ ! -f $cache/flutter_tools.snapshot || ! -f $cache/flutter_tools.stamp || ! -f $cache/.anland-flutter-tools.identity ]] ||
       [[ $(cat "$cache/flutter_tools.stamp") != "$FLUTTER_REV:" ]] ||
       [[ $(cat "$cache/.anland-flutter-tools.identity") != "$tool_identity" ]]; then
        in_dir "$FLUTTER" "$ENGINE/dart-sdk/bin/dart" --verbosity=error \
            "--snapshot=$cache/flutter_tools.snapshot" --snapshot-kind=app-jit \
            "--packages=$FLUTTER_EMBEDDER/packages/flutter_tools/.dart_tool/package_config.json" --no-enable-mirrors \
            "$FLUTTER_EMBEDDER/packages/flutter_tools/bin/flutter_tools.dart" "${local_engine[@]}" --no-version-check --suppress-analytics --help
        printf '%s:\n' "$FLUTTER_REV" > "$cache/flutter_tools.stamp" || die 'cannot write Flutter stamp'
        printf '%s\n' "$tool_identity" > "$cache/.anland-flutter-tools.identity" || die 'cannot record Flutter tool inputs'
    fi
    if [[ ! -f $cache/flutter.version.json ]]; then
        in_dir "$FLUTTER" "${flutter[@]}" --version --machine > "$cache/flutter.version.json" || die 'Flutter version failed'
    fi
    # The fork declares 3.47.5 even when the Git checkout has no release tag.
    run jq --arg version "$FLUTTER_VERSION" --arg revision "$FLUTTER_REV" \
        '.frameworkVersion=$version | .flutterVersion=$version | .frameworkRevision=$revision' \
        "$cache/flutter.version.json" > "$cache/flutter.version.json.new"
    run mv "$cache/flutter.version.json.new" "$cache/flutter.version.json"
}
fetch_dependencies() {
    log 'Fetch Cargo and Pub dependencies using their upstream lockfiles'
    local manifest app
    local manifests=(compositor) apps=(packages/denial_flutter_sdk dart_shell)
    if [[ $ANLAND_WITH_DE == 1 ]]; then
        manifests+=(native_app)
        apps+=(plugins/denial_desktop settings_app polkit_app packages/denial_sdk packages/denial_plugin_manager plugin_manager_app)
    fi
    for manifest in "${manifests[@]}"; do
        run cargo fetch --manifest-path "$SOURCE/$manifest/Cargo.toml" --locked --target aarch64-unknown-linux-gnu "${network[@]}"
    done
    for app in "${apps[@]}"; do
        in_dir "$SOURCE/$app" "${flutter[@]}" pub get --enforce-lockfile "${network[@]}"
    done
}
check_elf() {
    local file=$1 dynamic deps
    readelf -h "$file" | grep -q 'Machine:.*AArch64' || die "not AArch64 ELF: $file"
    dynamic=$(readelf -d "$file") || die "cannot inspect ELF: $file"
    if grep -E '(RPATH|RUNPATH)' <<< "$dynamic" | grep -Eq '/(home|data|cache)/'; then
        die "build path in runtime search: $file"
    fi
    # Dart AOT snapshots have no DT_NEEDED and need not pass ldd.
    if [[ $dynamic == *'(NEEDED)'* ]]; then
        deps=$(env -u LD_LIBRARY_PATH ldd "$file") || die "ldd failed: $file"
        [[ $deps != *'not found'* ]] || die "missing runtime library: $file: $deps"
    fi
}
build_native() {
    log 'Build public library, C bridge and Rust compositor'
    run cmake -S "$PUBLIC/producers/denial/anland_backend" -B "$BUILD/bridge" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib '-DCMAKE_INSTALL_RPATH=$ORIGIN'
    run cmake --build "$BUILD/bridge" --parallel "$JOBS"
    run env DESTDIR="$BUILD/native" cmake --install "$BUILD/bridge"
    run cargo build --manifest-path "$SOURCE/compositor/Cargo.toml" --release --locked --offline \
        --jobs "$JOBS" --features anland --bin deniald --bin denialctl
}
build_aot() {
    local app=$1
    log "Build Flutter AOT: $app"
    in_dir "$SOURCE/$app" "${flutter[@]}" assemble "--resource-pool-size=$JOBS" "--output=$BUILD/$app" \
        -dTargetFile=lib/main.dart -dBuildMode=release -dTargetPlatform=linux-arm64 \
        -dDartObfuscation=false -dTrackWidgetCreation=true -dTreeShakeIcons=true release_bundle_linux-arm64_assets
    [[ -d $BUILD/$app/flutter_assets && -f $BUILD/$app/lib/libapp.so ]] || die "incomplete AOT bundle: $app"
    check_elf "$BUILD/$app/lib/libapp.so"
}
build_desktop() {
    log 'Build native app runner, Polkit, portal and Plugin Manager'
    run cargo build --manifest-path "$SOURCE/native_app/Cargo.toml" --release --locked --offline --jobs "$JOBS"
    run cargo build --manifest-path "$SOURCE/compositor/Cargo.toml" --release --locked --offline --jobs "$JOBS" \
        -p denial -p denial-polkit-agent -p denial-portal --features anland --bin denial-polkit-agent --bin denial-portal
    local app name input="$BUILD/kit-input" release="$BUILD/kit-input/prebuilt/flutter-engine/linux-arm64-release"
    for app in settings_app polkit_app plugin_manager_app; do build_aot "$app"; done
    in_dir "$SOURCE/packages/denial_plugin_manager" "$ENGINE/dart-sdk/bin/dart" compile exe \
        bin/denial_plugins.dart "--output=$BUILD/denial-plugins"
    # Upstream's runtime build-kit format is generated, not a hand-maintained source lock.
    run rm -rf -- "$input" "$BUILD/plugin-build-kit"
    run mkdir -p "$release"
    for name in packages plugins protocol LICENSE compositor; do run ln -s "$SOURCE/$name" "$input/$name"; done
    run cp "$SOURCE/prebuilt/flutter-engine/SOURCE_LOCK.json" "$input/prebuilt/flutter-engine/"
    printf '%s  libflutter_engine.so\n' "$ENGINE_SHA256" > "$release/libflutter_engine.so.sha256" || die 'engine metadata failed'
    for name in LICENSE.flutter LICENSE.third_party; do
        run install -m644 "$SOURCE/prebuilt/flutter-engine/linux-x64-release/$name" "$release/$name"
    done
    # The relocatable plugin tool must use the same no-GTK asset target.
    run python3 "$FLUTTER_EMBEDDER/prepare-denial-plugin-kit" --source-root "$input" --source-revision "$DENIAL_REV" \
        --flutter-root "$FLUTTER_EMBEDDER" --flutter-revision "$FLUTTER_REV" --engine-root "$(dirname -- "$(dirname -- "$ENGINE")")" \
        --engine-source-root "$FLUTTER/engine" --engine-target "${ENGINE##*/}" --platform linux-arm64 --output "$BUILD/plugin-build-kit"
}
prepare_signing() {
    # Signing identity belongs to this machine/user, not a disposable build cache.
    local keyhome="${XDG_DATA_HOME:-$HOME/.local/share}/denial-anland/signing"
    local uid='Denial Anland local package signing <denial-local@localhost>'
    [[ ! -L $keyhome ]] || die 'signing key directory must not be a symlink'
    run install -dm700 "$keyhome"
    gpg=(gpg --no-options --homedir "$keyhome" --batch --yes)
    if ! "${gpg[@]}" --list-secret-keys "$uid" >/dev/null 2>&1; then
        log 'Create persistent local signing key (not an upstream release key)'
        run "${gpg[@]}" --pinentry-mode loopback --passphrase '' --quick-generate-key "$uid" ed25519 sign 0
    fi
    signing_fingerprint=$("${gpg[@]}" --with-colons --list-secret-keys "$uid" | awk -F: '$1 == "fpr" {print $10; exit}') || die 'cannot read signing key'
    [[ $signing_fingerprint =~ ^[0-9A-F]{40}$ ]] || die 'invalid local signing fingerprint'
    run "${gpg[@]}" --armor --output "$ARTIFACTS_DIR/denial-local-signing-key.asc" --export "$signing_fingerprint"
    log "Local signing key: $signing_fingerprint"
}
sign_file() (
    local file=$1 temporary
    temporary=$(mktemp "$file.sig.XXXXXX") || die "cannot stage signature: $file"
    trap 'rm -f -- "$temporary"' EXIT
    run "${gpg[@]}" --local-user "$signing_fingerprint" --detach-sign --output "$temporary" -- "$file"
    run "${gpg[@]}" --verify "$temporary" "$file"
    run chmod 644 "$temporary"
    run mv -f -- "$temporary" "$file.sig"
)
publish_build_metadata() {
    local package source_commit build_time
    source_commit=$(git -C "$ROOT" rev-parse HEAD) || die 'cannot identify Anland source commit'
    build_time=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || die 'cannot identify build time'
    : > "$ARTIFACTS_DIR/packages.list" || die 'cannot write package list'
    for package in "${packages[@]}"; do
        printf '%s\n' "${package##*/}" >> "$ARTIFACTS_DIR/packages.list" || die 'cannot record package name'
    done
    {
        printf 'format=1\ntarget=arch\narchitecture=aarch64\nsource_commit=%s\ndenial_commit=%s\nflutter_commit=%s\n' "$source_commit" "$DENIAL_REV" "$FLUTTER_REV"
        printf 'denial_version=%s\nengine_version=%s\nengine_sha256=%s\nengine_icu_sha256=%s\n' "$DENIAL_VERSION" "$ENGINE_VERSION" "$ENGINE_SHA256" "$ENGINE_ICU_SHA256"
        printf 'with_desktop=%s\nbuild_time=%s\npackage_list=packages.list\n' "$ANLAND_WITH_DE" "$build_time"
    } > "$ARTIFACTS_DIR/manifest.env" || die 'cannot write build manifest'
    printf '%s\n' "${DENIAL_VERSION//-/.}" > "$WORKDIR/.denial-version" || die 'cannot record workflow version'
    sign_file "$ARTIFACTS_DIR/packages.list" || die 'cannot sign package list'
    sign_file "$ARTIFACTS_DIR/manifest.env" || die 'cannot sign build manifest'
}

# Same pinned recipe and kgsl/turnip fixes as producers/kde/Arch_v5.
build_xwayland() {
    log 'Build patched Xwayland 24.1.13 (no installation)'
    local stage="$WORKDIR/xwayland-package" sources="$WORKDIR/xwayland-sources"
    local tarball=${XWAYLAND_TARBALL:-} candidate package
    run mkdir -p "$stage" "$sources"
    run install -m644 "$SCRIPT_DIR/xorg-xwayland.PKGBUILD" "$stage/PKGBUILD"
    run install -m644 "${XWAYLAND_PATCH:-$SCRIPT_DIR/xwayland.patch}" "$stage/xwayland.patch"
    if [[ -z $tarball ]]; then
        for candidate in "$SCRIPT_DIR/../xwayland-24.1.13.tar.xz" "$SCRIPT_DIR/xwayland-24.1.13.tar.xz"; do
            [[ ! -f $candidate ]] || { tarball=$candidate; break; }
        done
    fi
    if [[ -n $tarball ]]; then
        [[ -f $tarball ]] || die "XWAYLAND_TARBALL not found: $tarball"
        run install -m644 "$tarball" "$sources/xwayland-24.1.13.tar.xz"
    fi
    [[ $ANLAND_OFFLINE == 0 || -f $sources/xwayland-24.1.13.tar.xz ]] ||
        die 'offline Xwayland source missing (set XWAYLAND_TARBALL)'
    in_dir "$stage" env SRCDEST="$sources" BUILDDIR="$WORKDIR/xwayland-build" JOBS="$JOBS" \
        makepkg --nodeps --force --cleanbuild --noconfirm --nosign
    package=$(in_dir "$stage" makepkg --packagelist) || die 'cannot obtain Xwayland package path'
    [[ -s $package ]] || die "Xwayland package not produced: $package"
    run rm -f -- "$package.sig"
    packages+=("$package")
}

package_all() {
    log 'Build Arch packages (no installation)'
    local pack="$WORKDIR/package" kind package file runtime app
    local package_version=${DENIAL_VERSION//-/.}

    local kinds=(engine wm) packages=()
    [[ $ANLAND_WITH_DE == 0 ]] || kinds+=(de)
    run mkdir -p "$pack"
    run cp "$SCRIPT_DIR/PKGBUILD" "$SCRIPT_DIR/dependencies.lock" "$SCRIPT_DIR/startup.sh" "$pack/"
    # Keep repository packaging files unchanged; specialize this build's cached copy.
    {
        printf '\n# Verified engine selected by build.sh.\n'
        printf 'ENGINE_VERSION=%q\nENGINE_SHA256=%q\nENGINE_ICU_SHA256=%q\n' \
            "$ENGINE_VERSION" "$ENGINE_SHA256" "$ENGINE_ICU_SHA256"
    } >> "$pack/dependencies.lock" || die 'cannot record cached engine identity'
    printf '\n[[ $_kind != engine ]] || pkgdesc=%q\n' \
        "Denial private ARM64 Flutter embedder engine ($DENIAL_ENGINE_POLICY)" \
        >> "$pack/PKGBUILD" || die 'cannot record cached engine description'
    export DENIAL_SOURCE_TREE="$SOURCE" DENIAL_BUILD_DIR="$BUILD" DENIAL_ENGINE_DIR="$ENGINE"
    export PKGDEST="$ARTIFACTS_DIR" BUILDDIR="$pack/build" PKGEXT=.pkg.tar.xz XZ_OPT="-T$JOBS"
    build_xwayland
    for kind in "${kinds[@]}"; do
        export DENIAL_PACKAGE_KIND=$kind
        # Sign all verified outputs together with the local build identity.
        in_dir "$pack" makepkg --nodeps --force --noconfirm --nosign
        package=$(in_dir "$pack" makepkg --packagelist) || die 'cannot obtain package path'
        [[ -f $package ]] || die "package not produced: $package"
        run rm -f -- "$package.sig" # An old signature cannot authenticate rebuilt bytes.
        packages+=("$package")
    done
    log 'Check packaged files, runtime links and help/bundle commands; no graphical session'
    run rm -rf -- "$BUILD/package-check"
    run mkdir -p "$BUILD/package-check"
    for package in "${packages[@]}"; do
        bsdtar -xOf "$package" .PKGINFO | grep -qx 'arch = aarch64' || die "wrong package architecture: $package"
        local info
        info=$(bsdtar -xOf "$package" .PKGINFO) || die "cannot read package metadata: $package"
        case ${package##*/} in
            denial-anland-engine-*)
                grep -qx 'pkgname = denial-anland-engine' <<< "$info" || die 'wrong engine package name'
                grep -qx "pkgver = $ENGINE_VERSION" <<< "$info" || die 'wrong engine package version' ;;
            denial-"$package_version"-*)
                grep -qx 'pkgname = denial' <<< "$info" || die 'wrong WM package name'
                grep -qx "pkgver = $package_version-$ANLAND_PKGREL" <<< "$info" || die 'wrong WM package version'
                grep -qx "depend = denial-anland-engine=$ENGINE_VERSION" <<< "$info" || die 'wrong WM/engine dependency' ;;
            denial-desktop-"$package_version"-*)
                grep -qx 'pkgname = denial-desktop' <<< "$info" || die 'wrong desktop package name'
                grep -qx "pkgver = $package_version-$ANLAND_DE_PKGREL" <<< "$info" || die 'wrong desktop version'
                grep -qx "depend = denial=$package_version-$ANLAND_PKGREL" <<< "$info" || die 'wrong desktop/WM version dependency'
                grep -qx "depend = denial-anland-engine=$ENGINE_VERSION" <<< "$info" || die 'wrong desktop/engine dependency' ;;
        esac
        run bsdtar -xf "$package" -C "$BUILD/package-check"
    done
    runtime="$BUILD/package-check/usr/lib/denial-anland"
    check_sha "$ENGINE_SHA256" "$runtime/flutter/lib/libflutter_engine.so"
    check_sha "$ENGINE_ICU_SHA256" "$runtime/flutter/data/icudtl.dat"
    check_elf "$runtime/flutter/lib/libflutter_engine.so"
    for file in "$runtime/wm/deniald" "$runtime/wm/denialctl" "$runtime/wm/"*.so "$runtime/wm/shell/lib/"*.so; do check_elf "$file"; done
    run env -u LD_LIBRARY_PATH "$runtime/wm/deniald" --help
    local reported
    reported=$(env -u LD_LIBRARY_PATH "$runtime/wm/deniald" --version) || die 'version inspection failed'
    [[ $reported == *"$DENIAL_VERSION"* ]] || die "stale runtime version: $reported"
    [[ $(cat "$BUILD/package-check/usr/share/denial/version") == "$DENIAL_VERSION" ]] || die 'wrong release identity file'
    run "$BUILD/package-check/usr/bin/denial" --help
    run "$BUILD/package-check/usr/bin/denial" --version
    if [[ $ANLAND_WITH_DE == 1 ]]; then
        for file in "$runtime/desktop/native/"*; do [[ $file == *.json ]] || check_elf "$file"; done
        for app in settings:denial-settings polkit:denial-app plugins:denial-plugin-manager; do
            check_elf "$runtime/desktop/${app%%:*}/lib/libapp.so"
            run "$runtime/desktop/${app%%:*}/${app#*:}" --bundle "$runtime/desktop/${app%%:*}" \
                --engine "$runtime/flutter/lib/libflutter_engine.so" --check
        done
        run "$runtime/desktop/settings/denial-settings" --welcome --check
        run "$runtime/desktop/native/denial-plugins" --help
        for file in usr/lib/systemd/user/denial-session.target usr/lib/systemd/user/denial-polkit-agent.service \
            usr/lib/systemd/user/denial-portal.service usr/share/xdg-desktop-portal/portals/denial.portal \
            usr/share/xdg-desktop-portal/denial-portals.conf \
            usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.denial.service \
            usr/share/wayland-sessions/denial.desktop; do
            [[ -r $BUILD/package-check/$file ]] || die "missing desktop integration: $file"
        done
    fi
    publish_build_metadata
    log 'Sign all packages and checksum manifest'
    local checksums=(denial-local-signing-key.asc packages.list packages.list.sig manifest.env manifest.env.sig)
    for package in "${packages[@]}"; do
        sign_file "$package" || die "cannot sign package: $package"
        checksums+=("${package##*/}" "${package##*/}.sig")
    done
    run rm -f -- "$ARTIFACTS_DIR/SHA256SUMS.sig"
    in_dir "$ARTIFACTS_DIR" sha256sum "${checksums[@]}" > "$ARTIFACTS_DIR/SHA256SUMS"
    in_dir "$ARTIFACTS_DIR" sha256sum -c SHA256SUMS
    sign_file "$ARTIFACTS_DIR/SHA256SUMS" || die 'cannot sign checksum manifest'
    if [[ $ANLAND_INSTALL == 1 ]]; then
        log "Trust this local build key in pacman: $signing_fingerprint"
        run sudo pacman-key --init
        run sudo pacman-key --add "$ARTIFACTS_DIR/denial-local-signing-key.asc"
        run sudo pacman-key --lsign-key "$signing_fingerprint"
        run sudo pacman -U --needed "${packages[@]}"
    else
        printf 'First use on another machine: sudo pacman-key --add %q && sudo pacman-key --lsign-key %q\n' \
            "$ARTIFACTS_DIR/denial-local-signing-key.asc" "$signing_fingerprint"
    fi
    log "Done. Signed packages: $ARTIFACTS_DIR (DE=$ANLAND_WITH_DE, installed=$ANLAND_INSTALL; no graphical test)"
}

# Declare host tools and runtime libraries explicitly: prepared-engine builds
# also need archive tools, and deniald dlopens libpulse.so.0 for audio controls.
build_deps=(base-devel cmake ninja rust python git curl jq pkgconf binutils libarchive gnupg dbus
            bash coreutils util-linux procps-ng ca-certificates glibc gcc-libs tar unzip zip xz zlib
            libpipewire libpulse libglvnd mesa libdrm libinput seatd libxkbcommon xkeyboard-config
            systemd-libs pam polkit fontconfig freetype2 wayland)
# Dependencies of the KDE Arch Xwayland recipe (makepkg does not install them).
build_deps+=(meson xorgproto xtrans libxkbfile xorg-font-util wayland-protocols mesa-libgl systemd
             nettle libepoxy libxfont2 pixman xorg-server-common libxcvt libxau libtirpc libei libxshmfence libdecor)
# Clean ARM64 CI workers can build missing engine inputs from pinned sources.
[[ $ANLAND_ENGINE_MODE == prepared ]] || build_deps+=(clang lld llvm glib2 libunwind libffi)
# Keep full-desktop packages' external dependencies available on clean workers;
# installing them never implies enabling/restarting any desktop service.
if [[ $ANLAND_WITH_DE == 1 ]]; then
    build_deps+=(xdg-utils zenity xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-wlr)
fi
if [[ $ANLAND_WITH_DEPS == 1 ]]; then
    [[ $ANLAND_OFFLINE == 0 ]] || die 'dependency installation conflicts with ANLAND_OFFLINE=1'
    run sudo pacman -S --needed --noconfirm "${build_deps[@]}"
fi
missing=$(pacman -T "${build_deps[@]}") || die "missing dependencies: $missing (use ANLAND_WITH_DEPS=1)"
prepare_signing
prepare_sources
prepare_engine
prepare_flutter
fetch_dependencies
build_native
build_aot dart_shell
if [[ $ANLAND_WITH_DE == 1 ]]; then build_desktop; fi
package_all
