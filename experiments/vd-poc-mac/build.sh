#!/usr/bin/env bash
# Build the macOS virtual display POC.
# Single clang invocation; uses dynamic-lookup so SLS* symbols resolve at runtime
# from /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.

set -euo pipefail

cd "$(dirname "$0")"

clang \
  -fobjc-arc \
  -Wall -Wextra \
  -framework CoreGraphics \
  -framework Foundation \
  -framework AppKit \
  -Wl,-undefined,dynamic_lookup \
  src/vd_poc.m \
  -o vd-poc-mac

echo "Built ./vd-poc-mac"
