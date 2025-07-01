#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Minimal static mirrorlist for initial pacman use
cat > /etc/pacman.d/mirrorlist <<EOF
Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch
EOF

# === User variables ===
DISK="/dev/nvme0n1"
EFI_SIZE="981"
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="arch"
ROOTPASS="root"
SWAP_SIZE="32G"

ESSENTIALS=(
  base base-devel linux-zen linux-zen-headers linux-firmware
  nvidia-dkms nvidia-utils
  networkmanager ly gnome gnome-tweaks zsh efibootmgr
  pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse wireplumber
  xorg xorg-xinit xorg-xwayland xdg-desktop-portal-gnome
  smartmontools snapper sudo
)

echo "[1/12] Initialize pacman keyring and update system"
pacman-key --init
pacman -Sy --noconfirm archlinux-keyring git base-devel

echo "[2/12] Partitioning disk $DISK"
if ! lsblk -n -o NAME "$DISK" | grep -q "${DISK##*/}p2"; then
  sgdisk -Z "$DISK"
  sgdisk -n 1:0:+${EFI_SIZE}MiB -t 1:ef00 "$DISK"
  sgdisk -n 2:0:0 -t 2:bf00 "$DISK"
else
  echo "Partitions exist, skipping partitioning"
fi

echo "[3/12] Formatting EFI partition"
mkfs.fat -F32 "${DISK}p1"

echo "[4/12] Load ZFS module"
modprobe zfs || true

echo "[5/12] Clean existing ZFS pool if present"
zpool export rpool || true
zpool destroy -f rpool || true

echo "[6/12] Create ZFS pool and datasets"
zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O acltype=posixacl -O relatime=on -O mountpoint=none \
  -O canmount=off -O devices=off rpool "${DISK}p2"

zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=legacy rpool/ROOT/default
zpool set bootfs=rpool/ROOT/default rpool

echo "[7/12] Mount ZFS root dataset"
mount -t zfs rpool/ROOT/default /mnt
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot

echo "[8/12] Create ZFS swap volume"
zfs create -V "${SWAP_SIZE}" \
  -b 4K -o compression=off \
  -o sync=always \
  -o primarycache=metadata \
  -o secondarycache=none \
  rpool/swap
mkswap /dev/zvol/rpool/swap
swapon /dev/zvol/rpool/swap

echo "[9/12] Install paru AUR helper (build in /tmp, no raw disk mounts)"
mkdir -p /tmp/paru-build
export TMPDIR=/tmp/paru-build
export PKGDEST=/tmp/paru-build
export SRCDEST=/tmp/paru-build
export PARU_CACHE_DIR=/tmp/paru-build/paru-cache

cd /tmp/paru-build
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
cd /
rm -rf /tmp/paru-build

echo "[10/12] Installing base system and packages"
pacstrap /mnt "${ESSENTIALS[@]}"

echo "[11/12] Generate fstab and add swap"
genfstab -U /mnt > /mnt/etc/fstab
echo '/dev/zvol/rpool/swap none swap defaults 0 0' >> /mnt/etc/fstab

echo "[12/12] Configure resolv.conf"
cat > /mnt/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:2 rotate
EOF

echo "Copying install script for debugging"
cp "$0" /mnt/root/arch_install_last_run.sh

echo "Entering chroot to finalize install..."
arch-chroot /mnt /bin/bash <<EOF
set -e

# Install zfs-dkms and zfs-utils via paru inside chroot
mkdir -p /tmp/build
export TMPDIR=/tmp/build
export PKGDEST=/tmp/build
export SRCDEST=/tmp/build
export PARU_CACHE_DIR=/tmp/build/paru-cache

paru -Sy --needed --noconfirm zfs-dkms zfs-utils
paru -Scc --noconfirm

modprobe zfs

# Configure locale
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

# Hostname and hosts
echo "${HOSTNAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Create user
useradd -m -G wheel -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
echo "root:${ROOTPASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Initramfs with Nvidia modules
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems)/' /etc/mkinitcpio.conf
mkinitcpio -P

# EFISTUB boot entry
efibootmgr --create --disk $DISK --part 1 --label "CerebroArch" --loader /vmlinuz-linux-zen --unicode "root=ZFS=rpool/ROOT/default rw" --verbose

# Enable services
systemctl enable NetworkManager ly bluetooth zram-swap

# ZRAM config
cat > /etc/systemd/zram-generator.conf <<ZRAMCFG
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
ZRAMCFG

EOF

echo "✅ Installation complete! Please reboot."
