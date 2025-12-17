#!/usr/bin/env python3
"""
Dependency checker for Rookery OS .rook files.
Fetches dependency information from Arch Linux packages and compares
with dependencies declared in .rook spec files.
"""

import json
import re
import sys
import tomllib
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional
from dataclasses import dataclass, field


@dataclass
class ArchPackageInfo:
    """Arch Linux package information."""
    name: str
    version: str
    depends: list[str] = field(default_factory=list)
    makedepends: list[str] = field(default_factory=list)
    optdepends: list[str] = field(default_factory=list)
    provides: list[str] = field(default_factory=list)


@dataclass
class RookPackageInfo:
    """Rookery .rook package information."""
    name: str
    version: str
    depends: dict[str, str] = field(default_factory=dict)
    build_depends: dict[str, str] = field(default_factory=dict)
    optional_depends: dict[str, str] = field(default_factory=dict)


# Mapping from Arch package names to Rookery package names
ARCH_TO_ROOKERY = {
    # Qt6 - all Qt6 modules map to qt6
    "qt6-base": "qt6",
    "qt6-declarative": "qt6",
    "qt6-wayland": "qt6",
    "qt6-svg": "qt6",
    "qt6-tools": "qt6",
    "qt6-multimedia": "qt6",
    "qt6-networkauth": "qt6",
    "qt6-websockets": "qt6",
    "qt6-webengine": "qtwebengine",
    "qt6-webchannel": "qt6",
    "qt6-positioning": "qt6",
    "qt6-sensors": "qt6",
    "qt6-serialport": "qt6",
    "qt6-connectivity": "qt6",
    "qt6-imageformats": "qt6",
    "qt6-5compat": "qt6",
    "qt6-shadertools": "qt6",
    "qt6-quick3d": "qt6",
    "qt6-speech": "qt6",

    # KF5 (legacy) - ignore or map to kf6
    "frameworkintegration5": None,
    "kconfigwidgets5": None,
    "kiconthemes5": None,
    "kirigami2": None,
    "kwindowsystem5": None,
    "breeze5": None,

    # KF6 frameworks
    "karchive": "kf6-karchive",
    "kauth": "kf6-kauth",
    "kbookmarks": "kf6-kbookmarks",
    "kcalendarcore": "kf6-kcalendarcore",
    "kcmutils": "kf6-kcmutils",
    "kcodecs": "kf6-kcodecs",
    "kcolorscheme": "kf6-kcolorscheme",
    "kcompletion": "kf6-kcompletion",
    "kconfig": "kf6-kconfig",
    "kconfigwidgets": "kf6-kconfigwidgets",
    "kcontacts": "kf6-kcontacts",
    "kcoreaddons": "kf6-kcoreaddons",
    "kcrash": "kf6-kcrash",
    "kdav": "kf6-kdav",
    "kdbusaddons": "kf6-kdbusaddons",
    "kdeclarative": "kf6-kdeclarative",
    "kded": "kf6-kded",
    "kdesu": "kf6-kdesu",
    "kdnssd": "kf6-kdnssd",
    "kdoctools": None,  # Doc tools, build-only
    "kfilemetadata": "kf6-kfilemetadata",
    "kglobalaccel": "kf6-kglobalaccel",
    "kguiaddons": "kf6-kguiaddons",
    "kholidays": "kf6-kholidays",
    "ki18n": "kf6-ki18n",
    "kiconthemes": "kf6-kiconthemes",
    "kidletime": "kf6-kidletime",
    "kimageformats": "kf6-kimageformats",
    "kio": "kf6-kio",
    "kirigami": "kf6-kirigami",
    "kitemmodels": "kf6-kitemmodels",
    "kitemviews": "kf6-kitemviews",
    "kjobwidgets": "kf6-kjobwidgets",
    "knewstuff": "kf6-knewstuff",
    "knotifications": "kf6-knotifications",
    "knotifyconfig": "kf6-knotifyconfig",
    "kpackage": "kf6-kpackage",
    "kparts": "kf6-kparts",
    "kpeople": "kf6-kpeople",
    "kplotting": "kf6-kplotting",
    "kpty": "kf6-kpty",
    "kquickcharts": "kf6-kquickcharts",
    "krunner": "kf6-krunner",
    "kservice": "kf6-kservice",
    "kstatusnotifieritem": "kf6-kstatusnotifieritem",
    "ksvg": "kf6-ksvg",
    "ktexteditor": "kf6-ktexteditor",
    "ktexttemplate": "kf6-ktexttemplate",
    "ktextwidgets": "kf6-ktextwidgets",
    "kunitconversion": "kf6-kunitconversion",
    "kuserfeedback": "kf6-kuserfeedback",
    "kwallet": "kf6-kwallet",
    "kwidgetsaddons": "kf6-kwidgetsaddons",
    "kwindowsystem": "kf6-kwindowsystem",
    "kxmlgui": "kf6-kxmlgui",
    "solid": "kf6-solid",
    "sonnet": "kf6-sonnet",
    "syndication": "kf6-syndication",
    "syntax-highlighting": "kf6-syntax-highlighting",
    "threadweaver": "kf6-threadweaver",
    "attica": "kf6-attica",
    "baloo": "kf6-baloo",
    "bluez-qt": "kf6-bluez-qt",
    "frameworkintegration": "kf6-frameworkintegration",
    "modemmanager-qt": "kf6-modemmanager-qt",
    "networkmanager-qt": "kf6-networkmanager-qt",
    "prison": "kf6-prison",
    "purpose": "kf6-purpose",
    "qqc2-desktop-style": "kf6-qqc2-desktop-style",
    "kf6-karchive": "kf6-karchive",
    "kf6-kauth": "kf6-kauth",
    "kf6-kdoctools": None,  # Doc tools, build-only
    "kf6-kcmutils": "kf6-kcmutils",
    "kf6-kconfig": "kf6-kconfig",
    "kf6-kcoreaddons": "kf6-kcoreaddons",
    "kf6-kcrash": "kf6-kcrash",
    "kf6-kdbusaddons": "kf6-kdbusaddons",
    "kf6-kdeclarative": "kf6-kdeclarative",
    "kf6-kglobalaccel": "kf6-kglobalaccel",
    "kf6-kguiaddons": "kf6-kguiaddons",
    "kf6-ki18n": "kf6-ki18n",
    "kf6-kiconthemes": "kf6-kiconthemes",
    "kf6-kidletime": "kf6-kidletime",
    "kf6-kio": "kf6-kio",
    "kf6-kirigami": "kf6-kirigami",
    "kf6-kitemmodels": "kf6-kitemmodels",
    "kf6-kjobwidgets": "kf6-kjobwidgets",
    "kf6-knewstuff": "kf6-knewstuff",
    "kf6-knotifications": "kf6-knotifications",
    "kf6-kpackage": "kf6-kpackage",
    "kf6-kparts": "kf6-kparts",
    "kf6-krunner": "kf6-krunner",
    "kf6-kservice": "kf6-kservice",
    "kf6-ksvg": "kf6-ksvg",
    "kf6-kwidgetsaddons": "kf6-kwidgetsaddons",
    "kf6-kwindowsystem": "kf6-kwindowsystem",
    "kf6-kxmlgui": "kf6-kxmlgui",
    "kf6-solid": "kf6-solid",
    "kf6-frameworkintegration": "kf6-frameworkintegration",
    "kf6-kcolorscheme": "kf6-kcolorscheme",
    "kf6-kquickcharts": "kf6-kquickcharts",

    # Core system libs
    "glibc": "glibc",
    "gcc-libs": "gcc",
    "gcc": "gcc",
    "glib2": "glib2",
    "gtk3": "gtk3",
    "gtk4": "gtk4",
    "systemd": "systemd",
    "systemd-libs": "systemd",
    "util-linux-libs": "util-linux",
    "linux-api-headers": "linux",

    # X11/Wayland/Graphics
    "libx11": "libx11",
    "libxcb": "libxcb",
    "libxext": "libxext",
    "libxrender": "libxrender",
    "libxi": "libxi",
    "libxtst": "libxtst",
    "libxkbcommon": "libxkbcommon",
    "libxkbcommon-x11": "libxkbcommon",
    "libxkbfile": "libxkbfile",
    "libxcursor": "libxcursor",
    "libxfixes": "libxfixes",
    "libxdamage": "libxdamage",
    "libxrandr": "libxrandr",
    "libxinerama": "libxinerama",
    "libxxf86vm": "libxxf86vm",
    "libxshmfence": "libxshmfence",
    "libxcomposite": "libxcomposite",
    "wayland": "wayland",
    "wayland-protocols": "wayland-protocols",
    "mesa": "mesa",
    "libdrm": "libdrm",
    "libglvnd": "libglvnd",
    "vulkan-icd-loader": "vulkan-loader",
    "vulkan-headers": "vulkan-headers",
    "libepoxy": "libepoxy",
    "libva": "libva",
    "libvdpau": "libvdpau",

    # Compression
    "zlib": "zlib",
    "xz": "xz",
    "bzip2": "bzip2",
    "zstd": "zstd",
    "lz4": "lz4",
    "brotli": "brotli",
    "lzo": "lzo",
    "snappy": "snappy",

    # Networking
    "curl": "curl",
    "openssl": "openssl",
    "gnutls": "gnutls",
    "libssh": "libssh",
    "libssh2": "libssh2",
    "nghttp2": "nghttp2",
    "libnghttp2": "nghttp2",
    "libnghttp3": "nghttp3",
    "libidn2": "libidn2",
    "libpsl": "libpsl",
    "c-ares": "c-ares",
    "krb5": "krb5",

    # Image/Graphics libs
    "libpng": "libpng",
    "libjpeg-turbo": "libjpeg-turbo",
    "libtiff": "libtiff",
    "libwebp": "libwebp",
    "giflib": "giflib",
    "openjpeg2": "openjpeg",
    "libraw": "libraw",
    "libheif": "libheif",
    "libavif": "libavif",
    "libjxl": "libjxl",
    "librsvg": "librsvg",
    "gdk-pixbuf2": "gdk-pixbuf2",
    "graphite": "graphite",

    # Fonts/Text
    "freetype2": "freetype",
    "fontconfig": "fontconfig",
    "harfbuzz": "harfbuzz",
    "harfbuzz-icu": "harfbuzz",
    "pango": "pango",
    "cairo": "cairo",
    "pixman": "pixman",
    "fribidi": "fribidi",

    # Audio/Video
    "pipewire": "pipewire",
    "pipewire-audio": "pipewire",
    "pipewire-session-manager": "wireplumber",
    "libpipewire": "pipewire",
    "wireplumber": "wireplumber",
    "pulseaudio": "pulseaudio",
    "libpulse": "pulseaudio",
    "alsa-lib": "alsa-lib",
    "ffmpeg": "ffmpeg",
    "libavcodec.so": None,
    "libavformat.so": None,
    "libavutil.so": None,
    "libswscale.so": None,
    "libswresample.so": None,
    "gstreamer": "gstreamer",
    "gst-plugins-base": "gst-plugins-base",
    "gst-plugins-good": "gst-plugins-good",
    "sndio": "sndio",
    "jack": "jack2",
    "jack2": "jack2",
    "opus": "opus",
    "libvorbis": "libvorbis",
    "flac": "flac",
    "lame": "lame",
    "libsamplerate": "libsamplerate",
    "speexdsp": "speexdsp",
    "libcanberra": "libcanberra",

    # Database
    "sqlite": "sqlite",
    "sqlite3": "sqlite",
    "lmdb": "lmdb",
    "leveldb": "leveldb",

    # Crypto/Security
    "libgcrypt": "libgcrypt",
    "libgpg-error": "libgpg-error",
    "gnupg": "gnupg",
    "gpgme": "gpgme",
    "libsecret": "libsecret",
    "libcap": "libcap",
    "libcap-ng": "libcap-ng",
    "audit": "audit",
    "pam": "linux-pam",
    "linux-pam": "linux-pam",
    "polkit": "polkit",
    "libxcrypt": "libxcrypt",

    # D-Bus/IPC
    "dbus": "dbus",
    "at-spi2-core": "at-spi2-core",
    "at-spi2-atk": "at-spi2-core",

    # Text/XML
    "libxml2": "libxml2",
    "libxslt": "libxslt",
    "expat": "expat",
    "icu": "icu",
    "pcre": "pcre",
    "pcre2": "pcre2",
    "oniguruma": "oniguruma",
    "json-c": "json-c",
    "json-glib": "json-glib",
    "jansson": "jansson",
    "jsoncpp": "jsoncpp",
    "yaml-cpp": "yaml-cpp",
    "libyaml": "libyaml",

    # Misc libs
    "libffi": "libffi",
    "libevent": "libevent",
    "libuv": "libuv",
    "libev": "libev",
    "boost": "boost",
    "boost-libs": "boost",
    "ell": "ell",
    "libelf": None,  # Debug lib, usually optional
    "elfutils": None,  # Debug lib, usually optional
    "libdwarf": "libdwarf",
    "libunwind": "libunwind",
    "orc": "orc",
    "fftw": "fftw",
    "gsl": "gsl",
    "openblas": "openblas",
    "lapack": "lapack",
    "hdf5": "hdf5",
    "netcdf": "netcdf",

    # Input
    "libinput": "libinput",
    "libevdev": "libevdev",
    "mtdev": "mtdev",
    "libwacom": "libwacom",
    "xf86-input-libinput": "xf86-input-libinput",

    # Bluetooth
    "bluez": "bluez",
    "bluez-libs": "bluez",

    # Printing
    "cups": "cups",
    "libcups": "cups",
    "cups-filters": "cups-filters",

    # Scanning
    "sane": "sane-backends",

    # Spell checking
    "aspell": "aspell",
    "hunspell": "hunspell",
    "enchant": "enchant",

    # Build tools
    "python": "python",
    "python3": "python",
    "perl": "perl",
    "ruby": "ruby",
    "cmake": "cmake",
    "ninja": "ninja",
    "meson": "meson",
    "make": "make",
    "autoconf": "autoconf",
    "automake": "automake",
    "libtool": "libtool",
    "m4": "m4",
    "bison": "bison",
    "flex": "flex",
    "extra-cmake-modules": "extra-cmake-modules",
    "pkgconf": "pkgconf",
    "pkg-config": "pkgconf",
    "gettext": "gettext",
    "intltool": "intltool",
    "gobject-introspection": "gobject-introspection",
    "vala": "vala",
    "swig": "swig",
    "doxygen": "doxygen",

    # Terminal
    "ncurses": "ncurses",
    "readline": "readline",

    # Shell utilities
    "coreutils": "coreutils",
    "findutils": "findutils",
    "diffutils": "diffutils",
    "patch": "patch",
    "gzip": "gzip",
    "tar": "tar",
    "gawk": "gawk",
    "sed": "sed",
    "grep": "grep",
    "file": "file",
    "which": "which",
    "less": "less",

    # Version control
    "git": "git",
    "subversion": "subversion",
    "mercurial": "mercurial",

    # Network tools
    "iproute2": "iproute2",
    "iputils": "iputils",
    "net-tools": "net-tools",
    "openssh": "openssh",
    "wget": "wget",
    "rsync": "rsync",

    # Hardware info
    "pciutils": "pciutils",
    "usbutils": "usbutils",
    "hwdata": "hwdata",
    "dmidecode": "dmidecode",
    "lm_sensors": "lm_sensors",
    "smartmontools": "smartmontools",

    # Desktop
    "xdg-desktop-portal": "xdg-desktop-portal",
    "xdg-utils": "xdg-utils",
    "desktop-file-utils": "desktop-file-utils",
    "shared-mime-info": "shared-mime-info",
    "hicolor-icon-theme": "hicolor-icon-theme",
    "adwaita-icon-theme": "adwaita-icon-theme",
    "gsettings-desktop-schemas": "gsettings-desktop-schemas",

    # OpenCV
    "opencv": "opencv",

    # Sensors
    "iio-sensor-proxy": "iio-sensor-proxy",

    # Mobile
    "libimobiledevice": "libimobiledevice",
    "usbmuxd": "usbmuxd",

    # Plasma/KDE packages
    "plasma-workspace": "plasma-workspace",
    "plasma-desktop": "plasma-desktop",
    "plasma-framework": "libplasma",
    "libplasma": "libplasma",
    "kwayland": "kwayland",
    "kwayland-integration": "kwayland",
    "layer-shell-qt": "layer-shell-qt",
    "libkscreen": "libkscreen",
    "libksysguard": "libksysguard",
    "kdecoration": "kdecoration",
    "plasma5support": "plasma5support",
    "kpipewire": "kpipewire",
    "kactivitymanagerd": "kactivitymanagerd",
    "kglobalacceld": "kglobalacceld",
    "kscreenlocker": "kscreenlocker",
    "kwin": "kwin",
    "breeze": "breeze",
    "breeze-icons": "breeze-icons",
    "breeze-gtk": "breeze-gtk",
    "oxygen": "oxygen",
    "oxygen-icons": "oxygen-icons",
    "sddm": "sddm",
    "sddm-kcm": "sddm-kcm",
    "systemsettings": "systemsettings",
    "kinfocenter": "kinfocenter",
    "plasma-nm": "plasma-nm",
    "plasma-pa": "plasma-pa",
    "bluedevil": "bluedevil",
    "powerdevil": "powerdevil",
    "kscreen": "kscreen",
    "drkonqi": "drkonqi",
    "milou": "milou",
    "xdg-desktop-portal-kde": "xdg-desktop-portal-kde",
    "polkit-kde-agent": "polkit-kde-agent",
    "kde-cli-tools": "kde-cli-tools",
    "kde-gtk-config": "kde-gtk-config",
    "kmenuedit": "kmenuedit",
    "ksystemstats": "ksystemstats",
    "plasma-integration": "plasma-integration",
    "qqc2-breeze-style": "qqc2-breeze-style",
    "kwallet-pam": "kwallet-pam",
    "ksshaskpass": "ksshaskpass",
    "kwrited": "kwrited",
    "kgamma": "kgamma",
    "plasma-workspace-wallpapers": "plasma-workspace-wallpapers",
    "kdeplasma-addons": "kdeplasma-addons",
    "spectacle": "spectacle",
    "print-manager": "print-manager",
    "plasma-systemmonitor": "plasma-systemmonitor",
    "plasma-disks": "plasma-disks",
    "plasma-firewall": "plasma-firewall",
    "plasma-vault": "plasma-vault",
    "plasma-thunderbolt": "plasma-thunderbolt",
    "plasma-welcome": "plasma-welcome",
    "wacomtablet": "wacomtablet",
    "discover": "discover",
    "ocean-sound-theme": "ocean-sound-theme",
    "oxygen-sounds": "oxygen-sounds",
    "flatpak-kcm": "flatpak-kcm",

    # Additional libs
    "lcms2": "lcms2",
    "libexif": "libexif",
    "exiv2": "exiv2",
    "poppler": "poppler",
    "poppler-qt6": "poppler",
    "djvulibre": "djvulibre",
    "libspectre": "libspectre",
    "ebook-tools": "ebook-tools",
    "chmlib": "chmlib",
    "discount": "discount",

    # Accessibility
    "speech-dispatcher": "speech-dispatcher",
    "espeak-ng": "espeak-ng",
    "festival": "festival",

    # Power management
    "upower": "upower",
    "acpid": "acpid",
    "tlp": "tlp",

    # Display management
    "ddcutil": "ddcutil",
    "colord": "colord",

    # Misc utilities
    "accountsservice": "accountsservice",
    "packagekit": "packagekit",
    "packagekit-qt6": "packagekit",
    "appstream": "appstream",
    "appstream-qt": "appstream",
    "flatpak": "flatpak",
    "fwupd": "fwupd",
    "bolt": "bolt",
    "udisks2": "udisks2",
    "media-player-info": "media-player-info",

    # Archive formats
    "libarchive": "libarchive",
    "p7zip": "p7zip",
    "unrar": "unrar",
    "unzip": "unzip",
    "zip": "zip",

    # KDE applications deps
    "libkdegames": "libkdegames",
    "libkmahjongg": "libkmahjongg",
    "libkdcraw": "libkdcraw",
    "libkexiv2": "libkexiv2",
    "libksane": "libksane",
    "kimageannotator": "kimageannotator",
    "kcolorpicker": "kcolorpicker",

    # Phonon
    "phonon-qt6": "phonon",
    "phonon-qt6-vlc": "phonon-vlc",
    "phonon-qt6-gstreamer": "phonon-gstreamer",

    # VLC
    "vlc": "vlc",
    "libvlc": "vlc",

    # Extra X11
    "libxaw": "libxaw",
    "libxmu": "libxmu",
    "libxt": "libxt",
    "libxpm": "libxpm",
    "libxss": "libxscrnsaver",
    "libxscrnsaver": "libxscrnsaver",
    "libxft": "libxft",
    "libxv": "libxv",
    "libxvmc": "libxvmc",
    "libxxf86dga": "libxxf86dga",
    "xcb-util": "xcb-util",
    "xcb-util-wm": "xcb-util-wm",
    "xcb-util-image": "xcb-util-image",
    "xcb-util-keysyms": "xcb-util-keysyms",
    "xcb-util-renderutil": "xcb-util-renderutil",
    "xcb-util-cursor": "xcb-util-cursor",

    # Extra Wayland
    "wlroots": "wlroots",
    "xdg-desktop-portal-wlr": "xdg-desktop-portal-wlr",

    # Samba
    "samba": "samba",
    "libwbclient": "samba",
    "smbclient": "samba",

    # Additional network
    "libnm": "networkmanager",
    "libmm-glib": "modemmanager",

    # GStreamer plugins
    "gst-plugins-base-libs": "gst-plugins-base",
    "gst-plugins-bad": "gst-plugins-bad",
    "gst-plugins-ugly": "gst-plugins-ugly",
    "gst-plugin-pipewire": "pipewire",
    "gst-libav": "gst-libav",

    # More specialized libs
    "mpg123": "mpg123",
    "openexr": "openexr",
    "imath": "imath",
    "nettle": "nettle",
    "orc": "orc",
    "libusb": "libusb",
    "libnl": "libnl",
    "libpcap": "libpcap",
    "libnftnl": "libnftnl",
    "nftables": "nftables",
    "iptables": "iptables",

    # More Wayland
    "wayland-utils": "wayland",
    "weston": "weston",

    # ALSA
    "alsa-utils": "alsa-utils",
    "alsa-plugins": "alsa-plugins",
    "alsa-oss": "alsa-oss",

    # libglib name variations (without .so)
    "libglib-2.0": "glib2",
    "libgio-2.0": "glib2",
    "libgobject-2.0": "glib2",
    "libgmodule-2.0": "glib2",
    "libgthread-2.0": "glib2",
}

