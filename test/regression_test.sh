#!/usr/bin/env bash
#
# Headless regression test for virtualjaguar-libretro
#
# Builds miniretro, runs test ROMs for N frames, dumps screenshots,
# and compares the last screenshot's checksum against a known baseline.
#
# Usage: ./test/regression_test.sh <core_path> [platform]
# Example: ./test/regression_test.sh ./virtualjaguar_libretro.so linux-x86_64
#
set -euo pipefail

CORE="${1:?Usage: $0 <core_path> [platform]}"
PLATFORM="${2:-$(uname -s)-$(uname -m)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
BASELINE_DIR="${SCRIPT_DIR}/baselines/${PLATFORM}"
ROM_DIR="${SCRIPT_DIR}/roms"
MINIRETRO_DIR="${WORK_DIR}/miniretro"
MINIRETRO_BIN="${WORK_DIR}/miniretro-bin"
FRAMES=60
DUMP_EVERY=10

trap 'rm -rf "${WORK_DIR}"' EXIT

# --- Detect platform for build flags ---
LDFLAGS="-ldl"
BUILD_CXX="${CXX:-g++}"
case "$(uname -s)" in
    Darwin)
        LDFLAGS=""
        BUILD_CXX="${CXX:-clang++}"
        ;;
esac

# --- Get miniretro (use env var if pre-built, otherwise build from source) ---
if [ -n "${MINIRETRO_BIN:-}" ] && [ -x "${MINIRETRO_BIN}" ]; then
    echo "==> Using pre-built miniretro: ${MINIRETRO_BIN}"
else
    MINIRETRO_BIN="${WORK_DIR}/miniretro-bin"
    echo "==> Building miniretro..."
    git clone --depth 1 https://github.com/davidgfnet/miniretro.git "${MINIRETRO_DIR}" 2>/dev/null
    ${BUILD_CXX} -O2 -Wall -Wno-deprecated-declarations \
        -o "${MINIRETRO_BIN}" \
        "${MINIRETRO_DIR}/miniretro.cc" \
        "${MINIRETRO_DIR}/util.cc" \
        "${MINIRETRO_DIR}/loader.cc" \
        ${LDFLAGS}

    if [ ! -x "${MINIRETRO_BIN}" ]; then
        echo "ERROR: Failed to build miniretro"
        exit 1
    fi
    echo "==> miniretro built successfully"
fi
echo "==> Platform: ${PLATFORM}"
echo "==> Baselines: ${BASELINE_DIR}"

# --- Resolve core to absolute path ---
CORE="$(cd "$(dirname "${CORE}")" && pwd)/$(basename "${CORE}")"

# --- Run tests ---
PASS=0
FAIL=0
NEW=0

mkdir -p "${BASELINE_DIR}"

for rom in "${ROM_DIR}"/*.j64 "${ROM_DIR}"/*.rom; do
    [ -f "${rom}" ] || continue
    rom_name="$(basename "${rom}" | sed 's/\.[^.]*$//')"
    out_dir="${WORK_DIR}/output/${rom_name}"
    mkdir -p "${out_dir}"

    echo "==> Testing: ${rom_name} (${FRAMES} frames)"

    # Run the core, dump screenshots periodically
    "${MINIRETRO_BIN}" \
        --core "${CORE}" --rom "${rom}" \
        --output "${out_dir}" --system "${out_dir}" \
        --frames "${FRAMES}" --dump-frames-every "${DUMP_EVERY}" \
        --timeout 60 2>&1 | head -20 || true

    # Use the last dumped screenshot for comparison
    frame_file=$(find "${out_dir}" -name "screenshot*.png" 2>/dev/null | sort | tail -1)

    if [ -z "${frame_file}" ]; then
        echo "   WARNING: No frame dumped for ${rom_name}"
        FAIL=$((FAIL + 1))
        continue
    fi

    echo "   Using frame: $(basename "${frame_file}")"

    # Compute checksum
    if command -v md5sum &>/dev/null; then
        hash=$(md5sum "${frame_file}" | awk '{print $1}')
    else
        hash=$(md5 -q "${frame_file}")
    fi

    baseline_file="${BASELINE_DIR}/${rom_name}.md5"

    if [ -f "${baseline_file}" ]; then
        expected=$(cat "${baseline_file}")
        if [ "${hash}" = "${expected}" ]; then
            echo "   PASS: ${rom_name} (${hash})"
            PASS=$((PASS + 1))
        else
            echo "   FAIL: ${rom_name}"
            echo "     expected: ${expected}"
            echo "     got:      ${hash}"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "   NEW: ${rom_name} — no baseline yet (${hash})"
        echo "   Run: echo '${hash}' > ${baseline_file}"
        NEW=$((NEW + 1))
    fi
done

echo ""
echo "==> Results: ${PASS} passed, ${FAIL} failed, ${NEW} new (no baseline)"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
