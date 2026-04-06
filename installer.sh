#!/bin/bash
# ================================================================
#  Arch Linux Interactive Installer
#  - Asks about every important detail before touching the disk
#  - BTRFS or EXT4, systemd-boot or GRUB, any kernel
#  - Auto microcode detection, user account, sudo, shell
# ================================================================
set -e

# ── colors ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${GREEN}[*]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
ask()    { echo -e "${CYAN}[?]${NC} $1"; }
header() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }

# ── sanity checks ────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root (you're in the live ISO, right?)"
command -v sgdisk     &>/dev/null || error "sgdisk not found."
command -v pacstrap   &>/dev/null || error "pacstrap not found. Are you in the Arch ISO?"
command -v arch-chroot &>/dev/null || error "arch-chroot not found."

# ================================================================
#  SECTION 1 — DRIVE
# ================================================================
header "Drive Selection"
echo ""
lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN | grep -v loop
echo ""
ask "Enter the target drive (e.g. /dev/nvme0n1 or /dev/sda):"
read -r DRIVE
[[ -b "$DRIVE" ]] || error "Block device $DRIVE not found."

if [[ "$DRIVE" == *"nvme"* ]] || [[ "$DRIVE" == *"mmcblk"* ]]; then
    PART_PREFIX="${DRIVE}p"
else
    PART_PREFIX="${DRIVE}"
fi

# ================================================================
#  SECTION 2 — PARTITION SIZES
# ================================================================
header "Partition Sizes"

ask "EFI partition size? (default: 1G, recommended minimum 512M):"
read -r BOOT_SIZE
BOOT_SIZE="${BOOT_SIZE:-1G}"

echo ""
echo "  Swap options:"
echo "  - A swap partition is separate from root and fast to enable/disable"
echo "  - Enter 0 to skip (you can add a swapfile later)"
echo "  - Recommended: match your RAM size for hibernation support"
ask "Swap partition size? (e.g. 8G, 16G, or 0 to skip):"
read -r SWAP_SIZE
SWAP_SIZE="${SWAP_SIZE:-8G}"

if [[ "$SWAP_SIZE" == "0" ]]; then
    HAS_SWAP=false
    PART_SWAP=""
    PART_BOOT="${PART_PREFIX}1"
    PART_ROOT="${PART_PREFIX}2"
else
    HAS_SWAP=true
    PART_BOOT="${PART_PREFIX}1"
    PART_SWAP="${PART_PREFIX}2"
    PART_ROOT="${PART_PREFIX}3"
fi

# ================================================================
#  SECTION 3 — FILESYSTEM
# ================================================================
header "Filesystem"
echo ""
echo "  1) BTRFS  — snapshots, compression, subvolumes (recommended)"
echo "  2) EXT4   — classic, stable, zero surprises"
echo ""
ask "Choose filesystem [1/2] (default: 1):"
read -r FS_CHOICE
FS_CHOICE="${FS_CHOICE:-1}"
case "$FS_CHOICE" in
    1) FS_TYPE="btrfs" ;;
    2) FS_TYPE="ext4"  ;;
    *) warn "Invalid, defaulting to btrfs."; FS_TYPE="btrfs" ;;
esac

