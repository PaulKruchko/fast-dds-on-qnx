# fast-dds-on-qnx (ipcbench)

A small, reproducible benchmark project that builds a minimal **request/reply** IPC app (`sender` + `receiver`) on:

- **Linux x86_64** (native build)
- **QNX Neutrino 7.1.0 / aarch64le** (cross-compile)

Using eProsima's FastDDS: https://fast-dds.docs.eprosima.com/en/3.x/02-formalia/titlepage.html

The Fast DDS backend is implemented as a **C ABI shim** (`libfastdds_ipc_shim.so`) so the app can remain C-only while using Fast DDS underneath.

The project also supports generating DDS type code from an IDL using **Fast-DDS-Gen** and a simple “generated env” file (`idl_gen.env`) so the build scripts can stay consistent across Linux/QNX.

---

## What you get

- `sender` and `receiver` apps
- Fast DDS C shim: `libfastdds_ipc_shim.so`
- Scripts to:
  - build dependencies into a **stage prefix** (Linux/QNX)
  - generate IDL code and write a **drop-in env file**
  - build the app (Linux/QNX)
  - deploy to QNX and run reliably on target
- CSV capture workflow (`CAPTURE_CSV=1`) for later plotting

---

## Directory tree (what `tree` would show)

Run this to see the exact layout on your machine:

```bash
tree -a -L 4
```

fast-dds-on-qnx/
├── CMakeLists.txt
├── fastdds_profiles.xml
├── qnx.toolchain.cmake
├── generated/
│   └── Hello/
│       ├── idl_gen.env
│       └── src/
│           └── idl/
│               ├── Hello.hpp
│               ├── HelloPubSubTypes.cxx
│               ├── HelloPubSubTypes.hpp
│               ├── HelloTypeObjectSupport.cxx
│               └── HelloTypeObjectSupport.hpp
├── linux_stage/
│   ├── include/            # staged headers (asio + installed headers)
│   ├── lib/                # staged libs (fastdds/fastcdr/foonathan/...)
│   └── share/              # staged package configs (fastdds)
├── qnx_stage/
│   ├── include/
│   ├── lib/
│   └── share/
├── results/                # where you pull CSVs back to on host
├── scripts/
│   ├── build_linux_deps.sh
│   ├── build_qnx_deps.sh
│   ├── gen_idl.sh
│   ├── build_linux_app.sh
│   ├── build_qnx_app.sh
│   ├── deploy_qnx.sh
│   ├── run_qnx.sh
│   ├── summary.py
│   ├── plot_latency.py
│   ├── plot_cpu.py
│   └── plot_cdf.py
└── src/
    ├── idl/
    │   └── Hello.idl
    ├── app/
    │   ├── include/
    │   │   ├── common.h
    │   │   └── ipc_backend.h
    │   └── src/
    │       ├── sender.c
    │       ├── receiver.c
    │       ├── ipc_backend_fastdds.c
    │       └── ipc_backend_pps.c            # optional / QNX-only backend
    └── shim/
        ├── include/
        │   └── fastdds_ipc.h
        └── src/
            ├── fastdds_ipc_waitset.cpp
            └── fastdds_ipc_polling.cpp

Notes:

generated/ is committed/used as in-repo generated artifacts, keyed by IDL file basename.

linux_stage/ and qnx_stage/ are install prefixes containing the built dependency libs and CMake configs.

File-by-file: what everything does
Top-level build + config

CMakeLists.txt
Main build. Builds:

sender, receiver (C)

libfastdds_ipc_shim.so (C++ Fast DDS shim)
It integrates pre-generated IDL output via:

-DIPCBENCH_GENERATED_IDL_DIR=...

-DIPCBENCH_GEN_BASENAME=...
and generates small wrapper headers in the build dir so shim code can include stable names like:

ipcbench_idl.hpp

ipcbench_idl_pubsub.hpp

qnx.toolchain.cmake
QNX cross toolchain file (QNX Neutrino 7.1.0 / aarch64le). Points CMake at qcc variants, sysroot, and staged prefix discovery rules.

