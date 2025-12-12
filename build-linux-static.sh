#!/usr/bin/env bash

set -euf -o pipefail

# Full build by default (no reduced ops) for quantized model support
# Pass a config file as argument to enable reduced ops: ./build-linux-static.sh model.config
ONNX_CONFIG="${1:-}"
CMAKE_BUILD_TYPE=MinSizeRel
ARCH=x86_64

# Check for --list-libs flag to discover available libraries after build
if [[ "${1:-}" == "--list-libs" ]]; then
  BUILD_DIR=./onnxruntime/build/Linux_${ARCH}/${CMAKE_BUILD_TYPE}
  echo "Listing all .a files in build directory..."
  echo ""
  echo "=== Core libraries ==="
  find "$BUILD_DIR" -maxdepth 1 -name "*.a" 2>/dev/null | sort
  echo ""
  echo "=== Dependency libraries ==="
  find "${BUILD_DIR}/_deps" -name "*.a" 2>/dev/null | sort
  exit 0
fi

echo "Building ONNX Runtime static library for Linux ${ARCH}..."
if [[ -n "$ONNX_CONFIG" ]]; then
  echo "Using reduced ops config: ${ONNX_CONFIG}"
else
  echo "Building with FULL operators (supports quantized models)"
fi

# Apply patches for Clang 20 compatibility
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

# Use Clang with libc++ for Zig ABI compatibility
# Install via: ./deps.sh or manually: apt install clang-20 libc++-20-dev libc++abi-20-dev
CMAKE_EXTRA_DEFINES=""

# Clear any existing CFLAGS/CXXFLAGS that might have -march=native or other CPU-specific flags
# We want a portable baseline x86-64 build that runs on any x86-64 CPU
unset CFLAGS CXXFLAGS LDFLAGS

# Try clang-20, then clang
# Store cmake defines as array elements (each must be separate argument)
CMAKE_EXTRA_DEFINES=()
if command -v clang-20 &>/dev/null; then
  export CC=clang-20
  export CXX=clang++-20
  export ASM=clang-20
  # Only set -stdlib=libc++, explicitly NO arch-specific flags
  export CFLAGS=""
  export CXXFLAGS="-stdlib=libc++"
  export LDFLAGS="-stdlib=libc++"
  CMAKE_EXTRA_DEFINES+=(CMAKE_C_COMPILER=clang-20)
  CMAKE_EXTRA_DEFINES+=(CMAKE_CXX_COMPILER=clang++-20)
  CMAKE_EXTRA_DEFINES+=(CMAKE_ASM_COMPILER=clang-20)
  echo "Using Clang 20: $(clang-20 --version | head -1)"
elif command -v clang &>/dev/null; then
  export CC=clang
  export CXX=clang++
  export ASM=clang
  export CFLAGS=""
  export CXXFLAGS="-stdlib=libc++"
  export LDFLAGS="-stdlib=libc++"
  CMAKE_EXTRA_DEFINES+=(CMAKE_C_COMPILER=clang)
  CMAKE_EXTRA_DEFINES+=(CMAKE_CXX_COMPILER=clang++)
  CMAKE_EXTRA_DEFINES+=(CMAKE_ASM_COMPILER=clang)
  echo "Using system Clang: $(clang --version | head -1)"
else
  echo "ERROR: Clang not found. Install via: ./deps.sh"
  exit 1
fi

# Build using Python build.py (not shell wrapper) - matches macOS approach
# --compile_no_warning_as_error needed for Clang 20 (stricter array bounds checks)
# NOTE: DO NOT use --minimal_build as it only supports ORT format, not ONNX format
# NOTE: --disable_exceptions and --disable_rtti require --minimal_build
BUILD_ARGS=(
  --build_dir "onnxruntime/build/Linux_${ARCH}"
  --config="$CMAKE_BUILD_TYPE"
  --parallel
  --disable_ml_ops
  --skip_tests
  --compile_no_warning_as_error
)

# Only add reduced ops flags if a config file was provided
if [[ -n "$ONNX_CONFIG" ]]; then
  BUILD_ARGS+=(--include_ops_by_config "$ONNX_CONFIG")
  BUILD_ARGS+=(--enable_reduced_operator_type_support)
fi

# Add cmake defines (compiler settings + disable native CPU optimizations for portability)
# onnxruntime_BUILD_FOR_NATIVE_MACHINE=OFF disables -march=native
# Without AVX flags, build uses baseline x86-64 (SSE2) which runs on any 64-bit CPU
BUILD_ARGS+=(--cmake_extra_defines)
BUILD_ARGS+=("${CMAKE_EXTRA_DEFINES[@]}")
BUILD_ARGS+=(onnxruntime_BUILD_FOR_NATIVE_MACHINE=OFF)