# Packages to ignore (virtual packages, groups, build-only, etc.)
IGNORE_PACKAGES = {
    # Virtual packages and meta-packages
    "base",
    "base-devel",
    "filesystem",
    "sh",
    "pacman",

    # Core shell utilities (always present on any Linux system)
    "bash",
    "coreutils",
    "grep",
    "sed",
    "gawk",
    "findutils",
    "util-linux",
    "which",
    "less",
    "file",
    "tar",
    "gzip",

    # Build-only tools (not runtime deps)
    "git",
    "subversion",
    "mercurial",
    "wget",
    "rsync",

    # Documentation generators (build-only)
    "doxygen",
    "sphinx",
    "asciidoc",
    "xmlto",
    "docbook-xsl",
    "docbook-xml",
    "gtk-doc",
    "help2man",
    "texinfo",

    # Testing tools (build-only)
    "check",
    "cppunit",
    "gtest",
    "python-pytest",
    "python-mock",
    "python-nose",
    "valgrind",

    # Desktop integration (typically implicit)
    "hicolor-icon-theme",
    "xdg-utils",
    "desktop-file-utils",
    "shared-mime-info",

    # X.org utilities and virtual packages
    "xorg-server",
    "xorg-xwayland",
    "xorg-setxkbmap",
    "xorg-xrdb",
    "xorg-xinit",
    "xorg-xprop",
    "xorg-xset",
    "xorg-xrandr",

    # Firmware and microcode (hardware specific)
    "linux-firmware",
    "amd-ucode",
    "intel-ucode",

    # Font packages (typically optional/runtime choice)
    "ttf-dejavu",
    "ttf-liberation",
    "ttf-freefont",
    "noto-fonts",
    "noto-fonts-emoji",
    "cantarell-fonts",

    # Python optional/test dependencies
    "python-pip",
    "python-setuptools",
    "python-wheel",
    "python-build",
    "python-installer",
    "python-hatchling",
    "python-flit-core",
    "python-poetry-core",
    "cython",

    # Perl build tools
    "perl-extutils-makemaker",
    "perl-test-simple",
    "perl-test-harness",

    # Ruby build tools
    "ruby-bundler",
    "ruby-rake",

    # Locale data (implicitly available)
    "glibc-locales",
    "ca-certificates",
    "tzdata",

    # Network services (optional runtime)
    "avahi",
    "networkmanager",
    "modemmanager",
    "wpa_supplicant",

    # Systemd components (part of systemd)
    "systemd-sysvcompat",
    "systemd-resolvconf",
    "systemd-ukify",

    # X.org protocol headers (build-only)
    "xorgproto",
    "xcb-proto",
    "xproto",
    "kbproto",
    "inputproto",
    "randrproto",
    "renderproto",
    "xextproto",
    "fixesproto",
    "damageproto",
    "compositeproto",

    # GObject introspection (build tool)
    "gobject-introspection",

    # Optional Python bindings
    "pyside6",
    "pyside2",
    "pyqt6",
    "pyqt5",
    "sip",

    # Qt5 legacy packages (ignore, use qt6)
    "qt5-base",
    "qt5-declarative",
    "qt5-wayland",
    "qt5-svg",
    "qt5-tools",
    "qt5-multimedia",
    "qt5-x11extras",
    "qt5-xmlpatterns",
    "qt5-graphicaleffects",
    "qt5-quickcontrols2",

    # WebRTC (specialized, optional)
    "webrtc-audio-processing",
    "webrtc-audio-processing-1",

    # LLVM/Clang (usually just for building)
    "llvm",
    "llvm-libs",
    "clang",
    "lld",

    # More build tools
    "meson",
    "ninja",
    "cmake",
    "rust",
    "cargo",
    "go",

    # Misc optional/specialized
    "qrencode",
    "libdvdread",
    "libdvdnav",
    "libdvdcss",
    "libass",
    "libcdio",
    "libcdio-paranoia",
    "libbluray",
    "libsndfile",
    "mpg123",
    "openjpeg",
    "openexr",
    "imath",
    "libraw",
    "libheif",
    "libavif",
    "libjxl",

    # Jack2 is optional for audio apps
    "jack2",
    "jack",

    # These are typically transitive or implicit
    "orc",
    "libusb",
    "libnl",
    "elfutils",

    # Specific test/example programs
    "kf6-kdoctools",  # Only needed if docs are built
}


