#!/bin/sh
#--setup--
script="$(pwd)"
echo "$script"
pacman -Syy --noconfirm pacman-contrib reflector rsync grub gptfdisk btrfs-progs
sed -i 's/^#Para/Para/' /etc/pacman.conf
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

reflector -a 48 -f 5 -l 20 --sort rate --save /etc/pacman.d/mirrorlist
mkdir /mnt

lsblk
echo "Please enter disk to work on: (example /dev/sda)"
read mountpoint
echo "THIS WILL FORMAT AND DELETE ALL DATA ON THE DISK"
read -p "Are you sure you want to continue (y/n):" FORMAT
case $FORMAT in

    y|Y|yes|Yes|YES)
        echo -e "formatting disk"

        sgdisk -Z ${mountpoint}#destroy structure
        sgdisk -a 2048 -o ${mountpoint}#set alignment and clear all partitions

        #partitioning
        sgdisk -n 1::+1M -t 1:ef02 --change-name=1:'BIOSBOOT' ${mountpoint}#1 partition for BIOSBOOT
        sgdisk -n 2::+100M -t 1:ef00 --change-name=2:'EFIBOOT' ${mountpoint}#2 partition for EFIBOOT
        sgdisk -n 3::-0 -t 1:8300 --change-name=3:'ROOT' ${mountpoint}#3 partition for Root
        if [[ ! -d "/sys/firmware/efi" ]]; then
            sgdisk -A 1:set:2 ${mountpoint}#erace efi boot if efi system
        fi

        #make filesystem
        echo "Creating Filesystem"
        
        if [[ ${mountpoint} =~ "nvme" ]]; then
            mkfs.vfat -F32 -n "efi" "${mountpoint}p2"
            mkfs.btrfs -L "root" "${mountpoint}p3"
            mount -t btrfs "${mountpoint}p3" /mnt
        else
            mkfs.vfat -F32 -n "efi" "${mountpoint}2"
            mkfs.btrfs -L "root" "${mountpoint}3"
            mount -t btrfs "${mountpoint}3" /mnt
        fi
        ls /mnt | xarg btrfs subvolume delete
        btrfs subvolume create /mnt/@
        umount /mnt
        ;;
    *)
        echo "Rebooting" && sleep 1
        reboot now
        ;;
esac
mount -t btrfs -o subvol=@ -L ROOT /mnt
mkdir /mnt/boot
mkdir /mnt/boot/efi
mount -t vfat -L EFIBOOT /mnt/boot/

if ! grep -qs '/mnt' /proc/mounts; then
    echo "Drive is not mounted"
    echo "Rebooting" && sleep 1
    reboot now
fi
#installing
pacstrap /mnt base base-devel linux linux-firmware vim nano sudo archlinux-keyring wget libnewt --noconfirm --needed
genfstab -U /mnt >> /mnt/etc/fstab
cp -R ${script} /mnt/root/autoScript # måste hitta på något namn till detta
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# grub for BIOS
if [[ ! -d "/sys/firmware/efi" ]]; then
    grub-install --boot-directory=/mnt/boot ${mountpoint} #set grub
fi

arch-chroot /mnt
# network setup
pacman -S --noconfirm --needed networkmanager dhclient
systemctl enable --now NetworkManager

#
cores=$(grep -c ^processor /proc/cpuinfo)
echo "You have "$cores" cores."
echo "changing the makeflags for "$cores" cores."
totmem=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit]]*')
if [[ $totmem -gt 8000000 ]]; then
    sed -i "s/#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$cores\"/g" /etc/makepkg.conf
    sed -i "s/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T $cores -z -)/g" /etc/makepkg.conf
if
#language
sed -i 's/^#en_US.UFT-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
timedatectl --no-ask-password set-timezone Europe/Stockholm
timedatectl --no-ask-password set-ntp 1

#set locale
echo "LANG=en_US.UFT-8" >> /etc/locale.conf
#set keymap
echo "KEYMAP=se-latin1" >> /etc/vconsole.conf
##set up sudo with no password in a few seconds
sed -i 's/^# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
#speed up the download and add multilib
sed -i 's/^#Para/Para/' /etc/pacman.conf
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm

pkgs=(
'mesa'
'xorg'
    )
for pkg in "${pkgs[@]}"; do
    echo "Installing: ${pkg}"
    sudo pacman -S "$pkg" --noconfirm --needed
done
proc_type=$(lscpu | awk '/Vendor ID:/ {print $3}')
case "$proc_type" in
    GenuineIntel)
        print "Intalling Intel microcode"
        pacman -S --noconfirm intel-ucode
        proc_ucode=intel-ucode.img
        ;;
    AuthenticAMD)
        print "Installing AMD microcode"
        pacman -S --noconfirm amd-ucode
        proc_ucode=amd-ucode.img
        ;;
esac

if lspci | grep -E "NVIDIA|GeForce"; then
    pacman -S nvidia --noconfirm --needed
    nvidia-xconfig
elif lspci | grep -E "Radeon"; then
    pacman -S xf86-video-amdgpu --noconfirm --needed
elif lspci | grep -E "Integrated Graphics Controller"; then
    pacman -S libva-intel-driver libvdpau-va-gl lib32-vulkan-intel libva-intel-driver libva-utils --needed --noconfirm
fi
echo -e "\nDone"
if ! source install.conf; then
    read -p "Plaese enter username:"username
    echo "username:$username:"
fi
if [ $(whoami) = "root" ]; then
    useradd -m wheel,libvirt -s /bin/bash $username
    passwd $username
    cp -R /root/autoScript /home/$username/
    chown -R $username: /home/$username/autoScript
    read -p "please name your system machine:" nameofmachine
    echo $nameofmachine > /etc/hostname
else
    echo "You are already a user proceed with aur installs"
fi

#paru 
cd ~
git clone "https://aur.archlinux.org/paru.git"
cd ${HOME}/paru
makepkg -si --noconfirm
cd ~
if [[ -d "/sys/firmware/efi" ]]; then
    grub-install --efi-directory=/boot ${diskmount}
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Remove no password sudo rights
sed -i 's/^%wheel ALL=(ALL) NOPASSWD: ALL/# %wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
# Add sudo rights
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
echo "Done restart and enjoy!"
