#!/usr/bin/env bash

ROOT_UUID=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
SWAP_UUID=0657FD6D-A4AB-43C4-84E5-0933C84B4F4F
HOME_UUID=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
BOOT_UUID=21686148-6449-6E6F-744E-656564454649

ROOT_SIZE=7GiB
SWAP_SIZE=200MiB
# for UEFI BIOS
EFI_SIZE=300MiB
# for non-UEFI BIOS
BOOT_SIZE=300MiB

HOSTNAME=Arch_VV
USERNAME=carles

# exit when any command fails
set -e

if [[ $# -eq 0 ]]
then
    printf "Device name is required as a first argument\n"
    lsblk
    exit 0
fi

if [ -d /sys/firmware/efi ]; then
  BIOS_TYPE="uefi"
else
  BIOS_TYPE="bios"
fi


# keep track of the last executed command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
# echo an error message before exiting
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT

device=$1
log="install.log"


arch_install () {

  # update the system clock
  timedatectl set-ntp true

  # partition the disk
  if [ "$BIOS_TYPE" == "uefi" ]
  then
    sfdisk -W always /dev/${device} <<EOF
label: gpt
name=root, size="$ROOT_SIZE", type="$ROOT_UUID"
name=swap, size="$SWAP_SIZE", type="$SWAP_UUID"
name=efi, size="$EFI_SIZE", type="$EFI_UUID"
name=home, type="$HOME_UUID"
EOF
    EFI_DEVICE=$(blkid --list-one --output device --match-token PARTLABEL="home")
    mkfs.fat -n "efi" -F32 "$EFI_DEVICE"
  else
    # With gpt boot partition must not have a file system
    # https://wiki.archlinux.org/title/Partitioning#Example_layouts
    sfdisk -W always /dev/${device} <<EOF
label: gpt
name=root, size="$ROOT_SIZE", type="$ROOT_UUID"
name=swap, size="$SWAP_SIZE", type="$SWAP_UUID"
name=boot, size="$BOOT_SIZE", type="$BOOT_UUID"
name=home, type="$HOME_UUID"
EOF
  fi

  # formatting file systems
  ROOT_DEVICE=$(blkid --list-one --output device --match-token PARTLABEL="root")
  HOME_DEVICE=$(blkid --list-one --output device --match-token PARTLABEL="home")
  SWAP_DEVICE=$(blkid --list-one --output device --match-token PARTLABEL="swap")

  sfdisk -l /dev/${device}

  mkfs.ext4 -L "root" "$ROOT_DEVICE"
  mkfs.ext4 -L "home" "$HOME_DEVICE"
  mkswap -L "swap" "$SWAP_DEVICE"
  swapon "$SWAP_DEVICE"

  # mounting file systems
  mount "$ROOT_DEVICE" /mnt
  mkdir /mnt/home
  mount "$HOME_DEVICE" /mnt/home

  # if UEFI BIOS mount the efi partition
  [ "$BIOS_TYPE" == "uefi" ] &&
    mkdir /mnt/efi && # make dir to mount efi on
    mount "$EFI_DEVICE" /mnt/efi # Mounting efi file system

  # select only united kingdom mirrors
  mirrors_url="https://archlinux.org/mirrorlist/?country=GB&protocol=https&use_mirror_status=on"
  curl -s $mirrors_url | sed -e 's/^#Server/Server/' -e '/^#/d' > /etc/pacman.d/mirrorlist

  # create fstab
  genfstab -L /mnt >> /mnt/etc/fstab

  # create minimal system in /mnt by bootstrapping
  pacstrap /mnt base linux-zen linux-firmware base-conf

  arch-chroot /mnt pacman -Syyu --noconfirm
  arch-chroot /mnt pacman -Syu --noconfirm


  # set root password
  printf "\n\nSet root password\n"
  arch-chroot /mnt /bin/sh -c 'passwd; while [ $? -ne 0 ]; do passwd; done'
  arch-chroot /mnt useradd --create-home --groups wheel --shell /bin/bash $USERNAME
  printf "\n\nSet "$USERNAME" password\n"
  arch-chroot /mnt /bin/sh -c "passwd $USERNAME; while [ \$? -ne 0 ]; do passwd $USERNAME; done"
}

start=$(date +%s)
arch_install 2>&1 | tee -a $log
elapsed=$(($(date +%s)-$start))
set +e
mv $log /mnt/root/$log

# umount -R /mnt
# reboot
