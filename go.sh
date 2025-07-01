#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# === User-configurable variables ===
DISK="/dev/nvme0n1"
EFI_LABEL="Cerebro_ZFS"
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="arch"
ROOTPASS="root"

# EFI partition size (in MiB)
EFI_SIZE="981"

# ZFS swap zvol size (e.g. 32G)
SWAP_SIZE="32G"

# Mirror countries for reflector
MIRROR_COUNTRIES=(
  "Ukraine" "Poland" "Moldova" "Czech Republic" "Hungary" "Lithuania" "Latvia" "Slovenia" "Slovakia"
  "Romania" "Bulgaria" "Croatia" "Serbia" "South Korea" "Singapore" "Hong Kong" "Switzerland"
  "Denmark" "Netherlands" "Sweden" "United Arab Emirates" "Norway" "Finland" "Germany"
  "United Kingdom" "France" "Belgium" "Luxembourg" "Israel" "Spain" "Estonia"
  "Portugal" "Ireland" "Italy" "Greece" "Qatar" "Kuwait" "Turkey" "Brazil"
)

# Base & custom stack
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

# === Start installation ===

echo "[1/12] Initializing pacman keyring"
pacman-key --init
pacman -Syu --needed --noconfirm archlinux-keyring reflector

# Partitioning disk
echo "[2/12] Partitioning \$DISK"
sgdisk -Z \$DISK
sgdisk -n 1:0:+\${EFI_SIZE}MiB -t 1:ef00 \$DISK
sgdisk -n 2:0:0 -t 2:bf00 \$DISK

# Formatting EFI partition
echo "[3/12] Formatting EFI"
mkfs.fat -F32 \${DISK}p1

# Load ZFS module
echo "[4/12] Loading ZFS module"
modprobe zfs || true

# Create ZFS pool and root dataset
echo "[5/12] Creating ZFS pool"
zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O acltype=posixacl -O relatime=on -O mountpoint=none \
  -O canmount=off -O devices=off rpool \${DISK}p2
zfs create -o mountpoint=none rpool/ROOT
zfs create -o mountpoint=legacy rpool/ROOT/default
zpool set bootfs=rpool/ROOT/default rpool

mount -t zfs rpool/ROOT/default /mnt
mkdir -p /mnt/boot
mount \${DISK}p1 /mnt/boot

# Create ZFS swap volume
echo "[6/12] Creating ZFS swap zvol"
zfs create -V \$SWAP_SIZE \
  -b 4K -o compression=off \
  -o sync=always \
  -o primarycache=metadata \
  -o secondarycache=none \
  rpool/swap
mkswap /dev/zvol/rpool/swap
swapon /dev/zvol/rpool/swap

# Optimize mirrorlist
echo "[7/12] Updating mirrorlist"
reflector --country "\${MIRROR_COUNTRIES[*]}" --latest 16 --sort rate \
  --protocol https --save /etc/pacman.d/mirrorlist

# Check free space just in case
df -h /mnt
zfs list

# Install base system and full stack
echo "[8/12] Installing system packages"
pacstrap -K /mnt \
  "\${ESSENTIALS[@]}" \
  "\${CUSTOM_PKG[@]}" \
  "\${GRAPHICS_PKG[@]}"

# Generate fstab
echo "[9/12] Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
echo '/dev/zvol/rpool/swap none swap defaults 0 0' >> /mnt/etc/fstab

# Configure resolv.conf
echo "[10/12] Configuring DNS"
cat > /mnt/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:2 rotate
EOF

# Copy this script for debugging later
cp "$0" /mnt/root/arch_install_last_run.sh

# Enter chroot and finalize system
echo "[11/12] Entering chroot"
arch-chroot /mnt /bin/bash <<EOF
set -e

sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo $HOSTNAME > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

useradd -m -G wheel -s /bin/zsh $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd
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
RUSTFLAGS="-C target-cpu=native -C opt-level=3 \
  -C link-arg=-fuse-ld=mold -C strip=symbols \
  -C force-frame-pointers=yes"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCFG

pacman -Syu --needed --noconfirm
EOF

echo "[12/12] ✅ Cerebro Installation complete. Reboot & enjoy ;)"
