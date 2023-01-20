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
	repo init -u https://github.com/Halium/android -b $deviceinfo_android_branch --depth=1
	git clone https://gitlab.azka.li/l4t-community/ubtouch/manifest.git --recursive -b $deviceinfo_android_branch .repo/local_manifests
	wget -O halium/devices/nintendo_icosa_sr.xml https://gitlab.azka.li/l4t-community/ubtouch/manifest/-/raw/$deviceinfo_android_branch/default.xml
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

cp "$HALIUM/out/target/product/$deviceinfo_android_target/vendor.img" \
	"$HALIUM/out/target/product/$deviceinfo_android_target/system.img" \
	"$TMPDOWN/partitions"
