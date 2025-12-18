#!/bin/sh
# Here must be /bin/sh (in altboot envirtonment)

set -e

SRC_DEV="$1"
DST_DIR="${2:-.}"

if ! [ -d "$DST_DIR" ]; then
    echo "Destination [$DST_DIR] must be directory" >&2
    exit 1
fi
if [ -z "$SRC_DEV" ]; then
    echo "Usage:" >&2
    echo "    $0 device [destination]" >&2
    echo "       - device      - block device like /dev/sda" >&2
    echo "       - destination - directory, where archive.swu will be created. Default is current dir." >&2
    exit 1
fi
if ! [ -b "$SRC_DEV" ]; then
    echo "Source [$SRC_DEV] must be block device" >&2
    exit 1
fi

PLATFORM="edge"
FINAL_DEV="/dev/mmcblk0"
RESTORE_DEV='${DEV}'

DST_DIR=$(readlink -f "$DST_DIR")
mmc_part_prefix=$(printf "%s" "$FINAL_DEV" | sed -r 's/([0-9])$/\1p/') #'

root_part=$(fdisk -o Device,Attrs -l "$SRC_DEV" | awk '/LegacyBIOSBootable/ || $2==80  {print $1;}')

if which -s pigz; then
    pigz="pigz -p 4"
else
    pigz="gzip -"
fi
cpio_with_crc=cpio

TEMP=$(mktemp -d) || { echo "Cannot create temp dir" >&2; exit 1;}

# where the eMMC BTRFS partition will be mounted
ROOTFS_MNT="$TEMP/__root"
# extension appended to the name of the archived subvolume
CPIO_EXT="cpio.gz"
ARCHIVE_FILES="$TEMP/archive.files"
CLEARFS_FILE="${DST_DIR}/clearfs.sh"
SW_DESCRIPTION="${DST_DIR}/sw-description"
#MAX_CHUNK_SIZE=3800
#MAX_ZIP_SIZE=4000

# Cleanup function called at the end of script IN ALL CASES
do_cleanup() {
    # try to delete temporary archive files (may be incomplete or corrupted in case of error, e.g. no free space)
    cd "$DST_DIR" || true
    { while IFS='' read -r f; do rm -f "$f" ; done; } < "$ARCHIVE_FILES"
    cd / || return
    rm -f "$ARCHIVE_FILES" "$TEMP/archive.description" "$TEMP/fslist" "$TEMP/partable"
    # remove previously created symlink from live system
    rm -f "$ROOTFS_MNT/etc/systemd/system/sysinit.target.wants/regenerate_ssh_host_keys.service"
    sync
    sync
    umount "$ROOTFS_MNT" || true
    sync
    rmdir "$ROOTFS_MNT" || true
    rmdir "$TEMP"
}

trap do_cleanup EXIT

get_free_space()
{
    df "$@" | awk -e 'NR==2 {print $4}'
}

get_used_space()
{
    df "$@" | awk -e 'NR==2 {print $3}'
}

prepare_root_etc()
{
    # mount the top level BTRFS partition
    mkdir -p "$ROOTFS_MNT"
    fstype=$(blkid -o export "$root_part" | sed -n 's/^TYPE=//p')
    if [ "$fstype" = "btrfs" ]; then
        mount "$root_part" -o subvol=/rootfs "$ROOTFS_MNT" \
        || mount "$root_part" "$ROOTFS_MNT" || return 1
    else
        mount "$root_part" "$ROOTFS_MNT" || return 1
    fi
    # create symlink to enable the service on the next reboot
    ln -s /etc/systemd/system/regenerate_ssh_host_keys.service "$ROOTFS_MNT/etc/systemd/system/sysinit.target.wants/" || true
}

mk_disc_part()
{
    ROOTDEV="$1"
    PARTABLE="$2"

    rm -f "${PARTABLE}"
    # save partition table of ROOTDEV into file
    printf "O\n%s\nq\n" "${PARTABLE}" | fdisk "${ROOTDEV}" >/dev/null 2>&1
    # drop lable-id, first-lba, last-lba from file
    sed '/^label-id:/d;/^first-lba:/d;/^last-lba:/d' -i "${PARTABLE}"
    # drop size of last partition - will by used max free space
    sed '$s/size=[^,]*,//' -i "${PARTABLE}"
}

mk_fslist()
{
    ROOTDEV="$1"
    PARTABLE="$2"
    grep "^${ROOTDEV}" "${PARTABLE}" | ( while read -r dev _; do
        fstype=$(blkid -o export "$dev" | sed -n 's/^TYPE=//p')
        echo "$dev|$fstype"
    done )
}

