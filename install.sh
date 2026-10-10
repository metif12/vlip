#!/usr/bin/env bash
set -euo pipefail

BLIP_DIR="${BLIP_INSTALL_DIR:-$HOME/.blip}"
REPO="https://github.com/metif12/blip.git"

echo "==> Installing blip to $BLIP_DIR"

if [ ! -d "$BLIP_DIR" ]; then
    git clone "$REPO" "$BLIP_DIR"
fi

cd "$BLIP_DIR"
git pull --ff-only

if ! command -v v >/dev/null 2>&1; then
    echo "==> V not found. Installing V..."
    git clone https://github.com/vlang/v "$HOME/.v"
    cd "$HOME/.v"
    make
    export PATH="$HOME/.v:$PATH"
    cd "$BLIP_DIR"
fi

v -cc gcc -o "$BLIP_DIR/blip" blip.v

echo "==> blip installed to $BLIP_DIR/blip"
echo "==> Add to your PATH: export PATH=\"$BLIP_DIR:\$PATH\""
