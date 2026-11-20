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

# Stop and disable removed systemd units before rsync deletes their target files
deleted_systemd=()
for f in /etc/secc/systemd/*; do
    unit=${f##*/}
    if [[ -f "$f" && ! -e "./conf/systemd/$unit" ]] && systemctl cat -- "$unit" &>/dev/null; then
        deleted_systemd+=("$unit")
    fi
done
ctl_if_any "Stopping and disabling removed systemd units" deleted_systemd disable --now --no-reload

deleted_quadlets=() link_systemd=() enable_systemd=() to_start=() to_restart=()
declare -A warnings=()

echo "Deploying configuration"
sync_dir ./conf/ /etc/secc/
while read -r action file; do
    unit=${file##*/}
    case "$action:$file" in
        *:systemd/*/*)
            ;;
        ">f+"*:systemd/*)
            if grep -q '^\[Install\]' "./conf/$file"; then
                enable_systemd+=("/etc/secc/$file")
                can_start "$unit" && to_start+=("$unit")
            else
                link_systemd+=("/etc/secc/$file")
            fi
            ;;
        ">f"*:systemd/*)
            can_start "$unit" && to_restart+=("$unit")
            ;;
        ">f"*:env/*.env|"*deleting":env/*.env)
            warnings[env]="Changes detected in env/ (environment files). Affected containers may need a manual restart."
            ;;
    esac
done <<< "$rsync_out"

echo "Deploying quadlets"
sync_dir ./podman/ /etc/containers/systemd/secc/
while read -r action file; do
    unit="${file##*/}"
    unit="${unit%.container}.service"
    case "$action:$file" in
        ">f"*:*container.d/*|"*deleting":*container.d/*)
            warnings[override]="Changes detected in container.d/ (override configurations). Running containers may need a manual restart."
            ;;
        "*deleting":*.container) deleted_quadlets+=("$unit") ;;
        ">f+"*:*.container)      to_start+=("$unit") ;;
        ">f"*:*.container)       to_restart+=("$unit") ;;
    esac
done <<< "$rsync_out"

(( ${#warnings[@]} )) && printf 'Warning: %s\n' "${warnings[@]}" >&2

ctl_if_any "Stopping deleted quadlets" deleted_quadlets stop
ctl_if_any "Linking new systemd units" link_systemd link --no-reload
ctl_if_any "Enabling new systemd units" enable_systemd enable --no-reload

run_ctl "Reloading systemd" daemon-reload

ctl_if_any "Starting new units" to_start start
ctl_if_any "Restarting modified units" to_restart try-restart

if $DRY_RUN; then
    echo "Dry-run complete. No changes were made."
fi
