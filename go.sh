#!/bin/bash
set -euo pipefail

# === CONFIG ===
DISK="/dev/nvme0n1"
EFI="${DISK}p1"
ROOT="${DISK}p2"
SWAP="${DISK}p3"
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="arch"
ROOTPASS="root"
EFILABEL="Cerebro Zen"

# === WIPE & PARTITION ===
sgdisk -Z $DISK
sgdisk -n 1:0:+1981MiB -t 1:ef00 $DISK  # EFI
sgdisk -n 2:0:+64GiB   -t 2:bf00 $DISK  # ZFS
sgdisk -n 3:0:0        -t 3:8200 $DISK  # swap

mkfs.fat -F32 $EFI
mkswap $SWAP
swapon $SWAP

# === REFLECTOR ===
pacman -Sy --noconfirm reflector
reflector --country "Ukraine,Poland,Moldova,Czech Republic,Hungary,Lithuania,Latvia,Slovenia,Slovakia,Romania,Bulgaria,Croatia,Serbia,South Korea,Singapore,Hong Kong,Switzerland,Denmark,Netherlands,Sweden,United Arab Emirates,Norway,Japan,Finland,Canada,Germany,United Kingdom,France,Belgium,Luxembourg,Israel,Spain,Estonia,Austria,Malaysia,Thailand,Portugal,Ireland,Italy,Australia,Greece,Chile,Uruguay,Qatar,Kuwait,Turkey,Brazil" \
  --latest 24 --sort rate --protocol https --save /etc/pacman.d/mirrorlist

# === CUSTOM GNOME INSTALL (no bloat) ===
GNOME_PKGS=$(pacman -Sqg gnome | grep -Ev 'yelp|epiphany|totem|gnome-weather|gnome-maps|gnome-software|gnome-music|gnome-calendar|simple-scan|gnome-tour|malcontent|gnome-user-docs|decibels|gnome-contacts|gnome-characters|gnome-logs|gnome-clocks|gnome-photos|gnome-font-viewer|gnome-sound-recorder|gnome-boxes|gnome-remote-desktop|gnome-multi-writer|seahorse|rygel')

# === BASE INSTALL ===
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
  $GNOME_PKGS \
  zsh zsh-completions sudo git curl efibootmgr ly networkmanager \
  nvidia-dkms nvidia-utils rustup booster

# === FSTAB ===
genfstab -U /mnt >> /mnt/etc/fstab

# === /etc/resolv.conf FIX ===
echo -e "nameserver 1.1.1.1\nnameserver 9.9.9.9\nnameserver 8.8.8.8\noptions timeout:2 attempts:2 rotate" > /mnt/etc/resolv.conf

# === CHROOT CONFIG ===
arch-chroot /mnt bash -e <<EOF
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1       localhost\n127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" > /etc/hosts

useradd -m -G wheel -s /bin/zsh $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
chsh -s /bin/zsh $USERNAME

systemctl enable NetworkManager
systemctl enable ly
EOF

# === PARU & RUSTUP + minimal ZFS install from AUR ===
arch-chroot /mnt bash -e <<EOF
cd /home/$USERNAME
git clone https://aur.archlinux.org/paru.git
chown -R $USERNAME:$USERNAME paru
cd paru
sudo -u $USERNAME makepkg -sic --noconfirm

sudo -u $USERNAME paru -Sy --noconfirm zfs-dkms zfs-utils

rustup default stable
EOF

# Load ZFS kernel module for pool creation later
modprobe zfs

# === CREATE ZFS POOL with lz4 compression ===
zpool create -f -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O relatime=on \
  -O mountpoint=none \
  -O canmount=off \
  -O devices=off \
  -m none \
  rpool $ROOT

zfs create -o mountpoint=legacy rpool/ROOT
mount -t zfs rpool/ROOT /mnt
mkdir /mnt/boot
mount $EFI /mnt/boot

# === BOOTLOADER: EFISTUB via efibootmgr ===
PARTUUID=$(blkid -s PARTUUID -o value $EFI)
arch-chroot /mnt efibootmgr -c -d $DISK -p 1 \
-L "$EFILABEL" \
-l '\\vmlinuz-linux-zen' \
-u "root=ZFS=rpool/ROOT rw initrd=\\booster-linux-zen.img resume=$SWAP quiet loglevel=0 mitigations=off noibrs noibpb nospec_store_bypass_disable l1tf=off pcie_aspm=off nvme_core.default_ps_max_latency_us=0 u.random.trust_cpu=on processor.max_cstate=1 nohz=on iommu=pt nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1 liburing.force_io_uring=1 zswap.enabled=0"

echo "✅ Arch Linux Zen + NVIDIA + minimal ZFS + EFISTUB + Booster installed successfully."
echo "🔑 User: $USERNAME / Pass: $USERPASS"
echo "💡 Reboot, remove media, and enjoy Cerebro"
