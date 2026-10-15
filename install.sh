#!/usr/bin/env bash
# Installs UE4SS (if missing) and the GradedDefense mod into the game folder.
# usage: ./install.sh [path to "Expedition 33" folder]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="${1:-$HOME/.local/share/Steam/steamapps/common/Expedition 33}"
BIN="$GAME/Sandfall/Binaries/Win64"
STAGE="$HERE/tools/ue4ss_stage"
[ -f "$BIN/SandFall-Win64-Shipping.exe" ] || { echo "game not found at: $GAME"; exit 1; }

if [ ! -f "$BIN/ue4ss/UE4SS.dll" ]; then
  [ -f "$STAGE/dwmapi.dll" ] || { echo "UE4SS not staged in $STAGE (download the experimental zip from github.com/UE4SS-RE/RE-UE4SS/releases and unzip it there)"; exit 1; }
  cp "$STAGE/dwmapi.dll" "$BIN/"
  cp -r "$STAGE/ue4ss" "$BIN/"
  echo "installed UE4SS into $BIN"
else
  echo "UE4SS already present, left untouched"
fi

DEST="$BIN/ue4ss/Mods/GradedDefense"
mkdir -p "$DEST"
# keep an edited config across updates
if [ -f "$DEST/Scripts/gd_config.lua" ] && ! cmp -s "$DEST/Scripts/gd_config.lua" "$HERE/mod/GradedDefense/Scripts/gd_config.lua"; then
  cp "$DEST/Scripts/gd_config.lua" "$DEST/Scripts/gd_config.lua.bak"
  echo "your previous config was saved as gd_config.lua.bak"
fi
cp -r "$HERE/mod/GradedDefense/." "$DEST/"
echo "installed GradedDefense into $DEST"
echo
echo 'Steam > Expedition 33 > Properties > Launch Options (needed on Linux/Proton):'
echo '  WINEDLLOVERRIDES="dwmapi=n,b" %command%'
