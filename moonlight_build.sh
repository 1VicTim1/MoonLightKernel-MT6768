#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="MoonLightKernel"
DEFAULT_VARIANT="vanilla"
DEFAULT_MAINTAINER="~VicTim~"
DEFAULT_COMPILER="AOSP clang 14"
DEFAULT_SUPPORTED_VERSIONS="13.0-16.0"
DEFAULT_BUILD_USER="1VicTim1"
DEFAULT_BUILD_HOST="MoonLightKernel"
DEFAULT_PROFILE="vanilla"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_BASE="$ROOT_DIR/out"
RELEASE_DIR="$ROOT_DIR/release"
ANYKERNEL_DIR="$ROOT_DIR/packaging/anykernel"

DEVICE=""
VARIANT="$DEFAULT_VARIANT"
PROFILE="$DEFAULT_PROFILE"
MAINTAINER="$DEFAULT_MAINTAINER"
COMPILER_STRING="$DEFAULT_COMPILER"
SUPPORTED_VERSIONS="$DEFAULT_SUPPORTED_VERSIONS"
BUILD_USER="$DEFAULT_BUILD_USER"
BUILD_HOST="$DEFAULT_BUILD_HOST"
DEFCONFIG_OVERRIDE=""
CONFIG_SOURCE=""
LOCALVERSION_OVERRIDE=""
LLVM_IAS_VALUE=0
STAMP=""
JOBS="$(nproc)"
SYMBOL_CRC_OVERRIDES=()
CONFIG_FRAGMENTS=()

DO_CLEAN=0
DO_MRPROPER=0
DO_PACKAGE=1
USE_CCACHE=1
USE_WERROR=0
LIST_PROFILES=0
CUSTOM_OUT_BASE=0
CUSTOM_RELEASE_DIR=0

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$1" "$2"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") --device <heat|fire|both|universal> [options]

Options:
  --device <name>         Target device: heat, fire, both, universal
  --profile <name>        Build preset (default: ${DEFAULT_PROFILE})
  --variant <name>        Build label used in package naming (default: ${DEFAULT_VARIANT})
  --defconfig <name>      Override defconfig for all selected devices
  --config <path>         Seed build from an existing .config or config.gz
  --config-fragment <p>   Merge a Kconfig fragment after seeding the base config
  --localversion <text>   Override CONFIG_LOCALVERSION and disable LOCALVERSION_AUTO
  --symbol-crc <spec>     Override exported symbol CRC after build, format: name=deadbeef
  --llvm-ias <0|1>        Set LLVM integrated assembler usage (default: ${LLVM_IAS_VALUE})
  --jobs <count>          Parallel jobs for make (default: $(nproc))
  --stamp <yyyymmdd>      Override artifact date stamp (default: today)
  --out-dir <path>        Output base directory (default: ${OUT_BASE})
  --release-dir <path>    Release artifacts directory (default: ${RELEASE_DIR})
  --anykernel-dir <path>  AnyKernel3 template directory (default: ${ANYKERNEL_DIR})
  --maintainer <name>     Maintainer string for AnyKernel banner (default: ${DEFAULT_MAINTAINER})
  --compiler <text>       Compiler string for AnyKernel metadata
  --supported <text>      Supported Android versions for AnyKernel metadata
  --build-user <name>     KBUILD_BUILD_USER value (default: ${DEFAULT_BUILD_USER})
  --build-host <name>     KBUILD_BUILD_HOST value (default: ${DEFAULT_BUILD_HOST})
  --clean                 Remove the device out directory before build
  --mrproper              Run in-tree make mrproper before the first build
  --package               Build AnyKernel3 zip (default)
  --no-package            Skip AnyKernel3 zip creation
  --ccache                Enable ccache (default)
  --no-ccache             Disable ccache
  --werror                Keep warnings as errors
  --list-profiles         Show available build presets and exit
  --help                  Show this help

