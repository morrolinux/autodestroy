#!/bin/bash

# Variables for grub
user=""
password=""
entry_name=""
speed=0

usage() {
  echo "usage: $0 -u <user> -p <password> [-e <grub entry name>] [-s enable or disable erasing speed (write zero or urandom)]"
  exit 1
}


handle_args(){
	while getopts ":u:p:e:s:" opt; do
	case "${opt}" in
		u)
		user="$OPTARG"
		;;
		p)
		password="$OPTARG"
		;;
		e)
		entry_name="$OPTARG"
		;;
		s)
		speed=1
		;;		
		\?)
		echo "Unrecognized option: -$OPTARG"
		usage
		;;
	esac
	done
	if [ -z "$user" ] || [ -z "$password" ]
	then
		echo "You must specify the user, password."
		usage
	fi
	if [ -n "$entry_name" ]; then
		echo "GRUB Entry Name: $entry_name"
	else
		entry_name="Destroy"
	fi
}

handle_args "$@"

# install required dependencies
apt -y install gdisk
apt -y install efibootmgr

WORKDIR="/boot/autodestroy"
mkdir $WORKDIR
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

# extract multi part cpio archive
unmkinitramfs $INITRD .
rm -rf early*
mv main/* .
rmdir main

echo "extraction complete."
ls -l
echo "PLEASE confirm everything is alright and press ENTER to continue, or CTRL-c to abort."
read -n 1 -s


# MODIFY THE RAMDISK 

# copy the executables and their deps over to the initramfs
# if other apps are needed, add them to the list

apps=("lsblk" "dd" "sgdisk" "wipefs" "efibootmgr" "rev")

for app in "${apps[@]}"; do
	app_path="$(which $app)"
	if [ -f "$app_path" ] && [ -x "$app_path" ]
	then
		app_path_cut=$(echo "$app_path" | sed 's/^\///')
		cp -f "$app_path" "$app_path_cut"
		for file in $(ldd "$app_path" | cut -d' ' -f3 | grep -vE "^$"); do
			cp "$file" lib/x86_64-linux-gnu/
		done
	fi
done


# detect plymouth theme 
plymouth_theme=$(readlink -f /usr/share/plymouth/themes/default.plymouth|rev|cut -d/ -f2|rev)

# modify plymouth theme (distro-specific) - add yours below in a separate if clause.
if [[ $plymouth_theme == "rhino-spinner" ]]
then
	cp -f assets/plymouth/themes/skull/logo.png usr/share/plymouth/themes/$plymouth_theme/logo.png
else
# modify plymouth theme (generic, universal)
	for f in $(ls usr/share/plymouth/themes/*/*.png)
	do
		cp -f assets/plymouth/themes/skull/logo.png $f
	done
fi


DESTROY_BIN="bin/destroy.sh"
echo '#!/bin/sh' > $DESTROY_BIN
echo 'mount -t efivarfs efivarfs /sys/firmware/efi/efivars'  >> $DESTROY_BIN
echo 'for entry in $(efibootmgr | grep Boot0 | grep -v EFI | cut -d* -f1 | cut -dt -f2); do efibootmgr -B -b $entry; done' >> $DESTROY_BIN
echo 'efibootmgr -v' >> $DESTROY_BIN
echo 'export rootfs=$(mount | grep -w "on /root"|cut -d" " -f1)' >> $DESTROY_BIN
echo 'echo ROOTFS IS: $rootfs' >> $DESTROY_BIN
echo 'umount /root' >> $DESTROY_BIN
echo 'sgdisk -Z $rootfs' >> $DESTROY_BIN
echo 'wipefs -af $rootfs' >> $DESTROY_BIN
echo 'echo Erasing drive... please wait...' >> $DESTROY_BIN
if [ $speed -eq 1 ]
then
	echo 'dd if=/dev/zero of=/dev/$(lsblk -ndo pkname $rootfs) bs=4M status=progress' >> $DESTROY_BIN
else
	echo 'dd if=/dev/urandom of=/dev/$(lsblk -ndo pkname $rootfs) bs=4M status=progress' >> $DESTROY_BIN
fi
echo 'reboot -f' >> $DESTROY_BIN
chmod +x $DESTROY_BIN

# patch the init script
sed -i -r 's/(^# Mount cleanup$)/exec \/bin\/destroy.sh\n\1/' ./init
# sed -i -r 's/(^# Mount cleanup$)/exec \/usr\/bin\/sh\n\1/' ./init

# build the initramfs cpio archive
echo "creating initramfs cpio archive..."
find . -print0 | cpio --null --create --verbose --format=newc | gzip --best > /boot/destroy.cpio.gz

# ADD A CUSTOM GRUB ENTRY
GRUB_CUSTOM="/etc/grub.d/40_custom"
ROOT_UUID=$(blkid $(mount | grep -w "on /") -s UUID -o value)

echo "" >> $GRUB_CUSTOM
echo "menuentry '$entry_name' --users $user --class os 'destroy' { " >> $GRUB_CUSTOM
echo "        load_video" >> $GRUB_CUSTOM
echo "        set gfxpayload=keep" >> $GRUB_CUSTOM
echo "        insmod gzio" >> $GRUB_CUSTOM
echo "        insmod part_gpt" >> $GRUB_CUSTOM
echo "        insmod ext2" >> $GRUB_CUSTOM
echo "        search --no-floppy --fs-uuid --set=root $ROOT_UUID" >> $GRUB_CUSTOM
echo "        linux /boot/vmlinuz root=UUID=$ROOT_UUID ro quiet splash" >> $GRUB_CUSTOM
echo "        initrd /boot/destroy.cpio.gz" >> $GRUB_CUSTOM
echo "}" >> $GRUB_CUSTOM

# password protect the destroy menu entry
echo ""
echo "set superusers=\"$user\"" >> $GRUB_CUSTOM
echo "password $user $password" >> $GRUB_CUSTOM
echo "export superusers" >> $GRUB_CUSTOM
sed -i -r "s/(.*menuentry )('.*)/\1--unrestricted \2/g" /etc/grub.d/10_linux


# make the menu visible
sed -i 's/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/g' /etc/default/grub

# rebuild grub menu
grub-mkconfig -o /boot/grub/grub.cfg

echo "ALL IS DONE! - Now you can reboot.."
