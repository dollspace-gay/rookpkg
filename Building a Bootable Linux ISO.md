# **The Engineering and Architecture of Production-Grade Linux Installation Media**

## **Executive Summary**

The transformation of a collection of discrete software packages into a cohesive, bootable, and installable operating system image represents a pinnacle of systems engineering. This process, essential to the distribution of Linux, requires the precise orchestration of bootloader standards, filesystem compression, kernel-space initialization, and installer logic. It is not merely a data archiving task but the construction of a hybrid operational environment capable of traversing the hardware initialization gap—from Legacy BIOS to modern UEFI—while maintaining a unified user experience.

This comprehensive report analyzes the end-to-end pipeline required to construct a "Live ISO" akin to those produced by major distributions such as Fedora, Debian, and Arch Linux. The analysis dissects the monolithic ISO file into its constituent layers: the hybrid boot structures that satisfy conflicting firmware standards; the compressed immutable root filesystems that maximize storage efficiency; the volatile overlay networks that enable read-write operations on read-only media; and the installer frameworks that migrate this ephemeral state to permanent storage. By examining the tooling of industry leaders—including dracut, xorriso, calamares, and anaconda—this report provides a definitive technical blueprint for the creation of modern Linux installation media.

## ---

**1\. The Boot Architecture: Hybridization and Firmware Standards**

The fundamental requirement of any general-purpose Linux distribution media is universality. The resulting image must boot on a twenty-year-old server utilizing a Legacy BIOS (Basic Input/Output System) and a modern workstation employing the Unified Extensible Firmware Interface (UEFI) with Secure Boot enabled. To achieve this, the ISO 9660 filesystem—originally designed solely for optical media—has been adapted into a complex "Hybrid ISO" structure that masquerades as both a CD-ROM and a hard disk drive simultaneously.

### **1.1 The Evolution of El Torito**

The ISO 9660 standard, by itself, defines file placement on an optical disc but lacks a mechanism for bootstrapping a CPU. The **El Torito** extension fills this gap by creating a "Boot Catalog" at a fixed sector on the disc. This catalog serves as a menu for the system firmware, pointing to the location of boot loader code.1

In a modern Linux ISO, the El Torito catalog is multiplexed. It contains two distinct boot entries, ensuring compatibility across firmware generations:

1. **The BIOS Entry:** This entry points to a binary image (typically isolinux.bin) that runs in 16-bit Real Mode. The optical drive emulation loads this binary, which then initializes the CPU and loads the Linux kernel. This entry is strictly for Legacy BIOS systems or CSM (Compatibility Support Module) modes.2  
2. **The UEFI Entry:** UEFI does not load raw binary code from a sector; it requires a file-based structure. Therefore, the second entry in the El Torito catalog points to an embedded **EFI System Partition (ESP)** image. This is a FAT12/16/32 formatted filesystem image file (often named efiboot.img or efi.img) residing inside the ISO 9660 filesystem. The UEFI firmware mounts this image and executes the \\EFI\\BOOT\\BOOTX64.EFI application contained within.3

This duality implies that the ISO author must maintain two parallel bootloader configurations—one for ISOLINUX (BIOS) and one for GRUB2 or systemd-boot (UEFI)—that ultimately point to the same Linux kernel and initial RAM disk.

### **1.2 The Mechanics of Hybrid ISOs**

While El Torito handles optical media, modern installation is predominantly performed via USB flash drives. To a BIOS or UEFI, a USB drive is a block device, not a CD-ROM. A standard ISO image bit-streamed (dd) to a USB stick would lack the Master Boot Record (MBR) or GUID Partition Table (GPT) required to identify it as a bootable disk.

To solve this, the industry employs the **isohybrid** technique. This process injects an MBR partition table into the first 512 bytes of the ISO image (which are unused by the ISO 9660 standard).

* **Legacy Hybridization:** The MBR is constructed with a partition entry that points to the ISO filesystem itself. A bootstrap code (like isohdpfx.bin) is placed in the MBR code area. When the BIOS boots the USB, it executes this code, which locates the ISOLINUX bootloader on the filesystem.2  
* **UEFI Hybridization:** For UEFI booting from USB, the image must contain a valid partition table (GPT or MBR) where one partition is identified as an EFI System Partition. The xorriso tool achieves this by creating a partition entry that maps directly to the efiboot.img file embedded deep within the ISO structure. This allows the UEFI firmware to "see" the embedded FAT image as a legitimate partition on the USB drive, enabling boot.5

This architectural complexity demands precise mastering tools capable of writing the ISO 9660 filesystem while simultaneously calculating the sector offsets for the MBR/GPT partition tables that overlay it.

### **1.3 Bootloader Implementations and Handoff**

The choice of bootloader defines the initial user experience. While ISOLINUX is the de facto standard for the BIOS path due to its simplicity and resilience on optical media, the UEFI path is more varied.

