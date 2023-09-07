#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function install_distribution_agnostic() {
	display_alert "Installing distro-agnostic part of rootfs" "install_distribution_agnostic" "debug"

	# Bail if $ROOTFS_TYPE not set
	[[ -z $ROOTFS_TYPE ]] && exit_with_error "ROOTFS_TYPE not set" "install_distribution_agnostic"

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> "${SDCARD}"/etc/fstab
	# required for initramfs-tools-core on Stretch since it ignores the / fstab entry
	echo "/dev/mmcblk0p2 /usr $ROOTFS_TYPE defaults 0 2" >> "${SDCARD}"/etc/fstab

	# create modules file
	local modules=MODULES_${BRANCH^^}
	if [[ -n "${!modules}" ]]; then
		tr ' ' '\n' <<< "${!modules}" > "${SDCARD}"/etc/modules
	elif [[ -n "${MODULES}" ]]; then
		tr ' ' '\n' <<< "${MODULES}" > "${SDCARD}"/etc/modules
	fi

	# create blacklist files
	local blacklist=MODULES_BLACKLIST_${BRANCH^^}
	if [[ -n "${!blacklist}" ]]; then
		tr ' ' '\n' <<< "${!blacklist}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	elif [[ -n "${MODULES_BLACKLIST}" ]]; then
		tr ' ' '\n' <<< "${MODULES_BLACKLIST}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	fi

	# configure MIN / MAX speed for cpufrequtils
	cat <<- EOF > "${SDCARD}"/etc/default/cpufrequtils
		ENABLE=${CPUFREQUTILS_ENABLE:-false}
		MIN_SPEED=$CPUMIN
		MAX_SPEED=$CPUMAX
		GOVERNOR=$GOVERNOR
	EOF

	# remove default interfaces file if present
	# before installing board support package
	rm -f "${SDCARD}"/etc/network/interfaces

	# disable selinux by default
	mkdir -p "${SDCARD}"/selinux
	[[ -f "${SDCARD}"/etc/selinux/config ]] && sed "s/^SELINUX=.*/SELINUX=disabled/" -i "${SDCARD}"/etc/selinux/config

	# remove Ubuntu's legal text
	[[ -f "${SDCARD}"/etc/legal ]] && rm "${SDCARD}"/etc/legal

	# Prevent loading paralel printer port drivers which we don't need here.
	# Suppress boot error if kernel modules are absent
	if [[ -f "${SDCARD}"/etc/modules-load.d/cups-filters.conf ]]; then
		sed "s/^lp/#lp/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^ppdev/#ppdev/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^parport_pc/#parport_pc/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
	fi

	# console fix due to Debian bug # @TODO: rpardini: still needed?
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i "${SDCARD}"/etc/default/console-setup

	# add the /dev/urandom path to the rng config file
	echo "HRNGDEVICE=/dev/urandom" >> "${SDCARD}"/etc/default/rng-tools

	# @TODO: security problem?
	# ping needs privileged action to be able to create raw network socket
	# this is working properly but not with (at least) Debian Buster
	chroot_sdcard chmod u+s /bin/ping

	# change time zone data
	echo "${TZDATA}" > "${SDCARD}"/etc/timezone
	chroot_sdcard dpkg-reconfigure -f noninteractive tzdata

	# set root password. it is written to the log, of course. Escuse the escaping needed here.
	display_alert "Setting root password" "" "info"
	chroot_sdcard "(" echo "'${ROOTPWD}'" ";" echo "'${ROOTPWD}'" ";" ")" "|" passwd root

	# enable automated login to console(s)
	if [[ $CONSOLE_AUTOLOGIN == yes ]]; then
		mkdir -p "${SDCARD}"/etc/systemd/system/getty@.service.d/
		mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/
		# @TODO: check why there was a sleep 10s in ExecStartPre
		cat <<- EOF > "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf
			[Service]
			ExecStart=
			ExecStart=-/sbin/agetty --noissue --autologin root %I \$TERM
			Type=idle
		EOF
		cp "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf "${SDCARD}"/etc/systemd/system/getty@.service.d/override.conf
	fi

	# force change root password at first login
	#chroot "${SDCARD}" /bin/bash -c "chage -d 0 root"

	# change console welcome text
	echo -e "${VENDOR} ${IMAGE_VERSION:-"${REVISION}"} ${RELEASE^} \\l \n" > "${SDCARD}"/etc/issue
	echo "${VENDOR} ${IMAGE_VERSION:-"${REVISION}"} ${RELEASE^}" > "${SDCARD}"/etc/issue.net

	# PRETTY_NAME changing in os-release is now done in armbian-base-files directly.

	# enable few bash aliases enabled in Ubuntu by default to make it even
	sed "s/#alias ll='ls -l'/alias ll='ls -l'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias la='ls -A'/alias la='ls -A'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias l='ls -CF'/alias l='ls -CF'/" -i "${SDCARD}"/etc/skel/.bashrc
	# root user is already there. Copy bashrc there as well
	cp "${SDCARD}"/etc/skel/.bashrc "${SDCARD}"/root

	# display welcome message at first root login @TODO: what reads this?
	touch "${SDCARD}"/root/.not_logged_in_yet

	if [[ ${DESKTOP_AUTOLOGIN} == yes ]]; then
		# set desktop autologin
		touch "${SDCARD}"/root/.desktop_autologin
	fi

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}

	# create extlinux config file @TODO: refactor into extensions u-boot, extlinux
	if [[ $SRC_EXTLINUX == yes ]]; then
		display_alert "Using extlinux, SRC_EXTLINUX: ${SRC_EXTLINUX}" "$NAME_KERNEL - $NAME_INITRD" "info"
		mkdir -p "$SDCARD"/boot/extlinux
		local bootpart_prefix
		if [[ -n $BOOTFS_TYPE ]]; then
			bootpart_prefix=/
		else
			bootpart_prefix=/boot/
		fi
		cat <<- EOF > "$SDCARD/boot/extlinux/extlinux.conf"
			label ${VENDOR}
				kernel ${bootpart_prefix}$NAME_KERNEL
				initrd ${bootpart_prefix}$NAME_INITRD
		EOF
		if [[ -n $BOOT_FDT_FILE ]]; then
			if [[ $BOOT_FDT_FILE != "none" ]]; then
				echo "  fdt ${bootpart_prefix}dtb/$BOOT_FDT_FILE" >> "$SDCARD/boot/extlinux/extlinux.conf"
			fi
		else
			echo "  fdtdir ${bootpart_prefix}dtb/" >> "$SDCARD/boot/extlinux/extlinux.conf"
		fi
	else # ... not extlinux ...

		if [[ -n "${BOOTSCRIPT}" ]]; then # @TODO: && "${BOOTCONFIG}" != "none"
			display_alert "Deploying boot script" "$bootscript_src" "info"
			if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" ]; then
				run_host_command_logged cp -pv "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			else
				run_host_command_logged cp -pv "${SRC}/config/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			fi
		fi

		if [[ -n $BOOTENV_FILE ]]; then
			if [[ -f $USERPATCHES_PATH/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			elif [[ -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "${SRC}/config/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			fi
		fi

		# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
		# instead of copying sunxi-specific template
		if [[ $ROOTFS_TYPE == nfs ]]; then
			display_alert "Copying NFS boot script template"
			if [[ -f $USERPATCHES_PATH/nfs-boot.cmd ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH"/nfs-boot.cmd "${SDCARD}"/boot/boot.cmd
			else
				run_host_command_logged cp -pv "${SRC}"/config/templates/nfs-boot.cmd.template "${SDCARD}"/boot/boot.cmd
			fi
		fi

		if [[ -n $OVERLAY_PREFIX && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "overlay_prefix=$OVERLAY_PREFIX" "debug"
			run_host_command_logged echo "overlay_prefix=$OVERLAY_PREFIX" ">>" "${SDCARD}"/boot/armbianEnv.txt
		fi

		if [[ -n $DEFAULT_OVERLAYS && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "overlays=${DEFAULT_OVERLAYS//,/ }" "debug"
			run_host_command_logged echo "overlays=${DEFAULT_OVERLAYS//,/ }" ">>" "${SDCARD}"/boot/armbianEnv.txt
		fi

		if [[ -n $BOOT_FDT_FILE && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "fdtfile=${BOOT_FDT_FILE}" "debug"
			run_host_command_logged echo "fdtfile=${BOOT_FDT_FILE}" ">>" "${SDCARD}/boot/armbianEnv.txt"
		fi

	fi

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > "${SDCARD}"/etc/fake-hwclock.data

	echo "${HOST}" > "${SDCARD}"/etc/hostname

	# set hostname in hosts file
	cat <<- EOF > "${SDCARD}"/etc/hosts
		127.0.0.1   localhost
		127.0.1.1   $HOST
		::1         localhost $HOST ip6-localhost ip6-loopback
		fe00::0     ip6-localnet
		ff00::0     ip6-mcastprefix
		ff02::1     ip6-allnodes
		ff02::2     ip6-allrouters
	EOF

	cd "${SRC}" || exit_with_error "cray-cray about ${SRC}"

	# LOGGING: we're running under the logger framework here.
	# LOGGING: so we just log directly to stdout and let it handle it.
	# LOGGING: redirect commands' stderr to stdout so it goes into the log, not screen.

	display_alert "Temporarily disabling" "initramfs-tools hook for kernel"
	chroot_sdcard chmod -v -x /etc/kernel/postinst.d/initramfs-tools

	# Only clean if not using local cache. Otherwise it would be cleaning the cache, not the chroot.
	if [[ "${USE_LOCAL_APT_DEB_CACHE}" != "yes" ]]; then
		display_alert "Cleaning" "package lists and apt cache" "warn"
		chroot_sdcard_apt_get clean
	fi

	display_alert "Updating" "apt package lists"
	do_with_retries 3 chroot_sdcard_apt_get_update

	# install image packages; AGGREGATED_PACKAGES_IMAGE is produced by aggregation.py
	# and includes the old PACKAGE_LIST_BOARD and PACKAGE_LIST_FAMILY
	if [[ ${#AGGREGATED_PACKAGES_IMAGE[@]} -gt 0 ]]; then
		display_alert "Installing AGGREGATED_PACKAGES_IMAGE packages" "${AGGREGATED_PACKAGES_IMAGE[*]}"

		# dry-run, make sure everything can be installed.
		chroot_sdcard_apt_get_install_dry_run "${AGGREGATED_PACKAGES_IMAGE[@]}"

		# retry 3 times download-only to counter apt-cacher-ng failures.
		do_with_retries 3 chroot_sdcard_apt_get_install_download_only "${AGGREGATED_PACKAGES_IMAGE[@]}"

		chroot_sdcard_apt_get_install "${AGGREGATED_PACKAGES_IMAGE[@]}"
	fi

	# remove family packages
	if [[ -n ${PACKAGE_LIST_FAMILY_REMOVE} ]]; then
		_pkg_list=${PACKAGE_LIST_FAMILY_REMOVE}
		display_alert "Removing PACKAGE_LIST_FAMILY_REMOVE packages" "${_pkg_list}"
		chroot_sdcard_apt_get_remove --auto-remove ${_pkg_list}
	fi

	# @TODO check if this still necessary or not.
	## remove board packages. loop over the list to remove, check if they're actually installed, then remove individually.
	#if [[ -n ${PACKAGE_LIST_BOARD_REMOVE} ]]; then
	#	_pkg_list=${PACKAGE_LIST_BOARD_REMOVE}
	#	declare -a currently_installed_packages
	#	# shellcheck disable=SC2207 # I wanna split, thanks.
	#	currently_installed_packages=($(chroot_sdcard_with_stdout dpkg-query --show --showformat='${Package} '))
	#	for PKG_REMOVE in ${_pkg_list}; do
	#		# shellcheck disable=SC2076 # I wanna match literally, thanks.
	#		if [[ " ${currently_installed_packages[*]} " =~ " ${PKG_REMOVE} " ]]; then
	#			display_alert "Removing PACKAGE_LIST_BOARD_REMOVE package" "${PKG_REMOVE}"
	#			chroot_sdcard_apt_get_remove --auto-remove "${PKG_REMOVE}"
	#		fi
	#	done
	#	unset currently_installed_packages
	#fi

	# install u-boot
	# @TODO: add install_bootloader() extension method, refactor into u-boot extension
	declare -g image_artifacts_packages image_artifacts_debs_reversioned
	debug_dict image_artifacts_packages
	debug_dict image_artifacts_debs_reversioned
	if [[ "${BOOTCONFIG}" != "none" ]]; then
		install_artifact_deb_chroot "uboot"
	fi

	call_extension_method "pre_install_kernel_debs" <<- 'PRE_INSTALL_KERNEL_DEBS'
		*called before installing the Armbian-built kernel deb packages*
		It is not too late to `unset KERNELSOURCE` here and avoid kernel install.
	PRE_INSTALL_KERNEL_DEBS

	# default IMAGE_INSTALLED_KERNEL_VERSION, will be parsed from Kernel version in the installed deb package.
	IMAGE_INSTALLED_KERNEL_VERSION="generic"

	# install kernel: image/dtb/headers
	if [[ -n $KERNELSOURCE ]]; then
		install_artifact_deb_chroot "linux-image"

		if [[ "${KERNEL_BUILD_DTBS:-"yes"}" == "yes" ]]; then
			install_artifact_deb_chroot "linux-dtb"
		fi

		if [[ "${KERNEL_HAS_WORKING_HEADERS:-"no"}" == "yes" ]]; then
			if [[ $INSTALL_HEADERS == yes ]]; then # @TODO remove? might be a good idea to always install headers.
				install_artifact_deb_chroot "linux-headers"
			fi
		fi

		# Determine "IMAGE_INSTALLED_KERNEL_VERSION" for compatiblity with legacy update-initramfs code. @TODO get rid of this one day
		IMAGE_INSTALLED_KERNEL_VERSION=$(dpkg --info "${DEB_STORAGE}/${image_artifacts_debs_reversioned["linux-image"]}" | grep "^ Source:" | sed -e 's/ Source: linux-//')
		display_alert "Parsed kernel version from local package" "${IMAGE_INSTALLED_KERNEL_VERSION}" "debug"

	fi

	call_extension_method "post_install_kernel_debs" <<- 'POST_INSTALL_KERNEL_DEBS'
		*allow config to do more with the installed kernel/headers*
		Called after packages, u-boot, kernel and headers installed in the chroot, but before the BSP is installed.
	POST_INSTALL_KERNEL_DEBS

	# install armbian-firmware by default. Set BOARD_FIRMWARE_INSTALL="-full" to install full firmware variant
	if [[ "${INSTALL_ARMBIAN_FIRMWARE:-yes}" == "yes" ]]; then
		if [[ ${BOARD_FIRMWARE_INSTALL:-""} == "-full" ]]; then
			install_artifact_deb_chroot "armbian-firmware-full"
		else
			install_artifact_deb_chroot "armbian-firmware"
		fi
	fi

	# install board support packages
	install_artifact_deb_chroot "armbian-bsp-cli"

	# install armbian-desktop
	if [[ $BUILD_DESKTOP == yes ]]; then
		install_artifact_deb_chroot "armbian-desktop"
		install_artifact_deb_chroot "armbian-bsp-desktop"
		# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
		desktop_postinstall
	fi

	# install armbian-config
	if [[ "${PACKAGE_LIST_RM}" != *armbian-config* ]]; then
		if [[ $BUILD_MINIMAL != yes ]]; then
			install_artifact_deb_chroot "armbian-config"
		fi
	fi

	# install armbian-zsh
	if [[ "${PACKAGE_LIST_RM}" != *armbian-zsh* ]]; then
		if [[ $BUILD_MINIMAL != yes ]]; then
			install_artifact_deb_chroot "armbian-zsh"
		fi
	fi

	# install armbian-plymouth-theme
	if [[ $PLYMOUTH == yes ]]; then
		install_artifact_deb_chroot "armbian-plymouth-theme"
	else
		chroot_sdcard_apt_get_remove --auto-remove plymouth
	fi

	# install wireguard tools
	if [[ $WIREGUARD == yes ]]; then
		install_deb_chroot "wireguard-tools" "remote" # @TODO: move this to some image pkg list in config
	fi

	# freeze armbian packages
	if [[ "${BSPFREEZE:-"no"}" == yes ]]; then
		display_alert "Freezing Armbian packages" "$BOARD" "info"
		declare -g -A image_artifacts_debs_installed # global scope, set in main_default_build_packages()
		declare -g -A image_artifacts_packages       # global scope, set in main_default_build_packages()
		declare -a package_names_to_hold=()
		declare artifact_deb_id pkg_name pkg_wanted_version
		for artifact_deb_id in "${!image_artifacts_debs_installed[@]}"; do
			declare deb_is_installed_in_image="${image_artifacts_debs_installed["${artifact_deb_id}"]}"
			if [[ "${deb_is_installed_in_image}" != "yes" ]]; then
				continue
			fi
			pkg_name="${image_artifacts_packages["${artifact_deb_id}"]}"
			package_names_to_hold+=("${pkg_name}")
		done
		chroot_sdcard apt-mark hold "${package_names_to_hold[@]}"
	fi

	# remove deb files
	run_host_command_logged rm -fv "${SDCARD}"/root/*.deb

	# copy boot splash images
	run_host_command_logged cp -v "${SRC}"/packages/blobs/splash/armbian-u-boot.bmp "${SDCARD}"/boot/boot.bmp

	# execute $LINUXFAMILY-specific tweaks
	if [[ $(type -t family_tweaks) == function ]]; then
		display_alert "Applying family" " tweaks: $BOARD :: $LINUXFAMILY"
		family_tweaks
		display_alert "Done with family_tweaks" "$BOARD :: $LINUXFAMILY" "debug"
	fi

	call_extension_method "post_family_tweaks" <<- 'FAMILY_TWEAKS'
		*customize the tweaks made by $LINUXFAMILY-specific family_tweaks*
		It is run after packages are installed in the rootfs, but before enabling additional services.
		It allows implementors access to the rootfs (`${SDCARD}`) in its pristine state after packages are installed.
	FAMILY_TWEAKS

	# enable additional services, if they exist.
	display_alert "Enabling Armbian services" "systemd" "info"
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-firstrun.service ]] && chroot_sdcard systemctl --no-reload enable armbian-firstrun.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-firstrun-config.service ]] && chroot_sdcard systemctl --no-reload enable armbian-firstrun-config.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-zram-config.service ]] && chroot_sdcard systemctl --no-reload enable armbian-zram-config.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-hardware-optimize.service ]] && chroot_sdcard systemctl --no-reload enable armbian-hardware-optimize.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-ramlog.service ]] && chroot_sdcard systemctl --no-reload enable armbian-ramlog.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-resize-filesystem.service ]] && chroot_sdcard systemctl --no-reload enable armbian-resize-filesystem.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-hardware-monitor.service ]] && chroot_sdcard systemctl --no-reload enable armbian-hardware-monitor.service
	[[ -f "${SDCARD}"/lib/systemd/system/armbian-led-state.service ]] && chroot_sdcard systemctl --no-reload enable armbian-led-state.service

	# copy "first run automated config, optional user configured"
	run_host_command_logged cp -v "${SRC}"/packages/bsp/armbian_first_run.txt.template "${SDCARD}"/boot/armbian_first_run.txt.template

	# switch to beta repository at this stage if building nightly images
	if [[ $IMAGE_TYPE == nightly && -f "${SDCARD}"/etc/apt/sources.list.d/armbian.list ]]; then
		sed -i 's/apt/beta/' "${SDCARD}"/etc/apt/sources.list.d/armbian.list
	fi

	# fix for https://bugs.launchpad.net/ubuntu/+source/blueman/+bug/1542723 @TODO: from ubuntu 15. maybe gone?
	chroot_sdcard chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper
	chroot_sdcard chmod u+s /usr/lib/dbus-1.0/dbus-daemon-launch-helper

	# disable samba NetBIOS over IP name service requests since it hangs when no network is present at boot
	# @TODO: rpardini: still needed? people might want working Samba
	disable_systemd_service_sdcard nmbd

	# disable low-level kernel messages for non betas
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" "${SDCARD}"/etc/sysctl.conf
	fi

	# disable repeated messages due to xconsole not being installed.
	[[ -f "${SDCARD}"/etc/rsyslog.d/50-default.conf ]] &&
		sed '/daemon\.\*\;mail.*/,/xconsole/ s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.d/50-default.conf

	# disable deprecated parameter
	[[ -f "${SDCARD}"/etc/rsyslog.conf ]] &&
		sed '/.*$KLogPermitNonKernelFacility.*/,// s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.conf

	# enable getty on multiple serial consoles
	# and adjust the speed if it is defined and different than 115200
	#
	# example: SERIALCON="ttyS0:15000000,ttyGS1"
	#
	ifs=$IFS
	for i in $(echo "${SERIALCON:-'ttyS0'}" | sed "s/,/ /g"); do
		IFS=':' read -r -a array <<< "$i"
		[[ "${array[0]}" == "tty1" ]] && continue # Don't enable tty1 as serial console.
		display_alert "Enabling serial console" "${array[0]}" "info"
		# add serial console to secure tty list
		[ -z "$(grep -w '^${array[0]}' "${SDCARD}"/etc/securetty 2> /dev/null)" ] &&
			echo "${array[0]}" >> "${SDCARD}"/etc/securetty
		if [[ ${array[1]} != "115200" && -n ${array[1]} ]]; then
			# make a copy, fix speed and enable
			cp "${SDCARD}"/lib/systemd/system/serial-getty@.service \
				"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
			sed -i "s/--keep-baud 115200/--keep-baud ${array[1]},115200/" \
				"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
		fi
		chroot_sdcard systemctl daemon-reload
		chroot_sdcard systemctl --no-reload enable "serial-getty@${array[0]}.service"
		if [[ "${array[0]}" == "ttyGS0" && $LINUXFAMILY == sun8i && $BRANCH == default ]]; then
			mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d
			cat <<- EOF > "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d/10-switch-role.conf
				[Service]
				ExecStartPre=-/bin/sh -c "echo 2 > /sys/bus/platform/devices/sunxi_usb_udc/otg_role"
			EOF
		fi
	done
	IFS=$ifs

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p "${SDCARD}"/boot/overlay-user

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch "${SDCARD}"/var/swap

	# install initial asound.state if defined
	mkdir -p "${SDCARD}"/var/lib/alsa/
	if [[ -n ${ASOUND_STATE} ]]; then
		display_alert "Installing initial asound.state" "${ASOUND_STATE} for board ${BOARD}" "info"
		run_host_command_logged cp -v "${SRC}/packages/blobs/asound.state/${ASOUND_STATE}" "${SDCARD}"/var/lib/alsa/asound.state
	fi

	# save initial armbian-release state
	cp "${SDCARD}"/etc/armbian-release "${SDCARD}"/etc/armbian-image-release

	# DNS fix. package resolvconf is not available everywhere
	if [ -d "${SDCARD}"/etc/resolvconf/resolv.conf.d ] && [ -n "$NAMESERVER" ]; then
		echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolvconf/resolv.conf.d/head
	fi

	# permit root login via SSH for the first boot
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' "${SDCARD}"/etc/ssh/sshd_config

	# enable PubkeyAuthentication
	sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "${SDCARD}"/etc/ssh/sshd_config

	if [[ -f "${SDCARD}"/etc/NetworkManager/NetworkManager.conf ]]; then
		# configure network manager
		sed "s/managed=\(.*\)/managed=true/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

		## remove network manager defaults to handle eth by default @TODO: why?
		rm -f "${SDCARD}"/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

		# `systemd-networkd.service` will be enabled by `/lib/systemd/system-preset/90-systemd.preset` during first-run.
		# Mask it to avoid conflict
		chroot_sdcard systemctl mask systemd-networkd.service

		# most likely we don't need to wait for nm to get online
		chroot_sdcard systemctl disable NetworkManager-wait-online.service

		# Just regular DNS and maintain /etc/resolv.conf as a file @TODO: this does not apply as of impish at least
		sed "/dns/d" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
		sed "s/\[main\]/\[main\]\ndns=default\nrc-manager=file/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

		if [[ -n $NM_IGNORE_DEVICES ]]; then
			mkdir -p "${SDCARD}"/etc/NetworkManager/conf.d/
			cat <<- EOF > "${SDCARD}"/etc/NetworkManager/conf.d/10-ignore-interfaces.conf
				[keyfile]
				unmanaged-devices=$NM_IGNORE_DEVICES
			EOF
		fi

	elif [ -d "${SDCARD}"/etc/systemd/network ]; then
		# enable services
		chroot_sdcard systemctl enable systemd-networkd.service
		chroot_sdcard systemctl enable systemd-resolved.service || display_alert "Failed to enable systemd-resolved.service" "" "wrn"

		# Mask `NetworkManager.service` to avoid conflict
		chroot_sdcard systemctl mask NetworkManager.service

		if [ -e "${SDCARD}"/etc/systemd/timesyncd.conf ]; then
			chroot_sdcard systemctl enable systemd-timesyncd.service
		fi

		umask 022
		cat > "${SDCARD}"/etc/systemd/network/eth0.network <<- __EOF__
			[Match]
			Name=eth0

			[Network]
			#MACAddress=
			DHCP=ipv4
			LinkLocalAddressing=ipv4
			#Address=192.168.1.100/24
			#Gateway=192.168.1.1
			#DNS=192.168.1.1
			#Domains=example.com
			NTP=0.pool.ntp.org 1.pool.ntp.org
		__EOF__

	fi

	# avahi daemon defaults if exists
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service ]] &&
		cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service "${SDCARD}"/etc/avahi/services/
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service ]] &&
		cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service "${SDCARD}"/etc/avahi/services/

	# nsswitch settings for sane DNS behavior: remove resolve, assure libnss-myhostname support
	sed "s/hosts\:.*/hosts:          files mymachines dns myhostname/g" -i "${SDCARD}"/etc/nsswitch.conf

	# build logo in any case
	boot_logo

	# Show logo
	if [[ $PLYMOUTH == yes ]]; then
		if [[ $BOOT_LOGO == yes || $BOOT_LOGO == desktop && $BUILD_DESKTOP == yes ]]; then
			[[ -f "${SDCARD}"/boot/armbianEnv.txt ]] && grep -q '^bootlogo' "${SDCARD}"/boot/armbianEnv.txt &&
				sed -i 's/^bootlogo.*/bootlogo=true/' "${SDCARD}"/boot/armbianEnv.txt ||
				echo 'bootlogo=true' >> "${SDCARD}"/boot/armbianEnv.txt

			[[ -f "${SDCARD}"/boot/boot.ini ]] &&
				sed -i 's/^setenv bootlogo.*/setenv bootlogo "true"/' "${SDCARD}"/boot/boot.ini
		fi
	fi

	# disable MOTD for first boot - we want as clean 1st run as possible
	chmod -x "${SDCARD}"/etc/update-motd.d/*

	return 0 # make sure to exit with success
}

install_rclocal() {
	cat <<- EOF > "${SDCARD}"/etc/rc.local
		#!/bin/sh -e
		#
		# rc.local
		#
		# This script is executed at the end of each multiuser runlevel.
		# Make sure that the script will "exit 0" on success or any other
		# value on error.
		#
		# In order to enable or disable this script just change the execution
		# bits.
		#
		# By default this script does nothing.

		exit 0
	EOF
	chmod +x "${SDCARD}"/etc/rc.local
}