mkscript_fdisk()
{
    ROOTDEV="$1"
    PARTABLE="$2"
    echo "#!/bin/sh"
    echo ""
    echo "set -e"
    if [ "${ROOTDEV#\$}" != "$ROOTDEV" ]; then
        echo 'DEV="$1"'
        echo 'if [ -z "$DEV" ]; then echo "Missing destination device as parameter"; exit 1; fi'
        echo 'part_prefix=$(printf "%s" "$DEV" | sed -r '"'"'s/([0-9])$/\\1p/'"') #'"
        echo 'mount | grep "^$DEV" | while read mnt _; do'
        echo '   umount "$mnt"'
        echo 'done'
        echo ''
    fi
    echo "cat > /tmp/partable <<EOF"
    cat "${PARTABLE}"
    echo "EOF"
    printf 'printf "I\n/tmp/partable\np\nw\n" | fdisk %s\n' "${ROOTDEV}"
    echo 'rm /tmp/partable'
    echo 'sync; sleep 1; sync'
}

mkscript_subvol()
{
    # write to stdout commands for creating btrfs subvolumes
    dev="${1}"
    MNT="$TEMP/__mnt__"
    tmpmount=/tmp/__mnt__
    mkdir -p "${MNT}"
    mount "${dev}" "${MNT}"
    echo "mkdir -p ${tmpmount}"
    echo "mount ${dev} ${tmpmount}"
    for subvol in $(btrfs subvolume list "${MNT}" | sed 's/^.* path //' | sort); do
        vdir=$(dirname "$subvol")
        if [ "$vdir" != "." ]; then
            echo "mkdir -p ${tmpmount}/${vdir}"
        fi
        echo "btrfs subvol create ${tmpmount}/${subvol}"
        if [ "${subvol}" = "rootfs" ]; then
            echo "mkdir -p ${tmpmount}/rootfs/usr/share"
            echo "btrfs property set ${tmpmount}/rootfs/usr/share compression zstd 2>/dev/null || btrfs property set ${tmpmount}/rootfs/usr/share compression zlib > /dev/null"
        fi
    done
    echo "umount ${tmpmount}"
    echo "rmdir ${tmpmount}"
    umount "${MNT}"
    rmdir "${MNT}"
}

mkscript_fs()
{
    prefix="$2"
    # write to stdout commands for formatting partitions
    ( while IFS='|' read -r dev fstype; do
        dest_dev=${prefix}${dev##"$SRC_DEV"}
        case "$fstype" in
            vfat)
                echo "mkdosfs \"$dest_dev\""
                ;;
            ext*)
                echo "mkfs.ext4 -F -q -t $fstype \"$dest_dev\""
                ;;
            btrfs)
                echo "mkfs.btrfs -f -q \"$dest_dev\""
                mkscript_subvol "${dest_dev}"
                ;;
            *)
                echo "Unsupported filesystem ${fstype} on ${dest_dev}" >&2
                exit 1
                ;;
        esac
    done ) < "$1"
}

mkscript_cpio()
{
    cpiofile="$1"
    dest_dev="\${part_prefix}${2##"$SRC_DEV"}"
    cat <<EOF

mkdir -p /tmp/__mnt__
mount "${dest_dev}" /tmp/__mnt__ && \\
cpio -i  --to-stdout "${cpiofile}" < archive.swu | gunzip -c | cpio -i -D /tmp/__mnt__
umount /tmp/__mnt__
rmdir /tmp/__mnt__
EOF
}

mkdescr_cpio()
{
    cpiofile="$1"
    dest_dev="$2"
    fstype="$3"
    if [ "${cpiofile%%.*}" = "1" ]; then
        comma=""
    else
        comma=","
    fi
    cat <<EOF
          ${comma}{
            filename = "${cpiofile}";
            path = "/";
            preserve-attributes = true;
            type = "archive";
            device = "${dest_dev}";
            filesystem = "${fstype}";
            compressed = "zlib";
            installed-directly = true;
          }
EOF
}

list_fs()
{
    # create file $2.000 containing list of files from filesystem on device $1
    # create file $2 containing $2.000
    # write on stdout used space in MB of filesystem on device $1
    dev="${1}"
    archive="${2}"
    result=0
    MNT="$TEMP/__mnt__"
    mkdir -p "${MNT}"
    mount "${dev}" "${MNT}"
    # switch to the directory, so the paths will be generated as absolute
    if cd "${MNT}"; then
        #cpio-builder -o "$archive" -c "${MAX_CHUNK_SIZE}" 
        find . > "$archive.000"
        echo "$archive.000" > "$archive"
        get_used_space -m "."
    fi
    cd /
    umount "${MNT}"
    rmdir "${MNT}"
    return $result
}

