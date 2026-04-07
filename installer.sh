#!/bin/bash
# ================================================================
#  Advanced Arch Linux Interactive Installer (Explanatory Version)
#  - Fail-proofs, strict validation, and UEFI checks
#  - 5 practical options with detailed Pros/Cons for every choice
#  - Interactive, dynamic BTRFS subvolume configuration
# ================================================================
set -euo pipefail

# ── colors & helpers ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'; DIM='\033[2m'

info()   { echo -e "${GREEN}[*]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
ask()    { echo -e "${CYAN}[?]${NC} $1"; }
header() { echo -e "\n${BOLD}━━━ $1 ━━━${NC}"; }

# ── fail-proof sanity checks ─────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Must be run as root. Type 'sudo su' first."
[[ -d /sys/firmware/efi ]] || error "This script requires a UEFI booted system. BIOS/Legacy is not supported."
ping -c 1 -W 5 archlinux.org >/dev/null 2>&1 || error "No internet connection detected."
for cmd in sgdisk pacstrap arch-chroot mkfs.fat; do
    command -v "$cmd" &>/dev/null || error "'$cmd' not found. Are you on the official Arch ISO?"
done

# ================================================================
#  SECTION 1 — DRIVE
# ================================================================
header "Drive Selection"
lsblk -d -o NAME,SIZE,TYPE,MODEL,TRAN | grep -v loop
echo ""
while true; do
    ask "Enter the target drive (e.g. /dev/nvme0n1 or /dev/sda):"
    read -r DRIVE
    if [[ -b "$DRIVE" ]]; then break; else warn "Block device $DRIVE not found. Try again."; fi
done

if [[ "$DRIVE" == *"nvme"* ]] || [[ "$DRIVE" == *"mmcblk"* ]]; then
    PART_PREFIX="${DRIVE}p"
else
    PART_PREFIX="${DRIVE}"
fi

# ================================================================
#  SECTION 2 — PARTITION SIZES
# ================================================================
header "Partition Sizes"
echo -e "${DIM}EFI Partition: Stores bootloaders and kernel images.${NC}"
while true; do
    ask "EFI partition size? (e.g., 512M, 1G) [default: 1G]:"
    read -r BOOT_SIZE
    BOOT_SIZE="${BOOT_SIZE:-1G}"
    if [[ "$BOOT_SIZE" =~ ^[0-9]+[MG]$ ]]; then break; else warn "Invalid format. Use numbers followed by M or G."; fi
done

echo -e "\n${BOLD}Swap Strategy:${NC}"
echo "  - 0:  Skip (Best if you have 32GB+ RAM or prefer a swapfile later)"
echo "  - 4G-8G:  Good for general use/multitasking"
echo "  - 1x RAM: Required for reliable Hibernation (Suspend-to-Disk)"
while true; do
    ask "Swap partition size? [default: 8G]:"
    read -r SWAP_SIZE
    SWAP_SIZE="${SWAP_SIZE:-8G}"
    if [[ "$SWAP_SIZE" == "0" || "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]]; then break; else warn "Invalid format."; fi
done

if [[ "$SWAP_SIZE" == "0" ]]; then
    HAS_SWAP=false
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
header "Filesystem Selection"
echo -e "1) ${BOLD}BTRFS${NC}"
echo -e "   ${GREEN}+${NC} Snapshots (Timeshift/Snapper), transparent compression, easy subvolumes."
echo -e "   ${RED}-${NC} Slightly more complex; metadata can fill up if not maintained."
echo -e "2) ${BOLD}EXT4${NC}"
echo -e "   ${GREEN}+${NC} The gold standard for stability. Simple, fast, and rock-solid."
echo -e "   ${RED}-${NC} No native snapshots or built-in compression."
echo -e "3) ${BOLD}XFS${NC}"
echo -e "   ${GREEN}+${NC} Exceptional performance with large files and high-concurrency workloads."
echo -e "   ${RED}-${NC} Cannot be shrunk; only expanded."
echo -e "4) ${BOLD}F2FS${NC}"
echo -e "   ${GREEN}+${NC} Specifically optimized for NAND flash (SSDs/NVMe). Very fast."
echo -e "   ${RED}-${NC} Higher risk of corruption on sudden power loss compared to EXT4."
echo -e "5) ${BOLD}Bcachefs${NC}"
echo -e "   ${GREEN}+${NC} The 'next-gen' FS. Combines BTRFS features with XFS speed."
echo -e "   ${RED}-${NC} Very new in the Linux kernel; strictly for experimental users."
echo ""
while true; do
    ask "Choose filesystem [1-5] (default: 1):"
    read -r FS_CHOICE
    case "${FS_CHOICE:-1}" in
        1) FS_TYPE="btrfs"; FS_PKG="btrfs-progs"; break ;;
        2) FS_TYPE="ext4"; FS_PKG=""; break ;;
        3) FS_TYPE="xfs"; FS_PKG="xfsprogs"; break ;;
        4) FS_TYPE="f2fs"; FS_PKG="f2fs-tools"; break ;;
        5) FS_TYPE="bcachefs"; FS_PKG="bcachefs-tools"; break ;;
        *) warn "Invalid choice." ;;
    esac