fastdds_profiles.xml
Fast DDS XML profile file. On QNX we ultimately keep this minimal QoS-only to avoid XML transport schema differences across versions/builds. The shim enforces UDP-only programmatically.

Source code (apps)

src/app/include/common.h
Defines fd_msg_t and timing helpers (now_monotonic_ns, cpu_time_ns).

src/app/include/ipc_backend.h
Backend-agnostic API used by sender.c and receiver.c. The backend implementation is selected at build time (FastDDS or PPS).

src/app/src/sender.c
Sends requests, waits for replies, prints per-iteration measurements. When CAPTURE_CSV=1 is used (via run script), stdout is redirected to a .csv file.

src/app/src/receiver.c
Receives requests and responds with a modified payload.

src/app/src/ipc_backend_fastdds.c
Implements ipc_backend.h using the shim (fastdds_ipc.h). This is the bridge from the C app to the C++ DDS shim.

src/app/src/ipc_backend_pps.c
(Optional / QNX-only) PPS backend stub/implementation, if you choose to support PPS later.

Source code (Fast DDS shim)

src/shim/include/fastdds_ipc.h
C ABI for the shim: create/destroy, send/take request/reply.

src/shim/src/fastdds_ipc_waitset.cpp
Fast DDS shim implementation using a true WaitSet (no polling).
Also forces UDP-only and loopback discovery to avoid SHM and XML transport parsing issues on QNX.

src/shim/src/fastdds_ipc_polling.cpp
Same semantics as waitset version, but uses polling loops to take samples (fallback / comparison).

## IDL + generated code

src/idl/Hello.idl
DDS type definitions. Example includes:

```
struct HelloMsg
{
  unsigned long counter;
  unsigned long long t_send_ns;
  string<64> text;
};
```

generated/<IDLNAME>/src/idl/*
Output of Fast-DDS-Gen for that IDL file. The project can build without having fastddsgen in PATH as long as these generated sources exist.

generated/<IDLNAME>/idl_gen.env
A small env file written by scripts/gen_idl.sh so the build scripts know:

which IDL was used

where the generated code lives

what basename to include (Hello, etc.)

Scripts: deps, build, deploy, run

scripts/build_linux_deps.sh
Builds and installs dependencies into linux_stage/:

foonathan_memory

Fast-CDR

Fast-DDS

stages standalone Asio headers

(optionally) tinyxml2 if required by the Fast-DDS build you’re using

scripts/build_qnx_deps.sh
Cross-builds and installs dependencies into qnx_stage/ (QNX aarch64le):

foonathan_memory

Fast-CDR

tinyxml2

Fast-DDS (tools disabled to avoid extra link deps)

stages standalone Asio headers

scripts/gen_idl.sh
Runs Fast-DDS-Gen (fastddsgen) for a chosen IDL and writes:

generated sources into generated/<IDLNAME>/...

generated/<IDLNAME>/idl_gen.env for consistent subsequent builds

scripts/build_linux_app.sh
Configures and builds the app natively using linux_stage/. Auto-loads the most recent generated/*/idl_gen.env unless overridden.