def fetch_arch_package_info(package_name: str) -> Optional[ArchPackageInfo]:
    """Fetch package info from Arch Linux API."""
    # Try official repos first
    for repo in ["extra", "core", "multilib"]:
        url = f"https://archlinux.org/packages/{repo}/x86_64/{package_name}/json/"
        try:
            with urllib.request.urlopen(url, timeout=10) as response:
                data = json.loads(response.read().decode())
                return ArchPackageInfo(
                    name=data.get("pkgname", package_name),
                    version=data.get("pkgver", ""),
                    depends=data.get("depends", []),
                    makedepends=data.get("makedepends", []),
                    optdepends=[opt.split(":")[0].strip() for opt in data.get("optdepends", [])],
                    provides=data.get("provides", []),
                )
        except urllib.error.HTTPError:
            continue
        except Exception as e:
            print(f"  Warning: Error fetching {package_name} from {repo}: {e}", file=sys.stderr)
            continue

    # Try AUR as fallback for KDE packages
    try:
        url = f"https://aur.archlinux.org/rpc/?v=5&type=info&arg={package_name}"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode())
            if data.get("resultcount", 0) > 0:
                pkg = data["results"][0]
                return ArchPackageInfo(
                    name=pkg.get("Name", package_name),
                    version=pkg.get("Version", ""),
                    depends=pkg.get("Depends", []) or [],
                    makedepends=pkg.get("MakeDepends", []) or [],
                    optdepends=[opt.split(":")[0].strip() for opt in (pkg.get("OptDepends", []) or [])],
                    provides=pkg.get("Provides", []) or [],
                )
    except Exception:
        pass

    return None