if [[ "$FS_TYPE" == "btrfs" ]]; then
    echo ""
    echo "  BTRFS subvolumes to create:"
    echo "  Default layout: @  @home  @var_log  @snapshots  @pkg"
    echo "  @pkg = /var/cache/pacman/pkg  (excluded from snapshots, saves space)"
    echo ""
    ask "Use default subvolume layout? (Y/n):"
    read -r DEFAULT_SUBVOLS
    DEFAULT_SUBVOLS="${DEFAULT_SUBVOLS:-Y}"
    if [[ "$DEFAULT_SUBVOLS" =~ ^[Yy] ]]; then
        SUBVOLS=("@" "@home" "@var_log" "@snapshots" "@pkg")
    else
        ask "Enter subvolume names space-separated (e.g. @ @home @var_log):"
        read -r -a SUBVOLS
    fi

    echo ""
    echo "  Compression:"
    echo "  1) zstd  — best balance of speed + ratio (recommended)"
    echo "  2) lzo   — faster, less compression"
    echo "  3) none  — no compression"
    ask "Choose compression [1/2/3] (default: 1):"
    read -r COMPRESS_CHOICE
    case "${COMPRESS_CHOICE:-1}" in
        1) BTRFS_COMPRESS="compress=zstd" ;;
        2) BTRFS_COMPRESS="compress=lzo"  ;;
        3) BTRFS_COMPRESS=""              ;;
        *) warn "Invalid, defaulting to zstd."; BTRFS_COMPRESS="compress=zstd" ;;
    esac

    BTRFS_BASE_OPTS="noatime,space_cache=v2"
    [[ -n "$BTRFS_COMPRESS" ]] && BTRFS_OPTS="${BTRFS_BASE_OPTS},${BTRFS_COMPRESS}" || BTRFS_OPTS="$BTRFS_BASE_OPTS"
fi

# ================================================================
#  SECTION 4 — KERNEL
# ================================================================
header "Kernel"
echo ""
echo "  1) linux-zen      — tuned for desktop/gaming latency (recommended)"
echo "  2) linux          — vanilla stable"
echo "  3) linux-lts      — long-term support, most stable"
echo "  4) linux-hardened — security hardened (may break some software)"
echo ""
ask "Choose kernel [1/2/3/4] (default: 1):"
read -r KERNEL_CHOICE
case "${KERNEL_CHOICE:-1}" in
    1) KERNEL="linux-zen";      KERNEL_HEADERS="linux-zen-headers"      ;;
    2) KERNEL="linux";          KERNEL_HEADERS="linux-headers"           ;;
    3) KERNEL="linux-lts";      KERNEL_HEADERS="linux-lts-headers"       ;;
    4) KERNEL="linux-hardened"; KERNEL_HEADERS="linux-hardened-headers"  ;;
    *) warn "Invalid, defaulting to linux-zen."; KERNEL="linux-zen"; KERNEL_HEADERS="linux-zen-headers" ;;
esac

# ================================================================
#  SECTION 5 — BOOTLOADER
# ================================================================
header "Bootloader"
echo ""
echo "  1) systemd-boot — simple, fast, built into systemd (recommended for UEFI)"
echo "  2) GRUB         — more features, dual-boot friendly"
echo ""
ask "Choose bootloader [1/2] (default: 1):"
read -r BOOT_CHOICE
case "${BOOT_CHOICE:-1}" in
    1) BOOTLOADER="systemd-boot" ;;
    2) BOOTLOADER="grub"         ;;
    *) warn "Invalid, defaulting to systemd-boot."; BOOTLOADER="systemd-boot" ;;
esac

# ================================================================
#  SECTION 6 — SYSTEM SETTINGS
# ================================================================
header "System Settings"

ask "Hostname (default: archlinux):"
read -r HOSTNAME
HOSTNAME="${HOSTNAME:-archlinux}"

echo ""
echo "  Tip: find your timezone with: ls /usr/share/zoneinfo/  or  ls /usr/share/zoneinfo/Europe/"
echo "  Example: Europe/Istanbul"
ask "Timezone (default: UTC):"
read -r TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || warn "Timezone '$TIMEZONE' may not exist. Double-check after install."

ask "Console keymap (default: us — run 'localectl list-keymaps' to browse):"
read -r KEYMAP
KEYMAP="${KEYMAP:-us}"

echo ""
echo "  Common locales: en_US.UTF-8  tr_TR.UTF-8  de_DE.UTF-8  fr_FR.UTF-8"
ask "Locale (default: en_US.UTF-8):"
read -r LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

# ================================================================
#  SECTION 7 — EXTRA PACKAGES
# ================================================================
header "Extra Packages"
echo ""
echo "  Always included: base base-devel $KERNEL $KERNEL_HEADERS linux-firmware networkmanager sudo"
[[ "$FS_TYPE" == "btrfs" ]] && echo "  Auto-added:      btrfs-progs"
[[ -n "$UCODE" ]] && echo "  Auto-added:      $UCODE (microcode)"
echo ""
echo "  Suggestions: neovim vim git curl wget htop openssh reflector man-db"
ask "Extra packages (space-separated, or enter to skip):"
read -r EXTRA_PKGS