scripts/build_qnx_app.sh
Configures and cross-builds the app using QNX toolchain + qnx_stage/. Auto-loads the most recent generated/*/idl_gen.env unless overridden.

scripts/deploy_qnx.sh
Copies the QNX build outputs + required runtime libs + run_qnx.sh to the target.
Also has an “autofix missing libs” step by parsing ldd output on target and pulling missing libs from $QNX_TARGET/aarch64le.

scripts/run_qnx.sh
Runs on the QNX target with a minimal /bin/sh compatible script.

run_qnx.sh receiver runs receiver in foreground

run_qnx.sh sender runs sender (optionally redirects to CSV)

run_qnx.sh both runs receiver bg and sender fg

## Plotting/analysis (host-side)

scripts/summary.py
Summarizes CSV runs (you provided this; we’ll keep column names aligned to your “verbose columns” once applied).

scripts/plot_latency.py
Plot latency over time.

scripts/plot_cpu.py
Plot CPU utilization (%) over time.

scripts/plot_cdf.py
Plot a latency CDF (cumulative distribution function: “what fraction of samples are ≤ X ms”).

## Dependencies you need to clone alongside this repo

This repo expects sibling directories (same parent folder) or repo-local dirs; the scripts search both.

Recommended layout:

~/work/
├── fast-dds-on-qnx/
├── foonathan_memory/
├── Fast-CDR/
├── Fast-DDS/
├── asio/
├── tinyxml2/
└── Fast-DDS-Gen/

Dependencies:

foonathan_memory (Fast DDS dependency)

Fast-CDR (Fast DDS dependency)

Fast-DDS (the middleware)

asio (standalone Asio headers, staged into the prefix)

tinyxml2 (Fast DDS dependency for XML parsing)

Fast-DDS-Gen (IDL generator; needed for scripts/gen_idl.sh)

Download / clone instructions

```bash

# Choose a workspace directory
mkdir -p ~/work && cd ~/work

# Main repo
git clone <YOUR_URL>/fast-dds-on-qnx.git

# Dependencies
git clone <YOUR_URL>/foonathan_memory.git
git clone <YOUR_URL>/Fast-CDR.git
git clone <YOUR_URL>/Fast-DDS.git
git clone <YOUR_URL>/asio.git
git clone <YOUR_URL>/tinyxml2.git
git clone <YOUR_URL>/Fast-DDS-Gen.git

```
Build instructions (Linux)
1) Build dependencies into linux_stage/

```bash
cd ~/work/fast-dds-on-qnx
./scripts/build_linux_deps.sh
```
2) Generate IDL (recommended)

```bash
# Put fastddsgen on PATH (example)
export PATH=~/work/Fast-DDS-Gen/scripts:$PATH

# Generate code for an IDL file (writes generated/<idlname>/idl_gen.env)
./scripts/gen_idl.sh ./src/idl/Hello.idl
```
3) Build the app (cross)

```bash
./scripts/build_qnx_app.sh
```
Deploy + run on QNX target
1) Deploy to target

```bash
# Host side
source ~/qnx710/qnxsdp-env.sh
./scripts/deploy_qnx.sh --target autodrive@192.168.0.14 --dir /opt/home/autodrive
```

2) Run on target (two terminals)

Terminal 1 (receiver):
```bash
export TARGET_DIR=/opt/home/autodrive
$TARGET_DIR/run_qnx.sh receiver
```
Terminal 2 (sender + capture CSV):
```bash
export TARGET_DIR=/opt/home/autodrive
CAPTURE_CSV=1 $TARGET_DIR/run_qnx.sh sender
```
The CSV will appear under:
/opt/home/autodrive/out/

3) Pull CSV back to host
```bash
# Host side
mkdir -p ~/work/fast-dds-on-qnx/results
scp autodrive@192.168.0.14:/opt/home/autodrive/out/*.csv ~/work/fast-dds-on-qnx/results/
```
About CSV output (what it is and where it goes)

The benchmark is designed so sender prints per-iteration timing lines to stdout.

On QNX:

run_qnx.sh optionally redirects sender stdout into:

out/<backend>_sender.csv (example: fastdds_sender.csv)

On Linux:

you can redirect stdout manually, or we can add the same capture behavior to a Linux run helper later if you want.

CDF: what it means here

CDF = Cumulative Distribution Function for latency:

X axis: latency in ms

Y axis: fraction of samples with latency ≤ X

Example interpretation:

If the CDF at 2.0 ms is 0.95, then 95% of requests completed in ≤ 2.0 ms.

This is often more useful than averages because it shows tail behavior (p95, p99).

Troubleshooting notes (QNX)

If you see missing runtime libs (e.g., libc++.so.1, libcatalog.so.1):

scripts/deploy_qnx.sh can auto-copy missing libs from $QNX_TARGET/aarch64le using ldd parsing.

SHM transport errors:

We force UDP-only inside the shim (programmatic transport config), and keep XML minimal QoS-only.


