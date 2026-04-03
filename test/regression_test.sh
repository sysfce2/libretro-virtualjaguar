#!/usr/bin/env bash
#
# Headless regression test for virtualjaguar-libretro
#
# Runs test ROMs via miniretro, compares screenshots against reference
# images, and generates visual diffs on failure.
#
# Usage: ./test/regression_test.sh <core_path>
# Example: ./test/regression_test.sh ./virtualjaguar_libretro.so
#
# Set MINIRETRO_BIN env var to skip building miniretro from source.
# Set DIFF_DIR env var to specify where diff images are saved.
#
set -euo pipefail

CORE="${1:?Usage: $0 <core_path>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
BASELINE_DIR="${SCRIPT_DIR}/baselines"
ROM_DIR="${SCRIPT_DIR}/roms"
DIFF_DIR="${DIFF_DIR:-${WORK_DIR}/diffs}"
# 600 frames (~10 seconds at 60fps) to get past BIOS boot
FRAMES=600
DUMP_EVERY=100

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
    git clone --depth 1 https://github.com/davidgfnet/miniretro.git "${WORK_DIR}/miniretro" 2>/dev/null
    ${BUILD_CXX} -O2 -Wall -Wno-deprecated-declarations -Wno-unused-result \
        -o "${MINIRETRO_BIN}" \
        "${WORK_DIR}/miniretro/miniretro.cc" \
        "${WORK_DIR}/miniretro/util.cc" \
        "${WORK_DIR}/miniretro/loader.cc" \
        ${LDFLAGS}

    if [ ! -x "${MINIRETRO_BIN}" ]; then
        echo "ERROR: Failed to build miniretro"
        exit 1
    fi
    echo "==> miniretro built successfully"
fi

echo "==> Baselines: ${BASELINE_DIR}"
echo "==> Diff output: ${DIFF_DIR}"
mkdir -p "${DIFF_DIR}"

# --- Resolve core to absolute path ---
CORE="$(cd "$(dirname "${CORE}")" && pwd)/$(basename "${CORE}")"

# --- Run tests ---
PASS=0
FAIL=0
NEW=0
SUMMARY=""

for rom in "${ROM_DIR}"/*.j64 "${ROM_DIR}"/*.rom; do
    [ -f "${rom}" ] || continue
    rom_name="$(basename "${rom}" | sed 's/\.[^.]*$//')"
    out_dir="${WORK_DIR}/output/${rom_name}"
    mkdir -p "${out_dir}"

    echo "==> Testing: ${rom_name} (${FRAMES} frames)"

    # Run the core headless. --no-alarm disables per-frame timeout
    # since some Jaguar frames are slow (boot, complex rendering).
    "${MINIRETRO_BIN}" \
        --core "${CORE}" --rom "${rom}" \
        --output "${out_dir}" --system "${out_dir}" \
        --frames "${FRAMES}" --dump-frames-every "${DUMP_EVERY}" \
        --no-alarm 2>&1 | head -20 || true

    # Use the last dumped screenshot for comparison
    frame_file=$(find "${out_dir}" -name "screenshot*.png" 2>/dev/null | sort | tail -1)

    if [ -z "${frame_file}" ]; then
        echo "   WARNING: No frame dumped for ${rom_name}"
        FAIL=$((FAIL + 1))
        SUMMARY="${SUMMARY}| ${rom_name} | :x: FAIL | No frame output | - |\n"
        continue
    fi

    echo "   Using frame: $(basename "${frame_file}")"

    # Copy current screenshot to diff dir for reference
    cp "${frame_file}" "${DIFF_DIR}/${rom_name}_current.png"

    baseline_png="${BASELINE_DIR}/${rom_name}.png"

    if [ -f "${baseline_png}" ]; then
        # Compare against reference screenshot
        if command -v compare &>/dev/null; then
            # ImageMagick compare: generate diff image and get metric
            metric_raw=$(compare -metric AE "${baseline_png}" "${frame_file}" \
                "${DIFF_DIR}/${rom_name}_diff.png" 2>&1 || true)
            # Extract just the integer pixel count (ImageMagick may output "0 (0)")
            metric=$(echo "${metric_raw}" | awk '{print $1}')

            if [ "${metric}" = "0" ]; then
                echo "   PASS: ${rom_name} (0 pixels differ)"
                PASS=$((PASS + 1))
                SUMMARY="${SUMMARY}| ${rom_name} | :white_check_mark: PASS | 0 pixels differ | - |\n"
                # Clean up diff artifacts on pass
                rm -f "${DIFF_DIR}/${rom_name}_diff.png" "${DIFF_DIR}/${rom_name}_current.png"
            else
                echo "   FAIL: ${rom_name} (${metric} pixels differ)"
                # Also generate a side-by-side comparison
                if command -v montage &>/dev/null; then
                    montage "${baseline_png}" "${frame_file}" "${DIFF_DIR}/${rom_name}_diff.png" \
                        -tile 3x1 -geometry +4+4 -label '%f' \
                        "${DIFF_DIR}/${rom_name}_sidebyside.png" 2>/dev/null || true
                fi
                # Copy baseline to diff dir for artifact upload
                cp "${baseline_png}" "${DIFF_DIR}/${rom_name}_expected.png"
                FAIL=$((FAIL + 1))
                SUMMARY="${SUMMARY}| ${rom_name} | :x: FAIL | ${metric} pixels differ | See artifacts |\n"
            fi
        else
            # Fallback: byte-level comparison
            if cmp -s "${baseline_png}" "${frame_file}"; then
                echo "   PASS: ${rom_name} (identical)"
                PASS=$((PASS + 1))
                SUMMARY="${SUMMARY}| ${rom_name} | :white_check_mark: PASS | identical | - |\n"
            else
                echo "   FAIL: ${rom_name} (screenshots differ)"
                cp "${baseline_png}" "${DIFF_DIR}/${rom_name}_expected.png"
                FAIL=$((FAIL + 1))
                SUMMARY="${SUMMARY}| ${rom_name} | :x: FAIL | screenshots differ | See artifacts |\n"
            fi
        fi
    else
        echo "   NEW: ${rom_name} — no baseline yet"
        echo "   To create: cp ${frame_file} ${baseline_png}"
        NEW=$((NEW + 1))
        SUMMARY="${SUMMARY}| ${rom_name} | :new: NEW | no baseline | - |\n"
    fi
done

echo ""
echo "==> Results: ${PASS} passed, ${FAIL} failed, ${NEW} new (no baseline)"

# Write summary for CI to pick up
cat > "${DIFF_DIR}/summary.md" <<EOSUMMARY
## Regression Test Results

| ROM | Status | Details | Diff |
|-----|--------|---------|------|
$(echo -e "${SUMMARY}")

**Platform:** $(uname -s) $(uname -m)
EOSUMMARY

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