* **GRUB2:** Most major distributions (Fedora, Ubuntu, Debian) utilize GRUB2 for the UEFI path. It offers powerful scripting capabilities and support for Secure Boot via the shim loader. In this configuration, the BOOTX64.EFI is actually a signed shim binary, which validates and loads grubx64.efi, which in turn reads a configuration file (grub.cfg) embedded in the ISO.3  
* **Systemd-boot:** Some minimalist or cutting-edge distributions (like Pop\!\_OS or Arch derivatives) may employ systemd-boot. This loader is simpler and relies on the UEFI specification's native ability to read partition entries, but it requires the kernel to be located on the EFI partition itself or accessible via an EFI filesystem driver.8

The critical engineering challenge here is path unification. The bootloader must pass specific kernel parameters—such as the label of the boot media (root=live:CDLABEL=Fedora-Workstation or archisolabel=ARCH\_2024)—so that the kernel, once loaded, can find the filesystem from which it was launched.

## ---

**2\. The Supply Chain: Package Bootstrapping and Repository Management**

The core of any Linux distribution is its package set. Before an ISO can be assembled, the operating system effectively needs to be "installed" into a directory. This process, known as bootstrapping, creates the root filesystem (rootfs) that will eventually be compressed and distributed. This stage is distinct from compiling code; it involves resolving dependencies, verifying cryptographic signatures, and unpacking pre-compiled binaries into a staging area.

### **2.1 The Bootstrap Engines**

Different distribution families utilize specialized tooling to create this initial directory tree, each with unique handling of dependencies and host-system isolation.

Debian and Ubuntu: debootstrap  
The debootstrap utility is the industry standard for creating Debian-based root filesystems. It functions by downloading the essential .deb packages (libc, coreutils, apt, bash) from a specified mirror and unpacking them into a target directory.9

* *Mechanics:* Unlike a standard install, debootstrap does not require a running Debian system. It can run on any POSIX-compliant system (even Gentoo or Fedora) to cross-build a Debian rootfs.  
* *Phases:* It operates in two stages. The first stage downloads and unpacks packages. The second stage, executed within a chroot (change root) environment inside the target, runs the configuration scripts (postinst) for each package to set up the dynamic environment.10

Fedora and RHEL: dnf \--installroot  
The dnf package manager supports a powerful \--installroot=\<path\> argument. This isolates the transaction, effectively treating the specified directory as a blank hard drive.

* *Context:* This method relies on the host system's repositories unless overridden. It is heavily used by tools like mock and lorax to build build-roots and live images.  
* *Key Difference:* Unlike debootstrap, which is a standalone script, dnf is a complex Python application. Using it to bootstrap requires the host to have a compatible version of dnf, making cross-distribution builds (e.g., building Fedora on Ubuntu) more complex, often requiring containerization.8

Arch Linux: pacstrap  
The pacstrap script is a wrapper around pacman. It creates a new filesystem hierarchy and installs the base package group.

* *Simplicity:* It is designed specifically for the Arch installation process but is equally applicable to building ISOs. It mounts the API filesystems (/proc, /sys, /dev) into the target before running pacman hooks, ensuring that mkinitcpio and other hardware-dependent scripts run correctly.12

### **2.2 Cryptographic Chain of Trust**

A critical aspect of bootstrapping is ensuring the integrity of the binaries. A compromised package at this stage compromises every installation performed with the resulting ISO.

* **GPG Keyrings:** The bootstrap tool must be supplied with the public GPG keys of the target distribution. For debootstrap, this is handled via the \--keyring argument. If a builder is using a custom repository (e.g., for a corporate internal distro), they must import their own GPG keys into the bootstrap keyring.14  
* **Signed Metadata:** Repositories are secured not just by signing packages, but by signing the metadata (the list of packages and their hashes). Tools like reprepro (for Debian) and createrepo (for RPM) generate this metadata. The bootstrapping tool validates the signature of the Release or repomd.xml file before downloading any packages.16

### **2.3 Minimization and Customization Strategies**

The resulting root filesystem is often significantly larger than the final ISO. To engineer an efficient image, builders apply strict minimization policies.

* **Documentation Removal:** For a Live ISO, man pages and documentation (/usr/share/doc) are often superfluous. Build scripts typically delete these directories or configure the package manager (e.g., tsflags=nodocs in dnf.conf) to skip them during installation.12  
* **Locale Stripping:** A global distribution might support 50 languages, but a specialized rescue ISO might only need English. Removing /usr/share/locale can save hundreds of megabytes.  
* **Kernel Synchronization:** A common failure mode occurs when the kernel package installed in the rootfs (/boot/vmlinuz-x.y.z) does not match the kernel used by the ISO bootloader. The bootstrap process must ensure that the kernel version is explicitly pinned and that the corresponding kernel modules (/lib/modules/x.y.z) are present.4

## ---

**3\. The Immutable Core: Filesystem Engineering**

Once the root filesystem is populated with software, it must be packaged for distribution. Unlike a standard hard drive installation, a Live ISO cannot simply expose a raw ext4 filesystem, as this would be inefficient in space and incompatible with the read-only nature of optical media. The industry solution is the usage of highly compressed, read-only filesystems.

### **3.1 SquashFS: The Industry Standard**

SquashFS (Squash File System) is the ubiquitous choice for this layer. It is a compressed, read-only file system for Linux, designed to squash entire directory trees into a single file (often named filesystem.squashfs, airootfs.sfs, or squashfs.img).