# ================================================================
#  SECTION 8 — USER ACCOUNT
# ================================================================
header "User Account"

ask "Username for your main account:"
read -r USERNAME
while [[ -z "$USERNAME" || ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; do
    warn "Invalid. Use lowercase letters, numbers, _ or - (must start with letter or _)"
    ask "Username:"
    read -r USERNAME
done

ask "Should '$USERNAME' have sudo (wheel) access? (Y/n):"
read -r SUDO_ACCESS
SUDO_ACCESS="${SUDO_ACCESS:-Y}"

echo ""
echo "  1) bash  — universal default"
echo "  2) zsh   — more features, popular with oh-my-zsh"
echo "  3) fish  — beginner-friendly, autosuggestions built in"
ask "Shell for '$USERNAME' [1/2/3] (default: 1):"
read -r SHELL_CHOICE
case "${SHELL_CHOICE:-1}" in
    1) USER_SHELL="/bin/bash";     SHELL_PKG="" ;;
    2) USER_SHELL="/bin/zsh";      SHELL_PKG="zsh" ;;
    3) USER_SHELL="/usr/bin/fish"; SHELL_PKG="fish" ;;
    *) warn "Invalid, defaulting to bash."; USER_SHELL="/bin/bash"; SHELL_PKG="" ;;
esac

# ================================================================
#  SECTION 9 — MICROCODE AUTO-DETECT
# ================================================================
header "Microcode Detection"
if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
    UCODE="intel-ucode"
    info "Intel CPU detected → will install intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
    UCODE="amd-ucode"
    info "AMD CPU detected → will install amd-ucode"
else
    UCODE=""
    warn "CPU vendor unknown. No microcode will be installed."
fi

# ================================================================
#  SECTION 10 — FINAL SUMMARY + CONFIRM
# ================================================================
header "Full Summary — Review Before Confirming"
echo ""
echo -e "  Drive:         ${RED}${BOLD}$DRIVE  ← WILL BE COMPLETELY WIPED${NC}"
echo    "  EFI size:      $BOOT_SIZE"
if $HAS_SWAP; then
    echo "  Swap:          $SWAP_SIZE"
else
    echo "  Swap:          skipped"
fi
echo    "  Filesystem:    $FS_TYPE"
if [[ "$FS_TYPE" == "btrfs" ]]; then
    echo "  Subvolumes:    ${SUBVOLS[*]}"
    echo "  Compression:   ${BTRFS_COMPRESS:-none}"
fi
echo    "  Kernel:        $KERNEL"
echo    "  Bootloader:    $BOOTLOADER"
echo    "  Hostname:      $HOSTNAME"
echo    "  Timezone:      $TIMEZONE"
echo    "  Keymap:        $KEYMAP"
echo    "  Locale:        $LOCALE"
echo    "  Microcode:     ${UCODE:-none}"
echo    "  Username:      $USERNAME"
echo    "  User shell:    $USER_SHELL"
echo    "  Sudo access:   $SUDO_ACCESS"
[[ -n "$EXTRA_PKGS" ]] && echo "  Extra pkgs:    $EXTRA_PKGS"
echo ""
warn "ALL DATA ON $DRIVE WILL BE PERMANENTLY DESTROYED."
echo ""
ask "Type exactly 'yes' to continue, anything else to abort:"
read -r FINAL_CONFIRM
[[ "$FINAL_CONFIRM" == "yes" ]] || { echo "Aborted. Nothing was touched."; exit 0; }

# ================================================================
#  SECTION 11 — WIPE AND PARTITION
# ================================================================
header "Wiping Drive"
info "Wiping existing signatures..."
wipefs -af "$DRIVE"
info "Zapping partition table..."
sgdisk -Z "$DRIVE"
sleep 2

