#!/bin/bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
today="$(date +"%Y-%m-%d")"
tmpdir="$(mktemp -d)"

function log() {
        echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
        local msg=$1
        local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "$msg"
        exit "$code"
}

function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  
  set +e
  
  mount | grep isomnt | awk '{ print $3; }' | xargs -r sudo umount
  sudo losetup --list | grep noble-desktop-amd64.iso | awk '{ print $1; }' | xargs -r sudo losetup -d
  mount | grep msr_ | awk '{ print $3; }' | xargs -r sudo umount
  mount  | grep minimal_ | awk '{ print $3; }' | xargs -r sudo umount
  sudo rm -rf "${tmpdir}" *.upper *.root *.work *.mnt
  log "removed ${tmpdir}"
  
  set -e
  
  log "cleanup done"
}

trap cleanup SIGINT SIGTERM ERR EXIT

function check_command() {
  local cmd="${1}"
  local package="${2:-$1}"
  [[ -x "$(command -v "$cmd")" ]] || die "💥 $cmd is not installed. On Ubuntu, install  the '$package' package."
}

function check_package() {
  (dpkg-query --show --showformat='${db:Status-Status}\n' "$1" 2>/dev/null | grep -q '^installed$') || die "💥 the '$1' package is missing"
}
 
log "🔎 Checking for required utilities..."
check_command xorriso
check_command mksquashfs
check_command sed
check_command curl
check_command gpg
check_command fuse-overlayfs
check_package klibc-utils
check_package coreutils
check_package squashfs-tools
log "👍 All required utilities are installed."

# 1. Download the CD image. 
wget -nc https://cdimage.ubuntu.com/noble/daily-live/pending/noble-desktop-amd64.iso

# 2. Extract the content of the ISO
7z -y x "noble-desktop-amd64.iso" -o"${tmpdir}/iso" &>/dev/null
chmod -R u+w "${tmpdir}/iso"

# 4. Copy the image, so that we can modify it (we can't change it in-place because .iso filesystems are read-only) and remove unneeded files 
sudo cp -a "${tmpdir}/iso" "${tmpdir}/extracted"

