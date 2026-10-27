#!/bin/sh
# Privileged part of the installation: udev rule + serial-port group membership.
# Called by install.sh through pkexec/sudo/doas:  root-setup.sh <user> <group> <rules-template>
set -eu
user=$1; group=$2; rules=$3

tmp=$(mktemp)
sed "s|@GROUP@|$group|g" "$rules" > "$tmp"
install -Dm644 "$tmp" /etc/udev/rules.d/70-diver.rules
rm -f "$tmp"

if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload || true
    udevadm trigger --subsystem-match=tty || true
fi

if [ -n "$group" ] && [ "$group" != root ] && ! id -nG "$user" | tr ' ' '\n' | grep -qx "$group"; then
    if command -v usermod >/dev/null 2>&1; then usermod -aG "$group" "$user"
    elif command -v adduser >/dev/null 2>&1; then adduser "$user" "$group"
    elif command -v addgroup >/dev/null 2>&1; then addgroup "$user" "$group"
    fi
    echo "added $user to group $group (takes effect after logging out and in)"
fi