archive_fs()
{
    # create cpio archive file $2 from filesystem on device $1
    dev="${1}"
    archive="${2}"
    result=0
    MNT="$TEMP/__mnt__"
    mkdir -p "${MNT}"
    mount "${dev}" "${MNT}"
    # switch to the directory, so the paths will be generated as absolute
    if cd "${MNT}"; then
        # dump the content of the subvolume to the temporary archive on the USB
        echo "Packing fs $dev  ..."
        while IFS=  read -r filename; do
            cpioname="$filename.${CPIO_EXT}"
            echo "        to $(basename "$cpioname")"
            $cpio_with_crc -H crc -o < "$filename" 2>/dev/null | $pigz > "$cpioname" || result=1
            rm -f "$filename"
        done < "$archive"
        rm -f "$archive"
    fi
    cd /
    umount "${MNT}"
    rmdir "${MNT}"
    return $result
}


################ MAIN #################

prepare_root_etc

#### analyze environment
mk_disc_part "${SRC_DEV}" "$TEMP/partable"
mk_fslist "${SRC_DEV}" "$TEMP/partable" > "$TEMP/fslist"

#### create script clearfs.sh
mkscript_fdisk "${FINAL_DEV}" "$TEMP/partable" > "${CLEARFS_FILE}"
mkscript_fs "$TEMP/fslist" "${mmc_part_prefix}" >> "${CLEARFS_FILE}"

mkscript_fdisk "${RESTORE_DEV}" "$TEMP/partable" > "$DST_DIR/swu2rpiboot.sh"
mkscript_fs "$TEMP/fslist" '${part_prefix}' >> "$DST_DIR/swu2rpiboot.sh"

#### create archive file list and archive description
: > "$TEMP/archive.description"
: > "$TEMP/sizes"

echo "sw-description" > "${ARCHIVE_FILES}"
echo "clearfs.sh"  >> "${ARCHIVE_FILES}"

volumes=$(awk '/|vfat$/ || /|ext[234]*$/ || /|btrfs$/ {print $1}' "$TEMP/fslist")
volname=1
#comma="{"
for def in ${volumes}; do
    # parse def (format dev|fstype) into variables
    dev=${def%|*}
    fstype=${def##*|}
    dest_dev=${mmc_part_prefix}${dev##"$SRC_DEV"}
    list_fs "${dev}" "${DST_DIR}/${volname}" >> "$TEMP/sizes" || exit 1
    for i in $(cat "${DST_DIR}/${volname}"); do
        filename=$(basename "$i.${CPIO_EXT}")
        mkdescr_cpio "$filename" "$dest_dev" "$fstype" >> "$TEMP/archive.description"
        echo "${filename}" >> "${ARCHIVE_FILES}"
        mkscript_cpio "$filename" "$dev" >> "$DST_DIR/swu2rpiboot.sh"
    done
    volname=$((volname + 1))
done
#echo "          }" >> "$TEMP/archive.description"

reqsize=0; for i in $(cat "$TEMP/sizes"); do reqsize=$((reqsize+i)); done
rm "$TEMP/sizes"

# get free space in the DST_DIR
FREE_SPACE=$(get_free_space -m "$DST_DIR")
FREE_SPACE_H=$(get_free_space -h "$DST_DIR")
echo "Destination free space:   ${FREE_SPACE} MB (${FREE_SPACE_H})"
echo "Size of OS data:          ${reqsize} MB"
echo "Estimated required space: $((reqsize+reqsize/2)) MB"

# check the remaining space in the DST_DIR. Assume that NEEDED_SPACE = SPACE_OCCUPIED_BY_GZ_ARCHS*2
if [ "$FREE_SPACE" -lt $((reqsize+reqsize/2)) ];then
    echo "Not enough space in DESTINATION storage (needed $((reqsize+reqsize/2))MB, got ${FREE_SPACE}MB)" >&2
    exit 1
fi

#### create cpio archive files
volname=1
for def in ${volumes}; do
    # parse def (format dev|fstype) into variables
    dev=${def%|*}
    fstype=${def##*|}
    archive_fs "${dev}" "${DST_DIR}/${volname}" || exit 1
    volname=$((volname + 1))
done


# create the archive.swu containing all the neccessary files
cd "$DST_DIR" || exit 1

echo "Creating final archive.swu..."
# content of the sw-description file
cat > "${SW_DESCRIPTION}" << EOF
software =
{
    version = "2.0.0";
    description = "Operating system backup for Unipi PLC";
    hardware-compatibility: [ "1.0", "2.0" ];
    ${PLATFORM} = {
        scripts: (
          {
            filename = "clearfs.sh";
            type = "preinstall";
            installed-directly = true;
          }
        );
        files: (
            $(cat "$TEMP/archive.description")
        );
    }
}
EOF

$cpio_with_crc -ov -H crc -L -R 0:0 <"$ARCHIVE_FILES" >archive.swu 2>/dev/null
chmod +x "$DST_DIR/swu2rpiboot.sh"
