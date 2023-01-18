#!/bin/bash
set -ex

TMPDOWN=$1
INSTALL_MOD_PATH=$2
HERE=$(pwd)
source "${HERE}/deviceinfo"

KERNEL_DIR="${TMPDOWN}/android-kernel/kernel/nvidia/linux-4.9-icosa/kernel/kernel-4.9"

case "$deviceinfo_arch" in
    aarch64*) ARCH="arm64" ;;
    arm*) ARCH="arm" ;;
    x86_64) ARCH="x86_64" ;;
    x86) ARCH="x86" ;;
esac

export ARCH
export CROSS_COMPILE="${deviceinfo_arch}-linux-gnu-"
if [ "$ARCH" == "arm64" ]; then
    export CROSS_COMPILE_ARM32=arm-linux-androideabi-
fi
MAKEOPTS=""
if [ -n "$CC" ]; then
    MAKEOPTS="CC=$CC"
fi
if [ -n "$LD" ]; then
    MAKEOPTS+=" LD=$LD"
fi

cd "$KERNEL_DIR"
make O="$OUT" $MAKEOPTS $deviceinfo_kernel_defconfig
make O="$OUT" $MAKEOPTS -j$(nproc --all)
if [ "$deviceinfo_kernel_disable_modules" != "true" ]
then
    make O="$OUT" $MAKEOPTS INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH="$INSTALL_MOD_PATH" modules_install
fi
mkdtimg create "$OUT/arch/$ARCH/boot/nx-plat.dtimg" --page_size=1000 \
        "$KERNEL_DIR/arch/$ARCH/boot/dts/tegra210-odin.dtb"	 --id=0x4F44494E \
	"$KERNEL_DIR/arch/$ARCH/boot/dts/tegra210b01-odin.dtb" --id=0x4F44494E --rev=0xb01 \
	"$KERNEL_DIR/arch/$ARCH/boot/dts/tegra210b01-vali.dtb" --id=0x56414C49 \
	"$KERNEL_DIR/arch/$ARCH/boot/dts/tegra210b01-frig.dtb" --id=0x46524947

ls "$OUT/arch/$ARCH/boot/"*Image*

if [ -n "$deviceinfo_kernel_apply_overlay" ] && $deviceinfo_kernel_apply_overlay; then
    ${TMPDOWN}/ufdt_apply_overlay "$OUT/arch/$ARCH/boot/dts/qcom/${deviceinfo_kernel_appended_dtb}.dtb" \
        "$OUT/arch/$ARCH/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}.dtbo" \
        "$OUT/arch/$ARCH/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}-merged.dtb"
    cat "$OUT/arch/$ARCH/boot/Image.gz" \
        "$OUT/arch/$ARCH/boot/dts/qcom/${deviceinfo_kernel_dtb_overlay}-merged.dtb" > "$OUT/arch/$ARCH/boot/Image.gz-dtb"
fi
