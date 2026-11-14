#!/bin/bash

set -euo pipefail

cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

DRY_RUN=false
case "${1:-}" in
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help)
        echo "Usage: $(basename "$0") [-n|--dry-run]"
        exit 0
        ;;
    "") ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
esac

if [ "$DRY_RUN" = false ] && [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "Validating quadlets"

QUADLET_UNIT_DIRS="$(pwd)/podman" /usr/lib/systemd/system-generators/podman-system-generator -no-kmsg-log -dryrun >/dev/null

rsync_flags=(-rt --delete --mkpath --force -i)
if [ "$DRY_RUN" = true ]; then
    rsync_flags+=(-n)
fi

echo "Deploying configuration"

rsync "${rsync_flags[@]}" ./conf/ /etc/secc/

echo "Deploying quadlets"

sync_output=$(rsync "${rsync_flags[@]}" ./podman/ /etc/containers/systemd/secc/)
[ -n "$sync_output" ] && echo "$sync_output"

deleted=()
modified=()

while read -r action file; do
    [ -z "$file" ] || [[ "$file" != *.container ]] && continue
    unit="$(basename "$file" .container).service"
    case "$action" in
        \*deleting) deleted+=("$unit") ;;
        \>f[^+]*)   modified+=("$unit") ;;
    esac
done <<< "$sync_output"

if [ ${#deleted[@]} -gt 0 ]; then
    echo "Stopping deleted quadlets: ${deleted[*]}"
    if [ "$DRY_RUN" = false ]; then
        systemctl stop "${deleted[@]}" 2>/dev/null || true
        systemctl disable "${deleted[@]}" 2>/dev/null || true
    fi
fi

if [ "$DRY_RUN" = true ]; then
    echo "Dry-run complete. No changes were made."
    exit 0
fi

echo "Deploying systemd units"

shopt -s nullglob
systemd_units=(/etc/secc/systemd/*)

if [ ${#systemd_units[@]} -gt 0 ]; then
    systemctl link "${systemd_units[@]}"
fi

echo "Reloading systemd"

systemctl daemon-reload

for f in "${systemd_units[@]}"; do
    [ -f "$f" ] || continue
    unit=$(basename "$f")

    if [ "$(systemctl show -p RefuseManualStart --value "$unit")" = "yes" ]; then
        echo "Skipping $unit because it is marked as RefuseManualStart"
        continue
    fi
    if ! grep -q '^\[Install\]' "$f"; then
        echo "Skipping $unit because it has no [Install] section"
        continue
    fi
    echo "Enabling and starting $unit"
    systemctl enable --now "$unit"
done

if [ ${#modified[@]} -gt 0 ]; then
    echo "Restarting modified quadlets: ${modified[*]}"
    systemctl try-restart "${modified[@]}"
fi
