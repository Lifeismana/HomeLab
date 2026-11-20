#!/bin/bash

set -euo pipefail
shopt -s nullglob

cd "$(dirname "$(realpath "$0")")"

DRY_RUN=false
RSYNC_FLAGS=(-rci --delete --mkpath)
case "${1:-}" in
    -n|--dry-run) DRY_RUN=true; RSYNC_FLAGS+=(-n) ;;
    -h|--help)    echo "Usage: ${0##*/} [-n|--dry-run]"; exit 0 ;;
    "")           ;;
    *)            echo "Unknown option: $1" >&2; exit 1 ;;
esac

if ! $DRY_RUN && (( EUID != 0 )); then
    echo "This script must be run as root" >&2
    exit 1
fi

run_ctl() {
    local msg=$1; shift
    if $DRY_RUN; then echo "[dry-run] $msg"; return; fi
    echo "$msg"
    systemctl "$@"
}

ctl_if_any() {
    local msg=$1
    local -n _units=$2
    shift 2
    (( ${#_units[@]} == 0 )) && return 0
    run_ctl "$msg: ${_units[*]}" "$@" -- "${_units[@]}"
}

can_start() {
    local unit=$1
    if grep -Eiq '^\s*RefuseManualStart\s*=\s*(yes|y|true|t|1|on)\b' "./conf/systemd/$unit"; then
        echo "Skipping $unit (RefuseManualStart)"
        return 1
    fi
}

sync_dir() {
    rsync_out=$(rsync "${RSYNC_FLAGS[@]}" "$1" "$2")
    if $DRY_RUN && [[ -n "$rsync_out" ]]; then
        echo "$rsync_out"
    fi
}

echo "Validating quadlets"

if ! err=$(QUADLET_UNIT_DIRS="$PWD/podman" /usr/lib/systemd/system-generators/podman-system-generator -no-kmsg-log -dryrun 2>&1 >/dev/null); then
    grep -v 'Loading source ' <<< "$err" >&2 || echo "$err" >&2
    exit 1
fi


echo "Deploying configuration"
sync_dir ./conf/ /etc/secc/

echo "Deploying quadlets"
sync_dir ./podman/ /etc/containers/systemd/secc/

deleted=()
modified=()

while read -r action file; do
    [[ -z "$file" || "$file" != *.container ]] && continue
    unit="${file##*/}"
    unit="${unit%.container}.service"
    case "$action" in
        "*deleting") deleted+=("$unit") ;;
        ">f[^+]"*)   modified+=("$unit") ;;
    esac
done <<< "$rsync_out"

if $DRY_RUN; then
    echo "Dry-run complete. No changes were made."
    exit 0
fi

ctl_if_any "Stopping deleted quadlets" deleted stop

echo "Deploying systemd units"

systemd_units=(/etc/secc/systemd/*)
(( ${#systemd_units[@]} > 0 )) && systemctl link "${systemd_units[@]}"

echo "Reloading systemd"

systemctl daemon-reload

enable_systemd=()
for f in "${systemd_units[@]}"; do
    [[ -f "$f" ]] || continue
    unit=${f##*/}

    if ! grep -q '^\[Install\]' "$f"; then
        echo "Skipping $unit because it has no [Install] section"
        continue
    fi
    can_start "$unit" && enable_systemd+=("$unit")
done

ctl_if_any "Enabling and starting" enable_systemd enable --now

ctl_if_any "Restarting modified quadlets" modified try-restart
