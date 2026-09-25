#!/usr/bin/env bash
# the harness demo drives a headless frame through the public surface, in every profile this leg built
set -euo pipefail

for profile in $MACH_CI_PROFILES; do
    # the .exe name first: git bash on windows also answers `-f harness` for harness.exe
    bin=""
    for candidate in demo/harness/out/*/"$profile"/bin/harness.exe demo/harness/out/*/"$profile"/bin/harness; do
        if [ -f "$candidate" ]; then
            bin="$candidate"
            break
        fi
    done
    if [ -z "$bin" ]; then
        echo "::error::no $profile harness under demo/harness/out"
        exit 1
    fi
    out="$("$bin" | tr -d '\r')"
    echo "$bin: $out"
    case "$out" in
        *", ok=1") ;;
        *) echo "::error::$bin did not finish a frame cleanly"; exit 1 ;;
    esac
done