Examples:
  ./moonlight_build.sh --device heat
  ./moonlight_build.sh --device heat --profile miui-stock
  ./moonlight_build.sh --device heat --config-fragment packaging/config-fragments/example.config
  ./moonlight_build.sh --device heat --config /tmp/heat.config --localversion -perf-g5431a848c102
  ./moonlight_build.sh --device heat --symbol-crc remap_pfn_range=a5447b97
  ./moonlight_build.sh --device fire --variant kernelsu --jobs 16 --llvm-ias 0
  ./moonlight_build.sh --device both --variant vanilla --clean
  ./moonlight_build.sh --device universal --profile kernelsu --variant kernelsu-universal
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

normalize_variant() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-'
}

show_profiles() {
  cat <<EOF
Available profiles:
  vanilla
    Unified heat/fire build from the shared MoonLightKernel defconfig.
  miui-stock
    Shared heat/fire preset for MIUI stock vendor module compatibility.
    Applies:
      localversion=-perf-g5431a848c102
      symbol-crc remap_pfn_range=a5447b97
  nethunter
    Shared heat/fire preset for NetHunter-oriented builds on stock MIUI vendor.
    Applies:
      localversion=-perf-g5431a848c102
      symbol-crc remap_pfn_range=a5447b97
      fragment packaging/config-fragments/nethunter.config
  kernelsu
    Shared heat/fire preset for KernelSU builds on stock MIUI vendor.
    Applies:
      localversion=-perf-g5431a848c102
      symbol-crc remap_pfn_range=a5447b97
      fragment packaging/config-fragments/kernelsu.config
EOF
}

device_defconfig() {
  case "$1" in
    heat|fire|universal) echo "moonlight_mt6768_defconfig" ;;
    *) die "unsupported device: $1" ;;
  esac
}

device_config_fragment() {
  case "$1" in
    heat) echo "$(resolve_existing_file "packaging/config-fragments/device-heat.config")" ;;
    fire) echo "$(resolve_existing_file "packaging/config-fragments/device-fire.config")" ;;
    universal) echo "$(resolve_existing_file "packaging/config-fragments/device-universal.config")" ;;
    *) die "unsupported device: $1" ;;
  esac
}

resolve_defconfig() {
  if [[ -n "$DEFCONFIG_OVERRIDE" ]]; then
    echo "$DEFCONFIG_OVERRIDE"
  else
    device_defconfig "$1"
  fi
}

device_list() {
  case "$DEVICE" in
    heat|fire|universal) echo "$DEVICE" ;;
    both) echo "heat fire" ;;
    *) die "unsupported device: $DEVICE" ;;
  esac
}

resolve_existing_file() {
  local input_path="$1"

  if [[ -f "$input_path" ]]; then
    echo "$input_path"
    return
  fi

  if [[ -f "$ROOT_DIR/$input_path" ]]; then
    echo "$ROOT_DIR/$input_path"
    return
  fi

  die "file does not exist: $input_path"
}

append_unique() {
  local array_name="$1"
  local value="$2"
  local -n target="$array_name"
  local current

  for current in "${target[@]:-}"; do
    if [[ "$current" == "$value" ]]; then
      return
    fi
  done

  target+=("$value")
}

setup_ccache() {
  if [[ "$USE_CCACHE" -eq 0 ]]; then
    return
  fi

  need_cmd ccache
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache/moonlightkernel}"
  export CCACHE_BASEDIR="$ROOT_DIR"
  export CCACHE_NOHASHDIR="true"
  export CCACHE_COMPRESS="true"
  export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-6}"
  export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-time_macros}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"
  mkdir -p "$CCACHE_DIR"

  if [[ -d /usr/lib/ccache ]]; then
    export PATH="/usr/lib/ccache:$PATH"
  fi

  ccache -M "$CCACHE_MAXSIZE" >/dev/null
}

