#!/bin/zsh
# Builds and runs the shader A/B harness (see shader_ab.mm).
#   benchmarks/ab/run.sh [--layers 5000] [--frames 240]
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p build
clang++ -std=c++20 -O2 -fobjc-arc -Wno-unused-parameter -I Sources/MFCore/include \
    benchmarks/ab/shader_ab.mm Sources/MFCore/*.cpp \
    -framework Metal -framework Foundation -o build/shader_ab
build/shader_ab "$@"