done

if [[ "$FS_TYPE" == "btrfs" ]]; then
    header "BTRFS Compression"
    echo "1) zstd  (Best Ratio) - Balanced performance; great for saving SSD life."
    echo "2) zstd:1 (Fastest Zstd) - Lower CPU impact while keeping good compression."
    echo "3) lzo   (High Speed) - Very light on CPU, but poor compression ratio."
    echo "4) zlib  (Legacy) - Good compression but very slow compared to zstd."
    echo "5) none  (Disabled) - No CPU overhead, uses full disk space."
    while true; do
        ask "Choose compression [1-5] (default: 1):"
        read -r COMPRESS_CHOICE
        case "${COMPRESS_CHOICE:-1}" in
            1) BTRFS_COMPRESS="compress=zstd"; break ;;
            2) BTRFS_COMPRESS="compress=zstd:1"; break ;;
            3) BTRFS_COMPRESS="compress=lzo"; break ;;
            4) BTRFS_COMPRESS="compress=zlib"; break ;;
            5) BTRFS_COMPRESS=""; break ;;
            *) warn "Invalid choice." ;;
        esac
    done

    BTRFS_BASE_OPTS="noatime,space_cache=v2"
    [[ -n "$BTRFS_COMPRESS" ]] && BTRFS_OPTS="${BTRFS_BASE_OPTS},${BTRFS_COMPRESS}" || BTRFS_OPTS="$BTRFS_BASE_OPTS"

    echo ""
    info "BTRFS Interactive Subvolume Creation"
    echo -e "${DIM}Tip: Create '@' for / and '@home' for /home to allow easy system rollbacks.${NC}"
    declare -A SUBVOL_MOUNTS
    while true; do
        ask "Enter subvolume name (e.g., @) or press Enter to finish:"
        read -r SV
        if [[ -z "$SV" ]]; then
            HAS_ROOT=false
            for MP in "${SUBVOL_MOUNTS[@]}"; do [[ "$MP" == "/" ]] && HAS_ROOT=true; done
            if ! $HAS_ROOT; then warn "You MUST assign a subvolume to '/'"; continue; fi
            break
        fi
        [[ "$SV" =~ \  ]] && { warn "No spaces allowed."; continue; }
        ask "Mount point for '$SV' (e.g., /, /home, /var/cache):"
        read -r MP
        SUBVOL_MOUNTS["$SV"]="$MP"
    done
fi

# ================================================================
#  SECTION 4 — KERNEL
# ================================================================
header "Kernel Selection"
echo -e "1) ${BOLD}Linux (Mainline)${NC}"
echo "   Standard stable kernel. Best for most users."
echo -e "2) ${BOLD}Linux-LTS${NC}"
echo "   Long Term Support. Best for servers or if you hate frequent updates."
echo -e "3) ${BOLD}Linux-Zen (Recommended)${NC}"
echo "   Optimized for desktop responsiveness, gaming, and low latency."
echo -e "4) ${BOLD}Linux-Hardened${NC}"
echo "   Focus on security. Can break some apps (like VirtualBox or Wine)."
echo -e "5) ${BOLD}Linux-RT${NC}"
echo "   Real-Time kernel. Only for professional audio or industrial robotics."
echo ""
while true; do
    ask "Choose kernel [1-5] (default: 3):"
    read -r KERNEL_CHOICE
    case "${KERNEL_CHOICE:-3}" in
        1) KERNEL="linux"; KERNEL_HEADERS="linux-headers"; break ;;
        2) KERNEL="linux-lts"; KERNEL_HEADERS="linux-lts-headers"; break ;;
        3) KERNEL="linux-zen"; KERNEL_HEADERS="linux-zen-headers"; break ;;
        4) KERNEL="linux-hardened"; KERNEL_HEADERS="linux-hardened-headers"; break ;;
        5) KERNEL="linux-rt"; KERNEL_HEADERS="linux-rt-headers"; break ;;
        *) warn "Invalid choice." ;;
    esac
done

