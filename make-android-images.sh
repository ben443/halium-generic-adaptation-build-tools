#!/bin/bash
set -xe

HALIUM=$(realpath $1)
TMPDOWN=$(realpath $2)

HERE=$(pwd)
source "${HERE}/deviceinfo"

mkdir -p "$TMPDOWN/mount"

if [ ! -d "$HALIUM" ]; then
	mkdir -p "$HALIUM"
	cd "$HALIUM"
	repo init -u https://github.com/Halium/android -b $deviceinfo_kernel_source_branch --depth=1
	git clone https://gitlab.azka.li/l4t-community/ubtouch/manifest.git --recursive -b $deviceinfo_kernel_source_branch .repo/local_manifests
	wget -O halium/devices/nintendo_icosa_sr.xml https://gitlab.azka.li/l4t-community/ubtouch/manifest/-/raw/$deviceinfo_kernel_source_branch/default.xml
	./halium/devices/setup $deviceinfo_android_target
	./.repo/local_manifests/snack/snack.sh -y -p -w
	hybris-patches/apply-patches.sh --mb
else
	cd "$HALIUM"
	./.repo/local_manifests/snack/snack.sh -y -p
	hybris-patches/apply-patches.sh --mb
fi

# Prepare 
source build/envsetup.sh
breakfast $deviceinfo_android_target

# Build
mka e2fsdroid
mka systemimage
mka vendorimage

# Add vendor.img size to system.img before copying
TOTAL_SIZE_ADDED=(($(du -BM "$HALIUM/out/target/product/$deviceinfo_android_target/vendor.img" | awk -F "M" '{print $1}') + 2))
dd if=/dev/zero bs=1M count=$TOTAL_SIZE_ADDED >> "$HALIUM/out/target/product/$deviceinfo_android_target/system.img"

# Resize partition on disk
e2fsck -f "$HALIUM/out/target/product/$deviceinfo_android_target/system.img"
resize2fs "$HALIUM/out/target/product/$deviceinfo_android_target/system.img"

# Mount system, copy vendor to system, unmount system
mount "$HALIUM/out/target/product/$deviceinfo_android_target/system.img" "$TMPDOWN/mount"
cp "$HALIUM/out/target/product/$deviceinfo_android_target/vendor.img" "$TMPDOWN/mount/"
umount "$TMPDOWN/mount"

# TODO: copy vendor image inside system.img
