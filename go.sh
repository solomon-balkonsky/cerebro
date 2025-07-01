#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Minimal static mirrorlist for initial package installs
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

MIRROR_COUNTRIES=(
  "Ukraine" "Poland" "Moldova" "Czech Republic" "Hungary" "Lithuania" "Latvia" "Slovenia" "Slovakia"
  "Romania" "Bulgaria" "Croatia" "Serbia" "South Korea" "Singapore" "Hong Kong" "Switzerland"
  "Denmark" "Netherlands" "Sweden" "United Arab Emirates" "Norway" "Finland" "Germany"
  "United Kingdom" "France" "Belgium" "Luxembourg" "Israel" "Spain" "Estonia"
  "Portugal" "Ireland" "Italy" "Greece" "Qatar" "Kuwait" "Turkey" "Brazil"
)

ESSENTIALS=(
  base base-devel multilib-devel make devtools git podman fakechroot fakeroot
)
CUSTOM_PKG=(
  linux-zen linux-zen-headers zfs-dkms zfs-utils efibootmgr ly networkmanager \
  gnome-shell gnome-control-center gnome-terminal gnome-settings-daemon gnome-backgrounds \
  gnome-session nautilus gnome-keyring dconf-editor eog evince file-roller \
  gnome-system-monitor gnome-tweaks xdg-user-dirs-gtk \
  zsh zsh-completions paru rustup booster mold ninja zram-generator
)
GRAPHICS_PKG=(nvidia-dkms nvidia-utils)

echo "[1/12] Initialize pacman keyring and update system"
pacman-key --init
pacman -Sy --needed --noconfirm archlinux-keyring reflector
pacman -Syu --needed --noconfirm

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

echo "[4/12] Loading ZFS kernel module"
modprobe zfs || true

echo "[5/12] Cleaning existing ZFS pool (if any)"
zpool export rpool || true
zpool destroy -f rpool || true

echo "[6/12] Creating ZFS pool and datasets"
zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O acltype=posixacl -O relatime=on -O mountpoint=none \
  -O canmount=off -O devices=off rpool "${DISK}p2"

zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=legacy rpool/ROOT/default
zpool set bootfs=rpool/ROOT/default rpool

echo "[7/12] Mounting ZFS root"
mount -t zfs rpool/ROOT/default /mnt
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot

echo "[8/12] Creating ZFS swap zvol"
zfs create -V "${SWAP_SIZE}" \
  -b 4K -o compression=off \
  -o sync=always \
  -o primarycache=metadata \
  -o secondarycache=none \
  rpool/swap
mkswap /dev/zvol/rpool/swap
swapon /dev/zvol/rpool/swap

echo "[9/12] Checking mount point"
if ! mountpoint -q /mnt; then
  echo "Error: /mnt is not mounted correctly! Aborting."
  exit 1
fi
df -h /mnt
zfs list

echo "[10/12] Installing base system and custom packages"
pacstrap -K /mnt \
  "${ESSENTIALS[@]}" \
  "${CUSTOM_PKG[@]}" \
  "${GRAPHICS_PKG[@]}"

echo "[11/12] Generating fstab and swap entry"
genfstab -U /mnt > /mnt/etc/fstab
echo '/dev/zvol/rpool/swap none swap defaults 0 0' >> /mnt/etc/fstab

echo "[12/12] Configuring resolv.conf"
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

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname
cat <<HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

useradd -m -G wheel -s /bin/zsh "${USERNAME}"
echo "${USERNAME}:${USERPASS}" | chpasswd
echo "root:${ROOTPASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager ly bluetooth zram-swap

cat > /etc/systemd/zram-generator.conf <<ZRAMCFG
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
ZRAMCFG

cat > /etc/pacman.conf <<PACMANCFG
[options]
HoldPkg = pacman glibc
Architecture = auto
Color
CheckSpace
ParallelDownloads = 8
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
PACMANCFG

cat > /etc/paru.conf <<PARUCFG
[options]
PgpFetch
Devel
Provides
DevelSuffixes = -git -cvs -svn -bzr -darcs -always -hg -fossil
BottomUp
RemoveMake
SudoLoop
SkipReview
SaveChanges
CombinedUpgrade
CleanAfter
UpgradeMenu
PARUCFG

mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/rust.conf <<RUSTCFG
RUSTFLAGS="-C target-cpu=native -C opt-level=3 \\
  -C link-arg=-fuse-ld=mold -C strip=symbols \\
  -C force-frame-pointers=yes"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCFG

pacman -Syu --needed --noconfirm

EOF

echo "✅ Installation complete! Please reboot."
