#!/usr/bin/env bash
# Build ONNX Runtime with CoreML support for macOS
# Creates a static library that includes the CoreML execution provider
# Aligned with build-linux-static.sh patterns
set -euf -o pipefail

CMAKE_BUILD_TYPE=MinSizeRel
ARCH="${1:-arm64}"

# Check for --list-libs flag to discover available libraries after build
if [[ "${1:-}" == "--list-libs" ]]; then
  BUILD_DIR=./onnxruntime/build/macOS_${ARCH}_coreml/${CMAKE_BUILD_TYPE}
  echo "Listing all .a files in build directory..."
  echo ""
  echo "=== Core libraries ==="
  find "$BUILD_DIR" -maxdepth 1 -name "*.a" 2>/dev/null | sort
  echo ""
  echo "=== Dependency libraries ==="
  find "${BUILD_DIR}/_deps" -name "*.a" 2>/dev/null | sort
  exit 0
fi

# Full build by default (no reduced ops) for quantized model support
# Pass a config file as argument to enable reduced ops: ./build-mac-coreml.sh model.config
ONNX_CONFIG=""
if [[ -n "${1:-}" ]] && [[ "${1}" != "arm64" ]] && [[ "${1}" != "x86_64" ]]; then
  ONNX_CONFIG="${1}"
  ARCH="${2:-arm64}"
fi

echo "Building ONNX Runtime ${CMAKE_BUILD_TYPE} for macOS ${ARCH} with CoreML..."
if [[ -n "$ONNX_CONFIG" ]]; then
  echo "Using reduced ops config: ${ONNX_CONFIG}"
else
  echo "Building with FULL operators (supports quantized models)"
fi
echo "This will take 15-20 minutes..."

# Apply patches if they exist
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/patches" ]]; then
  for patch in "${SCRIPT_DIR}/patches"/*.patch; do
    if [[ -f "$patch" ]]; then
      echo "Applying patch: $(basename "$patch")"
      git -C onnxruntime apply --check "$patch" 2>/dev/null &&
        git -C onnxruntime apply "$patch" ||
        echo "  (already applied or not applicable)"
    fi
  done
fi

# Build using Python build.py
# NOTE: DO NOT use --minimal_build as it only supports ORT format, not ONNX format
BUILD_ARGS=(
  --build_dir "onnxruntime/build/macOS_${ARCH}_coreml"
  --config="$CMAKE_BUILD_TYPE"
  --parallel
  --skip_tests
  --compile_no_warning_as_error
  --use_coreml
  --cmake_extra_defines
    CMAKE_OSX_ARCHITECTURES="${ARCH}"
    onnxruntime_BUILD_UNIT_TESTS=OFF
    onnxruntime_BUILD_SHARED_LIB=OFF
    CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON
    onnxruntime_USE_FULL_PROTOBUF=ON
)

# Only add reduced ops flags if a config file was provided
if [[ -n "$ONNX_CONFIG" ]]; then
  BUILD_ARGS+=(--include_ops_by_config "$ONNX_CONFIG")
  BUILD_ARGS+=(--enable_reduced_operator_type_support)
fi

python onnxruntime/tools/ci_build/build.py "${BUILD_ARGS[@]}"

BUILD_DIR=./onnxruntime/build/macOS_${ARCH}_coreml/${CMAKE_BUILD_TYPE}

echo ""
echo "Build complete. Combining static libraries..."

# List all .a files found (for debugging)
echo ""
echo "Available static libraries:"
find "$BUILD_DIR" -maxdepth 1 -name "*.a" | head -20
echo "..."
echo ""

# Function to check if a library exists
check_lib() {
  if [[ ! -f "$1" ]]; then
    echo "WARNING: Library not found: $1"
    return 1
  fi
  return 0
}

# Verify critical libraries exist
MISSING=0
check_lib "${BUILD_DIR}/libonnx.a" || check_lib "${BUILD_DIR}/_deps/onnx-build/libonnx.a" || MISSING=1
check_lib "${BUILD_DIR}/libonnxruntime_common.a" || MISSING=1
check_lib "${BUILD_DIR}/libonnxruntime_session.a" || MISSING=1
check_lib "${BUILD_DIR}/libonnxruntime_providers_coreml.a" || MISSING=1

if [[ $MISSING -eq 1 ]]; then
  echo ""
  echo "Some libraries are missing. Run with --list-libs to see available libraries."
  echo "You may need to adjust the library list in this script."
  exit 1
fi

# Find all the static libraries we need to combine
LIBS=""

# Core ORT libs
for lib in \
  libonnxruntime_common.a \
  libonnxruntime_flatbuffers.a \
  libonnxruntime_framework.a \
  libonnxruntime_graph.a \
  libonnxruntime_mlas.a \
  libonnxruntime_optimizer.a \
  libonnxruntime_providers.a \
  libonnxruntime_providers_coreml.a \
  libonnxruntime_session.a \
  libonnxruntime_util.a \
  libonnxruntime_lora.a \
  ; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  fi
done

# ONNX libs (check both locations)
for lib in libonnx.a libonnx_proto.a; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  elif [ -f "${BUILD_DIR}/_deps/onnx-build/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/_deps/onnx-build/${lib}"
  fi
done

# Dependency libs from _deps
for lib in \
  _deps/protobuf-build/libprotobuf.a \
  _deps/protobuf-build/libprotobuf-lite.a \
  _deps/flatbuffers-build/libflatbuffers.a \
  _deps/re2-build/libre2.a \
  _deps/google_nsync-build/libnsync_cpp.a \
  _deps/pytorch_cpuinfo-build/libcpuinfo.a \
  ; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  fi
done

# Add all abseil libraries
for abseil_lib in $(find "${BUILD_DIR}/_deps/abseil_cpp-build" -name "*.a" 2>/dev/null); do
  LIBS="${LIBS} ${abseil_lib}"
done

# Add CoreML related Objective-C++ libs if they exist
for lib in \
  libonnxruntime_providers_coreml_objc.a \
  ; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  fi
done

echo "Combining libraries with libtool..."
OUTPUT_LIB="libonnxruntime_all.a"
libtool -static -o "${OUTPUT_LIB}" ${LIBS}

# Move to output directory
mkdir -p libs/macos-${ARCH}-coreml
mv "${OUTPUT_LIB}" libs/macos-${ARCH}-coreml/

echo ""
echo "Static library created: libs/macos-${ARCH}-coreml/libonnxruntime_all.a"
ls -lh "libs/macos-${ARCH}-coreml/libonnxruntime_all.a"

echo ""
echo "To use with fastembed-zig (with CoreML support):"
echo "  mkdir -p /path/to/fastembed-zig/deps/onnxruntime-static/{include,lib}"
echo "  cp include/onnxruntime_c_api.h /path/to/fastembed-zig/deps/onnxruntime-static/include/"
echo "  cp include/coreml_provider_factory.h /path/to/fastembed-zig/deps/onnxruntime-static/include/"
echo "  cp libs/macos-${ARCH}-coreml/libonnxruntime_all.a /path/to/fastembed-zig/deps/onnxruntime-static/lib/"
echo ""
echo "Then build with: zig build -Dstatic=true -Dcoreml=true"
