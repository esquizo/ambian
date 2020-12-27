# install default desktop settings
#mkdir -p "${destination}"/etc/skel
#cp -R "${SRC}"/config/desktop/focal/evviroments.deepin/skel/. "${destination}"/etc/skel

# install logo for login screen
mkdir -p "${destination}"/usr/share/pixmaps/armbian
cp "${SRC}"/config/desktop/desktop-extras/icons/armbian.png "${destination}"/usr/share/pixmaps/armbian

# install wallpapers
mkdir -p "${destination}"/usr/share/backgrounds/armbian/
cp "${SRC}"/config/desktop/desktop-extras/wallpapers/armbian*.jpg "${destination}"/usr/share/backgrounds/armbian/
mkdir -p "${destination}"/usr/share/gnome-background-properties
cat <<-EOF > "${destination}"/usr/share/gnome-background-properties/armbian.xml
<?xml version="1.0"?>
<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">
<wallpapers>
  <wallpaper deleted="false">
    <name>Armbian light</name>
    <filename>/usr/share/backgrounds/armbian/armbian18-Dre0x-Minum-light-3840x2160.jpg</filename>
    <options>zoom</options>
    <pcolor>#ffffff</pcolor>
    <scolor>#000000</scolor>
  </wallpaper>
  <wallpaper deleted="false">
    <name>Armbian dark</name>
    <filename>/usr/share/backgrounds/armbian/armbian03-Dre0x-Minum-dark-3840x2160.jpg</filename>
    <options>zoom</options>
    <pcolor>#ffffff</pcolor>
    <scolor>#000000</scolor>
  </wallpaper>
</wallpapers>
EOF
