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

# password protect the destroy menu entry
echo ""
echo "set superusers=\"morro\"" >> $GRUB_CUSTOM
echo "password morro morrolinux.it" >> $GRUB_CUSTOM
echo "export superusers" >> $GRUB_CUSTOM
sed -i -r "s/(.*menuentry )('.*)/\1--unrestricted \2/g" /etc/grub.d/10_linux


# make the menu visible
sed -i 's/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/g' /etc/default/grub

# rebuild grub menu
grub-mkconfig -o /boot/grub/grub.cfg

echo "ALL IS DONE! - Now you can reboot.."