header "Creating Partitions"
if $HAS_SWAP; then
    sgdisk \
        --new=1:0:+${BOOT_SIZE}  --typecode=1:ef00 --change-name=1:EFI  \
        --new=2:0:+${SWAP_SIZE}  --typecode=2:8200 --change-name=2:SWAP \
        --new=3:0:0              --typecode=3:8300 --change-name=3:ROOT  \
        "$DRIVE"
else
    sgdisk \
        --new=1:0:+${BOOT_SIZE}  --typecode=1:ef00 --change-name=1:EFI  \
        --new=2:0:0              --typecode=2:8300 --change-name=2:ROOT  \
        "$DRIVE"
fi

info "Telling kernel to re-read partition table..."
partprobe "$DRIVE" 2>/dev/null || true
sleep 2

[[ -b "$PART_BOOT" ]] || error "Boot partition $PART_BOOT not found. Partitioning may have failed."
[[ -b "$PART_ROOT" ]] || error "Root partition $PART_ROOT not found. Partitioning may have failed."
$HAS_SWAP && { [[ -b "$PART_SWAP" ]] || error "Swap partition $PART_SWAP not found."; }
info "All partitions verified."

# ================================================================
#  SECTION 12 — FORMAT
# ================================================================
header "Formatting"
info "EFI → FAT32..."
mkfs.fat -F32 -n EFI "$PART_BOOT"

if $HAS_SWAP; then
    info "Swap partition..."
    mkswap -L SWAP "$PART_SWAP"
    swapon "$PART_SWAP"
fi

if [[ "$FS_TYPE" == "btrfs" ]]; then
    info "Root → BTRFS..."
    mkfs.btrfs -f -L ROOT "$PART_ROOT"
else
    info "Root → EXT4..."
    mkfs.ext4 -F -L ROOT "$PART_ROOT"
fi

# ================================================================
#  SECTION 13 — MOUNT
# ================================================================
header "Mounting"

if [[ "$FS_TYPE" == "btrfs" ]]; then
    info "Creating subvolumes..."
    mount "$PART_ROOT" /mnt
    for SV in "${SUBVOLS[@]}"; do
        btrfs subvolume create "/mnt/$SV"
        info "  created: $SV"
    done
    umount /mnt

    info "Mounting @ as root with opts: $BTRFS_OPTS"
    mount -o "${BTRFS_OPTS},subvol=@" "$PART_ROOT" /mnt

    declare -A SUBVOL_MOUNTPOINTS=(
        ["@home"]="/mnt/home"
        ["@var_log"]="/mnt/var/log"
        ["@snapshots"]="/mnt/.snapshots"
        ["@pkg"]="/mnt/var/cache/pacman/pkg"
        ["@tmp"]="/mnt/tmp"
    )
    for SV in "${SUBVOLS[@]}"; do
        [[ "$SV" == "@" ]] && continue
        MP="${SUBVOL_MOUNTPOINTS[$SV]:-}"
        if [[ -n "$MP" ]]; then
            mkdir -p "$MP"
            mount -o "${BTRFS_OPTS},subvol=${SV}" "$PART_ROOT" "$MP"
            info "  mounted $SV → $MP"
        fi
    done
else
    mount "$PART_ROOT" /mnt
    mkdir -p /mnt/home
fi

mkdir -p /mnt/boot
mount "$PART_BOOT" /mnt/boot
info "Boot mounted at /mnt/boot"

# ================================================================
#  SECTION 14 — PACSTRAP
# ================================================================
header "Installing Base System"
PKGS="base base-devel $KERNEL $KERNEL_HEADERS linux-firmware networkmanager sudo"
[[ "$FS_TYPE"    == "btrfs" ]] && PKGS+=" btrfs-progs"
[[ -n "$UCODE"              ]] && PKGS+=" $UCODE"
[[ -n "$SHELL_PKG"          ]] && PKGS+=" $SHELL_PKG"
[[ "$BOOTLOADER" == "grub"  ]] && PKGS+=" grub efibootmgr"
[[ -n "$EXTRA_PKGS"         ]] && PKGS+=" $EXTRA_PKGS"

info "Running pacstrap with: $PKGS"
pacstrap -K /mnt $PKGS

