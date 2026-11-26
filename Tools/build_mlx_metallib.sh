#!/bin/bash
# Compiles MLX's Metal kernels into one mlx.metallib (FLU-149).
#
# SwiftPM on the command line builds mlx-swift's C++ but not its .metal files (only Xcode does),
# and without them MLX stops at its first GPU call. The kernels mlx-swift does not compile at
# run time are the .metal files under Source/Cmlx/mlx-generated/metal; this compiles each one
# with the flags of MLX's own CMake build and links them. The app points MLX at the result
# (`GPU.metallib`, CohereEngine), so it ships in Contents/Resources like any other resource.
#
#   Tools/build_mlx_metallib.sh <mlx-swift checkout> <out.metallib>
#
# Xcode 26 ships the Metal compiler as a separate component: when it is missing (a fresh CI
# runner), it is downloaded once with `xcodebuild -downloadComponent MetalToolchain`.
set -euo pipefail

KERNELS="${1:?usage: $0 <mlx-swift checkout> <out.metallib>}/Source/Cmlx/mlx-generated/metal"
OUT="${2:?usage: $0 <mlx-swift checkout> <out.metallib>}"
MIN_MACOS=26.0

test -d "$KERNELS" || { echo "no Metal kernels in $KERNELS" >&2; exit 1; }
xcrun -sdk macosx metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain >&2
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mlx-metal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pids=()
airs=()
while IFS= read -r source; do
    air="$WORK/$(echo "${source#"$KERNELS"/}" | tr / _).air"
    airs+=("$air")
    xcrun -sdk macosx metal -x metal -fno-fast-math -w \
        -mmacosx-version-min=$MIN_MACOS -c "$source" -o "$air" &
    pids+=($!)
done < <(find "$KERNELS" -name '*.metal' | sort)

test ${#airs[@]} -gt 0 || { echo "no .metal file under $KERNELS" >&2; exit 1; }
failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
test $failed -eq 0 || { echo "a Metal kernel failed to compile" >&2; exit 1; }

xcrun -sdk macosx metal -mmacosx-version-min=$MIN_MACOS "${airs[@]}" -o "$OUT.partial"
mv "$OUT.partial" "$OUT"
echo "built $OUT (${#airs[@]} kernels, $(($(stat -f%z "$OUT") / 1024)) KB)"