def parse_rook_file(path: Path) -> Optional[RookPackageInfo]:
    """Parse a .rook TOML file."""
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)

        pkg = data.get("package", {})
        return RookPackageInfo(
            name=pkg.get("name", path.stem),
            version=pkg.get("version", ""),
            depends=data.get("depends", {}),
            build_depends=data.get("build_depends", {}),
            optional_depends=data.get("optional_depends", {}),
        )
    except Exception as e:
        print(f"Error parsing {path}: {e}", file=sys.stderr)
        return None


def strip_version_constraint(dep: str) -> str:
    """Strip version constraints from dependency string."""
    # Handle formats like "package>=1.0", "package>1.0", "package=1.0"
    return re.split(r'[><=]', dep)[0].strip()


def normalize_dep_name(dep: str) -> str:
    """Normalize a dependency name by removing .so suffix and other variations."""
    dep = strip_version_constraint(dep)

    # Remove .so suffix (e.g., "libncursesw.so" -> "libncursesw")
    if dep.endswith(".so"):
        dep = dep[:-3]

    # Remove lib prefix variations for matching (but keep for final result)
    # This helps map things like "libfoo" to existing package "foo"
    return dep


def map_arch_to_rookery(arch_dep: str) -> Optional[str]:
    """Map an Arch package name to Rookery package name."""
    dep = normalize_dep_name(arch_dep)

    # Check if it's in the ignore list
    if dep in IGNORE_PACKAGES:
        return None

    # Check explicit mapping first
    if dep in ARCH_TO_ROOKERY:
        result = ARCH_TO_ROOKERY[dep]
        return result  # May be None to explicitly ignore

    # Handle .so library names - these are typically provided by a package
    # with a similar name, so we should ignore them as they're not package names
    if arch_dep.endswith(".so"):
        # Try common lib mappings
        lib_mappings = {
            "libncursesw": "ncurses",
            "libncurses": "ncurses",
            "libreadline": "readline",
            "libz": "zlib",
            "libbz2": "bzip2",
            "liblzma": "xz",
            "libzstd": "zstd",
            "liblz4": "lz4",
            "libcrypto": "openssl",
            "libssl": "openssl",
            "libcurl": "curl",
            "libxml2": "libxml2",
            "libxslt": "libxslt",
            "libpng16": "libpng",
            "libpng": "libpng",
            "libjpeg": "libjpeg-turbo",
            "libtiff": "libtiff",
            "libwebp": "libwebp",
            "libgif": "giflib",
            "libfreetype": "freetype",
            "libfontconfig": "fontconfig",
            "libharfbuzz": "harfbuzz",
            "libpango-1.0": "pango",
            "libcairo": "cairo",
            "libpixman-1": "pixman",
            "libfribidi": "fribidi",
            "libglib-2.0": "glib2",
            "libgio-2.0": "glib2",
            "libgobject-2.0": "glib2",
            "libgmodule-2.0": "glib2",
            "libgthread-2.0": "glib2",
            "libgtk-3": "gtk3",
            "libgtk-4": "gtk4",
            "libgdk-3": "gtk3",
            "libgdk_pixbuf-2.0": "gdk-pixbuf2",
            "libatk-1.0": "at-spi2-core",
            "libatspi": "at-spi2-core",
            "libdbus-1": "dbus",
            "libsystemd": "systemd",
            "libudev": "systemd",
            "libpulse": "pulseaudio",
            "libpulse-simple": "pulseaudio",
            "libasound": "alsa-lib",
            "libpipewire-0.3": "pipewire",
            "libspa-0.2": "pipewire",
            "libX11": "libx11",
            "libXext": "libxext",
            "libXrender": "libxrender",
            "libXi": "libxi",
            "libXtst": "libxtst",
            "libXcursor": "libxcursor",
            "libXfixes": "libxfixes",
            "libXdamage": "libxdamage",
            "libXrandr": "libxrandr",
            "libXinerama": "libxinerama",
            "libXxf86vm": "libxxf86vm",
            "libXshmfence": "libxshmfence",
            "libXcomposite": "libxcomposite",
            "libxcb": "libxcb",
            "libxkbcommon": "libxkbcommon",
            "libwayland-client": "wayland",
            "libwayland-server": "wayland",
            "libwayland-cursor": "wayland",
            "libwayland-egl": "wayland",
            "libdrm": "libdrm",
            "libGL": "mesa",
            "libGLESv2": "mesa",
            "libEGL": "mesa",
            "libgbm": "mesa",
            "libvulkan": "vulkan-loader",
            "libepoxy": "libepoxy",
            "libva": "libva",
            "libvdpau": "libvdpau",
            "libinput": "libinput",
            "libevdev": "libevdev",
            "libffi": "libffi",
            "libevent": "libevent",
            "libuv": "libuv",
            "libpcre2-8": "pcre2",
            "libpcre": "pcre",
            "libicu": "icu",
            "libicui18n": "icu",
            "libicuuc": "icu",
            "libicudata": "icu",
            "libexpat": "expat",
            "libjson-c": "json-c",
            "libsqlite3": "sqlite",
            "liblmdb": "lmdb",
            "libgcrypt": "libgcrypt",
            "libgpg-error": "libgpg-error",
            "libsecret-1": "libsecret",
            "libcap": "libcap",
            "libelf": None,  # Debug lib, usually optional
            "libdw": None,  # Debug lib, usually optional
            "libunwind": "libunwind",
            "libboost_system": "boost",
            "libboost_filesystem": "boost",
            "libboost_thread": "boost",
            "libopus": "opus",
            "libvorbis": "libvorbis",
            "libvorbisenc": "libvorbis",
            "libvorbisfile": "libvorbis",
            "libFLAC": "flac",
            "libmp3lame": "lame",
            "libsamplerate": "libsamplerate",
            "libspeexdsp": "speexdsp",
            "libavcodec": "ffmpeg",
            "libavformat": "ffmpeg",
            "libavutil": "ffmpeg",
            "libswscale": "ffmpeg",
            "libswresample": "ffmpeg",
            "libavfilter": "ffmpeg",
            "libavdevice": "ffmpeg",
            "libpostproc": "ffmpeg",
            "libgstreamer-1.0": "gstreamer",
            # Additional lib mappings from report analysis
            "libcrypt": "libxcrypt",
            "libxcrypt": "libxcrypt",
            "libgio-2.0": "glib2",
            "libgmodule-2.0": "glib2",
            "libgthread-2.0": "glib2",
            "libgobject-2.0": "glib2",
            "libglib-2.0": "glib2",
            "libdbus-1": "dbus",
            "libsystemd": "systemd",
            "libudev": "systemd",
            "libblkid": "util-linux",
            "libmount": "util-linux",
            "libuuid": "util-linux",
            "libattr": "attr",
            "libacl": "acl",
            "libbz2": "bzip2",
            "liblzma": "xz",
            "libzstd": "zstd",
            "liblz4": "lz4",
            "libbrotlidec": "brotli",
            "libbrotlienc": "brotli",
            "libbrotlicommon": "brotli",
            "libasound": "alsa-lib",
            "libreadline": "readline",
            "libncurses": "ncurses",
            "libncursesw": "ncurses",
            "libform": "ncurses",
            "libformw": "ncurses",
            "libmenu": "ncurses",
            "libmenuw": "ncurses",
            "libpanel": "ncurses",
            "libpanelw": "ncurses",
            "libtic": "ncurses",
            "libtinfo": "ncurses",
            "libtinfow": "ncurses",
            "libQt6Core": "qt6",
            "libQt6Gui": "qt6",
            "libQt6Widgets": "qt6",
            "libQt6Network": "qt6",
            "libQt6DBus": "qt6",
            "libQt6Qml": "qt6",
            "libQt6Quick": "qt6",
            "libQt6Svg": "qt6",
            "libQt6Xml": "qt6",
            "libQt6Concurrent": "qt6",
            "libQt6OpenGL": "qt6",
            "libQt6PrintSupport": "qt6",
            "libQt6Sql": "qt6",
            "libQt6Test": "qt6",
            "libQt6WaylandClient": "qt6",
            "libKF6CoreAddons": "kf6-kcoreaddons",
            "libKF6ConfigCore": "kf6-kconfig",
            "libKF6I18n": "kf6-ki18n",
            "libKF6Service": "kf6-kservice",
            "libKF6KIOCore": "kf6-kio",
            "libKF6WidgetsAddons": "kf6-kwidgetsaddons",
            "libKF6WindowSystem": "kf6-kwindowsystem",
            "libKF6DBusAddons": "kf6-kdbusaddons",
            "libKF6Crash": "kf6-kcrash",
            "libKF6GuiAddons": "kf6-kguiaddons",
        }
        if dep in lib_mappings:
            return lib_mappings[dep]
        # Unknown .so library - ignore it as it's likely provided by another package
        return None

    # Handle python- prefixed packages
    if dep.startswith("python-"):
        # Most python packages are build-only or optional, ignore for now
        return None

    # Handle perl- prefixed packages
    if dep.startswith("perl-"):
        # Most perl packages are build-only or optional, ignore for now
        return None

    # Handle lib32- packages (32-bit compat, not relevant for Rookery)
    if dep.startswith("lib32-"):
        return None

    # Handle -git, -svn, -bzr, -hg suffixed packages (development versions)
    for suffix in ["-git", "-svn", "-bzr", "-hg"]:
        if dep.endswith(suffix):
            return None

    # Handle -docs packages
    if dep.endswith("-docs") or dep.endswith("-doc"):
        return None

    # Handle -devel packages (Arch naming for -dev headers)
    if dep.endswith("-devel"):
        # Strip -devel and try to map the base package
        base = dep[:-6]
        if base in ARCH_TO_ROOKERY:
            return ARCH_TO_ROOKERY[base]
        return base

    # Handle Arch-specific split/config packages
    arch_split_packages = {
        "alsa-topology-conf": "alsa-lib",
        "alsa-ucm-conf": "alsa-lib",
        "bash-completion": None,  # Optional
        "nss-mdns": None,  # Optional
        "debuginfod": None,  # Optional
        "xorg-font-util": None,  # X.org build tool
        "xorg-util-macros": None,  # X.org build macros
        "xorg-xkbcomp": "xkeyboard-config",
        "xtrans": None,  # X.org transport lib (build-only)
        "gperf": None,  # Build tool
        "gi-docgen": None,  # Doc generator
        "itstool": None,  # Build tool
        "xmltoman": None,  # Build tool
        "graphviz": None,  # Build tool
        "dbus-broker": "dbus",  # Alternative D-Bus impl
        "mesa-libgl": "mesa",
        "libstemmer": None,  # Stemming library
        "libxmlb": None,  # XML library
        "libfyaml": None,  # YAML library
        "libatopology": "alsa-lib",
        "libformw": "ncurses",
        "libmenuw": "ncurses",
        "libpanelw": "ncurses",
        "psmisc": None,  # Optional utility
        "po4a": None,  # Translation tool
        "ed": None,  # Editor (build-only)
        "uasm": None,  # Assembler (build-only)
        "shadow": None,  # Shadow utils (implicit)
        "libcrypt": "libxcrypt",
    }
    if dep in arch_split_packages:
        return arch_split_packages[dep]

    # Try direct mapping as last resort
    return dep


