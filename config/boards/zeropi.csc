# Allwinner H3 quad core 512MB RAM GBE SoC headless
BOARD_NAME="ZeroPi"
BOARDFAMILY="sun8i"
BOARD_MAINTAINER=""
BOOTCONFIG="zeropi_defconfig"
DEFAULT_OVERLAYS="usbhost1 usbhost2"
MODULES_BLACKLIST="lima"
DEFAULT_CONSOLE="serial"
SERIALCON="ttyS0"
HAS_VIDEO_OUTPUT="no"
KERNEL_TARGET="legacy,current,edge"
