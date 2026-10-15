#!/usr/bin/env bash
# Removes the mod. Pass --all to also remove UE4SS itself.
set -euo pipefail
GAME="$HOME/.local/share/Steam/steamapps/common/Expedition 33"
ALL=0
for a in "$@"; do if [ "$a" = "--all" ]; then ALL=1; else GAME="$a"; fi; done
BIN="$GAME/Sandfall/Binaries/Win64"
rm -rf "$BIN/ue4ss/Mods/GradedDefense" && echo "removed GradedDefense"
if [ "$ALL" = 1 ]; then rm -rf "$BIN/ue4ss" "$BIN/dwmapi.dll" && echo "removed UE4SS"; fi
