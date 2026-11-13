#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "Deploying quadlets"

rsync -rt --delete --mkpath --force ./conf/ /etc/secc/

rsync -rt --delete --mkpath --force ./podman/ /etc/containers/systemd/secc/

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
