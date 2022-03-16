# Rockchip RK3566 quad core 4GB-8GB GBE PCIe USB3
BOARD_NAME="Quartz64 A"
BOARDFAMILY="media"
BOOT_SOC="rk3568"
BOOTCONFIG="quartz64-a-rk3566_defconfig"
KERNEL_TARGET="edge"
FULL_DESKTOP="yes"
BOOT_LOGO="desktop"
BOOT_FDT_FILE="rockchip/rk3566-quartz64-a.dtb"
SRC_EXTLINUX="yes"
SRC_CMDLINE="console=ttyS02,1500000 console=tty0"
ASOUND_STATE="asound.state.station-m2"
IMAGE_PARTITION_TABLE="gpt"
