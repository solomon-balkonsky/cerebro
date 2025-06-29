#!/bin/bash
set -euo pipefail

DISK="/dev/nvme0n1"
EFI="${DISK}p1"
ROOT="${DISK}p2"
SWAP="${DISK}p3"
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="arch"
ROOTPASS="root"
EFILABEL="Cerebro ZFS"

# Partitioning
sgdisk -Z $DISK
sgdisk -n 1:0:+1981MiB -t 1:ef00 $DISK
sgdisk -n 2:0:+64GiB -t 2:bf00 $DISK
sgdisk -n 3:0:0 -t 3:8200 $DISK

mkfs.fat -F32 $EFI
mkswap $SWAP
swapon $SWAP

# Base system install
pacman -Sy --noconfirm archlinux-keyring reflector
reflector --country "Ukraine,Poland,Moldova,Czech Republic,Hungary,Lithuania,Latvia,Slovenia,Slovakia,Romania,Bulgaria,Croatia,Serbia,South Korea,Singapore,Hong Kong,Switzerland,Denmark,Netherlands,Sweden,United Arab Emirates,Norway,Japan,Finland,Canada,Germany,United Kingdom,France,Belgium,Luxembourg,Israel,Spain,Estonia,Austria,Malaysia,Thailand,Portugal,Ireland,Italy,Australia,Greece,Chile,Uruguay,Qatar,Kuwait,Turkey,Brazil" --latest 24 --sort rate --protocol https --save /etc/pacman.d/mirrorlist

GNOME_PKGS=$(pacman -Sqg gnome | grep -Ev 'gdm|yelp|epiphany|totem|gnome-weather|gnome-maps|gnome-software|gnome-music|gnome-calendar|simple-scan|gnome-tour|malcontent|gnome-user-docs|decibels|gnome-contacts|gnome-characters|gnome-photos|gnome-font-viewer|gnome-sound-recorder|gnome-boxes|gnome-remote-desktop|gnome-multi-writer|seahorse')

pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
  $GNOME_PKGS \
  zsh zsh-completions sudo git curl efibootmgr ly networkmanager nvidia-dkms nvidia-utils rustup booster mold

rustup default stable

genfstab -U /mnt >> /mnt/etc/fstab

echo -e "nameserver 1.1.1.1\nnameserver 9.9.9.9\nnameserver 8.8.8.8\noptions timeout:2 attempts:2 rotate" > /mnt/etc/resolv.conf

arch-chroot /mnt bash -e <<EOF
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" > /etc/hosts

useradd -m -G wheel -s /bin/zsh $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
chsh -s /bin/zsh $USERNAME

systemctl enable NetworkManager
systemctl enable ly

# pacman config
cat <<PACMANCONF > /etc/pacman.conf
[options]
HoldPkg = pacman glibc
Architecture = auto
Color
CheckSpace
ParallelDownloads = 8
DownloadUser = alpm

SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
PACMANCONF

# paru config
cat <<PARUCONF > /etc/paru.conf
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
PARUCONF

# rust config
mkdir -p /etc/makepkg.conf.d
cat <<RUSTCONF > /etc/makepkg.conf.d/rust.conf
RUSTFLAGS="-C target-cpu=native -C opt-level=3 -C link-arg=-fuse-ld=mold -C strip=symbols -C force-frame-pointers=yes"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCONF
EOF

PARTUUID=$(blkid -s PARTUUID -o value $ROOT)
arch-chroot /mnt efibootmgr -c -d $DISK -p 1 \
  -L "$EFILABEL" \
  -l '\\vmlinuz-linux-zen' \
  -u "zfs=rpool/ROOT rw root=PARTUUID=$PARTUUID initrd=\\booster-linux-zen.img resume=$SWAP quiet loglevel=0 mitigations=off noibrs noibpb nospec_store_bypass_disable l1tf=off pcie_aspm=off nvme_core.default_ps_max_latency_us=0 u.random.trust_cpu=on processor.max_cstate=1 nohz=on iommu=pt nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1 liburing.force_io_uring=1 zswap.enabled=0"

arch-chroot /mnt bash -e <<EOF
cd /home/$USERNAME
git clone https://aur.archlinux.org/paru.git
chown -R $USERNAME:$USERNAME paru
cd paru
sudo -u $USERNAME makepkg -si --noconfirm

sudo -u $USERNAME paru -S --noconfirm zfs-dkms zfs-utils
EOF

echo "✅ Installation complete."
