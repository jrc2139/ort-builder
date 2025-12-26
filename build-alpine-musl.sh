#!/usr/bin/env bash

set -euf -o pipefail

# Build ONNX Runtime as a static musl library using Alpine's native toolchain
# Alpine uses musl as its system libc - no cross-compilation needed
#
# Usage:
#   ./build-alpine-musl.sh [config-file] [--arch x86_64|aarch64]

CMAKE_BUILD_TYPE=MinSizeRel

# Parse arguments
ONNX_CONFIG=""
TARGET_ARCH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--arch)
		TARGET_ARCH="$2"
		shift 2
		;;
	--list-libs)
		LIST_LIBS=1
		shift
		;;
	*)
		ONNX_CONFIG="$1"
		shift
		;;
	esac
done

# Auto-detect architecture or use override
if [[ -n "$TARGET_ARCH" ]]; then
	case "$TARGET_ARCH" in
	x86_64 | amd64) ARCH="x86_64" ;;
	aarch64 | arm64) ARCH="aarch64" ;;
	*)
		echo "ERROR: Unsupported architecture: $TARGET_ARCH"
		exit 1
		;;
	esac
	echo "Using override architecture: $ARCH"
else
	HOST_ARCH=$(uname -m)
	case "$HOST_ARCH" in
	x86_64 | amd64) ARCH="x86_64" ;;
	aarch64 | arm64) ARCH="aarch64" ;;
	*)
		echo "ERROR: Unsupported architecture: $HOST_ARCH"
		exit 1
		;;
	esac
	echo "Auto-detected architecture: $ARCH"
fi

# Handle --list-libs
if [[ "${LIST_LIBS:-}" == "1" ]]; then
	BUILD_DIR=./onnxruntime/build/Linux_${ARCH}_musl/${CMAKE_BUILD_TYPE}
	echo "Listing .a files in: $BUILD_DIR"
	find "$BUILD_DIR" -name "*.a" 2>/dev/null | sort
	exit 0
fi

echo ""
echo "=============================================="
echo "Building ONNX Runtime for Alpine/musl"
echo "Architecture: $ARCH"
echo "=============================================="
echo ""

if [[ -n "$ONNX_CONFIG" ]]; then
	echo "Using reduced ops config: ${ONNX_CONFIG}"
else
	echo "Building with FULL operators"
fi

# Apply patches
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

# Build arguments
BUILD_ARGS=(
	--build_dir "onnxruntime/build/Linux_${ARCH}_musl"
	--config="$CMAKE_BUILD_TYPE"
	--parallel
	--disable_ml_ops
	--skip_tests
	--compile_no_warning_as_error
	--allow_running_as_root
)

# Reduced ops if config provided
if [[ -n "$ONNX_CONFIG" ]]; then
	BUILD_ARGS+=(--include_ops_by_config "$ONNX_CONFIG")
	BUILD_ARGS+=(--enable_reduced_operator_type_support)
fi

# CMake defines
BUILD_ARGS+=(--cmake_extra_defines)
BUILD_ARGS+=(onnxruntime_BUILD_FOR_NATIVE_MACHINE=OFF)
BUILD_ARGS+=(onnxruntime_BUILD_SHARED_LIB=OFF)
BUILD_ARGS+=(onnxruntime_BUILD_UNIT_TESTS=OFF)
BUILD_ARGS+=(protobuf_BUILD_SHARED_LIBS=OFF)

echo ""
echo "Starting build..."
echo ""

# Run with verbose output to catch errors
python3 onnxruntime/tools/ci_build/build.py "${BUILD_ARGS[@]}" 2>&1 | tee /tmp/build.log

# Check for failure
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
	echo ""
	echo "=============================================="
	echo "BUILD FAILED - Last 100 lines of log:"
	echo "=============================================="
	tail -100 /tmp/build.log
	exit 1
fi

BUILD_DIR=./onnxruntime/build/Linux_${ARCH}_musl/${CMAKE_BUILD_TYPE}

