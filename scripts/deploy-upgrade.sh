#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: bash scripts/deploy-upgrade.sh EXTRACTED_PACKAGE GAME_DIRECTORY" >&2
  exit 1
fi
package="$1"
game="$2"
if [[ ! -d "$game" || ! -d "$package/addons" || ! -d "$package/materials" ||
      ! -s "$package/addons/sourcemod/extensions/gokz_top_replay_fs.ext.so" ]]; then
  echo "Expected an existing game directory and a package containing addons, materials, and the replay extension." >&2
  exit 1
fi

# Default rsync replaces files by rename; never use --inplace on a loaded .so.
rsync -ac -- "$package/addons/" "$game/addons/"
rsync -ac -- "$package/materials/" "$game/materials/"
echo "Runtime files installed; existing configuration and unrelated files preserved."
echo "Loaded extensions keep their previous binaries until a controlled server restart. Do not hot-reload extensions."
