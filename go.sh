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

# Partition sizes (in MiB)
EFI_SIZE="1981"
ROOT_SIZE="429496"

# Mirror countries for reflector
MIRROR_COUNTRIES=(
  "Ukraine" "Poland" "Moldova" "Czech Republic" "Hungary" "Lithuania"
  "Latvia" "Slovenia" "Slovakia" "Romania" "Bulgaria" "Croatia" "Serbia"
  "South Korea" "Singapore" "Hong Kong" "Switzerland" "Denmark" "Netherlands"
  "Sweden" "United Arab Emirates" "Norway" "Japan" "Finland" "Canada"
  "Germany" "United Kingdom" "France" "Belgium" "Luxembourg" "Israel"
  "Spain" "Estonia" "Austria" "Malaysia" "Thailand" "Portugal" "Ireland"
  "Italy" "Australia" "Greece" "Chile" "Uruguay" "Qatar" "Kuwait" "Turkey"
  "Brazil"
)

# GNOME packages to exclude
GNOME_EXCLUDES='yelp|epiphany|totem|gnome-weather|gnome-maps|gnome-software|gnome-music|gnome-calendar|simple-scan|gnome-tour|malcontent|gnome-user-docs|decibels|gdm|gnome-characters|gnome-photos|gnome-font-viewer|gnome-sound-recorder|gnome-remote-desktop|gnome-multi-writer|seahorse'

# Base & custom stack
ESSENTIALS=(
  base base-devel multilib-devel make devtools git podman fakechroot fakeroot
)
CUSTOM_PKG=(
  linux-zen linux-zen-headers zfs-dkms zfs-utils efibootmgr ly networkmanager gnome gnome-extra zsh zsh-completions paru rustup booster mold ninja
)
GRAPHICS_PKG=(nvidia-dkms nvidia-utils)

# === Start installation ===

echo "[1/10] Initializing pacman keyring"
pacman-key --init

# Refresh keyring and perform full system update
pacman -Syu --needed --noconfirm archlinux-keyring reflector

# Partitioning disk
echo "[2/10] Partitioning \$DISK"
sgdisk -Z \$DISK
sgdisk -n 1:0:+\${EFI_SIZE}MiB -t 1:ef00 \$DISK
sgdisk -n 2:0:+\${ROOT_SIZE}MiB -t 2:bf00 \$DISK
sgdisk -n 3:0:0 -t 3:8200 \$DISK

# Formatting partitions
echo "[3/10] Formatting partitions"
mkfs.fat -F32 \${DISK}p1
mkswap \${DISK}p3
swapon \${DISK}p3

# Load ZFS module
echo "[4/10] Loading ZFS module"
modprobe zfs || true

# Create ZFS pool and mount
echo "[5/10] Creating ZFS pool"
zpool create -f -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O acltype=posixacl -O relatime=on -O mountpoint=none \
  -O canmount=off -O devices=off rpool \$DISK"p2
zfs create -o mountpoint=legacy rpool/ROOT
mount -t zfs rpool/ROOT /mnt
mkdir -p /mnt/boot
mount \${DISK}p1 /mnt/boot

# Optimize mirrorlist
echo "[6/10] Updating mirrorlist via reflector"
reflector --country "\${MIRROR_COUNTRIES[*]}" --latest 16 --sort rate \
  --protocol https --save /etc/pacman.d/mirrorlist

# Install base system and custom stack
echo "[7/10] Installing base and custom packages"
GNOME_PKGS=$(pacman -Sqg gnome | grep -Ev "$GNOME_EXCLUDES")
pacstrap -K /mnt \
  "\${ESSENTIALS[@]}" \
  "${CUSTOM_PKG[@]/gnome-extra/\$GNOME_PKGS}" \
  "\${GRAPHICS_PKG[@]}"

# Generate fstab
echo "[8/10] Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Configure resolv.conf
echo "[9/10] Configuring DNS"
cat > /mnt/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:2 rotate
EOF

# Chroot and final configuration
cat << 'EOF' | arch-chroot /mnt /bin/bash -e
# Locale & hostname
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo $HOSTNAME > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Users & passwords
useradd -m -G wheel -s /bin/zsh $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager ly bluetooth

# Pacman config overrides
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

# Paru config
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

# Rust build options
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/rust.conf <<RUSTCFG
RUSTFLAGS="-C target-cpu=native -C opt-level=3 \
  -C link-arg=-fuse-ld=mold -C strip=symbols \
  -C force-frame-pointers=yes"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCFG

# Initialize pacman keyring & full update
pacman-key --init
pacman -Syu --needed --noconfirm
EOF

echo "[10/10] Cerebro installation complete. Reboot & enjoy ;) "
