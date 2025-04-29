#!/bin/bash

set -Eeuo pipefail

## Install proprietary NVidia drivers
 
# @see https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=24.04&target_type=deb_network
sudo wget -P /opt/ https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i /opt/cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get -y install cuda-toolkit-12-8

sudo apt-get install -y cuda-drivers

# https://askubuntu.com/questions/1228423/how-do-i-fix-cuda-breaking-after-suspend
echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/tmp" | sudo tee /etc/modprobe.d/nvidia-power-management.conf
sudo update-initramfs -u
sudo systemctl enable nvidia-suspend.service

sudo rm /opt/cuda-keyring_1.1-1_all.deb
