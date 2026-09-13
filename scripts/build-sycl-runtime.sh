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
    libur_adapter_level_zero.so
    libur_adapter_level_zero_v2.so.0
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
        driver_library_patterns=(
            'libze_loader.so*'
            'libze_intel_gpu.so*'
            'libigc.so*'
            'libigdgmm.so*'
        )
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
        adapter_library="$(find /opt/intel/oneapi -type f -name 'libur_adapter_level_zero.so*' -print -quit)"
        test -n "${adapter_library}"
        install -m 0755 "${adapter_library}" /output/libur_adapter_level_zero.so
        adapter_library_v2="$(find /opt/intel/oneapi -type f -name 'libur_adapter_level_zero_v2.so*' -print -quit)"
        test -n "${adapter_library_v2}"
        install -m 0755 "${adapter_library_v2}" /output/libur_adapter_level_zero_v2.so.0

        for driver_library_pattern in "${driver_library_patterns[@]}"; do
            while IFS= read -r driver_path; do
                [[ -n "${driver_path}" ]] || continue
                cp -a "${driver_path}" /output/
            done < <(find /usr/lib /usr/local/lib -maxdepth 3 -name "${driver_library_pattern}" -print 2>/dev/null)
        done

        is_core_library() {
            case "$(basename "$1")" in
                ld-linux*|ld.so|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libgcc_s.so.*|libstdc++.so.*|libresolv.so.*|libutil.so.*|linux-vdso.so.*)
                    return 0
                    ;;
            esac
            return 1
        }

        dependency_queue=("${BUILD_DIRECTORY}/bin/libggml-sycl.so" /output/libur_adapter_level_zero.so)
        declare -A copied_dependencies=()
        while ((${#dependency_queue[@]} > 0)); do
            library="${dependency_queue[0]}"
            dependency_queue=("${dependency_queue[@]:1}")
            while read -r dependency; do
                [[ -n "${dependency}" ]] || continue
                dependency_name="$(basename "${dependency}")"
                is_core_library "${dependency_name}" && continue
                if [[ ! -e "/output/${dependency_name}" ]]; then
                    install -m 0755 "${dependency}" "/output/${dependency_name}"
                fi
                if [[ -z "${copied_dependencies[${dependency_name}]+x}" ]]; then
                    copied_dependencies["${dependency_name}"]=1
                    dependency_queue+=("/output/${dependency_name}")
                fi
            done < <(
                ldd "${library}" \
                | sed -n "s/.*=> \\(\\/[^ ]*\\.so[^ ]*\\).*/\\1/p" \
                | sort -u
            )
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
