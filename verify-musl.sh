#!/usr/bin/env bash

set -euf -o pipefail

# Verify the musl static library has no glibc dependencies
# and contains the expected ONNX Runtime symbols

# Auto-detect architecture for default path
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) ARCH="x86_64" ;;
esac

LIB="${1:-libs/linux-${ARCH}-musl/libonnxruntime_all.a}"

echo "=============================================="
echo "Verifying musl static library"
echo "=============================================="
echo ""

if [[ ! -f "$LIB" ]]; then
  echo "ERROR: Library not found: $LIB"
  echo ""
  echo "Run ./build-linux-musl.sh first to create the library."
  exit 1
fi

echo "Library: $LIB"
echo ""

# File size
echo "=== Library Info ==="
ls -lh "$LIB"
echo ""

# Check for glibc-specific symbols that shouldn't be there
echo "=== Checking for glibc symbols (should be empty) ==="
GLIBC_SYMBOLS=$(nm "$LIB" 2>/dev/null | rg -i '__libc_start_main|__gmon_start__|__cxa_finalize.*GLIBC|GLIBC_' | head -10 || true)
if [[ -n "$GLIBC_SYMBOLS" ]]; then
  echo "WARNING: Found potential glibc symbols:"
  echo "$GLIBC_SYMBOLS"
  echo ""
  echo "This may indicate incomplete static linking."
else
  echo "OK: No obvious glibc symbols detected"
fi
echo ""

# Check for ONNX Runtime C API symbols
echo "=== Checking for ONNX Runtime API symbols ==="
ORT_SYMBOLS=$(nm "$LIB" 2>/dev/null | rg 'OrtGetApiBase|OrtCreateEnv|OrtSessionOptionsAppendExecutionProvider' | head -5 || true)
if [[ -n "$ORT_SYMBOLS" ]]; then
  echo "OK: ONNX Runtime API symbols found:"
  echo "$ORT_SYMBOLS"
else
  echo "WARNING: ONNX Runtime API symbols not found"
  echo "Checking for any Ort symbols..."
  nm "$LIB" 2>/dev/null | rg '^[0-9a-f]* T.*Ort' | head -5 || echo "  (none found)"
fi
echo ""

# Count total symbols
echo "=== Symbol Statistics ==="
TOTAL_SYMBOLS=$(nm "$LIB" 2>/dev/null | wc -l || echo "0")
TEXT_SYMBOLS=$(nm "$LIB" 2>/dev/null | rg '^[0-9a-f]* T' | wc -l || echo "0")
echo "Total symbols: $TOTAL_SYMBOLS"
echo "Text (code) symbols: $TEXT_SYMBOLS"
echo ""

# Check for dynamic dependencies (should be none for static lib)
echo "=== Dynamic Dependencies (should be empty/error) ==="
if command -v readelf &>/dev/null; then
  readelf -d "$LIB" 2>&1 | head -5 || echo "OK: No dynamic section (expected for static lib)"
else
  echo "readelf not available, skipping dynamic dependency check"
fi
echo ""

# Archive contents summary
echo "=== Archive Contents Summary ==="
if command -v ar &>/dev/null; then
  OBJECT_COUNT=$(ar -t "$LIB" 2>/dev/null | wc -l || echo "0")
  echo "Object files in archive: $OBJECT_COUNT"
  echo ""
  echo "Sample object files:"
  ar -t "$LIB" 2>/dev/null | head -10
  echo "..."
else
  echo "ar not available, skipping archive contents check"
fi
echo ""

# Summary
echo "=============================================="
echo "Verification complete"
echo "=============================================="
echo ""
echo "If all checks passed, this library should work in:"
echo "  - FROM scratch containers"
echo "  - Alpine/musl-based containers"
echo "  - Any Linux system (statically linked binaries)"
echo ""