Compression Algorithms and Trade-offs  
The performance of a Live ISO—specifically its boot time and application launch speed—is dictated by the compression algorithm chosen during the mksquashfs process.

* **gzip:** The historical default. It offers fast decompression but mediocre compression ratios. It is rarely used in modern desktop ISOs due to size constraints.19  
* **xz (LZMA):** The standard for minimum size. XZ provides the highest compression ratios, allowing distributions to fit large desktop environments onto smaller media. However, its high decompression CPU cost can make system responsiveness sluggish on older hardware.19  
* **zstd (Zstandard):** The modern contender. Zstandard (used by Arch Linux and Fedora) offers compression ratios comparable to gzip/xz but with decompression speeds that are orders of magnitude faster. This results in significantly faster boot times, as the CPU spends less time waiting for data to be unpacked from the storage medium.19

Block Sizes and Inodes  
SquashFS divides files into blocks (default 128KB). Increasing the block size (e.g., to 1MB) can improve compression ratios by allowing the algorithm to find more redundancy, but it increases the granularity of random access. If a program needs to read 4KB of data, the kernel must decompress the entire 1MB block. This trade-off must be tuned based on the expected workload.19

### **3.2 Determinism and Reproducible Builds**

In the context of software supply chain security, it is vital that the ISO generation process is reproducible. If two different engineers run the build script on the same source packages, the resulting ISO should have an identical cryptographic hash.  
SquashFS supports this via specific flags:

* \-reproducible: This flag, or the manual setting of timestamps using \-mkfs-time and \-all-time, ensures that the creation time of the filesystem does not pollute the hash. Without this, every build would yield a different hash solely due to the timestamp of the build server.21  
* **Sorting:** mksquashfs sorts files by filename by default to ensure the data is written to the image in a deterministic order.

### **3.3 The Union Mount Architecture: OverlayFS**

Since SquashFS is read-only, the operating system cannot write logs, create lock files, or save user preferences. To provide the illusion of a writable system, Live ISOs utilize a **Union Mount** strategy, specifically **OverlayFS**.

The Layered Model  
OverlayFS stacks two directories on top of each other to create a unified view:

1. **Lower Directory (Read-Only):** The mount point of the SquashFS image.  
2. **Upper Directory (Read-Write):** A tmpfs (RAM disk) mounted in memory.

Copy-On-Write (CoW) Mechanics  
When a process attempts to read a file, OverlayFS looks in the Upper Directory. If not found, it reads from the Lower Directory. When a process attempts to write or modify a file, OverlayFS intercepts the call. It copies the file from the read-only Lower layer to the writable Upper layer (in RAM) and applies the modification there. The Lower layer remains untouched.

* *Implications:* This means that the "capacity" of the Live OS to accept new files is limited by the system's available RAM. If the user installs a massive package in the live environment, it consumes RAM, potentially leading to an out-of-memory crash.23

Persistence  
To allow changes to survive a reboot, the Upper Directory can be mapped to a physical partition on a USB drive (often labeled casper-rw or persistence) instead of RAM. This allows users to carry a personalized OS on a stick.25

## ---

**4\. Early Userspace: The Initramfs and Boot Logic**

The most complex phase of the Live ISO lifecycle is the boot sequence. The Linux kernel, upon loading, has no knowledge of "ISO files" or "SquashFS." It only knows how to mount a block device. The bridge between the kernel and the complex Live ISO structure is the **Initial RAM Filesystem (initramfs)**.

### **4.1 The Role of Initramfs**

The initramfs is a small CPIO archive containing a minimal shell (often BusyBox), essential libraries, and kernel modules. Its sole purpose is to prepare the real root filesystem and hand over control to systemd (or init). For a Live ISO, this task is intricate:

1. **Hardware Detection:** Load USB and CD-ROM drivers.  
2. **Medium Hunting:** Scan all connected block devices to find the one containing the ISO. This is often done by looking for a specific Volume Label (e.g., Fedora-WS-Live) or a UUID.26  
3. **Loop Mounting:** Once the device is found, mount the ISO 9660 filesystem. Then, locate the SquashFS file inside it and mount it as a loop device (a pseudo-device that makes a file act like a block device).18  
4. **Overlay Setup:** Create the OverlayFS merging the loop-mounted SquashFS with a RAM-based tmpfs.27  
5. **Switch Root:** Pivot the system root (/) from the initramfs to the newly created OverlayFS mount and execute /sbin/init.28

### **4.2 Dracut: The Enterprise Approach**

Used by Red Hat, Fedora, and Void Linux, dracut generates initramfs images using a modular event-driven framework.

* **The dmsquash-live Module:** This is the specific Dracut module responsible for Live ISO logic. It handles the parsing of kernel command line arguments like rd.live.image.  
* **Kernel Command Line API:**  
  * root=live:CDLABEL=...: Tells Dracut to look for a storage device with the specified label.26  
  * rd.live.overlay.overlayfs=1: Forces the use of OverlayFS (instead of the older Device Mapper snapshot method).30  
  * iso-scan/filename: A critical parameter for multi-boot USB tools (like Ventoy or Rufus). It tells Dracut to look for an ISO file *inside* a partition, mount the partition, loop-mount the ISO, and then proceed. This allows the ISO to boot even if it's just a file on an NTFS USB stick.31