# ================================================================
#  SECTION 5 — BOOTLOADER
# ================================================================
header "Bootloader Selection"
echo -e "1) ${BOLD}systemd-boot${NC}"
echo "   Modern, UEFI-only, extremely fast. Configured via simple text files."
echo -e "2) ${BOLD}GRUB${NC}"
echo "   The classic. Best for dual-booting with Windows or complex disk setups."
echo -e "3) ${BOLD}rEFInd${NC}"
echo "   Graphical menu that auto-scans for OSs. Great if you have multiple kernels."
echo -e "4) ${BOLD}EFISTUB${NC}"
echo "   No bootloader software. The Motherboard BIOS boots the Linux kernel directly."
echo -e "5) ${BOLD}None${NC}"
echo "   For experts who want to manual-install something else."
echo ""
while true; do
    ask "Choose bootloader [1-5] (default: 1):"
    read -r BOOT_CHOICE
    case "${BOOT_CHOICE:-1}" in
        1) BOOTLOADER="systemd-boot"; BOOT_PKG=""; break ;;
        2) BOOTLOADER="grub"; BOOT_PKG="grub efibootmgr"; break ;;
        3) BOOTLOADER="refind"; BOOT_PKG="refind"; break ;;
        4) BOOTLOADER="efistub"; BOOT_PKG="efibootmgr"; break ;;
        5) BOOTLOADER="none"; BOOT_PKG=""; break ;;
        *) warn "Invalid choice." ;;
    esac
done

# ================================================================
#  SECTION 6 — SYSTEM SETTINGS
# ================================================================
header "Localization & Identity"
while true; do
    ask "Hostname (Name of this computer, e.g., arch-gaming):"
    read -r HOSTNAME
    HOSTNAME="${HOSTNAME:-archlinux}"
    [[ "$HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]] && break || warn "Invalid characters."
done

ask "Timezone [default: UTC] (e.g., Europe/London):"
read -r TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

ask "Console Keymap [default: us]:"
read -r KEYMAP
KEYMAP="${KEYMAP:-us}"

ask "Locale [default: en_US.UTF-8]:"
read -r LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

# ================================================================
#  SECTION 7 — USER ACCOUNT & SHELL
# ================================================================
header "User Setup"
while true; do
    ask "New Username:"
    read -r USERNAME
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break || warn "Invalid username format."
done

echo -e "\n${BOLD}Shell Selection:${NC}"
echo "1) Bash: The standard. Predictable and universal."
echo "2) Zsh:  Powerful, great plugins (Oh-My-Zsh). Very popular."
echo "3) Fish: Interactive features (autosuggestions) work out-of-the-box."
echo "4) Nu:   Modern, handles data like a spreadsheet. Not POSIX-compliant."
echo "5) Tcsh: Legacy C-shell. Useful for specific scientific environments."
while true; do
    ask "Choose Shell [1-5] (default: 1):"
    read -r SHELL_CHOICE
    case "${SHELL_CHOICE:-1}" in
        1) USER_SHELL="/bin/bash"; SHELL_PKG=""; break ;;
        2) USER_SHELL="/bin/zsh"; SHELL_PKG="zsh"; break ;;
        3) USER_SHELL="/usr/bin/fish"; SHELL_PKG="fish"; break ;;
        4) USER_SHELL="/usr/bin/nu"; SHELL_PKG="nushell"; break ;;
        5) USER_SHELL="/bin/tcsh"; SHELL_PKG="tcsh"; break ;;
        *) warn "Invalid choice." ;;
    esac
done

# ================================================================
#  [LOGIC REMAINS IDENTICAL FROM THIS POINT ONWARD]
#  (Wiping, Partitioning, Formatting, Mounting, Pacstrap, Chroot)
# ================================================================

header "Microcode Detection"
if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
    UCODE="intel-ucode"; info "Intel CPU detected → $UCODE"
elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
    UCODE="amd-ucode"; info "AMD CPU detected → $UCODE"
else
    UCODE=""; warn "CPU vendor unknown."
fi

UCODE_BOOT_LINE=""
[[ -n "$UCODE" ]] && UCODE_BOOT_LINE="initrd=\\${UCODE}.img "

header "Summary"
echo -e "  Drive:         $DRIVE"
echo -e "  FS / Kernel:   $FS_TYPE / $KERNEL"
echo -e "  Bootloader:    $BOOTLOADER"
echo -e "  User:          $USERNAME"
echo ""
ask "Type 'yes' to begin installation (ERASES DISK!):"
read -r FINAL_CONFIRM
[[ "$FINAL_CONFIRM" == "yes" ]] || exit 0

# --- DISK OPERATIONS ---
wipefs -af "$DRIVE"
sgdisk -Z "$DRIVE"
if $HAS_SWAP; then
    sgdisk --new=1:0:+${BOOT_SIZE} --typecode=1:ef00 --change-name=1:EFI \
           --new=2:0:+${SWAP_SIZE} --typecode=2:8200 --change-name=2:SWAP \
           --new=3:0:0             --typecode=3:8300 --change-name=3:ROOT "$DRIVE"