python onnxruntime/tools/ci_build/build.py "${BUILD_ARGS[@]}"

BUILD_DIR=./onnxruntime/build/Linux_${ARCH}/${CMAKE_BUILD_TYPE}

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

# Verify critical libraries exist (note: libonnx.a is in _deps/onnx-build/ on Linux)
MISSING=0
check_lib "${BUILD_DIR}/_deps/onnx-build/libonnx.a" || MISSING=1
check_lib "${BUILD_DIR}/libonnxruntime_common.a" || MISSING=1
check_lib "${BUILD_DIR}/libonnxruntime_session.a" || MISSING=1

if [[ $MISSING -eq 1 ]]; then
  echo ""
  echo "Some libraries are missing. Run with --list-libs to see available libraries."
  echo "You may need to adjust the library list in this script."
  exit 1
fi

# Combine static libraries using ar (Linux equivalent of libtool -static)
# Uses ar -M with MRI script for reliable archive merging
# Automatically finds all abseil libs to avoid missing dependencies
ABSEIL_LIBS=$(find "${BUILD_DIR}/_deps/abseil_cpp-build" -name "*.a" | sort)

echo "Combining libraries into libonnxruntime_all.a..."

# Generate MRI script
cat >/tmp/combine_libs.mri <<MRIEOF
CREATE libonnxruntime_all.a
ADDLIB ${BUILD_DIR}/_deps/onnx-build/libonnx.a
ADDLIB ${BUILD_DIR}/_deps/onnx-build/libonnx_proto.a
ADDLIB ${BUILD_DIR}/libonnxruntime_graph.a
ADDLIB ${BUILD_DIR}/libonnxruntime_mlas.a
ADDLIB ${BUILD_DIR}/libonnxruntime_optimizer.a
ADDLIB ${BUILD_DIR}/libonnxruntime_common.a
ADDLIB ${BUILD_DIR}/libonnxruntime_providers.a
ADDLIB ${BUILD_DIR}/libonnxruntime_session.a
ADDLIB ${BUILD_DIR}/libonnxruntime_flatbuffers.a
ADDLIB ${BUILD_DIR}/libonnxruntime_framework.a
ADDLIB ${BUILD_DIR}/libonnxruntime_util.a
ADDLIB ${BUILD_DIR}/libonnxruntime_lora.a
ADDLIB ${BUILD_DIR}/_deps/re2-build/libre2.a
ADDLIB ${BUILD_DIR}/_deps/protobuf-build/libprotobuf-lite.a
ADDLIB ${BUILD_DIR}/_deps/pytorch_cpuinfo-build/libcpuinfo.a
MRIEOF

# Find and add compiler-rt builtins (provides __cpu_features2 for __builtin_cpu_supports)
CLANG_VERSION="${CC#clang-}" # Extract version from clang-20 -> 20
BUILTINS_LIB="/usr/lib/llvm-${CLANG_VERSION}/lib/clang/${CLANG_VERSION}/lib/linux/libclang_rt.builtins-x86_64.a"
if [[ -f "$BUILTINS_LIB" ]]; then
  echo "ADDLIB ${BUILTINS_LIB}" >>/tmp/combine_libs.mri
  echo "Added compiler-rt builtins from: ${BUILTINS_LIB}"
else
  echo "WARNING: compiler-rt builtins not found at ${BUILTINS_LIB}"
  echo "  You may need to install: apt install libclang-rt-${CLANG_VERSION}-dev"
fi

# Add all abseil libraries
while IFS= read -r lib; do
  [[ -n "$lib" ]] && echo "ADDLIB ${lib}" >>/tmp/combine_libs.mri
done <<< "$ABSEIL_LIBS"

echo "SAVE" >>/tmp/combine_libs.mri
echo "END" >>/tmp/combine_libs.mri

ar -M </tmp/combine_libs.mri
rm -f /tmp/combine_libs.mri

# Move to output directory
mkdir -p libs/linux-x86_64
mv libonnxruntime_all.a libs/linux-x86_64/

echo ""
echo "Static library created: libs/linux-x86_64/libonnxruntime_all.a"
echo ""
echo "To use with fastembed-zig:"
echo "  mkdir -p /path/to/fastembed-zig/deps/onnxruntime-static/{include,lib}"
echo "  cp include/onnxruntime_c_api.h /path/to/fastembed-zig/deps/onnxruntime-static/include/"
echo "  cp libs/linux-x86_64/libonnxruntime_all.a /path/to/fastembed-zig/deps/onnxruntime-static/lib/"
echo ""
echo "Then build osgrep-zig with: zig build -Dstatic=true"

