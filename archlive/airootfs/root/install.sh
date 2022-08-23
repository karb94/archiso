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

USERNAME=carles

# exit when any command fails
set -e
# If a command inside a pipeline fails, exit with the failed command exit code
set -o pipefail

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

  # exit when any command fails

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
    EFI_DEVICE=$(blkid --list-one --output device --match-token PARTLABEL="efi")
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
    # mkdir /mnt/efi && # make dir to mount efi on
    # mount "$EFI_DEVICE" /mnt/efi # Mounting efi file system
    mkdir /mnt/boot && # make dir to mount efi on
    mount "$EFI_DEVICE" /mnt/boot # Mounting efi file system

  # select only united kingdom mirrors
  mirrors_url="https://archlinux.org/mirrorlist/?country=GB&protocol=https&use_mirror_status=on"
  curl -s $mirrors_url | sed -e 's/^#Server/Server/' -e '/^#/d' > /etc/pacman.d/mirrorlist

  # Create minimal system in /mnt by bootstrapping
  pacstrap /mnt base base-devel system_config-conf aur-conf

  # Update mirror list of the new system
  cp -fp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
  
  # Copy local aur repo to the new system with access to any user in the wheel group
  install -vd -m0775 --group=wheel /mnt/var/cache/pacman/aur
  install -vm0664 --group=wheel /root/aur/* /mnt/var/cache/pacman/aur

  # Update system
  arch-chroot /mnt pacman -Sy --noconfirm archlinux-keyring
  arch-chroot /mnt pacman -Syu --noconfirm
  arch-chroot /mnt pacman -S --noconfirm base-conf
  arch-chroot /mnt pacman -Rsn --noconfirm sudo
  # Install boot loader for convenience (dual booting)
  # The kernel images are generated in /boot/ as a hook at the end of pacstrap
  # arch-chroot /mnt pacman -S --noconfirm systemd-boot-conf

  # Install video drivers
  arch-chroot /mnt pacman -S --noconfirm xf86-video-vesa

  # Set root password
  printf "\n\nSet root password\n"
  arch-chroot /mnt /bin/sh -c 'passwd; while [ $? -ne 0 ]; do passwd; done'

  # Create a regular user and add it to the wheel group
  arch-chroot /mnt useradd --create-home --groups wheel --shell /bin/bash $USERNAME
  printf "\n\nSet "$USERNAME" password\n"
  arch-chroot /mnt /bin/sh -c "passwd $USERNAME; while [ \$? -ne 0 ]; do passwd $USERNAME; done"

  # Set up git bare repository of dotfiles
  # dotfiles_repo="https://github.com/karb94/dotfiles.git"
  # arch-chroot -u "$USERNAME" /mnt \
  #   git clone \
  #     --bare "$dotfiles_repo" \
  #     "/home/$USERNAME/.dotfiles"
  # arch-chroot -u "$USERNAME" /mnt \
  #   git \
  #     --git-dir="/home/$USERNAME/.dotfiles/" \
  #     --work-tree="/home/$USERNAME/" checkout

  # Set up git bare repository of dotfiles
  user_config_repo="https://github.com/karb94/stow_dotfiles.git"
  stow_dir="/home/$USERNAME/.config/stow"
  arch-chroot -u "$USERNAME" /mnt \
    mkdir -vp "$stow_dir"
  arch-chroot -u "$USERNAME" /mnt \
    git clone "$user_config_repo" "$stow_dir"
  arch-chroot -u "$USERNAME" /mnt \
    stow \
      --dir="$stow_dir" \
      --target="/home/$USERNAME" \
      --verbose \
      --no-folding \
      desktop
}

start=$(date +%s)
arch_install 2>&1 | tee -a $log
elapsed=$(($(date +%s)-$start))
mv -v $log /mnt/root/$log
install -vDm0600 id_ed25519 /mnt/home/carles/.ssh/id_ed25519
install -vDm0644 id_ed25519.pub /mnt/home/carles/.ssh/id_ed25519.pub
chmod 700 /mnt/home/carles/.ssh

# umount -R /mnt
# shutdown 0
