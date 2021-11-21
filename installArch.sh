#! /bin/bash
pacman -Sy --noconfirm dialog archlinux-keyring || { echo "You are not root user"; exit; }

dialog --no-cancel --inputbox "Enter your name for your computer." 10 60 2> computername
dialog --defaultno --title "Time Zone select" --yesno "Do you want to use the defualt time zone(Europe/Stockholm)?\n Press no to select your own time zone" 10 60 && echo "Europe/Stockholm" > tz.tmp || tzselect > tz.tmp
dialog --no-cancel --inputbox "Enter drive to install on (example sda)" 10 60 2> disk

sed -i 's/^#Para/Para/' /etc/pacman.conf
#fix so that it is correct drive and working
re='^[a-z0-9]{3,9}'

mount="/dev/"$(cat disk)
timedatectl set-ntp true
#format the drive and set up GPT structure
sgdisk -Z $mount 
sgdisk -a 2048 -o $mount
#check if it is efi system or not and add partition for it
if [[ ! -d "/sys/firmware/efi" ]]; then   
sgdisk -n 1::+1M --typecode=1:ef02 --change-name=1:'BIOSBOOT' $mount
else
sgdisk -n 1::+1000M --typecode=1:ef00 --change-name=1:'EFIBOOT' $mount
fi
sgdisk -n 2::-0 --typecode=2:8300 --change-name=2:'ROOT' $mount
#check if its nvme or sdX and set right ending
if [[ $mount =~ "nvme" ]]; then
yes | mkfs.vfat -F32 -n "efi" $mount"p1"
yes | mkfs.btrfs -L "root" $mount"p2"
mount -t btrfs $mount"p2" /mnt
else
yes | mkfs.vfat -F32 -n "efi" $mount"1"
yes | mkfs.btrfs -L "root" $mount"2"
mount -t btrfs  $mount"2" /mnt
fi
#remove subvolume and create new subvolume with @ in the begining for easy snapshots and unmountar
ls /mnt | xargs btrfs subvolume delete
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

#Make the directories
mkdir /mnt/home
mkdir /mnt/boot
mkdir /mnt/boot/efi
#mount the System 
mount -t btrfs -o subvol=@ -L ROOT /mnt
mount -t btrfs -o subvol=@home -L ROOT /mnt/home
mount -t vfat -L EFIBOOT /mnt/boot/

if ! grep -qs '/mnt' /proc/mounts; then
echo "Drive is not mounted"
cat | grep -qs '/mnt' /proc/mounts
echo "Rebooting in 3 secounds" && sleep 3
fi

pacstrap /mnt base base-devel linux linux-firmware vim
genfstab -U /mnt >> /mnt/etc/fstab
cat tz.tmp > /mnt/tzfinal.tmp
rm tz.tmp
mv computername /mnt/etc/hostname

arch-chroot /mnt 
dialog --defualtno --title "Final Qs" --yesno "reboot computer?" 5 30 && reboot
dialog --defualtno --title "final Qs" --yesno "return to chroot environment?" 6 30 && arch-choot /mnt
clear