# Build re2 if not already built (ORT configures but doesn't always build it)
if [[ ! -f "${BUILD_DIR}/_deps/re2-build/libre2.a" ]] && [[ -d "${BUILD_DIR}/_deps/re2-build" ]]; then
	echo ""
	echo "Building re2 static library..."
	cmake --build "${BUILD_DIR}/_deps/re2-build" --config "$CMAKE_BUILD_TYPE" --target re2
fi

echo ""
echo "Build complete. Combining static libraries..."

# Find abseil libs
ABSEIL_LIBS=$(find "${BUILD_DIR}/_deps/abseil_cpp-build" -name "*.a" 2>/dev/null | sort)

# Generate MRI script for ar
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
ADDLIB ${BUILD_DIR}/_deps/protobuf-build/libprotobuf-lite.a
ADDLIB ${BUILD_DIR}/_deps/pytorch_cpuinfo-build/libcpuinfo.a
MRIEOF

# Add re2 if present
RE2_LIB="${BUILD_DIR}/_deps/re2-build/libre2.a"
if [[ -f "$RE2_LIB" ]]; then
	echo "ADDLIB ${RE2_LIB}" >>/tmp/combine_libs.mri
	echo "Added: libre2.a"
else
	echo "WARNING: libre2.a not found, skipping"
fi

# Add abseil libraries
while IFS= read -r lib; do
	[[ -n "$lib" ]] && echo "ADDLIB ${lib}" >>/tmp/combine_libs.mri
done <<<"$ABSEIL_LIBS"

# Add nsync if present
NSYNC_LIB="${BUILD_DIR}/_deps/google_nsync-build/libnsync_cpp.a"
if [[ -f "$NSYNC_LIB" ]]; then
	echo "ADDLIB ${NSYNC_LIB}" >>/tmp/combine_libs.mri
fi

# Add libc++ static libraries (for Zig ABI compatibility)
# Alpine installs these in /usr/lib
if [[ -f "/usr/lib/libc++.a" ]]; then
	echo "ADDLIB /usr/lib/libc++.a" >>/tmp/combine_libs.mri
	echo "Added: libc++.a"
fi
if [[ -f "/usr/lib/libc++abi.a" ]]; then
	echo "ADDLIB /usr/lib/libc++abi.a" >>/tmp/combine_libs.mri
	echo "Added: libc++abi.a"
fi

# Add compiler-rt builtins if available
BUILTINS=$(find /usr/lib/clang -name "libclang_rt.builtins-*.a" 2>/dev/null | head -1)
if [[ -n "$BUILTINS" && -f "$BUILTINS" ]]; then
	echo "ADDLIB ${BUILTINS}" >>/tmp/combine_libs.mri
	echo "Added: $(basename "$BUILTINS")"
fi

# Add libunwind for exception handling
if [[ -f "/usr/lib/libunwind.a" ]]; then
	echo "ADDLIB /usr/lib/libunwind.a" >>/tmp/combine_libs.mri
	echo "Added: libunwind.a"
fi

# Add libexecinfo for backtrace support (musl)
if [[ -f "/usr/lib/libexecinfo.a" ]]; then
	echo "ADDLIB /usr/lib/libexecinfo.a" >>/tmp/combine_libs.mri
	echo "Added: libexecinfo.a"
fi

echo "SAVE" >>/tmp/combine_libs.mri
echo "END" >>/tmp/combine_libs.mri

ar -M </tmp/combine_libs.mri
rm -f /tmp/combine_libs.mri

# Move to output directory
mkdir -p "libs/linux-${ARCH}-musl"
mv libonnxruntime_all.a "libs/linux-${ARCH}-musl/"

echo ""
echo "=============================================="
echo "SUCCESS: libs/linux-${ARCH}-musl/libonnxruntime_all.a"
echo "=============================================="
echo ""
echo "This library is compiled against musl libc."
echo "Link into Zig projects with: -target ${ARCH}-linux-musl"
echo ""
