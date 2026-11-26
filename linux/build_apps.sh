#!/usr/bin/env bash
# ------------------------------------------------------------------
# build_apps.sh — build (and install) the Linux versions of the HDLTool apps.
#
#   ./build_apps.sh                      # build all three apps into <app>/dist/linux-unpacked
#   ./build_apps.sh --install            # build, then install for this user (no root needed):
#                                        #   ~/.local/opt/<app>, ~/.local/bin/<app>, menu entry, icon
#   ./build_apps.sh --package            # also make .deb and .tar.gz packages in <app>/dist
#   ./build_apps.sh --install hdl-phy     # only some apps: hdl-simulator, hdl-viewer, hdl-phy
#   ./build_apps.sh --uninstall          # remove what --install put in ~/.local
#
# Needs Node.js (npm). It is taken from ~/eda/tools/node/bin when present, else from PATH
# (Ubuntu: sudo apt install nodejs npm). The Electron binary is downloaded by npm on first use.
#
# Run from source without building:   ./run.sh hdl-phy [args]
# ------------------------------------------------------------------
set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)
[ -x "$HOME/eda/tools/node/bin/node" ] && export PATH="$HOME/eda/tools/node/bin:$PATH"

declare -A DIRS=([hdl-simulator]=HDLSimulator [hdl-viewer]=HDLViewer [hdl-phy]=HDLPhy)
declare -A NAMES=([hdl-simulator]="HDL Simulator" [hdl-viewer]="HDL Viewer" [hdl-phy]="HDLPhy")
declare -A COMMENTS=(
    [hdl-simulator]="Verilog editor and visual testbench builder"
    [hdl-viewer]="Waveform viewer for VCD files"
    [hdl-phy]="SKY130 synthesis and place-and-route with schematic and layout views")
declare -A MIMES=([hdl-simulator]="text/x-verilog;text/x-systemverilog;text/x-vhdl;" [hdl-viewer]="text/x-vcd;" [hdl-phy]="")
ORDER=(hdl-simulator hdl-viewer hdl-phy)

install=0 package=0 uninstall=0 apps=()
for a in "$@"; do
    case "$a" in
        --install) install=1 ;;
        --package) package=1 ;;
        --uninstall) uninstall=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) [ -n "${DIRS[$a]:-}" ] || { echo "unknown app '$a' (hdl-simulator, hdl-viewer, hdl-phy)" >&2; exit 2; }; apps+=("$a") ;;
    esac
done
[ ${#apps[@]} -gt 0 ] || apps=("${ORDER[@]}")

say() { echo "==> $*"; }

uninstall_app() {
    local exe=$1
    rm -rf "$HOME/.local/opt/$exe" "$HOME/.local/bin/$exe" "$HOME/.local/share/applications/$exe.desktop" \
        "$HOME/.local/share/icons/hicolor/256x256/apps/$exe.png"
    say "removed $exe"
}

if [ $uninstall = 1 ]; then
    for a in "${apps[@]}"; do uninstall_app "$a"; done
    command -v update-desktop-database > /dev/null && update-desktop-database -q "$HOME/.local/share/applications" || true
    exit 0
fi

command -v npm > /dev/null || { echo "npm not found: install Node.js (sudo apt install nodejs npm, or unpack it into ~/eda/tools/node)" >&2; exit 1; }

build_app() {
    local exe=$1 dir="$HERE/${DIRS[$1]}"
    say "building ${NAMES[$exe]} ($dir)"
    (cd "$dir" && npm install --no-fund --no-audit > /dev/null && node node_modules/electron/install.js)
    (cd "$dir" && npx electron-builder --linux dir --publish never)
    if [ $package = 1 ]; then
        (cd "$dir" && npx electron-builder --linux deb tar.gz --publish never)
    fi
}

install_app() {
    local exe=$1 dir="$HERE/${DIRS[$1]}"
    local src="$dir/dist/linux-unpacked" dest="$HOME/.local/opt/$exe"
    [ -x "$src/$exe" ] || { echo "$src/$exe missing: the build failed?" >&2; exit 1; }
    say "installing ${NAMES[$exe]} into $dest"
    rm -rf "$dest"
    mkdir -p "$HOME/.local/opt" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
    cp -a "$src" "$dest"
    cp "$dir/build/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/$exe.png"
    # Chromium's sandbox needs chrome-sandbox owned by root with mode 4755 (Ubuntu 24.04+ also restricts the
    # user-namespace sandbox). Without that the apps start with --no-sandbox; they only load their own pages.
    cat > "$HOME/.local/bin/$exe" << EOF
#!/bin/sh
# ${NAMES[$exe]} launcher (written by HDLTool/linux/build_apps.sh)
app="$dest/$exe"
sb="$dest/chrome-sandbox"
if [ "\$(stat -c %u:%a "\$sb" 2> /dev/null)" = "0:4755" ]; then exec "\$app" "\$@"; fi
exec "\$app" --no-sandbox "\$@"
EOF
    chmod +x "$HOME/.local/bin/$exe"
    cat > "$HOME/.local/share/applications/$exe.desktop" << EOF
[Desktop Entry]
Type=Application
Name=${NAMES[$exe]}
Comment=${COMMENTS[$exe]}
Exec=$HOME/.local/bin/$exe %F
Icon=$exe
Terminal=false
Categories=Development;Electronics;
MimeType=${MIMES[$exe]}
StartupWMClass=${NAMES[$exe]}
EOF
}

for a in "${apps[@]}"; do build_app "$a"; done
if [ $install = 1 ]; then
    for a in "${apps[@]}"; do install_app "$a"; done
    command -v update-desktop-database > /dev/null && update-desktop-database -q "$HOME/.local/share/applications" || true
    command -v gtk-update-icon-cache > /dev/null && gtk-update-icon-cache -q -t "$HOME/.local/share/icons/hicolor" 2> /dev/null || true
    say "installed: $(printf '%s ' "${apps[@]}")— start them from the app menu or as commands (~/.local/bin)"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: ~/.local/bin is not on PATH" ;; esac
fi
