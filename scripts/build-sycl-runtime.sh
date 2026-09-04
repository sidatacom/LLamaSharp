#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd -- "$script_directory/.." && pwd)"
llama_cpp_directory="${LLAMA_CPP_SOURCE:-$repository_directory/llama.cpp}"
output_directory="${SYCL_OUTPUT_DIRECTORY:-$repository_directory/LLama/runtimes/deps/sycl}"
docker_image="${SYCL_DOCKER_IMAGE:-intel/oneapi-basekit:2025.3.0-0-devel-ubuntu22.04}"
build_directory="${SYCL_BUILD_DIRECTORY:-/build}"
host_user_id="$(id -u)"
host_group_id="$(id -g)"

required_libraries=(
    libllama.so
    libggml.so
    libggml-base.so
    libggml-sycl.so
    libmtmd.so
)

if [[ ! -f "$llama_cpp_directory/CMakeLists.txt" ]]; then
    printf 'llama.cpp source was not found at %s. Initialize the LLamaSharp submodule first.\n' "$llama_cpp_directory" >&2
    printf 'Run: git -C "%s" submodule update --init --recursive\n' "$repository_directory" >&2
    exit 1
fi

mkdir -p "$output_directory"

printf 'Building LLamaSharp SYCL runtime\n'
printf '  image: %s\n' "$docker_image"
printf '  source: %s\n' "$llama_cpp_directory"
printf '  output: %s\n' "$output_directory"

docker run --rm \
    -u 0:0 \
    -v "$llama_cpp_directory:/workspace:ro" \
    -v "$output_directory:/output" \
    -e "BUILD_DIRECTORY=$build_directory" \
    -e "OUTPUT_USER_ID=$host_user_id" \
    -e "OUTPUT_GROUP_ID=$host_group_id" \
    "$docker_image" \
    bash -lc '
        set -eo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update >/dev/null
        apt-get install -y cmake ninja-build >/dev/null
        source /opt/intel/oneapi/setvars.sh --force >/dev/null
        set -u
        rm -rf "${BUILD_DIRECTORY}"
        mkdir -p "${BUILD_DIRECTORY}"
        cd "${BUILD_DIRECTORY}"
        cmake /workspace -G Ninja \
            -DGGML_NATIVE=OFF \
            -DLLAMA_BUILD_TESTS=OFF \
            -DLLAMA_OPENSSL=OFF \
            -DBUILD_SHARED_LIBS=ON \
            -DLLAMA_BUILD_UI=OFF \
            -DLLAMA_BUILD_APP=OFF \
            -DLLAMA_BUILD_EXAMPLES=OFF \
            -DLLAMA_BUILD_SERVER=OFF \
            -DCMAKE_INSTALL_RPATH=\$ORIGIN \
            -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
            -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON \
            -DGGML_SYCL=ON \
            -DGGML_SYCL_F16=ON \
            -DCMAKE_C_COMPILER=icx \
            -DCMAKE_CXX_COMPILER=icpx \
            -DCMAKE_CXX_FLAGS=-fsycl
        cmake --build "${BUILD_DIRECTORY}" --config Release --parallel "$(nproc)" --target ggml ggml-base ggml-sycl llama mtmd
        for library in libllama.so libggml.so libggml-base.so libggml-sycl.so libmtmd.so; do
            test -s "${BUILD_DIRECTORY}/bin/${library}"
            install -m 0755 "${BUILD_DIRECTORY}/bin/${library}" "/output/${library}"
        done
        chown "${OUTPUT_USER_ID}:${OUTPUT_GROUP_ID}" /output/libllama.so /output/libggml.so /output/libggml-base.so /output/libggml-sycl.so /output/libmtmd.so
    '

for library in "${required_libraries[@]}"; do
    if [[ ! -s "$output_directory/$library" ]]; then
        printf 'SYCL build did not produce %s in %s\n' "$library" "$output_directory" >&2
        exit 1
    fi
done

printf 'SYCL runtime completed:\n'
for library in "${required_libraries[@]}"; do
    stat --format='  %n (%s bytes)' "$output_directory/$library"
done
