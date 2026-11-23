#!/system/bin/sh
#
# Copyright (C) 2026 The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# ueventd is started from "on early-init", i.e. while init is still in the
# bootstrap mount namespace, and its coldboot can finish after early services
# have already tried to open their device nodes. surfaceflinger then fails
# open("/dev/ion") with ENOENT, eglInitialize() fails with EGL_BAD_ALLOC and
# init reboots the device after four crashes.
#
# Create the device nodes ourselves from sysfs as soon as post-fs-data runs, so
# that they exist before surfaceflinger starts. The script runs in the
# permissive "su" domain so that mknod and restorecon are not
# blocked by SELinux.
#
# This runs in the boot path and blocks the post-fs-data action, so it must not
# fork per sysfs entry: use shell builtins (test, read, case) for the scan and
# only fork for mknod/chmod/chown/restorecon on nodes that are really missing.
# restorecon is called once for all of them, since every invocation re-reads
# all of file_contexts (~100 ms on this device).

KMSG=/dev/kmsg
TAG="init.devnodes[$$]"
CREATED=0
CREATED_PATHS=

log() {
    echo "$TAG: $*" > $KMSG 2>/dev/null
}

# read_devname <sysfs dir>; sets DEVNAME to the node path relative to /dev, e.g.
# "ion", "mapper/control", "hw_random", "input/event1" or "snd/timer".
read_devname() {
    DEVNAME=
    while IFS= read -r _line; do
        case $_line in
            DEVNAME=*) DEVNAME=${_line#DEVNAME=} ;;
        esac
    done < "$1/uevent"
    [ -n "$DEVNAME" ] || DEVNAME=${1##*/}
}

# mknod_from_sysfs <sysfs dir> <device path> <mode> <owner:group>
mknod_from_sysfs() {
    [ -e "$2" ] && return 0
    [ -r "$1/dev" ] || return 0
    IFS=: read -r _maj _min < "$1/dev" || return 0
    [ -n "$_maj" ] || return 0
    _dir=${2%/*}
    [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null
    mknod "$2" c "$_maj" "$_min" 2>/dev/null || return 0
    chmod "$3" "$2" 2>/dev/null
    chown "$4" "$2" 2>/dev/null
    CREATED_PATHS="$CREATED_PATHS $2"
    CREATED=$((CREATED + 1))
}

create_nodes() {
    mkdir -p /dev/graphics /dev/dri 2>/dev/null

    # misc devices live directly in /dev, but some have a subdirectory in their
    # name ("mapper/control")
    for d in /sys/class/misc/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        case "$DEVNAME" in
            hw_random|hwrng) mknod_from_sysfs "$d" "/dev/$DEVNAME" 0600 root:root ;;
            ion)       mknod_from_sysfs "$d" "/dev/$DEVNAME" 0664 system:system ;;
            kgsl*)     mknod_from_sysfs "$d" "/dev/$DEVNAME" 0666 system:system ;;
            *)         mknod_from_sysfs "$d" "/dev/$DEVNAME" 0666 root:root ;;
        esac
    done

    # kgsl and fastrpc have their own classes
    for d in /sys/class/kgsl/* /sys/class/fastrpc/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        mknod_from_sysfs "$d" "/dev/$DEVNAME" 0666 system:system
    done

    for d in /sys/class/graphics/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        mknod_from_sysfs "$d" "/dev/graphics/${DEVNAME##*/}" 0660 system:graphics
    done

    for d in /sys/class/drm/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        mknod_from_sysfs "$d" "/dev/dri/${DEVNAME##*/}" 0660 system:graphics
    done

    # DEVNAME already contains the class directory for these two
    for d in /sys/class/sound/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        mknod_from_sysfs "$d" "/dev/$DEVNAME" 0666 root:root
    done

    for d in /sys/class/input/*; do
        [ -d "$d" ] || continue
        read_devname "$d"
        mknod_from_sysfs "$d" "/dev/$DEVNAME" 0660 root:input
    done

    if [ -n "$CREATED_PATHS" ]; then
        restorecon $CREATED_PATHS 2>/dev/null
        log "created $CREATED node(s):$CREATED_PATHS"
    fi
}

create_nodes