setup_toolchain() {
  if [[ -d /usr/lib/llvm-14/bin ]]; then
    export PATH="/usr/lib/llvm-14/bin:$PATH"
  fi

  need_cmd make
  need_cmd python3
  need_cmd gzip
  need_cmd clang-14
  need_cmd ld.lld-14
  need_cmd aarch64-linux-gnu-gcc
  need_cmd arm-linux-gnueabi-gcc
  need_cmd zip
  need_cmd unzip
  need_cmd sha256sum

  export ARCH=arm64
  export SUBARCH=arm64
  export LLVM=-14
  export LLVM_IAS="$LLVM_IAS_VALUE"
  export CROSS_COMPILE=aarch64-linux-gnu-
  export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
  export CLANG_TRIPLE=aarch64-linux-gnu-
  export AR=llvm-ar-14
  export NM=llvm-nm-14
  export OBJCOPY=llvm-objcopy-14
  export OBJDUMP=llvm-objdump-14
  export READELF=llvm-readelf-14
  export OBJSIZE=llvm-size-14
  export STRIP=llvm-strip-14
  export HOSTCC=clang-14
  export HOSTCXX=clang++-14
  export KBUILD_BUILD_USER="$BUILD_USER"
  export KBUILD_BUILD_HOST="$BUILD_HOST"

  if [[ "$USE_WERROR" -eq 0 ]]; then
    export KCFLAGS="${KCFLAGS:-} -Wno-error"
  fi
}

make_kernel() {
  make LOCALVERSION= "$@"
}

merge_config_fragments() {
  local out_dir="$1"
  shift
  local config_path="$out_dir/.config"
  local fragments=("$@")
  local fragment

  if [[ "${#fragments[@]}" -eq 0 ]]; then
    return
  fi

  [[ -f "$config_path" ]] || die "missing config for fragment merge: $config_path"

  for fragment in "${fragments[@]}"; do
    [[ -f "$fragment" ]] || die "missing config fragment: $fragment"
  done

  log "CONFIG" "merging ${#fragments[@]} fragment(s)"
  (
    cd "$ROOT_DIR"
    KCONFIG_CONFIG="$config_path" \
      "$ROOT_DIR/scripts/kconfig/merge_config.sh" -m -O "$out_dir" "$config_path" "${fragments[@]}" >/dev/null
  )
}

set_localversion_override() {
  local config="$1"
  local localversion="$2"

  if [[ -x "$ROOT_DIR/scripts/config" ]]; then
    if [[ -n "$localversion" ]]; then
      "$ROOT_DIR/scripts/config" --file "$config" --set-str LOCALVERSION "$localversion"
    fi
    "$ROOT_DIR/scripts/config" --file "$config" --disable LOCALVERSION_AUTO
    return
  fi

  python3 - "$config" "$localversion" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
localversion = sys.argv[2]
lines = path.read_text().splitlines()
have_localversion = False
have_auto = False
out = []

for line in lines:
    if line.startswith("CONFIG_LOCALVERSION="):
        if localversion:
            out.append(f'CONFIG_LOCALVERSION="{localversion}"')
        else:
            out.append(line)
        have_localversion = True
    elif line.startswith("CONFIG_LOCALVERSION_AUTO="):
        out.append("# CONFIG_LOCALVERSION_AUTO is not set")
        have_auto = True
    else:
        out.append(line)

if localversion and not have_localversion:
    out.append(f'CONFIG_LOCALVERSION="{localversion}"')
if not have_auto:
    out.append("# CONFIG_LOCALVERSION_AUTO is not set")

path.write_text("\n".join(out) + "\n")
PY
}

seed_config() {
  local device="$1"
  local out_dir="$2"
  local defconfig

  if [[ -n "$CONFIG_SOURCE" ]]; then
    mkdir -p "$out_dir"
    log "CONFIG" "${device} <- ${CONFIG_SOURCE}"
    case "$CONFIG_SOURCE" in
      *.gz)
        gzip -dc "$CONFIG_SOURCE" > "$out_dir/.config"
        ;;
      *)
        cp "$CONFIG_SOURCE" "$out_dir/.config"
        ;;
    esac
    return
  fi

  defconfig="$(resolve_defconfig "$device")"
  log "DEFCONFIG" "${device} -> ${defconfig}"
  make_kernel O="$out_dir" "$defconfig" >/dev/null
}

