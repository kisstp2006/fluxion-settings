#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Install Settings beside Fluxion Desktop: built as you, as a release build,
# then copied into place as root - the one step that needs it.
#
#   tools/install.sh                    into /usr/local
#   PREFIX=/opt/fluxion tools/install.sh
#   tools/install.sh --uninstall
set -eu
prefix=${PREFIX:-/usr/local}
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--uninstall" ]; then
    sudo rm -f "$prefix/bin/fluxion-settings" "$prefix/share/applications/org.fluxion.Settings.desktop"
    echo "Settings is uninstalled."
    exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
zig build -Doptimize=ReleaseSafe --prefix "$stage"

sudo install -Dm755 "$stage/bin/fluxion-settings" "$prefix/bin/fluxion-settings"
sudo install -Dm644 "$stage/share/applications/org.fluxion.Settings.desktop" "$prefix/share/applications/org.fluxion.Settings.desktop"
echo "Settings is installed: the shell opens it from the start menu, quick settings and the desktop."
