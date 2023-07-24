#!/bin/bash
set -xe

HALIUM=$(realpath $1)
TMPDOWN=$(realpath $2)
HERE=$(pwd)

source "${HERE}/deviceinfo"
export PATCHDIR=$HALIUM/.repo/local_manifests/patches

applyPatches() {
    PATCHES_FILE=$1
    echo "Applying patches from $PATCHES_FILE"

    while read -r line;
    do
        IFS=',' read -r -a parts <<< "$line"

        if [[ "${parts[2]}" == "git" ]];
        then
            echo "Applying patch ${parts[0]} with git am"
            eval "git -C ${HALIUM}/${parts[1]} am ${PATCHDIR}/${parts[0]}"
            cd $HALIUM
        else
            echo "Applying patch ${parts[0]} with Unix patch utility"
            eval "patch -p1 -d ${HALIUM}/${parts[1]} -i ${PATCHDIR}/${parts[0]}"
        fi
    done < $PATCHES_FILE
}

applyRepopicks() {
    REPOPICKS_FILE=$1
    echo "Applying repopicks from $REPOPICKS_FILE"

    cd $HALIUM
    while IFS= read -r line; do
        if [[ ${line:0:1} == "\"" ]];
        then
            echo "Picking topic: $line"
            eval "$HALIUM/vendor/lineage/build/tools/repopick.py -f -t $line"
        else
            echo "Picking: $line"
            eval "$HALIUM/vendor/lineage/build/tools/repopick.py -f $line"
        fi

    done < $REPOPICKS_FILE
}

setup() { source build/envsetup.sh; }

picks() {
	setup
	applyrepopicks $halium/.repo/local_manifests/picklist
	applypatches $halium/.repo/local_manifests/patchlist
}

setup_lunch() {
	setup
	lunch lineage_${deviceinfo_android_target}-userdebug
}

function patch_tree {
	cd "$HALIUM"

	# Get halium device manifest
	if [[ ! -e ./halium/devices/${deviceinfo_manufacturer}_${deviceinfo_android_target}.xml ]]; then
		wget -O ./halium/devices/${deviceinfo_manufacturer}_${deviceinfo_android_target}.xml https://gitlab.azka.li/l4t-community/ubtouch/manifest/-/raw/${deviceinfo_android_branch}/default.xml
	fi

	# Setup halium (Sync again)
	./halium/devices/setup ${deviceinfo_android_target}

	picks

	# Apply hybris patches
	hybris-patches/apply-patches.sh

	# HACK: replace defconfig by deviceinfo one
	sed -i 's/TARGET_KERNEL_CONFIG.*$/TARGET_KERNEL_CONFIG := '${deviceinfo_kernel_defconfig}'/g' device/${deviceinfo_manufacturer}/${deviceinfo_codename}/BoardConfig.mk
}

if [ ! -d "$HALIUM" ]; then
	mkdir -p "$HALIUM"
	cd "$HALIUM"
	repo init --git-lfs --depth=1	-u https://github.com/Halium/android -b ${deviceinfo_android_branch}
	repo sync -j$(nproc)
	git clone https://gitlab.azka.li/l4t-community/ubtouch/manifest.git --recursive -b ${deviceinfo_android_branch} .repo/local_manifests
	patch_tree
else
	cd "$HALIUM"
	repo forall -c 'git clean -dfx && git reset --hard'
	repo sync -j$(nproc) --force-sync
	patch_tree
fi

setup_lunch
mka e2fsdroid
mka systemimage

repo forall -c 'git clean -dfx && git reset --hard'
sed -i 's/TARGET_KERNEL_CONFIG.*$/TARGET_KERNEL_CONFIG := '${deviceinfo_kernel_defconfig}'/g' device/${deviceinfo_manufacturer}/${deviceinfo_codename}/BoardConfig.mk
picks
setup_lunch
mka vendorimage