prepare_config() {
  local out_dir="$1"
  local localversion="$2"
  shift 2
  local fragments=("$@")

  [[ -f "$out_dir/.config" ]] || die "missing config: $out_dir/.config"
  merge_config_fragments "$out_dir" "${fragments[@]}"
  set_localversion_override "$out_dir/.config" "$localversion"
  make_kernel O="$out_dir" olddefconfig >/dev/null
}

apply_symbol_crc_overrides() {
  local out_dir="$1"
  local device="$2"
  shift 2
  local symbol_crc_overrides=("$@")
  local image_path="$out_dir/arch/arm64/boot/Image"
  local image_gz_path="$out_dir/arch/arm64/boot/Image.gz"
  local image_gz_dtb_path="$out_dir/arch/arm64/boot/Image.gz-dtb"
  local symvers_path="$out_dir/Module.symvers"
  local -a dtb_paths=()

  if [[ "${#symbol_crc_overrides[@]}" -eq 0 ]]; then
    return
  fi

  [[ -f "$image_path" ]] || die "missing Image for CRC override: $image_path"
  [[ -f "$symvers_path" ]] || die "missing Module.symvers for CRC override: $symvers_path"

  mapfile -t dtb_paths < <(python3 - "$out_dir/.config" "$out_dir/arch/arm64/boot/dts" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
dts_root = Path(sys.argv[2])
raw_names = None
for line in config_path.read_text().splitlines():
    if line.startswith('CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES='):
        raw_names = line.split('=', 1)[1].strip()
        break

if raw_names is None:
    raise SystemExit('missing CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES in config')

if raw_names.startswith('"') and raw_names.endswith('"'):
    raw_names = raw_names[1:-1]

names = [name for name in raw_names.split() if name]
if not names:
    raise SystemExit('no DTB names found in CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES')

for name in names:
    print(dts_root / f'{name}.dtb')
PY
)

  [[ "${#dtb_paths[@]}" -gt 0 ]] || die "no DTBs resolved for CRC override"
  for dtb_path in "${dtb_paths[@]}"; do
    [[ -f "$dtb_path" ]] || die "missing DTB for CRC override: $dtb_path"
  done

  log "CRC" "applying ${#symbol_crc_overrides[@]} symbol override(s) for ${device} (${#dtb_paths[@]} dtb)"
  python3 - "$image_path" "$image_gz_path" "$image_gz_dtb_path" "$symvers_path" "${dtb_paths[@]}" -- "${symbol_crc_overrides[@]}" <<'PY'
import gzip
from pathlib import Path
import sys

image_path = Path(sys.argv[1])
image_gz_path = Path(sys.argv[2])
image_gz_dtb_path = Path(sys.argv[3])
symvers_path = Path(sys.argv[4])
args = sys.argv[5:]
sep = args.index('--')
dtb_paths = [Path(p) for p in args[:sep]]
specs = args[sep + 1:]

sym_lines = symvers_path.read_text().splitlines()
sym_index = {}
for idx, line in enumerate(sym_lines):
    parts = line.split("	")
    if len(parts) >= 4:
        sym_index[parts[1]] = (idx, parts)

image = image_path.read_bytes()

for spec in specs:
    if "=" not in spec:
        raise SystemExit(f"invalid --symbol-crc spec: {spec}")
    name, new_crc_text = spec.split("=", 1)
    if name not in sym_index:
        raise SystemExit(f"symbol not found in Module.symvers: {name}")
    if len(new_crc_text) != 8:
        raise SystemExit(f"CRC must be 8 hex chars: {spec}")

    idx, parts = sym_index[name]
    old_crc = int(parts[0], 16)
    new_crc = int(new_crc_text, 16)
    old_bytes = old_crc.to_bytes(4, "little")
    new_bytes = new_crc.to_bytes(4, "little")

    count = image.count(old_bytes)
    if count != 1:
        raise SystemExit(f"{name}: expected exactly one old CRC occurrence in Image, got {count}")

    image = image.replace(old_bytes, new_bytes, 1)
    parts[0] = f"0x{new_crc_text.lower()}"
    sym_lines[idx] = "	".join(parts)

image_path.write_bytes(image)
with gzip.open(image_gz_path, "wb", compresslevel=9) as fh:
    fh.write(image)
image_gz_dtb_path.write_bytes(image_gz_path.read_bytes() + b"".join(path.read_bytes() for path in dtb_paths))
symvers_path.write_text("\n".join(sym_lines) + "\n")
PY
}
resolve_profile_for_device() {
  local device="$1"
  local -n out_localversion="$2"
  local -n out_symbol_crcs="$3"
  local -n out_fragments="$4"

  out_localversion="$LOCALVERSION_OVERRIDE"
  out_symbol_crcs=("${SYMBOL_CRC_OVERRIDES[@]}")
  out_fragments=("${CONFIG_FRAGMENTS[@]}")

  case "$PROFILE" in
    vanilla)
      ;;
    miui-stock)
      if [[ -z "$out_localversion" ]]; then
        out_localversion="-perf-g5431a848c102"
      fi
      append_unique out_symbol_crcs "remap_pfn_range=a5447b97"
      ;;
    nethunter)
      if [[ -z "$out_localversion" ]]; then
        out_localversion="-perf-g5431a848c102"
      fi
      append_unique out_symbol_crcs "remap_pfn_range=a5447b97"
      append_unique out_fragments "$(resolve_existing_file "packaging/config-fragments/nethunter.config")"
      ;;
    kernelsu)
      if [[ -z "$out_localversion" ]]; then
        out_localversion="-perf-g5431a848c102"
      fi
      append_unique out_symbol_crcs "remap_pfn_range=a5447b97"
      append_unique out_fragments "$(resolve_existing_file "packaging/config-fragments/kernelsu.config")"
      ;;
    *)
      die "unsupported profile: $PROFILE"
      ;;
  esac
}

