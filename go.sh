#!/bin/bash

# ⚠️ WARNING: This script assumes full control of /dev/nvme0n1
# It will wipe the disk and set up Arch Linux with:
# - ZFS root filesystem
# - linux-zen kernel
# - EFISTUB boot (no GRUB)
# - Ly display manager
# - GNOME desktop environment
# - NVIDIA drivers (dkms)
# - PipeWire audio stack
# - User 'j' with ZSH shell
# - Paru AUR helper via rustup (needed for ZFS installation)

set -euo pipefail

# === Variables ===
disk=/dev/nvme0n1
part1="${disk}p1"
part2="${disk}p2"

# === 1. Set up clock ===
echo "🔧 Enabling NTP"
timedatectl set-ntp true

# === 2. Partition Disk ===
echo "🧹 Wiping disk and creating partitions"
wipefs -a $disk
parted $disk -- mklabel gpt
parted $disk -- mkpart ESP fat32 1MiB 2049MiB
parted $disk -- set 1 esp on
parted $disk -- mkpart primary 2049MiB 100%

# === 3. Format partitions ===
echo "💽 Formatting EFI and preparing ZFS"
mkfs.fat -F32 $part1
modprobe zfs || (echo "ZFS kernel module not found!" && exit 1)

zpool create -f -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=none \
  rpool $part2

zfs create -o mountpoint=/ rpool/ROOT
mount -t zfs rpool/ROOT /mnt
mkdir -p /mnt/boot
mount $part1 /mnt/boot

# === 4. Install base system (no zfs yet) ===
echo "📦 Installing base system and dependencies"
pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
          nvidia-dkms nvidia-utils networkmanager efibootmgr sudo zsh git rustup

genfstab -U /mnt >> /mnt/etc/fstab

# === 5. Chroot to complete config ===
echo "🔧 Chrooting for configuration"
arch-chroot /mnt /bin/bash <<EOF

ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc

sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo archzfs > /etc/hostname

# Initramfs
sed -i 's/^MODULES=.*/MODULES=(zfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block zfs filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

# EFISTUB boot entry
efibootmgr --create \
  --disk $disk \
  --part 1 \
  --label "Arch ZFS" \
  --loader '\vmlinuz-linux-zen' \
  --unicode "zfs=rpool/ROOT rw initrd=\\initramfs-linux-zen.img" \
  --verbose

# Set up user j
useradd -m -G wheel -s /bin/zsh j
echo "j:changeme" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

# Enable services
systemctl enable NetworkManager

# Setup paru for ZFS AUR packages
su - j -c 'rustup default stable'
su - j -c 'rustup install stable'
su - j -c 'git clone https://aur.archlinux.org/paru.git'
su - j -c 'cd paru && makepkg -si --noconfirm'

# Install ZFS via paru
su - j -c 'paru -S --noconfirm zfs-dkms zfs-utils'

# Install DE and audio
pacman -S --noconfirm ly gnome gnome-tweaks \
  pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse wireplumber \
  xorg xorg-xinit xorg-xwayland xdg-desktop-portal-gnome smartmontools

systemctl enable ly

EOF

# === 6. Done ===
echo "✅ Arch Linux with ZFS and Zen kernel installed"
echo "💡 Reboot and login as user: j / password: changeme"
