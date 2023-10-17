#!/bin/bash

# Install required dependencies
apt -y install gdisk
apt -y install efibootmgr
apt -y install parallel

WORKDIR="/boot/autodestroy"
mkdir -p $WORKDIR
rm -rf $WORKDIR/*
cp -rf assets $WORKDIR/
cd $WORKDIR

# EXTRACT THE INITIAL RAMDISK
INITRD="/boot/initrd.img"
rm ./init
echo "EXTRACTING $INITRD"

get_cpio_blocks() {
  dd if=$INITRD skip=$1 | cpio -it 2>&1 1>/dev/null | cut -d' ' -f1
}

get_stream_type() {
  dd if=$INITRD skip=$1 | file - | cut -d' ' -f2
}

# Extract multi-part cpio archive
unmkinitramfs $INITRD .
rm -rf early*
mv main/* .
rmdir main

echo "Extraction complete."
ls -l
read -p "Please confirm everything is alright and press ENTER to continue or CTRL-c to abort."

# MODIFY THE RAMDISK 

# Copy the executables and their dependencies to the initramfs
for exe in lsblk dd sgdisk wipefs efibootmgr rev; do
  cp -f $(which $exe) usr/bin/
  for file in $(ldd usr/bin/$exe | cut -d' ' -f3 | grep -vE ^$); do
    cp $file lib/x86_64-linux-gnu/
  done
done

# Detect the Plymouth theme 
plymouth_theme=$(readlink -f /usr/share/plymouth/themes/default.plymouth|rev|cut -d/ -f2|rev)

# Modify Plymouth theme (distro-specific)
if [[ $plymouth_theme == "rhino-spinner" ]]; then
  cp -f assets/plymouth/themes/skull/logo.png usr/share/plymouth/themes/$plymouth_theme/logo.png
else
  # Modify Plymouth theme (generic, universal)
  for f in $(ls usr/share/plymouth/themes/*/*.png); do
    cp -f assets/plymouth/themes/skull/logo.png $f
  done
fi

DESTROY_BIN="bin/destroy.sh"
echo '#!/bin/sh' > $DESTROY_BIN
echo 'mount -t efivarfs efivarfs /sys/firmware/efi/efivars'  >> $DESTROY_BIN
echo 'for entry in $(efibootmgr | grep Boot0 | grep -v EFI | cut -d* -f1 | cut -dt -f2); do efibootmgr -B -b $entry; done' >> $DESTROY_BIN
echo 'efibootmgr -v' >> $DESTROY_BIN
echo 'export rootfs=$(mount | grep -w "on /root"|cut-d" " -f1)' >> $DESTROY_BIN
echo 'echo ROOTFS IS: $rootfs' >> $DESTROY_BIN
echo 'umount /root' >> $DESTROY_BIN
echo 'sgdisk -Z $rootfs' >> $DESTROY_BIN
echo 'wipefs -a $rootfs' >> $DESTROY_BIN
echo 'echo Erasing drive... please wait...'

# Use parallel processing for erasure
echo 'parallel -j $(nproc) "dd if=/dev/urandom of=/dev/{} bs=4M status=progress" ::: $(lsblk -ndo pkname $rootfs)' >> $DESTROY_BIN

echo 'reboot -f' >> $DESTROY_BIN
chmod +x $DESTROY_BIN

# Patch the init script
sed -i -r 's/(^# Mount cleanup$)/exec \/bin\/destroy.sh\n\1/' ./init

# Create the initramfs cpio archive
echo "Creating initramfs cpio archive..."
find . -print0 | cpio --null --create --verbose --format=newc | gzip --best > /boot/destroy.cpio.gz

# ADD A CUSTOM GRUB ENTRY
GRUB_CUSTOM="/etc/grub.d/40_custom"
ROOT_UUID=$(blkid $(mount | grep -w "on /") -s UUID -o value)

echo "" >> $GRUB_CUSTOM
echo "menuentry 'Destroy' --users morro --class os 'destroy' { " >> $GRUB_CUSTOM
echo "        load_video" >> $GRUB_CUSTOM
echo "        set gfxpayload=keep" >> $GRUB_CUSTOM
echo "        insmod gzio" >> $GRUB_CUSTOM
echo "        insmod part_gpt" >> $GRUB_CUSTOM
echo "        insmod ext2" >> $GRUB_CUSTOM
echo "        search --no-floppy --fs-uuid --set=root $ROOT_UUID" >> $GRUB_CUSTOM
echo "        linux /boot/vmlinuz root=UUID=$ROOT_UUID ro quiet splash" >> $GRUB_CUSTOM
echo "        initrd /boot/destroy.cpio.gz" >> $GRUB_CUSTOM
echo "}" >> $GRUB_CUSTOM

# Password protect the destroy menu entry
echo ""
echo "set superusers=\"morro\"" >> $GRUB_CUSTOM
echo "password morro morrolinux.it" >> $GRUB_CUSTOM
echo "export superusers" >> $GRUB_CUSTOM
sed -i -r "s/(.*menuentry )('.*)/\1--unrestricted \2/g" /etc/grub.d/10_linux

# Make the menu visible
sed -i 's/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/g' /etc/default/grub

# Rebuild grub menu
grub-mkconfig -o /boot/grub/grub.cfg

echo "ALL IS DONE! - Now you can reboot.."