render_anykernel_script() {
  local template="$ANYKERNEL_DIR/anykernel.sh.in"
  local target="$1"
  local device="$2"
  local variant="$3"
  local kernel_string="${PROJECT_NAME} ${device} ${variant}"
  local message_word="${device}-${variant}"
  local device_name1="$device"
  local device_name2="$device"

  if [[ "$device" == "universal" ]]; then
    kernel_string="${PROJECT_NAME} heat+fire ${variant}"
    message_word="heat-fire-${variant}"
    device_name1="heat"
    device_name2="fire"
  fi

  [[ -f "$template" ]] || die "missing AnyKernel template: $template"

  sed     -e "s|__KERNEL_STRING__|${kernel_string}|g"     -e "s|__KERNEL_COMPILER__|${COMPILER_STRING}|g"     -e "s|__KERNEL_MADE__|${MAINTAINER}|g"     -e "s|__MESSAGE_WORD__|${message_word}|g"     -e "s|__DEVICE_NAME1__|${device_name1}|g"     -e "s|__DEVICE_NAME2__|${device_name2}|g"     -e "s|__SUPPORTED_VERSIONS__|${SUPPORTED_VERSIONS}|g"     -e "s|__PROJECT_NAME__|${PROJECT_NAME}|g"     -e "s|__VARIANT__|${variant}|g"     "$template" > "$target"
}
package_anykernel() {
  local device="$1"
  local variant="$2"
  local image_path="$3"
  local stamp="$4"
  local release_name="${PROJECT_NAME}-${device}-${variant}-${stamp}"
  local tmp_root="$RELEASE_DIR/.tmp"
  local pkg_dir
  local zip_path="$RELEASE_DIR/${release_name}.zip"

  [[ -d "$ANYKERNEL_DIR/META-INF" ]] || die "missing AnyKernel META-INF in ${ANYKERNEL_DIR}"
  [[ -d "$ANYKERNEL_DIR/tools" ]] || die "missing AnyKernel tools in ${ANYKERNEL_DIR}"

  mkdir -p "$tmp_root"
  pkg_dir="$(mktemp -d "$tmp_root/${device}-${variant}.XXXXXX")"
  rm -f "$zip_path" "${zip_path}.sha256"

  cp -a "$ANYKERNEL_DIR/META-INF" "$pkg_dir/"
  cp -a "$ANYKERNEL_DIR/tools" "$pkg_dir/"
  render_anykernel_script "$pkg_dir/anykernel.sh" "$device" "$variant"
  cp "$image_path" "$pkg_dir/Image.gz-dtb"

  (
    cd "$pkg_dir"
    zip -r -0 "$zip_path" . >/dev/null
  )

  rm -rf "$pkg_dir"
  sha256sum "$zip_path" > "${zip_path}.sha256"
  log "AK3" "created $(basename "$zip_path")"
}

