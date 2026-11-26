#!/bin/bash
# Compiles the stitchable Core Image kernels in App/Shaders/Dewrinkle.metal
# into the app bundle. The source uses [[ stitchable ]] kernels, which are a
# normal metallib (not metal -fcikernel). If the Metal tools fail, the app
# compiles the matching CIKernel language in KernelSources.swift at launch.
set -u

SRC="${SRCROOT:-}/App/Shaders/Dewrinkle.metal"
AIR="${DERIVED_FILE_DIR:-/tmp}/Dewrinkle.air"
LIB="${DERIVED_FILE_DIR:-/tmp}/Dewrinkle.ci.metallib"

warn() {
  echo "warning: $* Dewrinkle will compile the fallback kernel at runtime."
}

if [[ ! -f "${SRC}" ]]; then
  warn "Kernel source was not found at ${SRC}."
  exit 0
fi

# bash on the runner is 3.2, so keep this as two commands rather than an array.
if [[ "${ARCHS:-arm64}" == *arm64* ]]; then
  metal_ok=0
  xcrun --sdk macosx metal -c "${SRC}" -o "${AIR}" -target "air64-apple-macos${MACOSX_DEPLOYMENT_TARGET:-14.0}" && metal_ok=1
else
  metal_ok=0
  xcrun --sdk macosx metal -c "${SRC}" -o "${AIR}" && metal_ok=1
fi
if [[ "${metal_ok}" -ne 1 ]]; then
  warn "Core Image metallib was not built."
  exit 0
fi

if ! xcrun --sdk macosx metallib "${AIR}" -o "${LIB}"; then
  warn "metallib link failed."
  exit 0
fi

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${WRAPPER_NAME:-}" ]]; then
  DEST="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/Resources"
elif [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  DEST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
else
  warn "Build products directory was not set, so the metallib was not copied."
  exit 0
fi

mkdir -p "${DEST}"
cp "${LIB}" "${DEST}/Dewrinkle.ci.metallib"
echo "Copied Dewrinkle.ci.metallib to ${DEST}"
