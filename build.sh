#!/bin/bash
set -xe
shopt -s extglob

ROOTFS_URL=${ROOTFS_URL:-'https://ci.ubports.com/job/focal-hybris-rootfs-arm64/job/master/lastSuccessfulBuild/artifact/ubuntu-touch-android9plus-rootfs-arm64.tar.gz'}
BUILD_DIR=
OUT=

while [ $# -gt 0 ]
do
    case "$1" in
    (-b) BUILD_DIR="$(realpath "$2")"; shift;;
    (-o) OUT="$2"; shift;;
    (-*) echo "$0: Error: unknown option $1" 1>&2; exit 1;;
    (*) OUT="$2"; break;;
    esac
    shift
done

OUT="$(realpath "$OUT" 2>/dev/null || echo 'out')"
mkdir -p "$OUT"

if [ -z "$BUILD_DIR" ]; then
    TMP=$(mktemp -d)
    TMPDOWN=$(mktemp -d)
else
    TMP="$BUILD_DIR/tmp"
    # Clean up installation dir in case of local builds
    rm -rf "$TMP"
    mkdir -p "$TMP"
    TMPDOWN="$BUILD_DIR/downloads"
    mkdir -p "$TMPDOWN"
fi

HERE=$(pwd)
SCRIPT="$(dirname "$(realpath "$0")")"/build
if [ ! -d "$SCRIPT" ]; then
    SCRIPT="$(dirname "$SCRIPT")"
fi

mkdir -p "${TMP}/system" "${TMP}/partitions"

source "${HERE}/deviceinfo"

case $deviceinfo_arch in
    "armhf") RAMDISK_ARCH="armhf";;
    "aarch64") RAMDISK_ARCH="arm64";;
    "x86") RAMDISK_ARCH="i386";;
esac

cd "$TMPDOWN"
    KERNEL_DIR="$(basename "${deviceinfo_kernel_source}")"
    KERNEL_DIR="${KERNEL_DIR%.*}"

    GCC_PATH="$TMPDOWN/halium/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-gnu-6.4.1/"
    GCC32_PATH="$TMPDOWN/halium/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/"

    if [ ! -f "mkdtimg" ]; then
	wget https://android.googlesource.com/platform/system/libufdt/+archive/refs/heads/master/utils.tar.gz
	tar xvf utils.tar.gz
	cp src/mkdtboimg.py mkdtimg
	chmod a+x mkdtimg
	rm -rf utils.tar.gz tests src README.md
    fi

    [ -f halium-boot-ramdisk.img ] || curl --location --output halium-boot-ramdisk.img \
        "https://github.com/Halium/initramfs-tools-halium/releases/download/dynparts/initrd.img-touch-${RAMDISK_ARCH}"

    if ([ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay) || [ -n "$deviceinfo_dtbo" ]; then
        [ -d libufdt ] || git clone https://android.googlesource.com/platform/system/libufdt -b pie-gsi --depth 1
        [ -d dtc ] || git clone https://android.googlesource.com/platform/external/dtc -b pie-gsi --depth 1
    fi

    [ -d "avb" ] || git clone https://android.googlesource.com/platform/external/avb -b android10-gsi --depth 1

    if [ -n "$deviceinfo_kernel_use_dtc_ext" ] && $deviceinfo_kernel_use_dtc_ext; then
        [ -f "dtc_ext" ] || curl --location https://android.googlesource.com/platform/prebuilts/misc/+/refs/heads/android10-gsi/linux-x86/dtc/dtc?format=TEXT | base64 --decode > dtc_ext
        chmod +x dtc_ext
    fi

    if [ ! -f "vbmeta.img" ] && [ -n "$deviceinfo_bootimg_append_vbmeta" ] && $deviceinfo_bootimg_append_vbmeta; then
        wget https://dl.google.com/developers/android/qt/images/gsi/vbmeta.img
    fi

    [ -f "${ROOTFS_URL##*/}" ] || wget $ROOTFS_URL
    [ -d halium-install ] || git clone https://gitlab.com/JBBgameich/halium-install

    ls .
cd "$HERE"

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    "$SCRIPT/build-ufdt-apply-overlay.sh" "${TMPDOWN}"
fi

if [ -n "$deviceinfo_kernel_use_dtc_ext" ] && $deviceinfo_kernel_use_dtc_ext; then
    export DTC_EXT="$TMPDOWN/dtc_ext"
fi

"$SCRIPT/make-android-images.sh" "$TMPDOWN/halium"

PATH="$GCC_PATH/bin:$GC32_PATH/bin:$TMPDOWN:${PATH}" \
"$SCRIPT/build-kernel.sh" "${TMPDOWN}" "${TMP}/system" "${TMPDOWN}/halium/kernel/nvidia/linux-4.9_icosa/kernel/kernel-4.9"

if [ -n "$deviceinfo_prebuilt_dtbo" ]; then
    cp "$deviceinfo_prebuilt_dtbo" "${TMP}/partitions/dtbo.img"
elif [ -n "$deviceinfo_dtbo" ]; then
    "$SCRIPT/make-dtboimage.sh" "${TMPDOWN}" "${TMPDOWN}/KERNEL_OBJ" "${TMP}/partitions/dtbo.img"
fi

"$TMPDOWN/halium-install/halium-install" -u phablet -p phablet -l "${TMP}/partitions/" -p ut20.04 -s "${TMPDOWN}/${ROOTFS_URL##*/}" "${TMPDOWN}/halium/out/target/product/$deviceinfo_android_target/system.img"

if [ -n "$deviceinfo_kernel_uimage" ]; then
	"$SCRIPT/make-switchroot.sh" "${TMPDOWN}" "${TMPDOWN}/KERNEL_OBJ" "${TMPDOWN}/halium-boot-ramdisk.img" "${TMP}" "$HERE/assets/"
else
	"$SCRIPT/make-bootimage.sh" "${TMPDOWN}" "${TMPDOWN}/KERNEL_OBJ" "${TMPDOWN}/halium-boot-ramdisk.img" "${TMP}/partitions/boot.img"
fi

cp -av overlay/* "${TMP}/"

INITRC_PATHS="
${TMP}/system/opt/halium-overlay/system/etc/init
${TMP}/system/usr/share/halium-overlay/system/etc/init
${TMP}/system/opt/halium-overlay/vendor/etc/init
${TMP}/system/usr/share/halium-overlay/vendor/etc/init
"
while IFS= read -r path ; do
    if [ -d "$path" ]; then
        find "$path" -type f -exec chmod 644 {} \;
    fi
done <<< "$INITRC_PATHS"

BUILDPROP_PATHS="
${TMP}/system/opt/halium-overlay/system
${TMP}/system/usr/share/halium-overlay/system
${TMP}/system/opt/halium-overlay/vendor
${TMP}/system/usr/share/halium-overlay/vendor
"
while IFS= read -r path ; do
    if [ -d "$path" ]; then
        find "$path" -type f -name "build.prop" -exec chmod 600 {} \;
    fi
done <<< "$BUILDPROP_PATHS"

"$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}"
# create device tarball for https://wiki.debian.org/UsrMerge rootfs
"$SCRIPT/build-tarball-mainline.sh" "${deviceinfo_codename}" "${OUT}" "${TMP}" "true"

if [ -z "$BUILD_DIR" ]; then
    rm -r "${TMP}"
    rm -r "${TMPDOWN}"
fi

echo "done"
