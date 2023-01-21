#!/bin/bash
set -ex

TMPDOWN=$(realpath $1)
KERNEL_OBJ=$(realpath $2)
RAMDISK=$(realpath $3)
OUT=$(realpath $4)
ASSETS=$(realpath $5)

if [ -z "$TMPDOWN" ]; then
    TMPMOUNT=$(mktemp -d)
else
    TMPMOUNT="$TMPDOWN/uda/"
    mkdir -p "$TMPMOUNT"
fi

HERE=$(pwd)
source "${HERE}/deviceinfo"

case "$deviceinfo_arch" in
    aarch64*) ARCH="arm64" ;;
    arm*) ARCH="arm" ;;
    x86_64) ARCH="x86_64" ;;
    x86) ARCH="x86" ;;
esac

mkdir -p "$OUT"

[ -f "$HERE/ramdisk-recovery.img" ] && RECOVERY_RAMDISK="$HERE/ramdisk-recovery.img"
[ -f "$HERE/ramdisk-overlay/ramdisk-recovery.img" ] && RECOVERY_RAMDISK="$HERE/ramdisk-overlay/ramdisk-recovery.img"

if [ -d "$HERE/ramdisk-recovery-overlay" ] && [ -e "$RECOVERY_RAMDISK" ]; then
    rm -rf "$TMPDOWN/ramdisk-recovery"
    mkdir -p "$TMPDOWN/ramdisk-recovery"

    cd "$TMPDOWN/ramdisk-recovery"
    fakeroot -- bash <<EOF
gzip -dc "$RECOVERY_RAMDISK" | cpio -i
cp -r "$HERE/ramdisk-recovery-overlay"/* "$TMPDOWN/ramdisk-recovery"

# Set values in prop.default based on deviceinfo
echo "#" >> prop.default
echo "# added by halium-generic-adaptation-build-tools" >> prop.default
echo "ro.product.brand=$deviceinfo_manufacturer" >> prop.default
echo "ro.product.device=$deviceinfo_codename" >> prop.default
echo "ro.product.manufacturer=$deviceinfo_manufacturer" >> prop.default
echo "ro.product.model=$deviceinfo_name" >> prop.default
echo "ro.product.name=halium_$deviceinfo_codename" >> prop.default

find . | cpio -o -H newc | gzip > "$TMPDOWN/ramdisk-recovery.img-merged"
EOF
    if [ ! -f "$HERE/ramdisk-overlay/ramdisk-recovery.img" ]; then
        RECOVERY_RAMDISK="$TMPDOWN/ramdisk-recovery.img-merged"
    else
        mv "$HERE/ramdisk-overlay/ramdisk-recovery.img" "$TMPDOWN/ramdisk-recovery.img-original"
        cp "$TMPDOWN/ramdisk-recovery.img-merged" "$HERE/ramdisk-overlay/ramdisk-recovery.img"
    fi
fi

if [ -d "$HERE/ramdisk-overlay" ]; then
    cp "$RAMDISK" "${RAMDISK}-merged"
    RAMDISK="${RAMDISK}-merged"
    cd "$HERE/ramdisk-overlay"
    find . | cpio -o -H newc | gzip >> "$RAMDISK"

    # Restore unoverlayed recovery ramdisk
    if [ -f "$HERE/ramdisk-overlay/ramdisk-recovery.img" ] && [ -f "$TMPDOWN/ramdisk-recovery.img-original" ]; then
        mv "$TMPDOWN/ramdisk-recovery.img-original" "$HERE/ramdisk-overlay/ramdisk-recovery.img"
    fi
fi

mkdir -p "$OUT/switchroot/ut_focal/" "$OUT/bootloader/ini/" "$OUT/switchroot/install"

cp "$ASSETS/L4T-UTF.ini" "$OUT/bootloader/ini/"
cp "$ASSETS/bl31.bin" "$ASSETS/bl33.bin" "$OUT/switchroot/ut_focal/"
mkimage -A arm64 -T script -d "$ASSETS/boot.txt" "$OUT/switchroot/ut_focal/boot.scr"
mkimage -A arm64 -O linux -T ramdisk -C gzip -d "$RAMDISK" "$OUT/switchroot/ut_focal/initramfs"
mkimage -A arm64 -O linux -T kernel -C gzip -a 0x80200000 -e 0x80200000 -n "AZKRN-5.0.0" -d "$KERNEL_OBJ/arch/$ARCH/boot/$deviceinfo_kernel_image_name" "$OUT/switchroot/ut_focal/uImage"

if [ "$deviceinfo_bootimg_os_version" == "10" ]; then
	"$TMPDOWN/mkdtimg" create "$OUT/switchroot/ut_focal/nx-plat.dtimg" --page_size=1000 "$KERNEL_OBJ/arch/$ARCH/boot/dts/tegra210-icosa.dtb" --id=0x4F44494E
else
	"$TMPDOWN/mkdtimg" create "$OUT/switchroot/ut_focal/nx-plat.dtimg" --page_size=1000 \
		"$KERNEL_OBJ/arch/$ARCH/boot/dts/tegra210-odin.dtb"    --id=0x4F44494E \
		"$KERNEL_OBJ/arch/$ARCH/boot/dts/tegra210b01-odin.dtb" --id=0x4F44494E --rev=0xb01 \
		"$KERNEL_OBJ/arch/$ARCH/boot/dts/tegra210b01-vali.dtb" --id=0x56414C49 \
		"$KERNEL_OBJ/arch/$ARCH/boot/dts/tegra210b01-frig.dtb" --id=0x46524947
fi

zerofree "$OUT/partitions/rootfs.img"

mv "$OUT/partitions/rootfs.img" \
        "$OUT/partitions/android-rootfs.img" \
        "$TMPDOWN/halium/out/target/product/$deviceinfo_android_target/vendor.img" \
        "$TMPMOUNT"

virt-make-fs --size=+256M -t ext4 --label "UDA" "$TMPMOUNT" "$OUT/partitions/uda.img"
zerofree "$OUT/partitions/uda.img"
split -b4290772992 --numeric-suffixes=0 "$OUT/partitions/uda.img" "$OUT/switchroot/install/l4t."

cd $OUT
7z a ../switch-ubuntu-touch-focal.7z bootloader switchroot

echo "Cleaning up"
rm -rf "$OUT/partitions" "$OUT/switchroot" "$OUT/bootloader" "$OUT/system" "$TMPDOWN/uda"
echo "Creating Ubuntu touch rootfs done !"