else
    sgdisk --new=1:0:+${BOOT_SIZE} --typecode=1:ef00 --change-name=1:EFI \
           --new=2:0:0             --typecode=2:8300 --change-name=2:ROOT "$DRIVE"
fi
partprobe "$DRIVE" && sleep 2

# --- FORMATTING ---
mkfs.fat -F32 -n EFI "$PART_BOOT"
$HAS_SWAP && { mkswap -L SWAP "$PART_SWAP"; swapon "$PART_SWAP"; }
case "$FS_TYPE" in
    btrfs) mkfs.btrfs -f -L ROOT "$PART_ROOT" ;;
    ext4) mkfs.ext4 -F -L ROOT "$PART_ROOT" ;;
    xfs) mkfs.xfs -f -L ROOT "$PART_ROOT" ;;
    f2fs) mkfs.f2fs -f -l ROOT "$PART_ROOT" ;;
    bcachefs) bcachefs format --force -L ROOT "$PART_ROOT" ;;
esac

# --- MOUNTING ---
if [[ "$FS_TYPE" == "btrfs" ]]; then
    mount "$PART_ROOT" /mnt
    for SV in "${!SUBVOL_MOUNTS[@]}"; do btrfs subvolume create "/mnt/$SV"; done
    umount /mnt
    ROOT_SUBVOL=""
    for SV in "${!SUBVOL_MOUNTS[@]}"; do [[ "${SUBVOL_MOUNTS[$SV]}" == "/" ]] && ROOT_SUBVOL="$SV"; done
    mount -o "${BTRFS_OPTS},subvol=${ROOT_SUBVOL}" "$PART_ROOT" /mnt
    for SV in "${!SUBVOL_MOUNTS[@]}"; do
        MP="${SUBVOL_MOUNTS[$SV]}"
        [[ "$MP" == "/" ]] && continue
        mkdir -p "/mnt$MP"
        mount -o "${BTRFS_OPTS},subvol=${SV}" "$PART_ROOT" "/mnt$MP"
    done
else
    mount "$PART_ROOT" /mnt
fi
mkdir -p /mnt/boot && mount "$PART_BOOT" /mnt/boot

# --- INSTALL ---
PKGS="base base-devel $KERNEL $KERNEL_HEADERS linux-firmware networkmanager sudo $FS_PKG $BOOT_PKG $SHELL_PKG $UCODE"
pacstrap -K /mnt $PKGS
genfstab -U /mnt >> /mnt/etc/fstab

# --- CHROOT ---
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
UCODE_SYSTEMD_LINE=""
[[ -n "$UCODE" ]] && UCODE_SYSTEMD_LINE="initrd  /${UCODE}.img"

cat > /mnt/chroot_install.sh <<CHROOT_SCRIPT
#!/bin/bash
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname
systemctl enable NetworkManager
mkinitcpio -P

# Bootloader Config
case "$BOOTLOADER" in
    systemd-boot)
        bootctl install
        echo "default arch.conf" > /boot/loader/loader.conf
        { echo "title Arch Linux"; echo "linux /vmlinuz-${KERNEL}"; [[ -n "${UCODE_SYSTEMD_LINE}" ]] && echo "${UCODE_SYSTEMD_LINE}"; echo "initrd /initramfs-${KERNEL}.img"; echo "options root=UUID=${ROOT_UUID} $([[ "$FS_TYPE" == "btrfs" ]] && echo "rootflags=subvol=${ROOT_SUBVOL}") rw quiet"; } > /boot/loader/entries/arch.conf
        ;;
    grub)
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    refind)
        refind-install
        echo "\"Boot\" \"root=UUID=${ROOT_UUID} $([[ "$FS_TYPE" == "btrfs" ]] && echo "rootflags=subvol=${ROOT_SUBVOL}") rw ${UCODE_BOOT_LINE}initrd=\\initramfs-${KERNEL}.img\"" > /boot/refind_linux.conf
        ;;
    efistub)
        efibootmgr --create --disk "${DRIVE}" --part 1 --label "Arch" --loader /vmlinuz-${KERNEL} --unicode "root=UUID=${ROOT_UUID} rw ${UCODE_BOOT_LINE}initrd=\\initramfs-${KERNEL}.img"
        ;;
esac

echo "Setting Root Password:"
passwd
useradd -m -G wheel -s ${USER_SHELL} ${USERNAME}
echo "Setting Password for ${USERNAME}:"
passwd ${USERNAME}
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
CHROOT_SCRIPT

arch-chroot /mnt /bin/bash /chroot_install.sh
rm /mnt/chroot_install.sh
info "Done! Reboot now."