Customization with Dracut  
When building the ISO, the engineer typically invokes Dracut with specific inclusions to ensure the live environment is robust.

Bash

dracut \--nomdadmconf \--nolvmconf \--xz \\  
       \--add "livenet dmsquash-live convertfs pollcdrom" \\  
       \--omit "plymouth" \\  
       initramfs-live.img \<kernel-version\>

This command explicitly adds the live booting modules and removes unnecessary ones (like mdadm for RAID, which is rarely needed for the live boot itself) to save space.32

### **4.3 Mkinitcpio: The Arch Approach**

Arch Linux uses mkinitcpio, which is configured via a strictly defined HOOKS array in /etc/mkinitcpio.conf.

* **The archiso Hook:** This custom hook performs the mounting logic. It utilizes the archisobasedir (e.g., arch) and archisolabel kernel parameters to locate the medium.  
* **Copy-to-RAM:** Archiso includes a copytoram feature which copies the entire SquashFS image into RAM during boot. This allows the USB drive to be physically removed after booting, a feature highly valued in rescue scenarios.34

### **Table 1: Initramfs Generation Comparison**

| Feature | Dracut (dmsquash-live) | Mkinitcpio (archiso) |
| :---- | :---- | :---- |
| **Configuration** | Command line arguments (--add) and configuration files in /etc/dracut.conf.d/ | /etc/mkinitcpio.conf HOOKS array |
| **Logic Style** | Shell scripts with event loops | Linear shell script execution |
| **Network Boot** | Module livenet handles HTTP/NFS fetching of the ISO | Hook archiso\_pxe\_common handles NBD/HTTP/NFS |
| **Overlay Backend** | Device Mapper (Snapshot) or OverlayFS | Device Mapper (Snapshot) primarily, OverlayFS optional |
| **Discovery** | root=live:LABEL=... | archisolabel=... |

## ---

**5\. The Installation Engines: Migrating to Metal**

The "Live" environment is ephemeral. To make the OS permanent, an installer application is required. This application does not install packages one by one (which would be slow); instead, it typically copies the filesystem image directly to the disk.

### **5.1 Calamares: The Universal Framework**

Calamares is a distro-agnostic installer used by Manjaro, Lubuntu, EndeavourOS, and dozens of others. It acts as a sequencer, running a series of Python and C++ modules defined in a settings.conf file.36

The Unpackfs Module  
The core of Calamares is the unpackfs module.

* *Mechanism:* Instead of running dnf install or apt-get install, unpackfs performs a raw file copy (rsync-like) or a block-level copy of the SquashFS image from the live media to the target partition. This results in an installation time of minutes rather than hours.  
* *Configuration:* The unpackfs.conf file maps the source image (on the ISO) to the destination (the /target mount point).  
  YAML  
  unpack:  
    \- source: "/run/archiso/airootfs"  
      sourcefs: "squashfs"  
      destination: ""

  This instructs Calamares to unpack the contents of the live root directly to the user's hard drive.37

Branding and Identity  
Calamares is highly themable via the branding.desc file. This directory structure allows the ISO creator to inject their own logos, slideshows, and welcome text without recompiling the installer binary.

* *Structure:* Located in /usr/share/calamares/branding/\<brand\>/, it contains the branding.desc file and associated assets (images, QML files).  
* *Global Variables:* The branding file controls window size, navigation sidebars, and external links (e.g., "Support," "Release Notes").39

### **5.2 Anaconda: The Enterprise Standard**

Red Hat's Anaconda installer is driven by **Kickstart**, a text-based configuration format.

* Liveimg Install: In a Live ISO context, Anaconda uses the liveimg command in its configuration.  
  liveimg \--url=file:///run/install/repo/LiveOS/squashfs.img  
  This tells Anaconda to install the OS by copying the specified SquashFS image. It handles the resizing of the filesystem to fill the target partition automatically.42  
* **Lorax:** While Anaconda is the installer, **Lorax** is the tool used to build the environment *for* Anaconda. Lorax creates a specialized boot.iso that contains the kernel and a massive initramfs containing Anaconda and its Python dependencies. This differs from the Calamares approach, where the installer is just an app running inside the standard desktop environment.44

## ---

**6\. Mastering the Image: Xorriso and Hybridization**

The final assembly phase, or "mastering," fuses the bootloaders, the kernel, and the compressed filesystem into a deliverable ISO file. The tool xorriso has totally supplanted legacy tools like genisoimage due to its native handling of UEFI hybrid scenarios.

### **6.1 The Command Line Anatomy**

Creating a hybrid BIOS/UEFI ISO requires a precise invocation of xorriso. Each flag maps to a specific structure in the ISO/MBR layout.5

Bash