build_one_device() {
  local device="$1"
  local variant="$2"
  local stamp="$3"
  local out_dir="$OUT_BASE/$device"
  local device_localversion=""
  local -a device_symbol_crc_overrides=()
  local -a device_config_fragments=()
  local image_path="$out_dir/arch/arm64/boot/Image.gz-dtb"
  local image_copy="$RELEASE_DIR/${PROJECT_NAME}-${device}-${variant}-${stamp}.Image.gz-dtb"
  local log_dir="$RELEASE_DIR/logs"
  local build_log="$log_dir/${PROJECT_NAME}-${device}-${variant}-${stamp}.log"

  resolve_profile_for_device "$device" device_localversion device_symbol_crc_overrides device_config_fragments
  append_unique device_config_fragments "$(device_config_fragment "$device")"
  mkdir -p "$OUT_BASE" "$RELEASE_DIR" "$log_dir"

  if [[ "$DO_CLEAN" -eq 1 ]]; then
    rm -rf "$out_dir"
  fi

  seed_config "$device" "$out_dir"
  prepare_config "$out_dir" "$device_localversion" "${device_config_fragments[@]}"

  log "BUILD" "${device} (${JOBS} jobs, LLVM_IAS=${LLVM_IAS_VALUE}, profile=${PROFILE})"
  make_kernel -j"$JOBS" O="$out_dir" Image.gz-dtb 2>&1 | tee "$build_log"
  apply_symbol_crc_overrides "$out_dir" "$device" "${device_symbol_crc_overrides[@]}"
  [[ -f "$image_path" ]] || die "missing build artifact: $image_path"

  cp "$image_path" "$image_copy"
  sha256sum "$image_copy" > "${image_copy}.sha256"
  log "IMAGE" "created $(basename "$image_copy")"

  if [[ "$DO_PACKAGE" -eq 1 ]]; then
    package_anykernel "$device" "$variant" "$image_path" "$stamp"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        DEVICE="${2:-}"
        shift 2
        ;;
      --profile)
        PROFILE="$(normalize_variant "${2:-}")"
        shift 2
        ;;
      --variant)
        VARIANT="$(normalize_variant "${2:-}")"
        shift 2
        ;;
      --defconfig)
        DEFCONFIG_OVERRIDE="${2:-}"
        shift 2
        ;;
      --config)
        CONFIG_SOURCE="${2:-}"
        shift 2
        ;;
      --config-fragment)
        CONFIG_FRAGMENTS+=("${2:-}")
        shift 2
        ;;
      --localversion)
        LOCALVERSION_OVERRIDE="${2:-}"
        shift 2
        ;;
      --symbol-crc)
        SYMBOL_CRC_OVERRIDES+=("${2:-}")
        shift 2
        ;;
      --llvm-ias)
        LLVM_IAS_VALUE="${2:-}"
        shift 2
        ;;
      --jobs)
        JOBS="${2:-}"
        shift 2
        ;;
      --stamp)
        STAMP="${2:-}"
        shift 2
        ;;
      --out-dir)
        OUT_BASE="${2:-}"
        CUSTOM_OUT_BASE=1
        shift 2
        ;;
      --release-dir)
        RELEASE_DIR="${2:-}"
        CUSTOM_RELEASE_DIR=1
        shift 2
        ;;
      --anykernel-dir)
        ANYKERNEL_DIR="${2:-}"
        shift 2
        ;;
      --maintainer)
        MAINTAINER="${2:-}"
        shift 2
        ;;
      --compiler)
        COMPILER_STRING="${2:-}"
        shift 2
        ;;
      --supported)
        SUPPORTED_VERSIONS="${2:-}"
        shift 2
        ;;
      --build-user)
        BUILD_USER="${2:-}"
        shift 2
        ;;
      --build-host)
        BUILD_HOST="${2:-}"
        shift 2
        ;;
      --clean)
        DO_CLEAN=1
        shift
        ;;
      --mrproper)
        DO_MRPROPER=1
        shift
        ;;
      --package)
        DO_PACKAGE=1
        shift
        ;;
      --no-package)
        DO_PACKAGE=0
        shift
        ;;
      --ccache)
        USE_CCACHE=1
        shift
        ;;
      --no-ccache)
        USE_CCACHE=0
        shift
        ;;
      --werror)
        USE_WERROR=1
        shift
        ;;
      --list-profiles)
        LIST_PROFILES=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  if [[ "$LIST_PROFILES" -eq 1 ]]; then
    show_profiles
    exit 0
  fi

  [[ -n "$DEVICE" ]] || die "--device is required"
  [[ "$JOBS" =~ ^[0-9]+$ ]] || die "--jobs must be a positive integer"
  [[ "$LLVM_IAS_VALUE" =~ ^[01]$ ]] || die "--llvm-ias must be 0 or 1"

  if [[ -n "$STAMP" ]] && [[ ! "$STAMP" =~ ^[0-9]{8}$ ]]; then
    die "--stamp must be in yyyymmdd format"
  fi

  if [[ -n "$CONFIG_SOURCE" ]] && [[ ! -f "$CONFIG_SOURCE" ]]; then
    CONFIG_SOURCE="$(resolve_existing_file "$CONFIG_SOURCE")"
  fi

  if [[ -n "$CONFIG_SOURCE" ]]; then
    CONFIG_SOURCE="$(resolve_existing_file "$CONFIG_SOURCE")"
  fi

  for spec in "${SYMBOL_CRC_OVERRIDES[@]}"; do
    [[ "$spec" =~ ^[A-Za-z0-9_]+=[A-Fa-f0-9]{8}$ ]] || die "invalid --symbol-crc format: $spec"
  done

  if [[ "$PROFILE" != "vanilla" && "$PROFILE" != "miui-stock" && "$PROFILE" != "nethunter" && "$PROFILE" != "kernelsu" ]]; then
    die "unsupported profile: $PROFILE"
  fi

  for idx in "${!CONFIG_FRAGMENTS[@]}"; do
    CONFIG_FRAGMENTS[$idx]="$(resolve_existing_file "${CONFIG_FRAGMENTS[$idx]}")"
  done
}

main() {
  local stamp

  parse_args "$@"
  setup_toolchain
  setup_ccache

  stamp="${STAMP:-$(date +%Y%m%d)}"

  if [[ "$CUSTOM_OUT_BASE" -eq 0 ]]; then
    OUT_BASE="$OUT_BASE/$VARIANT"
  fi

  if [[ "$CUSTOM_RELEASE_DIR" -eq 0 ]]; then
    RELEASE_DIR="$RELEASE_DIR/$VARIANT"
  fi

  mkdir -p "$OUT_BASE" "$RELEASE_DIR"

  if [[ "$DO_MRPROPER" -eq 1 ]]; then
    log "CLEAN" "running make mrproper"
    make_kernel mrproper >/dev/null
  fi

  if [[ "$USE_CCACHE" -eq 1 ]]; then
    ccache -s || true
  fi

  for target in $(device_list); do
    build_one_device "$target" "$VARIANT" "$stamp"
  done

  if [[ "$USE_CCACHE" -eq 1 ]]; then
    ccache -s || true
  fi

  log "DONE" "artifacts are in ${RELEASE_DIR}"
}

main "$@"