# Remove the files we don't need
sudo rm -rf ${tmpdir}/extracted/casper/*.{de,en,es,fr,it,no-languages,pt,ru,zh}.*
sudo rm -rf ${tmpdir}/extracted/casper/*secureboot*
sudo rm -rf ${tmpdir}/extracted/casper/*filesystem*

mv "$tmpdir/iso/"'[BOOT]' "$tmpdir/BOOT"

log "👍 Extracted to $tmpdir/iso"

log "🧩 Adding autoinstall parameter to kernel command line..."
sed -i -e 's/---/ autoinstall ---/g' "$tmpdir/extracted/boot/grub/grub.cfg"
sed -i -e 's/---/ autoinstall ---/g' "$tmpdir/extracted/boot/grub/loopback.cfg"
log "👍 Added parameter to UEFI kernel command line."

log "🧩 Setting grub timeout to 5 seconds..."
sed -i -e 's/timeout=30/timeout=5/g' "$tmpdir/extracted/boot/grub/grub.cfg"
sed -i -e 's/timeout=30/timeout=5/g' "$tmpdir/extracted/boot/grub/loopback.cfg"
log "👍 Timeout set for UEFI kernel command line."

log "🧩 Adding user-data and meta-data files..."
mkdir "$tmpdir/extracted/server"
cp "$script_dir/user-data" "$tmpdir/extracted/server/user-data"
touch "$tmpdir/extracted/server/meta-data"

sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/server/ ---,g' "$tmpdir/extracted/boot/grub/grub.cfg"
sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/server/ ---,g' "$tmpdir/extracted/boot/grub/loopback.cfg"
log "👍 Added data and configured kernel command line."

# 6. Setup the image to install a custom disk image, rather than one of the provided images:

# Overrite the install-sources.yaml
cat << EOF | sudo tee ${tmpdir}/extracted/casper/install-sources.yaml
- default: false
  description:
     en: Minimal Ubuntu for NUMSR.
  id: ubuntu-desktop-minimal
  locale_support: langpack
  name:
     en: Ubuntu (minimized)
  size: 0
  path: msr.squashfs
  type: fsimage-layered
  variant: desktop
EOF

if [[ ! -d msr_image ]]; then
# Bootstrap the system
sudo debootstrap --arch=amd64 --variant=minbase \
--include=\
adduser,\
apt,\
apt-utils,\
bash-completion,\
console-setup,\
debconf,\
debconf-i18n,\
e2fsprogs,\
efibootmgr,\
grub-efi-amd64,\
grub-efi-amd64-signed,\
init,\
initramfs-tools,\
iproute2,\
iputils-ping,\
kbd,\
kmod,\
language-selector-common,\
less,\
linux-image-generic,\
locales,\
lsb-release,\
mawk,\
mount,\
netbase,\
passwd,\
procps,\
python3,\
sensible-utils,\
shim-signed,\
systemd-resolved,\
sudo,\
tzdata,\
ubuntu-keyring,\
udev,\
vim-tiny,\
whiptail,\
rsyslog,\
zstd \
noble msr_image
fi

if [[ ! -f msr.squashfs ]]; then
sudo mount none -t proc msr_image/proc/
sudo mount none -t sysfs msr_image/sys/
sudo mount none -t devpts msr_image/dev/pts
sudo mount none -t tmpfs msr_image/tmp
sudo mount none -t tmpfs msr_image/run

# Make sure we can resolve hostnames in the chroot
sudo mkdir -p msr_image/run/systemd/resolve
sudo cp /etc/resolv.conf msr_image/run/systemd/resolve/stub-resolv.conf
sudo chroot msr_image /bin/bash -x <<'EOF'

# Install some improtant packages
apt update
apt install --no-install-recommends -y software-properties-common wpasupplicant

# Add all ubuntu distribution components
add-apt-repository -y universe
add-apt-repository -y restricted
add-apt-repository -y multiverse

apt update
apt install --no-install-recommends \
network-manager \
cloud-init \
curl \
ca-certificates \
make \
vim \
git \
cryptsetup \
cryptsetup-initramfs \
lvm2 \
thin-provisioning-tools \
btrfs-progs \
dmsetup \
openssh-server

apt autoremove
apt clean

exit
EOF

sudo umount msr_image/proc
sudo umount msr_image/sys
sudo umount msr_image/dev/pts
sudo umount msr_image/tmp
sudo umount msr_image/run

## Make the Minimal Squashfs

# Make the squashfs filesystem from the chroot environment
# Warning, there should not be an existing msr.squashfs present: rm msr.squashfs
sudo mksquashfs msr_image msr.squashfs -comp xz
fi

# Copy squashfs to casper
sudo cp msr.squashfs ${tmpdir}/extracted/casper

## Make the Desktop Squashfs

# Append the install-sources.yaml
cat << EOF | sudo tee -a ${tmpdir}/extracted/casper/install-sources.yaml
- default: true
  description:
    en: A minimal Ubuntu Desktop for NUMSR.
  id: ubuntu-desktop
  locale_support: langpack
  name:
    en: Ubuntu Desktop (NUMSR)
  size: 0
  path: msr.desktop.squashfs
  type: fsimage-layered
  variant: desktop
EOF

if [[ ! -f msr.desktop.squashfs ]]; then
mkdir -p msr_desktop msr_desktop.work msr_desktop.upper msr_image.mnt

# 2.  Mount the overlay (assumes fuse-overlayfs is installed): 
sudo mount -t squashfs msr.squashfs msr_image.mnt -o loop
sudo mount -t overlay \
 -o lowerdir=msr_image.mnt,upperdir=msr_desktop.upper,workdir=msr_desktop.work \
 overlay msr_desktop

# 3.  Mount all the filesystems needed for chroot and enter it 
sudo mount none -t proc msr_desktop/proc/
sudo mount none -t sysfs msr_desktop/sys/
sudo mount none -t devpts msr_desktop/dev/pts
sudo mount none -t tmpfs msr_desktop/tmp
sudo mount none -t tmpfs msr_desktop/run

# Copy Luks password changer
sudo cp ./luks-password-changer.deb msr_desktop/opt/

# Copy GPG/ASC keys
sudo mkdir -p msr_desktop/opt/keys
sudo cp keys/* msr_desktop/opt/keys/

# Make sure we can resolve hostnames in the chroot
sudo mkdir -p msr_desktop/run/systemd/resolve
sudo cp /etc/resolv.conf msr_desktop/run/systemd/resolve/stub-resolv.conf
sudo chroot msr_desktop /bin/bash -x <<'EOF'
apt update
apt install --no-install-recommends -y \
  alsa-base \
  alsa-utils \
  anacron \
  at-spi2-core \
  bc \
  dbus-x11 \
  dmz-cursor-theme \
  fontconfig \
  fonts-dejavu-core \
  foomatic-db-compressed-ppds \
  gdm3 \
  ghostscript \
  gnome-control-center \
  gnome-menus \
  gnome-session-canberra \
  gnome-settings-daemon \
  gnome-shell \
  gnome-shell-extension-appindicator \
  gnome-shell-extension-desktop-icons-ng \
  gnome-shell-extension-ubuntu-dock \
  gnome-shell-extension-ubuntu-tiling-assistant \
  gstreamer1.0-alsa \
  gstreamer1.0-packagekit \
  gstreamer1.0-plugins-base-apps \
  inputattach \
  language-selector-gnome \
  libatk-adaptor \
  libnotify-bin \
  libsasl2-modules \
  libu2f-udev \
  nautilus \
  openprinting-ppds \
  pipewire-pulse \
  printer-driver-pnm2ppa \
  rfkill \
  spice-vdagent \
  ubuntu-drivers-common \
  ubuntu-session \
  ubuntu-settings \
  unzip \
  wireless-tools \
  wireplumber \
  xdg-user-dirs \
  xdg-user-dirs-gtk \
  xorg \
  yelp \
  zenity \
  zip \
  appstream \
  apt-config-icons-hidpi \
  baobab \
  bluez \
  bluez-cups \
  cups \
  cups-bsd \
  cups-client \
  cups-filters \
  dirmngr \
  eog \
  evince \
  fonts-liberation \
  fonts-noto-cjk \
  fonts-noto-color-emoji \
  fonts-noto-core \
  fonts-ubuntu \
  fwupd \
  fwupd-signed \
  gir1.2-gmenu-3.0 \
  gnome-accessibility-themes \
  gnome-bluetooth-sendto \
  gnome-calculator \
  gnome-characters \
  gnome-clocks \
  gnome-disk-utility \
  gnome-font-viewer \
  gnome-keyring \
  gnome-logs \
  gnome-power-manager \
  gnome-remote-desktop \
  gnome-system-monitor \
  gnome-terminal \
  gnome-text-editor \
  gpg-agent \
  gsettings-ubuntu-schemas \
  gvfs-fuse \
  hplip \
  ibus \
  ibus-gtk \
  ibus-gtk3 \
  ibus-table \
  im-config \
  kerneloops \
  laptop-detect \
  libnss-mdns \
  libpam-gnome-keyring \
  libpam-sss \
  libspa-0.2-bluetooth \
  libwmf0.2-7-gtk \
  memtest86+ \
  mousetweaks \
  nautilus-sendto \
  orca \
  plymouth-theme-spinner \
  policykit-desktop-privileges \
  seahorse \
  speech-dispatcher \
  systemd-oomd \
  ubuntu-docs \
  ubuntu-wallpapers \
  xcursor-themes \
  xdg-desktop-portal-gnome \
  xdg-utils \
  yaru-theme-gnome-shell \
  yaru-theme-gtk \
  yaru-theme-icon \
  yaru-theme-sound \
  libfuse2 \
  mesa-utils \
  libayatana-appindicator3-1 \
  file-roller \
  p7zip-full

# Mozilla Firefox
wget -qO /etc/apt/keyrings/packages.mozilla.org.asc https://packages.mozilla.org/apt/repo-signing-key.gpg

cat << EOT > /etc/apt/sources.list.d/mozilla.sources
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOT

cat << EOT > /etc/apt/preferences.d/mozilla
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1' | sudo tee /etc/apt/preferences.d/mozilla
EOT

# Docker
wget -qO /etc/apt/keyrings/docker.asc https://download.docker.com/linux/ubuntu/gpg

cat << EOT > /etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOT

# Jetbrains (https://github.com/JonasGroeger/jetbrains-ppa)
wget -qO- https://s3.eu-central-1.amazonaws.com/jetbrains-ppa/0xA6E8698A.pub.asc | gpg --dearmor > /etc/apt/keyrings/jetbrains-ppa-archive-keyring.gpg

cat << EOT > /etc/apt/sources.list.d/jetbrains.sources
Types: deb
URIs: http://jetbrains-ppa.s3-website.eu-central-1.amazonaws.com
Suites: any
Components: main
Signed-By: /etc/apt/keyrings/jetbrains-ppa-archive-keyring.gpg
EOT

# VSCode
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/packages.microsoft.gpg

cat << EOT > /etc/apt/sources.list.d/code.sources
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /etc/apt/keyrings/packages.microsoft.gpg
EOT

# Google Chrome
wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /etc/apt/keyrings/google-chrome.gpg

cat << EOT > /etc/apt/sources.list.d/google-chrome.sources
Types: deb
URIs: http://dl.google.com/linux/chrome/deb/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/google-chrome.gpg
EOT

cat << EOT > /etc/apt/apt.conf.d/99remove-google-chrome-crap
DPkg::Post-Invoke { "rm -f /etc/apt/sources.list.d/google-chrome.list || true"; };
DPkg::Post-Invoke { "rm -f /etc/cron.daily/google-chrome || true"; };
EOT

# Slack
cat /opt/keys/slack-desktop.gpg | gpg --dearmor > /etc/apt/keyrings/slack-desktop.gpg

cat << EOT > /etc/apt/sources.list.d/slack-desktop.sources
Types: deb
URIs: https://packagecloud.io/slacktechnologies/slack/debian/
Suites: jessie
Components: main
Signed-By: /etc/apt/keyrings/slack-desktop.gpg
EOT

cat << EOT > /etc/apt/apt.conf.d/99remove-slack-desktop-crap
DPkg::Post-Invoke { "rm -f /etc/cron.daily/slack || true"; };
EOT

tee -a /etc/skel/.profile <<EOT
if [ ! -f "$HOME/.config/.favorite-apps-installed" ]; then
    mkdir -p $HOME/.config
    touch $HOME/.config/.favorite-apps-installed
    gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'firefox.desktop', 'google-chrome.desktop', 'slack.desktop', 'code.desktop', 'phpstorm.desktop']"
fi
EOT

sudo apt-get update

apt update
apt install --no-install-recommends -y \
firefox \
google-chrome-stable \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin \
code \
phpstorm \
slack-desktop \
/opt/luks-password-changer.deb

apt autoremove
apt clean

exit
EOF

# 6. Unmount the filesystems needed for the chroot: 
sudo umount msr_desktop/proc
sudo umount msr_desktop/sys
sudo umount msr_desktop/dev/pts
sudo umount msr_desktop/tmp
sudo umount msr_desktop/run

# Make the squashfs of the overlayed filesystem: 
sudo mksquashfs msr_desktop.upper msr.desktop.squashfs -comp xz
fi

# Copy the squashfs to the iso: 
sudo cp msr.desktop.squashfs ${tmpdir}/extracted/casper

if [[ ! -f "${script_dir}/noble-desktop-amd64-autoinstall-${today}.iso" ]]; then
pushd "$tmpdir/extracted"
xorriso \
  -as mkisofs -r -V "ubuntu-autoinstall-$today" -o "${script_dir}/noble-desktop-amd64-autoinstall-${today}.iso" \
  --grub2-mbr ../BOOT/1-Boot-NoEmul.img \
  -partition_offset 16 \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b ../BOOT/2-Boot-NoEmul.img \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b '/boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e '--interval:appended_partition_2:::' -no-emul-boot .
popd
fi