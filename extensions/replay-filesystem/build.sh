#!/usr/bin/env bash
set -euo pipefail
# Linux compiler with multilib support; SDK checkouts are supplied by the caller.
: "${SOURCEMOD_SDK:?Set SOURCEMOD_SDK to the SourceMod checkout}"
: "${SOURCEPAWN_SDK:?Set SOURCEPAWN_SDK to the SourcePawn checkout}"
: "${AMTL_SDK:?Set AMTL_SDK to the AMTL checkout}"
output="${1:?Supply the output .ext.so path}"
# Verify git checkouts use the SDK's ABI-compatible SourcePawn revision.
expected="$(git -C "$SOURCEMOD_SDK" ls-tree HEAD sourcepawn 2>/dev/null | awk '{print $3}')"
if [[ -n "$expected" ]]; then
  actual="$(git -C "$SOURCEPAWN_SDK" rev-parse HEAD)"
  if [[ "$actual" != "$expected" ]]; then
    echo "SOURCEPAWN_SDK must match the SourceMod SDK's pinned submodule revision" >&2
    exit 1
  fi
fi
"${CXX:-g++}" -m32 -std=c++17 -shared -fPIC -fvisibility=hidden -Wall -Wextra \
  -Wno-unused-parameter -I"$SOURCEMOD_SDK/public" -I"$SOURCEPAWN_SDK/include" \
  -I"$AMTL_SDK" -I"$AMTL_SDK/amtl" \
  "$(dirname "$0")/extension.cpp" -o "$output"
