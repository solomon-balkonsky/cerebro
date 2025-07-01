#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

cat > /etc/pacman.d/mirrorlist <<EOF
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
EOF

DISK="/dev/nvme0n1"
EFI_SIZE="981"
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="arch"
ROOTPASS="root"
SWAP_SIZE="32G"

ESSENTIALS=(
  base base-devel multilib-devel make devtools git podman fakechroot fakeroot
)
CUSTOM_PKG=(
  linux-zen linux-zen-headers efibootmgr ly networkmanager \
  gnome-shell gnome-control-center gnome-terminal gnome-settings-daemon gnome-backgrounds \
  gnome-session nautilus gnome-keyring dconf-editor eog evince file-roller \
  gnome-system-monitor gnome-tweaks xdg-user-dirs-gtk \
  zsh zsh-completions paru rustup booster mold ninja zram-generator
)
GRAPHICS_PKG=(nvidia-dkms nvidia-utils)

echo "[1/12] Initialize pacman keyring and update system"
pacman-key --init
pacman -Sy --needed --noconfirm archlinux-keyring reflector
modprobe zfs || true

# Partitioning, formatting, zpool creation etc. same as before...

# ... (partitioning and ZFS pool creation code) ...

echo "[10/12] Installing base system and custom packages (excluding zfs)"
pacstrap -K /mnt \
  "${ESSENTIALS[@]}" \
  "${CUSTOM_PKG[@]}" \
  "${GRAPHICS_PKG[@]}"

# Generate fstab, etc.

echo "Entering chroot to finalize install..."
arch-chroot /mnt /bin/bash <<EOF
set -e

# Install zfs packages via paru inside chroot
paru -Sy --needed --noconfirm zfs-dkms zfs-utils

# Rest of config (locale, hostname, users, efibootmgr, systemd enable etc.)

# Enable modules
modprobe zfs

# EFISTUB boot entry
efibootmgr --create --disk $DISK --part 1 --label "CerebroArch" --loader /vmlinuz-linux-zen --unicode "root=ZFS=rpool/ROOT/default rw" --verbose

EOF

echo "✅ Installation complete! Please reboot."
