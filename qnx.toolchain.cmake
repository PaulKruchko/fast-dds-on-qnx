# qnx.toolchain.cmake
# QNX Neutrino 7.1.0 cross toolchain for aarch64le using qcc variants shown by `qcc -V`.
#
# Usage:
#   source ~/qnx710/qnxsdp-env.sh   # (path name may still say 710 even for 7.1.0 installs)
#   export QNX_STAGE=/abs/path/to/qnx_stage   # recommended
#   cmake -S . -B build-qnx \
#     -DCMAKE_TOOLCHAIN_FILE=$PWD/qnx.toolchain.cmake \
#     -DCMAKE_PREFIX_PATH=$QNX_STAGE
#
cmake_minimum_required(VERSION 3.16)

set(CMAKE_SYSTEM_NAME QNX)
set(CMAKE_SYSTEM_VERSION 7.1.0)

# Target arch
set(QNX_ARCH aarch64le)

# Compilers (QNX compiler driver)
set(CMAKE_C_COMPILER qcc)
set(CMAKE_CXX_COMPILER qcc)

# Variants available (from your qcc -V):
#   gcc_ntoaarch64le
#   gcc_ntoaarch64le_cxx
set(QNX_C_VARIANT   "gcc_nto${QNX_ARCH}")
set(QNX_CXX_VARIANT "gcc_nto${QNX_ARCH}_cxx")

# Flags: pick the correct variant and use PIC for shared libs
set(CMAKE_C_FLAGS_INIT   "-V${QNX_C_VARIANT} -fPIC")

# Disable Asio signal_set on QNX to avoid SA_RESTART dependency
set(CMAKE_CXX_FLAGS_INIT
    "-V${QNX_CXX_VARIANT} -fPIC -std=gnu++17 \
     -DASIO_DISABLE_SIGNAL_SET -DASIO_DISABLE_SIGNAL_SET_BASE \
     -DSA_RESTART=0")

# QNX socket library is under $QNX_TARGET/<arch>/lib, not $QNX_TARGET/usr/lib
# Ensure the linker can find it for executables/tools like fast-discovery-server.
set(QNX_ARCH_LIBDIR "$ENV{QNX_TARGET}/${QNX_ARCH}/lib")

set(CMAKE_EXE_LINKER_FLAGS_INIT    "-L${QNX_ARCH_LIBDIR} -lsocket")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L${QNX_ARCH_LIBDIR} -lsocket")

# Ensure QNX env is sourced
if(NOT DEFINED ENV{QNX_TARGET})
  message(FATAL_ERROR "QNX_TARGET is not set. Run: source ~/qnx710/qnxsdp-env.sh")
endif()
if(NOT DEFINED ENV{QNX_HOST})
  message(FATAL_ERROR "QNX_HOST is not set. Run: source ~/qnx710/qnxsdp-env.sh")
endif()

# Sysroot
set(CMAKE_SYSROOT "$ENV{QNX_TARGET}")

# Root paths for finding headers/libs/packages
# IMPORTANT: with *_MODE_PACKAGE=ONLY, staged prefixes must be added here.
if(DEFINED ENV{QNX_STAGE})
  set(CMAKE_FIND_ROOT_PATH
      "$ENV{QNX_TARGET}"
      "$ENV{QNX_STAGE}"
  )
else()
  set(CMAKE_FIND_ROOT_PATH
      "$ENV{QNX_TARGET}"
  )
endif()

# Search for libraries/headers/packages ONLY within CMAKE_FIND_ROOT_PATH
# Programs are host tools, so NEVER.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# RPATH: keep it off; use LD_LIBRARY_PATH on target
set(CMAKE_SKIP_RPATH ON)

# Threads
set(THREADS_PREFER_PTHREAD_FLAG ON)
