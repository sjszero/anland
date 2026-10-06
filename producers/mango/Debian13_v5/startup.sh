#!/usr/bin/env bash
# Foreground Mango session; never stops another WM or changes services.
# Usage: ./startup.sh [--check|--version|--help]
set -uo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
if [[ -f "$HERE/mango" && -x "$HERE/mango" ]]; then
    PREFIX=$(cd -- "$HERE/.." && pwd -P)
else
    PREFIX=${MANGO_PREFIX:-${WORKDIR:-${MANGO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/anland-mango}}/prefix}
fi
die() { printf 'mango-start: %s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || die 'usage: startup.sh [--check|--version|--help]'
case "${1:-start}" in
    --help|-h) sed -n '2,3p' "$0"; exit 0 ;;
    start|run|--check|--version) ;;
    *) die 'usage: startup.sh [--check|--version|--help]' ;;
esac
[[ -x "$PREFIX/bin/mango" ]] || die "build output unavailable: $PREFIX"
export PATH="$PREFIX/bin:$PATH" LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ANLAND=1 ANLAND_SOCKET=${ANLAND_SOCKET:-/run/display.sock}
export ANLAND_DRM_DEVICE=${ANLAND_DRM_DEVICE:-/dev/dri/renderD128}
export WLR_RENDER_DRM_DEVICE=${WLR_RENDER_DRM_DEVICE:-$ANLAND_DRM_DEVICE}
export XWAYLAND_GBM_DEVICE=${XWAYLAND_GBM_DEVICE:-$ANLAND_DRM_DEVICE}
export ANLAND_SKIP_IMPLICIT_SYNC_WAIT=${ANLAND_SKIP_IMPLICIT_SYNC_WAIT:-1}
export MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-kgsl} GALLIUM_DRIVER=${GALLIUM_DRIVER:-kgsl}
export WLR_RENDERER_ALLOW_SOFTWARE=${WLR_RENDERER_ALLOW_SOFTWARE:-1}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export PULSE_SERVER=${PULSE_SERVER:-unix:$XDG_RUNTIME_DIR/pulse/native}
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=mango
export MANGO_ANLAND_MANAGE_SESSION=${MANGO_ANLAND_MANAGE_SESSION:-0}
[[ "$MANGO_ANLAND_MANAGE_SESSION" =~ ^[01]$ ]] || die 'MANGO_ANLAND_MANAGE_SESSION must be 0 or 1'
[[ "${1:-}" != --version ]] || exec "$PREFIX/bin/mango" -v
config=${MANGO_ANLAND_CONFIG:-$HOME/.config/mango/config.conf}
if [[ -z ${MANGO_ANLAND_CONFIG:-} && ! -f "$config" ]]; then
    if [[ "$PREFIX" == /usr/lib/mango-anland ]]; then config=/etc/mango-anland/config.conf;
    else config="$PREFIX/etc/mango/config.conf"; fi
fi
[[ -r "$config" ]] || die "configuration is not readable: $config"
[[ -d "$XDG_RUNTIME_DIR" && -w "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]] || die 'runtime directory must exist, be owned and writable'
if [[ "${1:-}" == --check ]]; then
    [[ -S "$ANLAND_SOCKET" && -r "$ANLAND_DRM_DEVICE" && -w "$ANLAND_DRM_DEVICE" ]] || die 'socket or DRM device unavailable'
    linkage=$(ldd "$PREFIX/bin/mango") || die 'ldd failed'
    printf '%s\n' "$linkage"
    [[ "$linkage" != *'not found'* ]] || die 'runtime library missing'
    printf 'MANGO_START_PREFLIGHT_OK (filesystem/link checks only, not a handshake)\n'
    exit 0
fi
for tool in flock pgrep; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
exec 9>"$XDG_RUNTIME_DIR/anland-producer-session.lock" || die "cannot open session lock"
flock -n 9 || die 'session is already running'
for name in kwin_wayland kwin_x11 gamescope gnome-shell niri Hyprland weston mango; do
    if pgrep -u "$(id -u)" -x "$name" >/dev/null; then die "existing $name session detected; explicitly exit it first"; fi
done
for ((attempt=0; attempt<60; attempt++)); do
    [[ ! -S "$ANLAND_SOCKET" || ! -e "$ANLAND_DRM_DEVICE" ]] || break
    sleep 0.5
done
[[ -S "$ANLAND_SOCKET" && -e "$ANLAND_DRM_DEVICE" ]] || die 'Anland socket or DRM device is unavailable'
args=(-c "$config")
case "${MANGO_ANLAND_PANEL:-auto}" in
    auto) if command -v mangobar >/dev/null; then args+=(-s 'while :; do mangobar; sleep 1; done'); fi ;;
    1) command -v mangobar >/dev/null || die 'explicitly requested mangobar is unavailable'; args+=(-s 'while :; do mangobar; sleep 1; done') ;;
    0) ;;
    *) die 'MANGO_ANLAND_PANEL must be auto, 0 or 1' ;;
esac
unset DISPLAY WAYLAND_DISPLAY
exec "$PREFIX/bin/mango" "${args[@]}"
