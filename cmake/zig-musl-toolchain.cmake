# Zig Cross-Compilation Toolchain for Linux musl
#
# Creates fully static binaries with zero glibc dependencies.
# Zig bundles musl, libc++, libc++abi, and libunwind.
#
# Architecture is determined by ZIG_TARGET env var:
#   x86_64-linux-musl  or  aarch64-linux-musl
#
# Usage:
#   export ZIG_TARGET=aarch64-linux-musl
#   cmake -DCMAKE_TOOLCHAIN_FILE=cmake/zig-musl-toolchain.cmake ..

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)

# Detect target architecture from ZIG_TARGET env var
if(DEFINED ENV{ZIG_TARGET})
    set(ZIG_TARGET "$ENV{ZIG_TARGET}")
else()
    set(ZIG_TARGET "x86_64-linux-musl")
endif()

# Set processor based on target
if(ZIG_TARGET MATCHES "^x86_64")
    set(CMAKE_SYSTEM_PROCESSOR x86_64)
elseif(ZIG_TARGET MATCHES "^aarch64")
    set(CMAKE_SYSTEM_PROCESSOR aarch64)
else()
    message(FATAL_ERROR "Unknown ZIG_TARGET: ${ZIG_TARGET}")
endif()

message(STATUS "Zig musl toolchain: ${ZIG_TARGET} (${CMAKE_SYSTEM_PROCESSOR})")

# Use wrapper scripts (CMake's CMAKE_AR doesn't support commands with arguments)
set(CMAKE_C_COMPILER "${CMAKE_CURRENT_LIST_DIR}/zig-cc")
set(CMAKE_CXX_COMPILER "${CMAKE_CURRENT_LIST_DIR}/zig-cxx")
set(CMAKE_ASM_COMPILER "${CMAKE_CURRENT_LIST_DIR}/zig-cc")
set(CMAKE_AR "${CMAKE_CURRENT_LIST_DIR}/zig-ar")
set(CMAKE_RANLIB "${CMAKE_CURRENT_LIST_DIR}/zig-ranlib")

# Tell CMake to not try running test executables (may be cross-compiled)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Static linking flags
set(CMAKE_C_FLAGS_INIT "-static")
set(CMAKE_CXX_FLAGS_INIT "-static")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static")

# Force static libraries only
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries" FORCE)

# Don't search host paths for libraries/includes
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Disable position-independent code for fully static builds
set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
