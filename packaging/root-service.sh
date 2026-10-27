#!/bin/sh
# Optional: install/remove an init service (advanced use, headless "service mode").
#   root-service.sh install   <init> <user> <group> <home> <bin> <packaging-dir>
#   root-service.sh uninstall
set -eu
action=$1
if [ "$action" = uninstall ]; then
    rm -f /etc/systemd/user/divez.service /etc/init.d/divez
    rm -rf /etc/sv/divez
    rm -f /var/service/divez /run/runit/service/divez
    exit 0
fi
init=$2; user=$3; group=$4; home=$5; bin=$6; pk=$7

subst() { # subst <src> <dst> <mode>
    tmp=$(mktemp)
    sed -e "s|@USER@|$user|g" -e "s|@GROUP@|$group|g" -e "s|@HOME@|$home|g" -e "s|@BIN@|$bin|g" "$1" > "$tmp"
    install -Dm"$3" "$tmp" "$2"
    rm -f "$tmp"
}
case "$init" in
    systemd) subst "$pk/systemd/divez.service" /etc/systemd/user/divez.service 644 ;;
    runit)   subst "$pk/runit/divez/run" /etc/sv/divez/run 755 ;;
    openrc)  subst "$pk/openrc/divez" /etc/init.d/divez 755 ;;
    *) echo "no supported init system detected" >&2; exit 1 ;;
esac
