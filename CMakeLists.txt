cmake_minimum_required(VERSION 3.16)
project(ipcbench LANGUAGES C CXX)

# -------------------------
# Enforce out-of-source build
# -------------------------
if (CMAKE_SOURCE_DIR STREQUAL CMAKE_BINARY_DIR)
  message(FATAL_ERROR
    "In-source builds are not allowed.\n"
    "Use:\n"
    "  cmake -S ${CMAKE_SOURCE_DIR} -B ${CMAKE_SOURCE_DIR}/build\n"
    "  cmake --build ${CMAKE_SOURCE_DIR}/build\n")
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# -------------------------
# Repo layout paths
# -------------------------
set(REPO_ROOT            ${CMAKE_SOURCE_DIR})
set(SRC_ROOT             ${REPO_ROOT}/src)

set(APP_INC_DIR          ${SRC_ROOT}/app/include)
set(APP_SRC_DIR          ${SRC_ROOT}/app/src)

set(SHIM_INC_DIR         ${SRC_ROOT}/shim/include)
set(SHIM_SRC_DIR         ${SRC_ROOT}/shim/src)

set(IDL_DIR              ${SRC_ROOT}/idl)
set(IDL_FILE             ${IDL_DIR}/Hello.idl)

# Generated code is kept in-repo per your structure:
set(GENERATED_DIR        ${REPO_ROOT}/generated)

# Some people like to keep build-time generated artifacts in the build tree;
# you explicitly want them in ./generated, so we honor that.

# -------------------------
# Ensure required directories exist
# -------------------------
file(MAKE_DIRECTORY ${GENERATED_DIR})
# Also ensure common build subdirs exist (not strictly necessary, but nice)
file(MAKE_DIRECTORY ${CMAKE_BINARY_DIR})

# -------------------------
# Options
# -------------------------
option(IPC_USE_FASTDDS        "Enable Fast DDS backend" ON)
option(IPC_USE_PPS            "Enable QNX PPS backend (QNX only)" OFF)
option(FD_SHIM_USE_WAITSET    "Fast DDS shim: WaitSet (else Polling)" ON)

# If you want to force PPS backend on QNX builds you can default it via toolchain/config.

# -------------------------
# Fast-DDS-Gen integration (IDL -> generated/)
# -------------------------
# We look for a generator executable. Names vary by install:
# - fastddsgen (newer)
# - fastddsgen.jar / Fast-DDS-Gen (java invocation)
# - fastrtpsgen (older ecosystem)
#
# Prefer fastddsgen if found.
find_program(FASTDDSGEN_EXE NAMES fastddsgen fastrtpsgen)

set(GEN_HELLO_H              ${GENERATED_DIR}/HelloMsg.h)
set(GEN_HELLO_CXX            ${GENERATED_DIR}/HelloMsg.cxx)
set(GEN_PUBSUB_H             ${GENERATED_DIR}/HelloMsgPubSubTypes.h)
set(GEN_PUBSUB_CXX           ${GENERATED_DIR}/HelloMsgPubSubTypes.cxx)

set(GENERATED_SOURCES
  ${GEN_HELLO_H}
  ${GEN_HELLO_CXX}
  ${GEN_PUBSUB_H}
  ${GEN_PUBSUB_CXX}
)

# Custom command to generate files only if tool is available.
# If the generator isn't available, we fail with a helpful message.
if (IPC_USE_FASTDDS)
  if (NOT FASTDDSGEN_EXE)
    message(FATAL_ERROR
      "IPC_USE_FASTDDS=ON but no Fast DDS IDL generator found.\n"
      "Install Fast-DDS-Gen (fastddsgen) or ensure it is in PATH.\n"
      "Then re-run cmake.\n")
  endif()

  add_custom_command(
    OUTPUT ${GENERATED_SOURCES}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${GENERATED_DIR}
    # Ensure generator outputs into ./generated
    # fastddsgen supports -d <dir> to select output directory.
    # Some versions accept -typeros2/-example; we avoid those.
    COMMAND ${FASTDDSGEN_EXE} -d ${GENERATED_DIR} ${IDL_FILE}
    DEPENDS ${IDL_FILE}
    WORKING_DIRECTORY ${REPO_ROOT}
    COMMENT "Generating Fast DDS types from ${IDL_FILE} into ${GENERATED_DIR}"
    VERBATIM
  )

  add_custom_target(generate_idl DEPENDS ${GENERATED_SOURCES})
endif()

# -------------------------
# Common sources for apps
# -------------------------
add_executable(sender
  ${APP_SRC_DIR}/sender.c
)
add_executable(receiver
  ${APP_SRC_DIR}/receiver.c
)

target_include_directories(sender PRIVATE ${APP_INC_DIR})
target_include_directories(receiver PRIVATE ${APP_INC_DIR})

# -------------------------
# Backend selection
# -------------------------
# We build one backend object file and link it into sender/receiver.
add_library(ipc_backend_obj OBJECT)

if (IPC_USE_FASTDDS)
  add_compile_definitions(IPC_BACKEND_FASTDDS=1)

  find_package(fastdds REQUIRED)
  find_package(fastcdr REQUIRED)

  # Shim library (C++ shared lib exporting C ABI)
  add_library(fastdds_ipc_shim SHARED
    ${SHIM_INC_DIR}/fastdds_ipc.h
    ${GENERATED_SOURCES}
  )

  # Ensure IDL is generated before building shim
  add_dependencies(fastdds_ipc_shim generate_idl)

  if (FD_SHIM_USE_WAITSET)
    target_sources(fastdds_ipc_shim PRIVATE ${SHIM_SRC_DIR}/fastdds_ipc_waitset.cpp)
    target_compile_definitions(fastdds_ipc_shim PRIVATE FD_SHIM_WAITSET=1)
  else()
    target_sources(fastdds_ipc_shim PRIVATE ${SHIM_SRC_DIR}/fastdds_ipc_polling.cpp)
    target_compile_definitions(fastdds_ipc_shim PRIVATE FD_SHIM_POLLING=1)
  endif()

  target_include_directories(fastdds_ipc_shim PUBLIC
    ${SHIM_INC_DIR}
    ${GENERATED_DIR}
  )

  target_link_libraries(fastdds_ipc_shim PRIVATE fastdds fastcdr)

  # C11 backend wrapper
  target_sources(ipc_backend_obj PRIVATE ${APP_SRC_DIR}/ipc_backend_fastdds.c)

  target_link_libraries(sender PRIVATE fastdds_ipc_shim)
  target_link_libraries(receiver PRIVATE fastdds_ipc_shim)

elseif (IPC_USE_PPS)
  add_compile_definitions(IPC_BACKEND_PPS=1)
  target_sources(ipc_backend_obj PRIVATE ${APP_SRC_DIR}/ipc_backend_pps.c)

else()
  message(FATAL_ERROR "Enable either IPC_USE_FASTDDS or IPC_USE_PPS")
endif()

target_sources(sender PRIVATE $<TARGET_OBJECTS:ipc_backend_obj>)
target_sources(receiver PRIVATE $<TARGET_OBJECTS:ipc_backend_obj>)

# RPATH convenience for Linux (so it finds libfastdds_ipc_shim.so next to binaries if you place it there)
set_target_properties(sender receiver PROPERTIES BUILD_RPATH "\$ORIGIN")

# -------------------------
# Nice-to-have: install layout
# -------------------------
# (Optional) Keep it simple; you can tweak for QNX packaging.
install(TARGETS sender receiver fastdds_ipc_shim
        RUNTIME DESTINATION bin
        LIBRARY DESTINATION lib)

install(FILES fastdds_profiles.xml DESTINATION .)
