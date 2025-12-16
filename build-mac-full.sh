#!/usr/bin/env bash
# Full build of ONNX Runtime (with all ops including Tokenizer/contrib)
# Based on ort-builder but without --minimal_build
set -euf -o pipefail

CMAKE_BUILD_TYPE=Release
ARCH="${1:-arm64}"

echo "Building ONNX Runtime ${CMAKE_BUILD_TYPE} for macOS ${ARCH}..."
echo "This will take 10-15 minutes..."

python onnxruntime/tools/ci_build/build.py \
  --build_dir "onnxruntime/build/macOS_${ARCH}" \
  --config=${CMAKE_BUILD_TYPE} \
  --parallel \
  --skip_tests \
  --compile_no_warning_as_error \
  --cmake_extra_defines \
    CMAKE_OSX_ARCHITECTURES="${ARCH}" \
    onnxruntime_BUILD_UNIT_TESTS=OFF \
    onnxruntime_BUILD_SHARED_LIB=OFF \
    CMAKE_DISABLE_FIND_PACKAGE_Protobuf=ON \
    onnxruntime_USE_FULL_PROTOBUF=ON

BUILD_DIR=./onnxruntime/build/macOS_${ARCH}/${CMAKE_BUILD_TYPE}

echo ""
echo "Build complete. Combining static libraries..."

# Find all the static libraries we need to combine
# Core ORT libs
LIBS=""
for lib in \
  libonnxruntime_common.a \
  libonnxruntime_flatbuffers.a \
  libonnxruntime_framework.a \
  libonnxruntime_graph.a \
  libonnxruntime_mlas.a \
  libonnxruntime_optimizer.a \
  libonnxruntime_providers.a \
  libonnxruntime_session.a \
  libonnxruntime_util.a \
  ; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  fi
done

# ONNX libs
for lib in \
  libonnx.a \
  libonnx_proto.a \
  ; do
  if [ -f "${BUILD_DIR}/${lib}" ]; then
    LIBS="${LIBS} ${BUILD_DIR}/${lib}"
  fi
done

# Dependency libs from _deps
for lib in \
  _deps/protobuf-build/libprotobuf.a \
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

echo "Combining libraries with libtool..."
OUTPUT_LIB="libonnxruntime-macOS_${ARCH}.a"
libtool -static -o "${OUTPUT_LIB}" ${LIBS}

echo ""
echo "Created: ${OUTPUT_LIB}"
ls -lh "${OUTPUT_LIB}"

echo ""
echo "To use in onnxruntime-zig:"
echo "  cp ${OUTPUT_LIB} ../onnxruntime-zig/deps/onnxruntime-static/lib/libonnxruntime_all.a"
echo "  cp onnxruntime/include/onnxruntime/core/session/*.h ../onnxruntime-zig/deps/onnxruntime-static/include/"