# ================================================================
#  SECTION 15 — FSTAB
# ================================================================
header "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
info "fstab written."

# ================================================================
#  SECTION 16 — CHROOT SCRIPT
# ================================================================
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
[[ -z "$ROOT_UUID" ]] && error "Could not get UUID for $PART_ROOT"

# build ucode initrd line — empty string if no ucode
UCODE_LINE=""
[[ -n "$UCODE" ]] && UCODE_LINE="initrd  /${UCODE}.img"

header "Building Chroot Script"
cat > /mnt/chroot_install.sh <<CHROOT_SCRIPT
#!/bin/bash
set -e
GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "\${GREEN}[*]\${NC} \$1"; }

info "Setting timezone ${TIMEZONE}..."
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

info "Configuring locale..."
grep -qxF "${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
[[ "${LOCALE}" != "en_US.UTF-8" ]] && { grep -qxF "en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; }
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

info "Setting console keymap..."
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

info "Setting hostname..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1       localhost
::1             localhost
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

info "Enabling NetworkManager..."
systemctl enable NetworkManager

CHROOT_SCRIPT

# ── bootloader section (injected based on choice) ────────────────
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
cat >> /mnt/chroot_install.sh <<CHROOT_SCRIPT
info "Installing systemd-boot..."
bootctl install

cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 5
console-mode max
editor no
LOADER

{
echo "title   Arch Linux (${KERNEL})"
echo "linux   /vmlinuz-${KERNEL}"
[[ -n "${UCODE_LINE}" ]] && echo "${UCODE_LINE}"
echo "initrd  /initramfs-${KERNEL}.img"
if [[ "${FS_TYPE}" == "btrfs" ]]; then
    echo "options root=UUID=${ROOT_UUID} rootflags=subvol=@ rw rootfstype=${FS_TYPE} quiet loglevel=3"
else
    echo "options root=UUID=${ROOT_UUID} rw rootfstype=${FS_TYPE} quiet loglevel=3"
fi
} > /boot/loader/entries/arch.conf

info "systemd-boot configured."
CHROOT_SCRIPT
else
cat >> /mnt/chroot_install.sh <<CHROOT_SCRIPT
info "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
sed -i 's/#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
info "GRUB installed and configured."
CHROOT_SCRIPT
fi

cat >> /mnt/chroot_install.sh <<CHROOT_SCRIPT

info "Regenerating initramfs..."
mkinitcpio -P

info "--- Set ROOT password ---"
passwd

info "Creating user account: ${USERNAME}"
useradd -m -G wheel,audio,video,storage,optical,network -s ${USER_SHELL} ${USERNAME}
info "--- Set password for ${USERNAME} ---"
passwd ${USERNAME}

if [[ "${SUDO_ACCESS}" =~ ^[Yy] ]]; then
    info "Configuring sudo for wheel group..."
    echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel
fi

info "Chroot configuration done."
CHROOT_SCRIPT

chmod +x /mnt/chroot_install.sh

# ================================================================
#  SECTION 17 — EXECUTE CHROOT
# ================================================================
header "Entering Chroot"
arch-chroot /mnt /chroot_install.sh

# ================================================================
#  SECTION 18 — CLEANUP + DONE
# ================================================================
rm -f /mnt/chroot_install.sh

echo ""
echo -e "${GREEN}${BOLD}━━━ Installation Complete ━━━${NC}"
echo ""
echo "  Kernel:     $KERNEL"
echo "  Bootloader: $BOOTLOADER"
echo "  Filesystem: $FS_TYPE"
echo "  User:       $USERNAME  ($USER_SHELL)"
echo "  Hostname:   $HOSTNAME"
echo ""
echo "  Next steps:"
echo "  1. Type 'reboot'"
echo "  2. Remove USB/ISO when screen goes black"
echo "  3. Boot into Arch"
echo ""
warn "If boot fails, boot back into the ISO and check:"
echo "  cat /mnt/boot/loader/entries/arch.conf   (systemd-boot)"
echo "  lsblk -o NAME,UUID                        (verify UUIDs)"
echo ""