xorriso \-as mkisofs \\  
  \-iso-level 3 \\  
  \-full-iso9660-filenames \\  
  \-volid "ARCH\_2024" \\  
  \-eltorito-boot isolinux/isolinux.bin \\  
  \-eltorito-catalog isolinux/boot.cat \\  
  \-no-emul-boot \-boot-load-size 4 \-boot-info-table \\  
  \-isohybrid-mbr isolinux/isohdpfx.bin \\  
  \-eltorito-alt-boot \\  
  \-e boot/grub/efi.img \\  
  \-no-emul-boot \-isohybrid-gpt-basdat \\  
  \-output arch-custom.iso \\  
  work\_directory/

**Deconstruction:**

* \-volid "ARCH\_2024": Sets the Volume ID. **Critical:** This must match the label searched for by the initramfs (e.g., archisolabel=ARCH\_2024 or root=live:LABEL=ARCH\_2024). If these mismatch, the boot will fail at the "Waiting for root device" stage.25  
* \-eltorito-boot: Starts the definition of the BIOS boot entry.  
* \-isohybrid-mbr: Injects the SYSLINUX MBR code (isohdpfx.bin) into the start of the file, allowing BIOS USB booting.  
* \-eltorito-alt-boot: A delimiter signal. It tells xorriso to stop defining the BIOS entry and start defining the UEFI entry.  
* \-e boot/grub/efi.img: Specifies the FAT filesystem image that serves as the EFI System Partition.  
* \-isohybrid-gpt-basdat: Creates a GPT partition entry for the efi.img, setting its type code to "Basic Data" (which UEFI firmware recognizes).

### **6.2 Directory Structure of the Final ISO**

The file layout on the ISO must correspond exactly to the paths expected by the bootloader configurations (grub.cfg, isolinux.cfg).

* /isolinux/: Contains isolinux.bin, isolinux.cfg, and the kernel modules for the bootloader (ldlinux.c32, libutil.c32).  
* /EFI/BOOT/: Contains the fallback UEFI loader BOOTX64.EFI (shim or grub).  
* /LiveOS/: Contains the massive squashfs.img.  
* /images/: (Fedora specific) Contains the efiboot.img secondary partition image.

## ---

**7\. Automated Build Systems: The "Factory" Approach**

While understanding the manual steps is essential for debugging, production ISOs are built using automated pipelines that abstract these complexities.

### **7.1 Debian Live Build**

Debian encapsulates the entire process in the live-build toolchain.

* **Config Tree:** Instead of a single script, it uses a directory tree (config/).  
  * config/package-lists/: Text files listing packages to install.  
  * config/hooks/: Scripts to run inside the chroot before mastering (e.g., to delete temp files).  
  * config/includes.chroot/: Files to be copied directly into the overlay (e.g., custom wallpapers, dotfiles).  
* **Auto Scripts:** The auto/config script is the entry point, defining the high-level architecture (distro codename, architecture, mirror URLs).  
  Bash  
  lb config \\  
  \--binary-images iso-hybrid \\  
  \--distribution bookworm \\  
  \--bootappend-live "boot=live components quiet splash"

  Running lb build then executes the bootstrap, chroot, binary, and source stages sequentially.47

### **7.2 Archiso**

Arch Linux uses archiso, which relies on "Profiles."

* **Profile Structure:** A profile contains a packages.x86\_64 file and an airootfs directory. Any file placed in airootfs (e.g., /etc/systemd/system/custom.service) is automatically copied to the live system.  
* **Transparency:** Archiso scripts (mkarchiso) are essentially bash wrappers around pacstrap and xorriso. They are highly readable and easy to modify for custom behavior, such as adding a custom repository to pacman.conf during the build.50

### **7.3 Fedora Livemedia-creator**

Fedora utilizes livemedia-creator, which can build ISOs using virtualization.

* **Virtual Machine Isolation:** Instead of just chroot, livemedia-creator can spawn a KVM virtual machine, install Fedora into a disk image inside that VM (using Anaconda), and then tar up the results to create the rootfs. This ensures that the build environment does not contaminate the target image, providing the highest level of isolation.51

## ---

**8\. Conclusion**

The creation of a bootable Linux ISO is a multidisciplinary engineering challenge that integrates kernel-space mechanics with user-space configuration. The process creates a bridge between the static nature of distribution packages and the dynamic requirements of hardware initialization.

For the researcher or engineer tasked with replicating this capability, the "Golden Path" involves:

1. **Bootstrapping** a minimal root filesystem using dnf or debootstrap.  
2. **Compressing** this root using mksquashfs with reproducibility flags.  
3. **Encapsulating** the squashfs within an initramfs generated by dracut that is aware of the live overlay logic.  
4. **Mastering** the final artifact with xorriso to generate a hybrid MBR/GPT partition map that satisfies both Legacy BIOS and UEFI standards.

As the industry moves toward immutable operating systems (like Fedora Silverblue or SteamOS), the architecture of the "Live ISO"—specifically the read-only root with a volatile overlay—is transitioning from a mere installation medium to the standard runtime architecture of the OS itself. Understanding these mechanisms is therefore not only key to building installers but to understanding the future of Linux system architecture.

### **Table 2: Comparative Analysis of ISO Build Toolchains**

