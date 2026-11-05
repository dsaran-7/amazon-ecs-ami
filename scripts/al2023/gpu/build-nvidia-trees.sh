#!/usr/bin/env bash
# Functions that build a per-version NVIDIA driver tree for each branch in nvidia_driver_branches_al2023, under
# /opt/nvidia/<branch>. install-nvidia-driver.sh sources this file and calls them after the native install, only when
# nvidia_driver_trees_al2023 is on (off by default). So far they download and check each branch's packages and build
# each branch's kernel modules, one set per flavor, into the branch's tree. Nothing reads the trees yet: the native
# driver still runs the AMI.

TREES_BUILD_DIR=/opt/nvidia-build # scratch space for the build, removed at the end
TREES_DIR=/opt/nvidia             # the trees, one per branch
NVIDIA_DRIVER_VERSION_FILE=${NVIDIA_DRIVER_VERSION_FILE:-/tmp/NVIDIA_DRIVER_VERSION}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# read_driver_branches: fill NAMES, FLAVORS and VERSION from NVIDIA_DRIVER_BRANCHES and NVIDIA_DRIVER_VERSION.
#
# Packer passes nvidia_driver_branches_al2023 in order as "name=flavor,flavor" pairs; the first branch is the default,
# the natively installed driver. Each branch's full version is pinned in NVIDIA_DRIVER_VERSION, which check-update.sh
# keeps current: nvidia_driver_version_al2023 for the default branch, nvidia_driver_version_al2023_<name> for the
# others.
NAMES=()                         # branch names, in order; NAMES[0] is the default branch
declare -A FLAVORS=() VERSION=() # flavors and version of each branch, by name
read_driver_branches() {
    local pair name flavor
    # Each "lts=open,proprietary,grid" pair adds "lts" to NAMES and "open proprietary grid" to FLAVORS[lts], keeping
    # packer's order so the default branch comes first.
    for pair in ${NVIDIA_DRIVER_BRANCHES:-}; do
        name=${pair%%=*}
        NAMES+=("$name")
        FLAVORS[$name]=${pair#*=}
        FLAVORS[$name]=${FLAVORS[$name]//,/ }
    done
    [[ ${#NAMES[@]} -gt 0 ]] || die "no branches in NVIDIA_DRIVER_BRANCHES"

    # VERSION[lts] from nvidia_driver_version_al2023, VERSION[pb] from nvidia_driver_version_al2023_pb
    VERSION[${NAMES[0]}]=$(pinned_version nvidia_driver_version_al2023)
    for name in "${NAMES[@]:1}"; do
        VERSION[$name]=$(pinned_version "nvidia_driver_version_al2023_$name")
    done

    # Each branch needs a version and at least one flavor, and every flavor must be open, proprietary or grid
    for name in "${NAMES[@]}"; do
        [[ -n ${VERSION[$name]:-} ]] || die "no driver version for branch '$name' in $NVIDIA_DRIVER_VERSION_FILE"
        [[ -n ${FLAVORS[$name]} ]] || die "no kernel module flavors for branch '$name'"
        for flavor in ${FLAVORS[$name]}; do
            case $flavor in
            open | proprietary | grid) ;;
            *) die "branch $name: unknown flavor '$flavor'" ;;
            esac
        done
        echo "branch $name: ${VERSION[$name]} (flavors: ${FLAVORS[$name]})"
    done
}
# pinned_version KEY: the version NVIDIA_DRIVER_VERSION pins for KEY, by exact key, so _al2023 doesn't match _al2023_pb
pinned_version() {
    awk -F'"' -v key="$1" '$1 ~ "^" key " *= *$" {print $2}' "$NVIDIA_DRIVER_VERSION_FILE"
}

# download_branch_packages NAME PACKAGE...: download branch NAME's version of the version-specific PACKAGEs, the
# DKMS source packages its flavors build from, and check every signature.
#
# Each branch's packages are downloaded in one dnf transaction, so dnf resolves them together and every dependency comes
# out at the branch's version, plus the other dependencies the host doesn't have yet (such as 595's egl-wayland2). The
# default branch's packages are the native install's, already installed, so they're downloaded with reinstall.
download_branch_packages() {
    local name=$1 version=${VERSION[$1]} download_dir=$TREES_BUILD_DIR/download/$1 dkms_dir=$TREES_BUILD_DIR/dkms/$1
    shift
    local package flavor rpm_file result action=install
    local package_specs=() dkms_packages=() rpm_files=()
    sudo mkdir -p "$download_dir" "$dkms_dir"

    for package in "$@"; do package_specs+=("$package-$version"); done
    if [[ $name == "${NAMES[0]}" ]]; then
        action=reinstall
    fi
    sudo dnf -y "$action" --downloadonly --downloaddir="$download_dir" "${package_specs[@]}"

    # dnf has to resolve a kmod-nvidia-*-dkms package, since nvidia-kmod-common requires nvidia-kmod at the same version
    # and only those provide it, so they can't be excluded from the transaction. They're build inputs, downloaded per
    # flavor below, so the resolved copy is removed.
    sudo rm -f "$download_dir"/kmod-nvidia-*-dkms-*.rpm
    echo "branch $name: packages:"
    rpm -qp --nosignature --qf '  %{NAME} %{VERSION}\n' "$download_dir"/*.rpm | sort

    # The DKMS source packages each branch builds its kernel modules from, one per flavor it lists. They conflict with
    # each other, so they're downloaded without dependency resolution. The GRID flavor comes from the GRID runfile
    # instead.
    for flavor in ${FLAVORS[$name]}; do
        case $flavor in
        open) dkms_packages+=("kmod-nvidia-open-dkms-$version") ;;
        proprietary) dkms_packages+=("kmod-nvidia-latest-dkms-$version") ;;
        esac
    done
    [[ ${#dkms_packages[@]} -eq 0 ]] ||
        sudo dnf -y download --destdir="$dkms_dir" "${dkms_packages[@]}"

    # dnf checks the packages only against the repo metadata, which isn't signed (repo_gpgcheck=0), and the packages are
    # unpacked rather than installed, so no install transaction checks their signatures either. Each one must be signed
    # by a key the native install imported. rpmkeys exits 0 for an unsigned package, so the output is matched.
    shopt -s nullglob
    rpm_files=("$download_dir"/*.rpm "$dkms_dir"/*.rpm)
    shopt -u nullglob
    for rpm_file in "${rpm_files[@]}"; do
        result=$(rpmkeys --checksig "$rpm_file") || die "branch $name: $result"
        [[ $result == *"signatures OK" ]] || die "branch $name: not signed by an imported key: $result"
    done
    echo "branch $name: ${#rpm_files[@]} packages signed by an imported key"
}

# build_branch_modules NAME KERNEL SKIP_GRID: build branch NAME's kernel modules for KERNEL, once per flavor it lists,
# into <tree>/flavors/<flavor>/lib/modules/<kernel>/extra. SKIP_GRID is install-nvidia-driver.sh's skip_grid_driver,
# set in the regions without the GRID bucket.
#
# The modules are built here so an instance only copies its flavor's modules into /lib/modules at boot and runs depmod:
# no DKMS build and no initramfs rebuild at boot. The AMI keeps DKMS as it is; the trees just don't use it at boot. The
# default branch serves every instance family that isn't mapped to another branch, so its tree needs every flavor:
# without one, the instances that need it would boot without a driver. Other branches serve only their families.
build_branch_modules() {
    local name=$1 kernel=$2 skip_grid=$3 flavor source_tree
    if [[ $name == "${NAMES[0]}" ]]; then
        for flavor in open proprietary grid; do
            [[ " ${FLAVORS[$name]} " == *" $flavor "* ]] ||
                die "the default branch '$name' must list the $flavor flavor"
        done
    fi
    for flavor in ${FLAVORS[$name]}; do
        case $flavor in
        open) source_tree=$(dkms_package_source "$name" open kmod-nvidia-open-dkms) ;;
        proprietary) source_tree=$(dkms_package_source "$name" proprietary kmod-nvidia-latest-dkms) ;;
        grid)
            if [[ -n $skip_grid ]]; then
                echo "branch $name: this region has no GRID bucket, so no GRID kernel modules"
                continue
            fi
            source_tree=$(grid_runfile_source "$name")
            ;;
        esac
        build_flavor_modules "$name" "$flavor" "$source_tree" "$kernel"
    done
}

# build_flavor_modules NAME FLAVOR SOURCE_TREE KERNEL: build the nvidia DKMS source in SOURCE_TREE/nvidia-<version>
# in its own DKMS tree under the scratch space, so the native install's DKMS modules aren't touched, and keep the
# modules, stripped of the debug symbols nothing on the AMI reads.
build_flavor_modules() {
    local name=$1 flavor=$2 source_tree=$3 kernel=$4 version=${VERSION[$1]} module
    local dkms_tree=$TREES_BUILD_DIR/dkms-tree/$1-$2 module_dir=$TREES_DIR/$1/flavors/$2/lib/modules/$4/extra
    sudo mkdir -p "$dkms_tree" "$module_dir"
    sudo dkms add -m nvidia -v "$version" --sourcetree "$source_tree" --dkmstree "$dkms_tree"
    sudo dkms build -m nvidia -v "$version" -k "$kernel" --sourcetree "$source_tree" --dkmstree "$dkms_tree" || {
        sudo tail -n 40 "$dkms_tree/nvidia/$version/build/make.log" >&2
        die "branch $name: building the $flavor kernel modules failed"
    }
    sudo cp "$dkms_tree/nvidia/$version/$kernel/$(uname -m)/module"/*.ko "$module_dir/"
    for module in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
        [[ -f $module_dir/$module.ko ]] || die "branch $name: the $flavor build has no $module module"
        sudo strip -g "$module_dir/$module.ko"
    done
    echo "branch $name: $flavor modules: $(cd "$module_dir" && echo *) ($(sudo du -sh "$module_dir" | cut -f1))"
}

# dkms_package_source NAME FLAVOR PACKAGE: unpack the DKMS source package the open or proprietary flavor builds from,
# downloaded with the branch's packages, and print its source tree
dkms_package_source() {
    local name=$1 flavor=$2 package=$3 unpack_dir=$TREES_BUILD_DIR/source/$1-$2
    local - # pipefail for this function only, so a failed rpm2cpio fails the unpack too
    set -o pipefail
    sudo mkdir -p "$unpack_dir"
    rpm2cpio "$TREES_BUILD_DIR/dkms/$name/$package-${VERSION[$name]}"-*.rpm |
        (cd "$unpack_dir" && sudo cpio -idmu --quiet) || die "branch $name: cannot unpack $package"
    echo "$unpack_dir/usr/src"
}

# grid_runfile_source NAME: the GRID flavor's source, from the EC2 GRID runfile in install-nvidia-driver.sh's
# EC2_GRID_DRIVER_S3_BUCKET, found the way the native install finds it; print its source tree.
#
# The runfile's kernel-open directory is a self-contained module source (with the prebuilt nv-kernel.o_binary), but its
# dkms.conf is a template that nvidia-installer fills in, and nvidia-installer would install the driver natively, so
# the dkms.conf is written here: the same modules as the open flavor, built in the source root. The GRID licensing
# daemon ships only in the runfile, so it goes into the tree's grid flavor too.
grid_runfile_source() {
    local name=$1 version=${VERSION[$1]} source_dir=$TREES_BUILD_DIR/source/$1-grid runfile_key runfile module index=0
    local -
    set -o pipefail
    runfile_key=$(aws s3 ls --recursive "s3://${EC2_GRID_DRIVER_S3_BUCKET}/" --no-sign-request |
        grep "NVIDIA-Linux-x86_64-${version}" | sort -k1,2 | tail -1 | awk '{print $4}') || true
    [[ -n $runfile_key ]] || die "branch $name: no GRID runfile for $version in s3://${EC2_GRID_DRIVER_S3_BUCKET}"
    runfile=$(mktemp -d)/grid.run # downloaded as the build user, so into a directory it owns
    aws s3 cp "s3://${EC2_GRID_DRIVER_S3_BUCKET}/$runfile_key" "$runfile" --no-sign-request --no-progress >&2
    chmod +x "$runfile"
    sudo rm -rf "$TREES_BUILD_DIR/grid" # the previous branch's runfile
    sudo "$runfile" --extract-only --target "$TREES_BUILD_DIR/grid" >&2
    rm -rf "$(dirname "$runfile")"
    sudo mkdir -p "$source_dir/nvidia-$version"
    sudo cp -a "$TREES_BUILD_DIR/grid/kernel-open/." "$source_dir/nvidia-$version/"
    {
        printf 'PACKAGE_NAME="nvidia"\nPACKAGE_VERSION="%s"\nAUTOINSTALL="yes"\n' "$version"
        # shellcheck disable=SC2016 # dkms expands these
        printf 'MAKE[0]="%s"\n' \
            "'make' \${parallel_jobs+-j\$parallel_jobs} KERNEL_UNAME=\${kernelver} IGNORE_PREEMPT_RT_PRESENCE=1 IGNORE_XEN_PRESENCE=1 modules"
        for module in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
            printf 'BUILT_MODULE_NAME[%d]="%s"\nDEST_MODULE_LOCATION[%d]="/extra"\n' "$index" "$module" "$index"
            index=$((index + 1))
        done
    } | sudo tee "$source_dir/nvidia-$version/dkms.conf" >/dev/null
    sudo install -D -m0755 "$TREES_BUILD_DIR/grid/nvidia-gridd" "$TREES_DIR/$name/flavors/grid/usr/bin/nvidia-gridd"
    sudo install -D -m0644 "$TREES_BUILD_DIR/grid/init-scripts/systemd/nvidia-gridd.service" \
        "$TREES_DIR/$name/flavors/grid/usr/lib/systemd/system/nvidia-gridd.service"
    echo "$source_dir"
}
