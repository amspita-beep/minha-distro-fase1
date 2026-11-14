#!/bin/bash
set -e

mkdir -p build-env && cd build-env

# 1. Configuração da ISO Híbrida (BIOS MBR + UEFI) iniciando no terminal
sudo lb config \
  --architecture amd64 \
  --distribution bookworm \
  --archive-areas "main contrib non-free-firmware" \
  --apt-recommends false \
  --binary-images iso-hybrid \
  --bootloaders "syslinux,grub-efi" \
  --iso-application "CustomLinux-CLI" \
  --iso-volume "CUSTOM_LINUX_F1" \
  --bootappend-live "boot=live components locales=pt_BR.UTF-8 keyboard-layouts=br systemd.unit=multi-user.target"

# 2. Lista de Pacotes da Fase 1 (Kernel, Compilador, Rede e Bootloaders)
mkdir -p config/package-lists
cat << 'EOF' > config/package-lists/fase1.list.chroot
# Coração do Sistema e Boot
linux-image-amd64
live-boot
systemd-sysv

# Bootloaders Híbridos (MBR e UEFI) e Particionamento
grub-pc-bin
grub-efi-amd64-bin
grub2-common
efibootmgr
dosfstools
parted

# Compiladores e Ferramentas de Desenvolvimento
build-essential
git
bc
bison
flex
libssl-dev
libelf-dev

# Rede e Wi-Fi pelo Terminal
network-manager
wpasupplicant
wireless-tools
firmware-linux-free
firmware-realtek
firmware-atheros
curl
wget
openssh-client

# Otimização de Memória e Utilitários VPS-Style
zram-tools
htop
nano
vim
tmux
rsync
EOF

# 3. Otimizações de Memória (zRAM e Kernel) para Dual-Core
mkdir -p config/includes.chroot/etc/default
cat << 'EOF' > config/includes.chroot/etc/default/zramswap
ALGO=zstd
PERCENT=60
PRIORITY=100
EOF

mkdir -p config/includes.chroot/etc/sysctl.d
cat << 'EOF' > config/includes.chroot/etc/sysctl.d/99-perf.conf
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

# 4. Instalador em Modo Texto Embutido (/usr/local/bin/instalar-sistema)
mkdir -p config/includes.chroot/usr/local/bin
cat << 'EOF' > config/includes.chroot/usr/local/bin/instalar-sistema
#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "Execute como root: sudo instalar-sistema"
  exit 1
fi

clear
echo "=================================================="
echo "    INSTALADOR DE SISTEMA (BIOS MBR & UEFI)       "
echo "=================================================="
lsblk -d -p -n -l -o NAME,SIZE,MODEL | grep -E "sd|nvme|vd"
echo "--------------------------------------------------"
read -p "Digite o disco de destino (ex: /dev/sda): " DISCO

if [ ! -b "$DISCO" ]; then
  echo "Disco inválido!"
  exit 1
fi

echo "ATENÇÃO: Todos os dados em $DISCO serão apagados!"
read -p "Digite SIM para continuar: " CONFIRMA
[ "$CONFIRMA" != "SIM" ] && exit 1

read -p "Nome de usuário para o sistema: " NOVO_USER
read -s -p "Senha para $NOVO_USER e root: " SENHA
echo ""

if [ -d /sys/firmware/efi ]; then
  MODO="UEFI"
else
  MODO="BIOS"
fi
echo "Modo de boot detectado: $MODO"

wipefs -af "$DISCO"
if [ "$MODO" == "UEFI" ]; then
  parted -s "$DISCO" mklabel gpt
  parted -s "$DISCO" mkpart primary fat32 1MiB 301MiB
  parted -s "$DISCO" set 1 esp on
  parted -s "$DISCO" mkpart primary ext4 301MiB 100%
  PART_EFI="${DISCO}1"
  PART_ROOT="${DISCO}2"
  [[ "$DISCO" == *"nvme"* ]] && PART_EFI="${DISCO}p1" && PART_ROOT="${DISCO}p2"
  mkfs.vfat -F32 "$PART_EFI"
  mkfs.ext4 -F "$PART_ROOT"
  mount "$PART_ROOT" /mnt
  mkdir -p /mnt/boot/efi
  mount "$PART_EFI" /mnt/boot/efi
else
  parted -s "$DISCO" mklabel msdos
  parted -s "$DISCO" mkpart primary ext4 1MiB 100%
  parted -s "$DISCO" set 1 boot on
  PART_ROOT="${DISCO}1"
  [[ "$DISCO" == *"nvme"* ]] && PART_ROOT="${DISCO}p1"
  mkfs.ext4 -F "$PART_ROOT"
  mount "$PART_ROOT" /mnt
fi

echo "Instalando arquivos do sistema em $DISCO..."
rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/lib/live/*"} / /mnt/

UUID_ROOT=$(blkid -s UUID -o value "$PART_ROOT")
echo "UUID=$UUID_ROOT / ext4 errors=remount-ro 0 1" > /mnt/etc/fstab
if [ "$MODO" == "UEFI" ]; then
  UUID_EFI=$(blkid -s UUID -o value "$PART_EFI")
  echo "UUID=$UUID_EFI /boot/efi vfat umask=0077 0 1" >> /mnt/etc/fstab
fi

mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

chroot /mnt /bin/bash << CHROOT_EOF
apt-get purge -y live-boot live-config* || true
useradd -m -s /bin/bash -G sudo "$NOVO_USER"
echo "$NOVO_USER:$SENHA" | chpasswd
echo "root:$SENHA" | chpasswd
systemctl set-default multi-user.target
systemctl enable zramswap.service || true

if [ "$MODO" == "UEFI" ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=CustomLinux --recheck
else
  grub-install --target=i386-pc "$DISCO"
fi
update-grub
CHROOT_EOF

umount -R /mnt
echo "=================================================="
echo "Instalação concluída! Remova o pen drive e digite 'reboot'."
echo "=================================================="
EOF
chmod +x config/includes.chroot/usr/local/bin/instalar-sistema

# 5. Mensagem de boas-vindas no terminal
mkdir -p config/includes.chroot/etc
cat << 'EOF' > config/includes.chroot/etc/motd

==============================================================
 Fase 1 Ativa: Kernel + Compilador + Terminal Otimizado
 - Conectar Wi-Fi: nmtui
 - Instalar no HD/SSD: sudo instalar-sistema
==============================================================

EOF

# 6. Compila a ISO final
sudo lb build
mv live-image-amd64.hybrid.iso ../custom-linux-fase1.iso
