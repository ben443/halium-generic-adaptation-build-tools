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

case "${deviceinfo_ramdisk_compression:=gzip}" in
    gzip)
        COMPRESSION_CMD="gzip -9"
        ;;
    lz4)
        COMPRESSION_CMD="lz4 -l -9"
        ;;
    *)
        echo "Unsupported deviceinfo_ramdisk_compression value: '$deviceinfo_ramdisk_compression'"
        exit 1
        ;;
esac

if [ -d "$HERE/ramdisk-recovery-overlay" ] && [ -e "$RECOVERY_RAMDISK" ]; then
    rm -rf "$TMPDOWN/ramdisk-recovery"
    mkdir -p "$TMPDOWN/ramdisk-recovery"
    cd "$TMPDOWN/ramdisk-recovery"

    HAS_DYNAMIC_PARTITIONS=false
    [[ "$deviceinfo_kernel_cmdline" == *"systempart=/dev/mapper"* ]] && HAS_DYNAMIC_PARTITIONS=true

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
[ "$HAS_DYNAMIC_PARTITIONS" = true ] && echo "ro.boot.dynamic_partitions=true" >> prop.default

find . | cpio -o -H newc | gzip -9 > "$TMPDOWN/ramdisk-recovery.img-merged"
EOF
    if [ ! -f "$HERE/ramdisk-overlay/ramdisk-recovery.img" ]; then
        RECOVERY_RAMDISK="$TMPDOWN/ramdisk-recovery.img-merged"
    else
        mv "$HERE/ramdisk-overlay/ramdisk-recovery.img" "$TMPDOWN/ramdisk-recovery.img-original"
        cp "$TMPDOWN/ramdisk-recovery.img-merged" "$HERE/ramdisk-overlay/ramdisk-recovery.img"
    fi
fi

if [ "$deviceinfo_ramdisk_compression" != "gzip" ]; then
    gzip -dc "$RAMDISK" | $COMPRESSION_CMD > "${RAMDISK}.${deviceinfo_ramdisk_compression}"
    RAMDISK="${RAMDISK}.${deviceinfo_ramdisk_compression}"
fi

if [ -d "$HERE/ramdisk-overlay" ]; then
    cp "$RAMDISK" "${RAMDISK}-merged"
    RAMDISK="${RAMDISK}-merged"
    cd "$HERE/ramdisk-overlay"
    find . | cpio -o -H newc | $COMPRESSION_CMD >> "$RAMDISK"

    # Restore unoverlayed recovery ramdisk
    if [ -f "$HERE/ramdisk-overlay/ramdisk-recovery.img" ] && [ -f "$TMPDOWN/ramdisk-recovery.img-original" ]; then
        mv "$TMPDOWN/ramdisk-recovery.img-original" "$HERE/ramdisk-overlay/ramdisk-recovery.img"
    fi
fi

# Create ramdisk for vendor_boot.img
if [ -d "$HERE/vendor-ramdisk-overlay" ]; then
    VENDOR_RAMDISK="$TMPDOWN/ramdisk-vendor_boot.img"
    rm -rf "$TMPDOWN/vendor-ramdisk"
    mkdir -p "$TMPDOWN/vendor-ramdisk"
    cd "$TMPDOWN/vendor-ramdisk"

    if [[ -f "$HERE/vendor-ramdisk-overlay/lib/modules/modules.load" && "$deviceinfo_kernel_disable_modules" != "true" ]]; then
        item_in_array() { local item match="$1"; shift; for item; do [ "$item" = "$match" ] && return 0; done; return 1; }
        modules_dep="$(find "$INSTALL_MOD_PATH"/ -type f -name modules.dep)"
        modules="$(dirname "$modules_dep")" # e.g. ".../lib/modules/5.10.110-gb4d6c7a2f3a6"
        modules_len=${#modules} # e.g. 105
        all_modules="$(find "$modules" -type f -name "*.ko*")"
        module_files=("$modules/modules.alias" "$modules/modules.dep" "$modules/modules.softdep")
        set +x
        while read -r mod; do
            mod_path="$(echo -e "$all_modules" | grep "/$mod")" # ".../kernel/.../mod.ko"
            mod_path="${mod_path:$((modules_len+1))}" # drop absolute path prefix
            dep_paths="$(sed -n "s|^$mod_path: ||p" "$modules_dep")"
            for mod_file in $mod_path $dep_paths; do # e.g. "kernel/.../mod.ko"
                item_in_array "$modules/$mod_file" "${module_files[@]}" && continue # skip over already processed modules
                module_files+=("$modules/$mod_file")
            done
        done < <(cat "$HERE/vendor-ramdisk-overlay/lib/modules/modules.load"* | sort | uniq)
        set -x
        mkdir -p "$TMPDOWN/vendor-ramdisk/lib/modules"
        cp "${module_files[@]}" "$TMPDOWN/vendor-ramdisk/lib/modules"

        # rewrite modules.dep for GKI /lib/modules/*.ko structure
        set +x
        while read -r line; do
            printf '/lib/modules/%s:' "$(basename ${line%:*})"
            deps="${line#*:}"
            if [ "$deps" ]; then
                for m in $(basename -a $deps); do
                    printf ' /lib/modules/%s' "$m"
                done
            fi
            echo
        done < "$modules/modules.dep" | tee "$TMPDOWN/vendor-ramdisk/lib/modules/modules.dep"
        set -x
    fi

    cp -r "$HERE/vendor-ramdisk-overlay"/* "$TMPDOWN/vendor-ramdisk"

    find . | cpio -o -H newc | $COMPRESSION_CMD > "$VENDOR_RAMDISK"
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

mv "$OUT/partitions/rootfs.img" "$OUT/partitions/android-rootfs.img" "$TMPMOUNT"
cp "$TMPDOWN/lineage/out/target/product/${deviceinfo_android_target}/vendor.img" "$OUT/switchroot/install"

dd if=/dev/zero bs=1G count=1 >> "$TMPMOUNT/android-rootfs.img"
e2fsck -fy "$TMPMOUNT/android-rootfs.img"
resize2fs "$TMPMOUNT/android-rootfs.img"

TMPSYS=$(mktemp -d)
mount "$TMPMOUNT/android-rootfs.img" "$TMPSYS"
cp -r "${HERE}/tmp/system/lib/" "$TMPSYS/system/"
umount "$TMPSYS"

TMPROOT=$(mktemp -d)
dd if=/dev/zero bs=5G count=1 >> "$TMPMOUNT/rootfs.img"
e2fsck -fy "$TMPMOUNT/rootfs.img"
resize2fs "$TMPMOUNT/rootfs.img"

mount "$TMPMOUNT/rootfs.img" "${TMPROOT}"
cp -av "${HERE}/overlay/system/opt/" "${TMPROOT}"
cp "$TMPMOUNT/android-rootfs.img" "${TMPROOT}/var/lib/lxc/android/"
umount "${TMPROOT}"
zerofree "$TMPMOUNT/rootfs.img"

mv "$TMPMOUNT/rootfs.img" "$OUT/switchroot/install"

cd $OUT
7z a ../switch-ubuntu-touch-focal.7z bootloader switchroot

echo "Cleaning up"
rm -rf "$OUT" "$TMPMOUNT"
echo "Creating Ubuntu touch rootfs done !"
