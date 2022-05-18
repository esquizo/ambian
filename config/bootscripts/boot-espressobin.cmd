# DO NOT EDIT THIS FILE
#
# Please edit /boot/armbianEnv.txt to set supported parameters
#

# Some tests to try to keep compatibility with old variables
if test -z "${kernel_addr_r}"; then
  setenv kernel_addr_r $kernel_addr
fi
if test -z "${ramdisk_addr_r}"; then
  setenv ramdisk_addr_r $initrd_addr
fi
if test -z "${fdt_addr_r}"; then
  setenv fdt_addr_r $fdt_addr
fi
if test -z "${distro_bootpart}"; then
  setenv distro_bootpart 1
fi
if test -z "${devtype}"; then
  setenv devtype $boot_interface
fi

load ${devtype} ${devnum}:${distro_bootpart} ${scriptaddr} ${prefix}armbianEnv.txt
env import -t ${scriptaddr} ${filesize}

setenv bootargs "$console root=${rootdev} rootfstype=${rootfstype} rootwait loglevel=${verbosity} usb-storage.quirks=${usbstoragequirks}  ${extraargs}"

load $devtype ${devnum}:${distro_bootpart} $ramdisk_addr_r ${prefix}espressobin.itb

bootm ${ramdisk_addr_r}#$board_version

# fallback to non-FIT image
if test -z "${image_name}"; then
  setenv image_name "Image"
fi
if test -z "${initrd_image}"; then
  setenv initrd_image "uInitrd"
fi
if test -z "${fdt_name}"; then
  if test -z "${fdtfile}"; then
    setenv fdt_name "dtb/marvell/armada-3720-espressobin.dtb"
  else
    setenv fdt_name "dtb/$fdtfile"
  fi
fi
ext4load $devtype ${devnum}:1 $kernel_addr_r ${prefix}$image_name
ext4load $devtype ${devnum}:1 $ramdisk_addr_r ${prefix}$initrd_image
ext4load $devtype ${devnum}:1 $fdt_addr_r ${prefix}$fdt_name

booti $kernel_addr_r $ramdisk_addr_r $fdt_addr_r
# mkimage -C none -A arm -T script -d /boot/boot.cmd /boot/boot.scr.uimg