| Toolchain | Target Distro | Bootstrap Engine | Initramfs Generator | Bootloader Strategy | Primary Use Case |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Live Build** | Debian / Kali | debootstrap | live-boot / initramfs-tools | ISOLINUX \+ GRUB | Official Debian Images |
| **Archiso** | Arch / Endeavour | pacstrap | mkinitcpio | Syslinux \+ Systemd-boot | Minimalist, DIY Customization |
| **Lorax** | Fedora / RHEL | dnf / rpm-ostree | dracut | GRUB2 (Macos-signed) | Enterprise, Secure Boot focus |
| **Linux From Scratch** | Custom | Manual Compilation | Manual / Custom Scripts | GRUB2 | Educational, Embedded |

#### **Works cited**

1. Booting with Legacy BIOS and UEFI from one ISO. : r/osdev \- Reddit, accessed December 20, 2025, [https://www.reddit.com/r/osdev/comments/1j791xb/booting\_with\_legacy\_bios\_and\_uefi\_from\_one\_iso/](https://www.reddit.com/r/osdev/comments/1j791xb/booting_with_legacy_bios_and_uefi_from_one_iso/)  
2. RepackBootableISO \- Debian Wiki, accessed December 20, 2025, [https://wiki.debian.org/RepackBootableISO](https://wiki.debian.org/RepackBootableISO)  
3. Making a UEFI-bootable image with mkisofs and \-eltorito-boot efiboot.img, accessed December 20, 2025, [https://unix.stackexchange.com/questions/312789/making-a-uefi-bootable-image-with-mkisofs-and-eltorito-boot-efiboot-img](https://unix.stackexchange.com/questions/312789/making-a-uefi-bootable-image-with-mkisofs-and-eltorito-boot-efiboot-img)  
4. \[SOLVED\] What is the purpose of efiboot.img on the live DVD? / Kernel & Hardware / Arch Linux Forums, accessed December 20, 2025, [https://bbs.archlinux.org/viewtopic.php?id=240034](https://bbs.archlinux.org/viewtopic.php?id=240034)  
5. Make iso as "bootable (dos/MBR sector)" in mkisofs \- Unix & Linux Stack Exchange, accessed December 20, 2025, [https://unix.stackexchange.com/questions/708672/make-iso-as-bootable-dos-mbr-sector-in-mkisofs](https://unix.stackexchange.com/questions/708672/make-iso-as-bootable-dos-mbr-sector-in-mkisofs)  
6. How to create uefi bootable iso? \- Ask Ubuntu, accessed December 20, 2025, [https://askubuntu.com/questions/625286/how-to-create-uefi-bootable-iso](https://askubuntu.com/questions/625286/how-to-create-uefi-bootable-iso)  
7. Making a bootloader for UEFI and BIOS at the same time. \- OSDev.org, accessed December 20, 2025, [https://forum.osdev.org/viewtopic.php?t=57058](https://forum.osdev.org/viewtopic.php?t=57058)  
8. Linux Bootstrap Installation \- Undus' Blog, accessed December 20, 2025, [https://undus.net/posts/linux-bootstrap-installation/](https://undus.net/posts/linux-bootstrap-installation/)  
9. Debootstrap \- Debian Wiki, accessed December 20, 2025, [https://wiki.debian.org/Debootstrap](https://wiki.debian.org/Debootstrap)  
10. How would a debootstrap'ed system differ from a regular-installation system?, accessed December 20, 2025, [https://unix.stackexchange.com/questions/643313/how-would-a-debootstraped-system-differ-from-a-regular-installation-system](https://unix.stackexchange.com/questions/643313/how-would-a-debootstraped-system-differ-from-a-regular-installation-system)  
11. DNF Command Reference — DNF @DNF\_VERSION@-1 documentation, accessed December 20, 2025, [https://dnf.readthedocs.io/en/latest/command\_ref.html](https://dnf.readthedocs.io/en/latest/command_ref.html)  
12. Install Arch Linux from existing Linux \- ArchWiki, accessed December 20, 2025, [https://wiki.archlinux.org/title/Install\_Arch\_Linux\_from\_existing\_Linux](https://wiki.archlinux.org/title/Install_Arch_Linux_from_existing_Linux)  
13. Anyone installed a linux distro, but the 100% command line or Arch way, through "debootstrap/pacstrap" or "dnf \--installroot ..." (or similar), and chroot? \- Reddit, accessed December 20, 2025, [https://www.reddit.com/r/linuxquestions/comments/1mvck8u/anyone\_installed\_a\_linux\_distro\_but\_the\_100/](https://www.reddit.com/r/linuxquestions/comments/1mvck8u/anyone_installed_a_linux_distro_but_the_100/)  
14. Use a custom keyring with live-build \- GitHub Gist, accessed December 20, 2025, [https://gist.github.com/rgov/92a7a0cb8ec6052f6e9968e755e88aad](https://gist.github.com/rgov/92a7a0cb8ec6052f6e9968e755e88aad)  
15. debootstrap "Release signed by unknown key" \- debian \- Server Fault, accessed December 20, 2025, [https://serverfault.com/questions/984604/debootstrap-release-signed-by-unknown-key](https://serverfault.com/questions/984604/debootstrap-release-signed-by-unknown-key)  
16. DebianRepository/SetupWithReprepro \- Debian Wiki, accessed December 20, 2025, [https://wiki.debian.org/DebianRepository/SetupWithReprepro](https://wiki.debian.org/DebianRepository/SetupWithReprepro)  
17. HOWTO: GPG sign and verify RPM packages and yum repositories | Packagecloud Blog, accessed December 20, 2025, [https://blog.packagecloud.io/how-to-gpg-sign-and-verify-rpm-packages-and-yum-repositories/](https://blog.packagecloud.io/how-to-gpg-sign-and-verify-rpm-packages-and-yum-repositories/)  
18. How does void live iso mount the squashfs? : r/voidlinux \- Reddit, accessed December 20, 2025, [https://www.reddit.com/r/voidlinux/comments/1d254y1/how\_does\_void\_live\_iso\_mount\_the\_squashfs/](https://www.reddit.com/r/voidlinux/comments/1d254y1/how_does_void_live_iso_mount_the_squashfs/)  
19. Best way to compress mksquashfs? \- Puppy Linux Discussion Forum, accessed December 20, 2025, [https://forum.puppylinux.com/viewtopic.php?t=9319](https://forum.puppylinux.com/viewtopic.php?t=9319)  
20. What was the SquashFS compression method? \- Super User, accessed December 20, 2025, [https://superuser.com/questions/919025/what-was-the-squashfs-compression-method](https://superuser.com/questions/919025/what-was-the-squashfs-compression-method)  
21. mksquashfs(1) — squashfs-tools — Debian testing, accessed December 20, 2025, [https://manpages.debian.org/testing/squashfs-tools/mksquashfs.1.en.html](https://manpages.debian.org/testing/squashfs-tools/mksquashfs.1.en.html)  
22. mksquashfs(1) \- Arch manual pages, accessed December 20, 2025, [https://man.archlinux.org/man/extra/squashfs-tools/mksquashfs.1.en](https://man.archlinux.org/man/extra/squashfs-tools/mksquashfs.1.en)  
23. How OverlayFS and SquashFS Power Embedded Linux Storage | by Akash saini | Medium, accessed December 20, 2025, [https://medium.com/@akashsainisaini37/how-overlayfs-and-squashfs-power-embedded-linux-storage-75273028ef20](https://medium.com/@akashsainisaini37/how-overlayfs-and-squashfs-power-embedded-linux-storage-75273028ef20)  
24. Adventures in live booting Linux distributions \- Major Hayden, accessed December 20, 2025, [https://major.io/p/adventures-in-live-booting-linux-distributions/](https://major.io/p/adventures-in-live-booting-linux-distributions/)  
25. Creating a custom persistent Arch Linux live cd for UEFI and BIOS systems, accessed December 20, 2025, [http://allican.be/blog/2016/02/04/creating\_custom\_persistent\_arch\_live\_iso.html](http://allican.be/blog/2016/02/04/creating_custom_persistent_arch_live_iso.html)  
26. dracut.cmdline \- dracut kernel command line options \- Ubuntu Manpage, accessed December 20, 2025, [https://manpages.ubuntu.com/manpages/trusty/man7/dracut.cmdline.7.html](https://manpages.ubuntu.com/manpages/trusty/man7/dracut.cmdline.7.html)  
27. filesystem \- How do I use OverlayFS? \- Ask Ubuntu, accessed December 20, 2025, [https://askubuntu.com/questions/109413/how-do-i-use-overlayfs](https://askubuntu.com/questions/109413/how-do-i-use-overlayfs)  
28. rd.live.overlay.overlayfs doesn't seem to work when $DRACUT\_SYSTEMD=1 · Issue \#1820 · dracutdevs/dracut \- GitHub, accessed December 20, 2025, [https://github.com/dracutdevs/dracut/issues/1820](https://github.com/dracutdevs/dracut/issues/1820)  
29. What rd.live.image means? \- fedora \- Unix & Linux Stack Exchange, accessed December 20, 2025, [https://unix.stackexchange.com/questions/684775/what-rd-live-image-means](https://unix.stackexchange.com/questions/684775/what-rd-live-image-means)  
30. dmsquash-live-root.sh \- dracut \- GitHub, accessed December 20, 2025, [https://github.com/dracutdevs/dracut/blob/master/modules.d/90dmsquash-live/dmsquash-live-root.sh](https://github.com/dracutdevs/dracut/blob/master/modules.d/90dmsquash-live/dmsquash-live-root.sh)  
31. dracut.cmdline(7) \- Linux manual page \- man7.org, accessed December 20, 2025, [https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html](https://man7.org/linux/man-pages/man7/dracut.cmdline.7.html)  
32. live-iso-boot/README.md at master \- GitHub, accessed December 20, 2025, [https://github.com/probonopd/live-iso-boot/blob/master/README.md](https://github.com/probonopd/live-iso-boot/blob/master/README.md)  
33. dracut \- ArchWiki, accessed December 20, 2025, [https://wiki.archlinux.org/title/Dracut](https://wiki.archlinux.org/title/Dracut)  
34. mkinitcpio \- ArchWiki, accessed December 20, 2025, [https://wiki.archlinux.org/title/Mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)  
35. How does the archiso boot in mkinitcpio? : r/archlinux \- Reddit, accessed December 20, 2025, [https://www.reddit.com/r/archlinux/comments/eo035r/how\_does\_the\_archiso\_boot\_in\_mkinitcpio/](https://www.reddit.com/r/archlinux/comments/eo035r/how_does_the_archiso_boot_in_mkinitcpio/)  
36. User's Guide \- Calamares, accessed December 20, 2025, [https://calamares.io/docs/users-guide/](https://calamares.io/docs/users-guide/)  
37. unpackfs.conf \- calamares \- GitHub, accessed December 20, 2025, [https://github.com/calamares/calamares/blob/master/src/modules/unpackfs/unpackfs.conf](https://github.com/calamares/calamares/blob/master/src/modules/unpackfs/unpackfs.conf)  
38. Calamares Installer Creation : r/linuxquestions \- Reddit, accessed December 20, 2025, [https://www.reddit.com/r/linuxquestions/comments/113a9dm/calamares\_installer\_creation/](https://www.reddit.com/r/linuxquestions/comments/113a9dm/calamares_installer_creation/)  
39. src/branding · 3.1.x-stable · Applications / calamares \- Manjaro Gitlab, accessed December 20, 2025, [https://gitlab.manjaro.org/applications/calamares/-/tree/3.1.x-stable/src/branding](https://gitlab.manjaro.org/applications/calamares/-/tree/3.1.x-stable/src/branding)  
40. calamares/src/branding/README.md at calamares \- GitHub, accessed December 20, 2025, [https://github.com/calamares/calamares/blob/calamares/src/branding/README.md](https://github.com/calamares/calamares/blob/calamares/src/branding/README.md)  
41. branding.desc \- calamares \- GitHub, accessed December 20, 2025, [https://github.com/calamares/calamares/blob/calamares/src/branding/default/branding.desc](https://github.com/calamares/calamares/blob/calamares/src/branding/default/branding.desc)  
42. Anaconda/Kickstart/KickstartingFedoraLiveInstallation \- Fedora Project Wiki, accessed December 20, 2025, [https://fedoraproject.org/wiki/Anaconda/Kickstart/KickstartingFedoraLiveInstallation](https://fedoraproject.org/wiki/Anaconda/Kickstart/KickstartingFedoraLiveInstallation)  
43. Chapter 22\. Kickstart commands and options reference | Automatically installing RHEL | Red Hat Enterprise Linux | 9, accessed December 20, 2025, [https://docs.redhat.com/en/documentation/red\_hat\_enterprise\_linux/9/html/automatically\_installing\_rhel/kickstart-commands-and-options-reference\_rhel-installer](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/automatically_installing_rhel/kickstart-commands-and-options-reference_rhel-installer)  
44. Lorax 41.3 documentation \- Weldr, accessed December 20, 2025, [https://weldr.io/lorax/lorax.html](https://weldr.io/lorax/lorax.html)  
45. Creating the Anaconda boot.iso with lorax \- Brian C. Lane, accessed December 20, 2025, [https://www.brianlane.com/post/creating-the-anaconda-bootiso-with-lorax/](https://www.brianlane.com/post/creating-the-anaconda-bootiso-with-lorax/)  
46. Remastering the install Iso for booting it form a Usb stick \- Arch Linux Forums, accessed December 20, 2025, [https://bbs.archlinux.org/viewtopic.php?id=207697](https://bbs.archlinux.org/viewtopic.php?id=207697)  
47. lb\_config(1) — live-build — Debian unstable, accessed December 20, 2025, [https://manpages.debian.org/unstable/live-build/lb\_config.1.en.html](https://manpages.debian.org/unstable/live-build/lb_config.1.en.html)  
48. lb config \[live-build options\] \- Linux Manpages Online \- man.cx manual pages, accessed December 20, 2025, [https://man.cx/lb\_config(1)](https://man.cx/lb_config\(1\))  
49. live-build(7) \- bookworm \- Debian Manpages, accessed December 20, 2025, [https://manpages.debian.org/bookworm/live-build/live-build.7.en.html](https://manpages.debian.org/bookworm/live-build/live-build.7.en.html)  
50. archiso \- ArchWiki, accessed December 20, 2025, [https://wiki.archlinux.org/title/Archiso](https://wiki.archlinux.org/title/Archiso)  
51. Chapter 7\. Creating a boot ISO installer image with RHEL image builder | Composing a customized RHEL system image | Red Hat Enterprise Linux, accessed December 20, 2025, [https://docs.redhat.com/en/documentation/red\_hat\_enterprise\_linux/8/html/composing\_a\_customized\_rhel\_system\_image/creating-a-boot-iso-installer-image-with-image-builder\_composing-a-customized-rhel-system-image](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/composing_a_customized_rhel_system_image/creating-a-boot-iso-installer-image-with-image-builder_composing-a-customized-rhel-system-image)