def compare_dependencies(rook_pkg: RookPackageInfo, arch_pkg: ArchPackageInfo) -> dict:
    """Compare dependencies between rook and arch package."""
    results = {
        "missing_depends": [],
        "missing_build_depends": [],
        "missing_optional": [],
        "extra_depends": [],
        "extra_build_depends": [],
    }

    # Get Rookery dependency names (keys only)
    rook_depends = set(rook_pkg.depends.keys())
    rook_build_depends = set(rook_pkg.build_depends.keys())
    rook_optional = set(rook_pkg.optional_depends.keys())

    # Map Arch dependencies to Rookery names
    arch_depends_mapped = set()
    for dep in arch_pkg.depends:
        mapped = map_arch_to_rookery(dep)
        if mapped:
            arch_depends_mapped.add(mapped)

    arch_makedepends_mapped = set()
    for dep in arch_pkg.makedepends:
        mapped = map_arch_to_rookery(dep)
        if mapped:
            arch_makedepends_mapped.add(mapped)

    arch_optdepends_mapped = set()
    for dep in arch_pkg.optdepends:
        mapped = map_arch_to_rookery(dep)
        if mapped:
            arch_optdepends_mapped.add(mapped)

    # Find missing runtime dependencies
    for dep in arch_depends_mapped:
        if dep not in rook_depends and dep not in rook_build_depends:
            results["missing_depends"].append(dep)

    # Find missing build dependencies
    for dep in arch_makedepends_mapped:
        if dep not in rook_build_depends and dep not in rook_depends:
            results["missing_build_depends"].append(dep)

    # Find missing optional dependencies
    for dep in arch_optdepends_mapped:
        if dep not in rook_optional and dep not in rook_depends:
            results["missing_optional"].append(dep)

    return results


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Check .rook dependencies against Arch Linux")
    parser.add_argument("--specs-dir", default="specs", help="Directory containing .rook files")
    parser.add_argument("--package", "-p", help="Check specific package only")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--fix", action="store_true", help="Show suggested fixes")
    args = parser.parse_args()

    specs_dir = Path(args.specs_dir)
    if not specs_dir.exists():
        print(f"Error: specs directory not found: {specs_dir}", file=sys.stderr)
        sys.exit(1)

    # Get list of .rook files to check
    if args.package:
        rook_files = list(specs_dir.glob(f"{args.package}.rook"))
        if not rook_files:
            # Try with kf6- prefix
            rook_files = list(specs_dir.glob(f"kf6-{args.package}.rook"))
        if not rook_files:
            print(f"Error: Package not found: {args.package}", file=sys.stderr)
            sys.exit(1)
    else:
        rook_files = sorted(specs_dir.glob("*.rook"))

    total_missing = 0
    packages_with_issues = 0

    for rook_file in rook_files:
        rook_pkg = parse_rook_file(rook_file)
        if not rook_pkg:
            continue

        # Determine Arch package name
        arch_name = rook_pkg.name
        if arch_name.startswith("kf6-"):
            arch_name = arch_name[4:]  # Strip kf6- prefix for Arch lookup

        if args.verbose:
            print(f"Checking {rook_pkg.name}...", end=" ", flush=True)

        arch_pkg = fetch_arch_package_info(arch_name)
        if not arch_pkg:
            if args.verbose:
                print("(not found in Arch)")
            continue

        if args.verbose:
            print(f"(found: {arch_pkg.name})")

        # Compare dependencies
        diff = compare_dependencies(rook_pkg, arch_pkg)

        has_issues = any([
            diff["missing_depends"],
            diff["missing_build_depends"],
            diff["missing_optional"],
        ])

        if has_issues:
            packages_with_issues += 1
            print(f"\n{'='*60}")
            print(f"Package: {rook_pkg.name}")
            print(f"Arch equivalent: {arch_pkg.name} ({arch_pkg.version})")

            if diff["missing_depends"]:
                print(f"\n  Missing runtime dependencies:")
                for dep in sorted(diff["missing_depends"]):
                    print(f"    - {dep}")
                    total_missing += 1

            if diff["missing_build_depends"]:
                print(f"\n  Missing build dependencies:")
                for dep in sorted(diff["missing_build_depends"]):
                    print(f"    - {dep}")
                    total_missing += 1

            if diff["missing_optional"]:
                print(f"\n  Missing optional dependencies:")
                for dep in sorted(diff["missing_optional"]):
                    print(f"    - {dep}")
                    total_missing += 1

            if args.fix:
                print(f"\n  Suggested additions to {rook_file.name}:")
                if diff["missing_depends"]:
                    print("  [depends]")
                    for dep in sorted(diff["missing_depends"]):
                        print(f'  {dep} = ">= 1.0"')
                if diff["missing_build_depends"]:
                    print("  [build_depends]")
                    for dep in sorted(diff["missing_build_depends"]):
                        print(f'  {dep} = ">= 1.0"')
                if diff["missing_optional"]:
                    print("  [optional_depends]")
                    for dep in sorted(diff["missing_optional"]):
                        print(f'  {dep} = ">= 1.0"')

    print(f"\n{'='*60}")
    print(f"Summary:")
    print(f"  Packages checked: {len(rook_files)}")
    print(f"  Packages with issues: {packages_with_issues}")
    print(f"  Total missing dependencies: {total_missing}")


if __name__ == "__main__":
    main()
