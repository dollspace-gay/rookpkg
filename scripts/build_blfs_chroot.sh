#!/bin/bash
set -e

# =============================================================================
# Rookery OS Extended Packages Chroot Build Script
# Builds Rookery Extended packages inside the chroot environment
# =============================================================================

# Simple logging for chroot environment (no file logging - stdout only)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Load checkpointing (doesn't need file logging)
if [ -f /tmp/rookery-common/checkpointing.sh ]; then
    source /tmp/rookery-common/checkpointing.sh
fi

# Checkpointing for BLFS (always use these, simpler than LFS checkpointing)
should_skip_package() {
    local pkg="$1"
    [ -f "/.checkpoints/blfs-${pkg}.checkpoint" ]
}
create_checkpoint() {
    local pkg="$1"
    mkdir -p /.checkpoints
    echo "Built on $(date)" > "/.checkpoints/blfs-${pkg}.checkpoint"
    log_info "Checkpoint created for $pkg"
}

# Environment
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

# Set UTF-8 locale for Qt and other packages that require it
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Build directory
BUILD_DIR="/build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log_info "=========================================="
log_info "Rookery Extended Package Build - Chroot Environment"
log_info "=========================================="
log_info "Build directory: $BUILD_DIR"
log_info "MAKEFLAGS: $MAKEFLAGS"

# =====================================================================
# BLFS 4.1 Linux-PAM-1.7.1
# =====================================================================
should_skip_package "linux-pam" && { log_info "Skipping Linux-PAM (already built)"; } || {
log_step "Building Linux-PAM-1.7.1..."

# Check if source exists
if [ ! -f /sources/Linux-PAM-1.7.1.tar.xz ]; then
    log_error "Linux-PAM-1.7.1.tar.xz not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf Linux-PAM-*
tar -xf /sources/Linux-PAM-1.7.1.tar.xz
cd Linux-PAM-*

# Create build directory (meson build)
rm -rf build && mkdir build
cd build

# Configure with meson
# Following BLFS 12.4 instructions exactly
meson setup ..            \
    --prefix=/usr         \
    --buildtype=release   \
    -D docdir=/usr/share/doc/Linux-PAM-1.7.1

# Build
ninja

# Create /etc/pam.d for tests (first-time installation)
log_info "Creating initial PAM configuration for tests..."
install -v -m755 -d /etc/pam.d

cat > /etc/pam.d/other << "EOF"
auth     required       pam_deny.so
account  required       pam_deny.so
password required       pam_deny.so
session  required       pam_deny.so
EOF

# Run tests (optional but recommended)
log_info "Running Linux-PAM tests..."
ninja test || log_warn "Some tests failed (may be expected without full PAM config)"

# Remove temporary test config
rm -fv /etc/pam.d/other

# Install
log_info "Installing Linux-PAM..."
ninja install

# Set SUID bit on unix_chkpwd (required for non-root password verification)
chmod -v 4755 /usr/sbin/unix_chkpwd

# Create PAM configuration files (BLFS recommended setup)
log_info "Creating PAM configuration files..."

install -vdm755 /etc/pam.d

# system-account
cat > /etc/pam.d/system-account << "EOF"
# Begin /etc/pam.d/system-account

account   required    pam_unix.so

# End /etc/pam.d/system-account
EOF

# system-auth
cat > /etc/pam.d/system-auth << "EOF"
# Begin /etc/pam.d/system-auth

auth      required    pam_unix.so

# End /etc/pam.d/system-auth
EOF

# system-session
cat > /etc/pam.d/system-session << "EOF"
# Begin /etc/pam.d/system-session

session   required    pam_unix.so

# End /etc/pam.d/system-session
EOF

# system-password
cat > /etc/pam.d/system-password << "EOF"
# Begin /etc/pam.d/system-password

# use yescrypt hash for encryption, use shadow, and try to use any
# previously defined authentication token (chosen password) set by any
# prior module.
password  required    pam_unix.so       yescrypt shadow try_first_pass

# End /etc/pam.d/system-password
EOF

# Restrictive /etc/pam.d/other (denies access for unconfigured apps)
cat > /etc/pam.d/other << "EOF"
# Begin /etc/pam.d/other

auth        required        pam_warn.so
auth        required        pam_deny.so
account     required        pam_warn.so
account     required        pam_deny.so
password    required        pam_warn.so
password    required        pam_deny.so
session     required        pam_warn.so
session     required        pam_deny.so

# End /etc/pam.d/other
EOF

# Clean up
cd "$BUILD_DIR"
rm -rf Linux-PAM-*

log_info "Linux-PAM-1.7.1 installed successfully"
create_checkpoint "linux-pam"
}

# =====================================================================
# BLFS 4.2 Shadow-4.18.0 (Rebuild with PAM support)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/shadow.html
# =====================================================================
should_skip_package "shadow-pam" && { log_info "Skipping Shadow rebuild (already built with PAM)"; } || {
log_step "Rebuilding Shadow-4.18.0 with PAM support..."

# Check if source exists
if [ ! -f /sources/shadow-4.18.0.tar.xz ]; then
    log_error "shadow-4.18.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf shadow-*
tar -xf /sources/shadow-4.18.0.tar.xz
cd shadow-*

# Apply BLFS modifications
# Remove groups program (Coreutils version preferred)
sed -i 's/groups$(EXEEXT) //' src/Makefile.in

# Remove conflicting man pages
find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;

# Configure login.defs for YESCRYPT and proper paths
sed -e 's@#ENCRYPT_METHOD DES@ENCRYPT_METHOD YESCRYPT@' \
    -e 's@/var/spool/mail@/var/mail@'                   \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                  \
    -i etc/login.defs

# Configure with PAM support
./configure --sysconfdir=/etc   \
            --disable-static    \
            --without-libbsd    \
            --with-{b,yes}crypt

# Build
make

# Install (pamddir= prevents installing shipped PAM configs)
log_info "Installing Shadow with PAM support..."
make exec_prefix=/usr pamddir= install

# Install man pages
make -C man install-man

# Configure /etc/login.defs for PAM (comment out functions now handled by PAM)
log_info "Configuring /etc/login.defs for PAM..."
install -v -m644 /etc/login.defs /etc/login.defs.orig
for FUNCTION in FAIL_DELAY               \
                FAILLOG_ENAB             \
                LASTLOG_ENAB             \
                MAIL_CHECK_ENAB          \
                OBSCURE_CHECKS_ENAB      \
                PORTTIME_CHECKS_ENAB     \
                QUOTAS_ENAB              \
                CONSOLE MOTD_FILE        \
                FTMP_FILE NOLOGINS_FILE  \
                ENV_HZ PASS_MIN_LEN      \
                SU_WHEEL_ONLY            \
                PASS_CHANGE_TRIES        \
                PASS_ALWAYS_WARN         \
                CHFN_AUTH ENCRYPT_METHOD \
                ENVIRON_FILE
do
    sed -i "s/^${FUNCTION}/# &/" /etc/login.defs
done

# Create PAM configuration files for Shadow utilities
log_info "Creating PAM configuration files for Shadow..."

# login
cat > /etc/pam.d/login << "EOF"
# Begin /etc/pam.d/login

# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that the user is allowed to login
auth      requisite   pam_nologin.so

# Check to make sure that root is allowed to login
# Disabled by default. You will need to create /etc/securetty
# file for this module to function. See man 5 securetty.
#auth      required    pam_securetty.so

# Additional group memberships - disabled by default
#auth      optional    pam_group.so

# include system auth settings
auth      include     system-auth

# check access for the user
account   required    pam_access.so

# include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# Display the message of the day - Disabled by default
#session   optional    pam_motd.so

# Check user's mail - Disabled by default
#session   optional    pam_mail.so      standard quiet

# include system session and password settings
session   include     system-session
password  include     system-password

# End /etc/pam.d/login
EOF

# passwd
cat > /etc/pam.d/passwd << "EOF"
# Begin /etc/pam.d/passwd

password  include     system-password

# End /etc/pam.d/passwd
EOF

# su
cat > /etc/pam.d/su << "EOF"
# Begin /etc/pam.d/su

# always allow root
auth      sufficient  pam_rootok.so

# Allow users in the wheel group to execute su without a password
# disabled by default
#auth      sufficient  pam_wheel.so trust use_uid

# include system auth settings
auth      include     system-auth

# limit su to users in the wheel group
# disabled by default
#auth      required    pam_wheel.so use_uid

# include system account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session settings
session   include     system-session

# End /etc/pam.d/su
EOF

# chpasswd and newusers
cat > /etc/pam.d/chpasswd << "EOF"
# Begin /etc/pam.d/chpasswd

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account
password  include     system-password

# End /etc/pam.d/chpasswd
EOF
sed -e s/chpasswd/newusers/ /etc/pam.d/chpasswd > /etc/pam.d/newusers

# chage
cat > /etc/pam.d/chage << "EOF"
# Begin /etc/pam.d/chage

# always allow root
auth      sufficient  pam_rootok.so

# include system auth and account settings
auth      include     system-auth
account   include     system-account

# End /etc/pam.d/chage
EOF

# Other shadow utilities (chfn, chgpasswd, chsh, groupadd, etc.)
for PROGRAM in chfn chgpasswd chsh groupadd groupdel \
               groupmems groupmod useradd userdel usermod
do
    install -v -m644 /etc/pam.d/chage /etc/pam.d/${PROGRAM}
    sed -i "s/chage/$PROGRAM/" /etc/pam.d/${PROGRAM}
done

# Rename /etc/login.access if it exists
if [ -f /etc/login.access ]; then
    mv -v /etc/login.access /etc/login.access.NOUSE
fi

# Rename /etc/limits if it exists
if [ -f /etc/limits ]; then
    mv -v /etc/limits /etc/limits.NOUSE
fi

# Clean up
cd "$BUILD_DIR"
rm -rf shadow-*

log_info "Shadow-4.18.0 rebuilt with PAM support"
create_checkpoint "shadow-pam"
}

# =====================================================================
# BLFS 12.1 Systemd-257.8 (Rebuild with PAM support)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/systemd.html
# =====================================================================
should_skip_package "systemd-pam" && { log_info "Skipping systemd rebuild (already built with PAM)"; } || {
log_step "Rebuilding systemd-257.8 with PAM support..."

# Check if source exists
if [ ! -f /sources/systemd-257.8.tar.gz ]; then
    log_error "systemd-257.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf systemd-*
tar -xf /sources/systemd-257.8.tar.gz
cd systemd-*

# Remove unneeded groups from udev rules (BLFS modification)
sed -i -e 's/GROUP="render"/GROUP="video"/' \
       -e 's/GROUP="sgx", //' rules.d/50-udev-default.rules.in

# Create build directory
rm -rf build && mkdir build
cd build

# Configure with PAM support enabled
# Following BLFS 12.4 instructions exactly
meson setup ..                 \
      --prefix=/usr            \
      --buildtype=release      \
      -D default-dnssec=no     \
      -D firstboot=false       \
      -D install-tests=false   \
      -D ldconfig=false        \
      -D man=auto              \
      -D sysusers=false        \
      -D rpmmacrosdir=no       \
      -D homed=disabled        \
      -D userdb=false          \
      -D mode=release          \
      -D pam=enabled           \
      -D pamconfdir=/etc/pam.d \
      -D dev-kvm-mode=0660     \
      -D nobody-group=nogroup  \
      -D sysupdate=disabled    \
      -D ukify=disabled        \
      -D docdir=/usr/share/doc/systemd-257.8

# Build
ninja

# Install using DESTDIR to avoid post-install scripts that fail in chroot
# (systemd-hwdb update, journalctl --update-catalog, etc. require running system)
log_info "Installing systemd with PAM support..."
DESTDIR=/tmp/systemd-install ninja install

# Copy installed files to root filesystem
log_info "Copying systemd files to filesystem..."
cp -a /tmp/systemd-install/* /

# Update hwdb and catalog manually (these may fail in chroot but that's OK)
/usr/bin/systemd-hwdb update 2>/dev/null || log_warn "hwdb update skipped (will run on first boot)"
/usr/bin/journalctl --update-catalog 2>/dev/null || log_warn "catalog update skipped (will run on first boot)"

# Clean up temp install
rm -rf /tmp/systemd-install

# Configure PAM for systemd-logind
log_info "Configuring PAM for systemd-logind..."

# Add systemd session support to system-session
grep 'pam_systemd' /etc/pam.d/system-session || \
cat >> /etc/pam.d/system-session << "EOF"
# Begin Systemd addition

session  required    pam_loginuid.so
session  optional    pam_systemd.so

# End Systemd addition
EOF

# Create systemd-user PAM config
cat > /etc/pam.d/systemd-user << "EOF"
# Begin /etc/pam.d/systemd-user

account  required    pam_access.so
account  include     system-account

session  required    pam_env.so
session  required    pam_limits.so
session  required    pam_loginuid.so
session  optional    pam_keyinit.so force revoke
session  optional    pam_systemd.so

auth     required    pam_deny.so
password required    pam_deny.so

# End /etc/pam.d/systemd-user
EOF

# Clean up
cd "$BUILD_DIR"
rm -rf systemd-*

log_info "systemd-257.8 rebuilt with PAM support"
create_checkpoint "systemd-pam"
}

# =====================================================================
# BLFS 9.2 libgpg-error-1.58
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libgpg-error.html
# Required by: libgcrypt (and subsequently by many GNOME/KDE components)
# =====================================================================
should_skip_package "libgpg-error" && { log_info "Skipping libgpg-error (already built)"; } || {
log_step "Building libgpg-error-1.58..."

# Check if source exists
if [ ! -f /sources/libgpg-error-1.58.tar.bz2 ]; then
    log_error "libgpg-error-1.58.tar.bz2 not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libgpg-error-*
tar -xf /sources/libgpg-error-1.58.tar.bz2
cd libgpg-error-*

# Configure
./configure --prefix=/usr

# Build
make

# Run tests (optional but recommended)
log_info "Running libgpg-error tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing libgpg-error..."
make install

# Install documentation
install -v -m644 -D README /usr/share/doc/libgpg-error-1.58/README

# Clean up
cd "$BUILD_DIR"
rm -rf libgpg-error-*

log_info "libgpg-error-1.58 installed successfully"
create_checkpoint "libgpg-error"
}

# =====================================================================
# BLFS 9.1 libgcrypt-1.11.2
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libgcrypt.html
# Required by: many GNOME/KDE components, GnuPG, systemd-homed
# Depends on: libgpg-error
# =====================================================================
should_skip_package "libgcrypt" && { log_info "Skipping libgcrypt (already built)"; } || {
log_step "Building libgcrypt-1.11.2..."

# Check if source exists
if [ ! -f /sources/libgcrypt-1.11.2.tar.bz2 ]; then
    log_error "libgcrypt-1.11.2.tar.bz2 not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libgcrypt-*
tar -xf /sources/libgcrypt-1.11.2.tar.bz2
cd libgcrypt-*

# Configure
./configure --prefix=/usr

# Build
make

# Build documentation (optional - skip if texinfo not available)
if command -v makeinfo >/dev/null 2>&1; then
    log_info "Building libgcrypt documentation..."
    make -C doc html || log_warn "HTML docs failed (optional)"
    makeinfo --html --no-split -o doc/gcrypt_nochunks.html doc/gcrypt.texi 2>/dev/null || true
    makeinfo --plaintext -o doc/gcrypt.txt doc/gcrypt.texi 2>/dev/null || true
fi

# Run tests (optional but recommended)
log_info "Running libgcrypt tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing libgcrypt..."
make install

# Install documentation
install -v -dm755 /usr/share/doc/libgcrypt-1.11.2
install -v -m644 README doc/README.apichanges /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true

# Install HTML docs if they were built
if [ -d doc/gcrypt.html ]; then
    install -v -dm755 /usr/share/doc/libgcrypt-1.11.2/html
    install -v -m644 doc/gcrypt.html/* /usr/share/doc/libgcrypt-1.11.2/html/ 2>/dev/null || true
fi
if [ -f doc/gcrypt_nochunks.html ]; then
    install -v -m644 doc/gcrypt_nochunks.html /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true
fi
if [ -f doc/gcrypt.txt ]; then
    install -v -m644 doc/gcrypt.txt /usr/share/doc/libgcrypt-1.11.2/ 2>/dev/null || true
fi

# Clean up
cd "$BUILD_DIR"
rm -rf libgcrypt-*

log_info "libgcrypt-1.11.2 installed successfully"
create_checkpoint "libgcrypt"
}

# =====================================================================
# BLFS 4.4 Sudo-1.9.17p2
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/sudo.html
# Privilege escalation for authorized users
# Optional dependency: Linux-PAM (we have it installed)
# =====================================================================
should_skip_package "sudo" && { log_info "Skipping sudo (already built)"; } || {
log_step "Building sudo-1.9.17p2..."

# Check if source exists
if [ ! -f /sources/sudo-1.9.17p2.tar.gz ]; then
    log_error "sudo-1.9.17p2.tar.gz not found in /sources"
    log_error "Please download it first"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf sudo-*
tar -xf /sources/sudo-1.9.17p2.tar.gz
cd sudo-*

# Configure with PAM support (since we have Linux-PAM installed)
# Following BLFS 12.4 instructions exactly
./configure --prefix=/usr         \
            --libexecdir=/usr/lib \
            --with-secure-path    \
            --with-env-editor     \
            --docdir=/usr/share/doc/sudo-1.9.17p2 \
            --with-passprompt="[sudo] password for %p: "

# Build
make

# Run tests (optional)
log_info "Running sudo tests..."
env LC_ALL=C make check 2>&1 | tee make-check.log || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing sudo..."
make install

# Create sudoers.d directory
install -v -dm755 /etc/sudoers.d

# Create default sudo configuration for wheel group
log_info "Creating default sudo configuration..."
cat > /etc/sudoers.d/00-sudo << "EOF"
# Allow wheel group members to execute any command
Defaults secure_path="/usr/sbin:/usr/bin"
%wheel ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/00-sudo

# Create PAM configuration for sudo (since we have Linux-PAM)
log_info "Creating PAM configuration for sudo..."
cat > /etc/pam.d/sudo << "EOF"
# Begin /etc/pam.d/sudo

# include the default auth settings
auth      include     system-auth

# include the default account settings
account   include     system-account

# Set default environment variables for the service user
session   required    pam_env.so

# include system session defaults
session   include     system-session

# End /etc/pam.d/sudo
EOF
chmod 644 /etc/pam.d/sudo

# Clean up
cd "$BUILD_DIR"
rm -rf sudo-*

log_info "sudo-1.9.17p2 installed successfully"
create_checkpoint "sudo"
}

# =====================================================================
# BLFS 9.6 PCRE2-10.45
# https://www.linuxfromscratch.org/blfs/view/12.4/general/pcre2.html
# Perl Compatible Regular Expressions - required by GLib
# =====================================================================
should_skip_package "pcre2" && { log_info "Skipping pcre2 (already built)"; } || {
log_step "Building pcre2-10.45..."

if [ ! -f /sources/pcre2-10.45.tar.bz2 ]; then
    log_error "pcre2-10.45.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf pcre2-*
tar -xf /sources/pcre2-10.45.tar.bz2
cd pcre2-*

# Configure with full Unicode support and JIT compilation
./configure --prefix=/usr                       \
            --docdir=/usr/share/doc/pcre2-10.45 \
            --enable-unicode                    \
            --enable-jit                        \
            --enable-pcre2-16                   \
            --enable-pcre2-32                   \
            --enable-pcre2grep-libz             \
            --enable-pcre2grep-libbz2           \
            --enable-pcre2test-libreadline      \
            --disable-static

make

# Run tests
log_info "Running pcre2 tests..."
make check || log_warn "Some tests failed (may be expected)"

# Install
log_info "Installing pcre2..."
make install

cd "$BUILD_DIR"
rm -rf pcre2-*

log_info "pcre2-10.45 installed successfully"
create_checkpoint "pcre2"
}

# =====================================================================
# BLFS 9.x ICU-77.1 (International Components for Unicode)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/icu.html
# Recommended for libxml2, required for proper Unicode support
# =====================================================================
should_skip_package "icu" && { log_info "Skipping ICU (already built)"; } || {
log_step "Building ICU-77.1..."

if [ ! -f /sources/icu4c-77_1-src.tgz ]; then
    log_error "icu4c-77_1-src.tgz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf icu
tar -xf /sources/icu4c-77_1-src.tgz
cd icu/source

./configure --prefix=/usr

make

log_info "Installing ICU..."
make install

cd "$BUILD_DIR"
rm -rf icu

log_info "ICU-77.1 installed successfully"
create_checkpoint "icu"
}

# =====================================================================
# BLFS 9.3 duktape-2.7.0
# https://www.linuxfromscratch.org/blfs/view/12.4/general/duktape.html
# Embeddable JavaScript engine - required by polkit
# =====================================================================
should_skip_package "duktape" && { log_info "Skipping duktape (already built)"; } || {
log_step "Building duktape-2.7.0..."

if [ ! -f /sources/duktape-2.7.0.tar.xz ]; then
    log_error "duktape-2.7.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf duktape-*
tar -xf /sources/duktape-2.7.0.tar.xz
cd duktape-*

# Use -O2 instead of -Os for better performance
sed -i 's/-Os/-O2/' Makefile.sharedlibrary

# Build
make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr

# Install
log_info "Installing duktape..."
make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr install

cd "$BUILD_DIR"
rm -rf duktape-*

log_info "duktape-2.7.0 installed successfully"
create_checkpoint "duktape"
}

# =====================================================================
# BLFS 9.4 GLib-2.84.4 + GObject Introspection-1.84.0
# https://www.linuxfromscratch.org/blfs/view/12.4/general/glib2.html
# Low-level core library for GNOME - required by polkit
#
# This follows the BLFS approach of building gobject-introspection
# as a subdirectory within glib's build, which avoids library path
# issues that occur when building g-i as a standalone package.
# =====================================================================
should_skip_package "glib2-introspection" && { log_info "Skipping glib2 with introspection (already built)"; } || {
log_step "Building glib-2.84.4 with GObject Introspection (BLFS method)..."

if [ ! -f /sources/glib-2.84.4.tar.xz ]; then
    log_error "glib-2.84.4.tar.xz not found in /sources"
    exit 1
fi

if [ ! -f /sources/gobject-introspection-1.84.0.tar.xz ]; then
    log_error "gobject-introspection-1.84.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf glib-*
tar -xf /sources/glib-2.84.4.tar.xz
cd glib-*

# Create build directory
mkdir build
cd build

# Step 1: Configure glib WITHOUT introspection first
log_info "Step 1: Configuring glib without introspection..."
meson setup ..                  \
      --prefix=/usr             \
      --buildtype=release       \
      -D introspection=disabled \
      -D glib_debug=disabled    \
      -D man-pages=disabled     \
      -D sysprof=disabled       \
      -D tests=false

# Step 2: Build and install glib (needed before g-i can build)
log_info "Step 2: Building and installing glib..."
ninja
ninja install
ldconfig

# Step 3: Extract gobject-introspection INSIDE the glib build directory
# This is the key BLFS technique - g-i is built as a subdirectory
log_info "Step 3: Extracting gobject-introspection inside glib build..."
tar xf /sources/gobject-introspection-1.84.0.tar.xz

# Step 4: Configure gobject-introspection as a subdirectory
log_info "Step 4: Configuring gobject-introspection..."
meson setup gobject-introspection-1.84.0 gi-build \
            --prefix=/usr --buildtype=release

# Step 4a: Build the library first
log_info "Step 4a: Building libgirepository-1.0..."
ninja -C gi-build girepository/libgirepository-1.0.so.1.0.0

# Step 4b: Install libgirepository-1.0 to system before running tools
log_info "Step 4b: Installing libgirepository-1.0 to /usr/lib..."
cp gi-build/girepository/libgirepository-1.0.so.1.0.0 /usr/lib/
ln -sf libgirepository-1.0.so.1.0.0 /usr/lib/libgirepository-1.0.so.1
ln -sf libgirepository-1.0.so.1 /usr/lib/libgirepository-1.0.so
ldconfig

# Step 4c: Complete the build (g-ir-compiler will now find the library)
log_info "Step 4c: Completing gobject-introspection build..."
ninja -C gi-build

# Step 5: Install gobject-introspection
log_info "Step 5: Installing gobject-introspection..."
ninja -C gi-build install
ldconfig

# Step 6: Re-enable introspection in glib and rebuild
log_info "Step 6: Rebuilding glib with introspection enabled..."
meson configure -D introspection=enabled
ninja

# Step 7: Install glib with introspection data
log_info "Step 7: Installing glib with introspection data..."
ninja install
ldconfig

cd "$BUILD_DIR"
rm -rf glib-*

log_info "glib-2.84.4 with gobject-introspection-1.84.0 installed successfully"
create_checkpoint "glib2-introspection"
}

# =====================================================================
# BLFS 4.5 Polkit-126
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/polkit.html
# Authorization toolkit for controlling system-wide privileges
# Depends on: duktape, glib2, Linux-PAM (we have all of these)
# =====================================================================
should_skip_package "polkit" && { log_info "Skipping polkit (already built)"; } || {
log_step "Building polkit-126..."

if [ ! -f /sources/polkit-126.tar.gz ]; then
    log_error "polkit-126.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf polkit-*
tar -xf /sources/polkit-126.tar.gz
cd polkit-*

# Create polkitd user and group
log_info "Creating polkitd user and group..."
groupadd -fg 27 polkitd 2>/dev/null || true
useradd -c "PolicyKit Daemon Owner" -d /etc/polkit-1 -u 27 \
        -g polkitd -s /bin/false polkitd 2>/dev/null || true

# Create build directory
rm -rf build && mkdir build
cd build

# Configure with PAM and systemd-logind session tracking
# Disable man pages (requires libxslt/docbook)
# Use os_type=lfs since we don't have /etc/lfs-release
meson setup ..                   \
      --prefix=/usr              \
      --buildtype=release        \
      -D man=false               \
      -D session_tracking=logind \
      -D os_type=lfs             \
      -D introspection=false     \
      -D tests=false

# Build
ninja

# Install
log_info "Installing polkit..."
ninja install

cd "$BUILD_DIR"
rm -rf polkit-*

log_info "polkit-126 installed successfully"
create_checkpoint "polkit"
}

# =====================================================================
# CMake-4.1.0 (build system - required by c-ares, libproxy, etc.)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/cmake.html
# Uses bootstrap (no cmake required to build)
# =====================================================================
should_skip_package "cmake" && { log_info "Skipping cmake (already built)"; } || {
log_step "Building cmake-4.1.0..."

if [ ! -f /sources/cmake-4.1.0.tar.gz ]; then
    log_error "cmake-4.1.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"

# Clean any previous cmake build attempt
rm -rf cmake-*

tar -xf /sources/cmake-4.1.0.tar.gz
cd cmake-4.1.0

# Fix lib64 path
sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake

# Bootstrap and build CMake
# Using bundled versions for all optional dependencies to minimize build issues
# --no-system-form disables curses form library requirement
./bootstrap --prefix=/usr        \
            --mandir=/share/man  \
            --no-system-jsoncpp  \
            --no-system-cppdap   \
            --no-system-librhash \
            --no-system-curl     \
            --no-system-libarchive \
            --no-system-libuv    \
            --no-system-nghttp2  \
            --no-qt-gui          \
            --docdir=/share/doc/cmake-4.1.0 \
            --parallel=4         \
            -- -DCMAKE_USE_OPENSSL=ON -DBUILD_CursesDialog=OFF

make

# Install
log_info "Installing cmake..."
make install

cd "$BUILD_DIR"
rm -rf cmake-*

log_info "cmake-4.1.0 installed successfully"
create_checkpoint "cmake"
}

# #####################################################################
# TIER 2: NETWORKING & PROTOCOLS
# #####################################################################

# =====================================================================
# libmnl-1.0.5 (Netfilter minimalistic library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libmnl.html
# Required by: iptables
# =====================================================================
should_skip_package "libmnl" && { log_info "Skipping libmnl (already built)"; } || {
log_step "Building libmnl-1.0.5..."

if [ ! -f /sources/libmnl-1.0.5.tar.bz2 ]; then
    log_error "libmnl-1.0.5.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libmnl-*
tar -xf /sources/libmnl-1.0.5.tar.bz2
cd libmnl-*

./configure --prefix=/usr

make

log_info "Installing libmnl..."
make install

cd "$BUILD_DIR"
rm -rf libmnl-*

log_info "libmnl-1.0.5 installed successfully"
create_checkpoint "libmnl"
}

# =====================================================================
# libevent-2.1.12 (Event notification library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libevent.html
# =====================================================================
should_skip_package "libevent" && { log_info "Skipping libevent (already built)"; } || {
log_step "Building libevent-2.1.12..."

if [ ! -f /sources/libevent-2.1.12-stable.tar.gz ]; then
    log_error "libevent-2.1.12-stable.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libevent-*
tar -xf /sources/libevent-2.1.12-stable.tar.gz
cd libevent-*

# Disable building of doxygen docs
sed -i 's/python/python3/' event_rpcgen.py

./configure --prefix=/usr --disable-static

make

log_info "Installing libevent..."
make install

cd "$BUILD_DIR"
rm -rf libevent-*

log_info "libevent-2.1.12 installed successfully"
create_checkpoint "libevent"
}

# =====================================================================
# c-ares-1.34.5 (Async DNS resolver)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/c-ares.html
# Required by: curl (optional)
# =====================================================================
should_skip_package "c-ares" && { log_info "Skipping c-ares (already built)"; } || {
log_step "Building c-ares-1.34.5..."

if [ ! -f /sources/c-ares-1.34.5.tar.gz ]; then
    log_error "c-ares-1.34.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf c-ares-*
tar -xf /sources/c-ares-1.34.5.tar.gz
cd c-ares-*

rm -rf build && mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release  \
      ..

make

log_info "Installing c-ares..."
make install

cd "$BUILD_DIR"
rm -rf c-ares-*

log_info "c-ares-1.34.5 installed successfully"
create_checkpoint "c-ares"
}

# =====================================================================
# libdaemon-0.14 (Unix daemon library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libdaemon.html
# Required by: avahi
# =====================================================================
should_skip_package "libdaemon" && { log_info "Skipping libdaemon (already built)"; } || {
log_step "Building libdaemon-0.14..."

if [ ! -f /sources/libdaemon-0.14.tar.gz ]; then
    log_error "libdaemon-0.14.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libdaemon-*
tar -xf /sources/libdaemon-0.14.tar.gz
cd libdaemon-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libdaemon..."
make install

cd "$BUILD_DIR"
rm -rf libdaemon-*

log_info "libdaemon-0.14 installed successfully"
create_checkpoint "libdaemon"
}

# =====================================================================
# Avahi-0.8 (mDNS/DNS-SD service discovery)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/avahi.html
# Depends on: glib2, libdaemon (we have both)
# =====================================================================
should_skip_package "avahi" && { log_info "Skipping Avahi (already built)"; } || {
log_step "Building Avahi-0.8..."

if [ ! -f /sources/avahi-0.8.tar.gz ]; then
    log_error "avahi-0.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf avahi-*
tar -xf /sources/avahi-0.8.tar.gz
cd avahi-*

# Create avahi user and group
groupadd -fg 84 avahi 2>/dev/null || true
useradd -c "Avahi Daemon Owner" -d /run/avahi-daemon -u 84 \
        -g avahi -s /bin/false avahi 2>/dev/null || true

# Create netdev group for privileged access (may already exist from NetworkManager)
groupadd -fg 86 netdev 2>/dev/null || true

# Apply IPv6 race condition fix patch
if [ -f /sources/avahi-0.8-ipv6_race_condition_fix-1.patch ]; then
    log_info "Applying IPv6 race condition fix patch..."
    patch -Np1 -i /sources/avahi-0.8-ipv6_race_condition_fix-1.patch
fi

# Fix security vulnerability in avahi-daemon
sed -i '426a if (events & AVAHI_WATCH_HUP) { \
client_free(c); \
return; \
}' avahi-daemon/simple-protocol.c

# Configure - disable GTK (we don't have it yet), enable libevent (we have it)
./configure \
    --prefix=/usr        \
    --sysconfdir=/etc    \
    --localstatedir=/var \
    --disable-static     \
    --disable-mono       \
    --disable-monodoc    \
    --disable-python     \
    --disable-qt3        \
    --disable-qt4        \
    --disable-qt5        \
    --disable-gtk        \
    --disable-gtk3       \
    --enable-core-docs   \
    --with-distro=none   \
    --with-dbus-system-address='unix:path=/run/dbus/system_bus_socket'

make

log_info "Installing Avahi..."
make install

# Enable systemd services
systemctl enable avahi-daemon 2>/dev/null || true

cd "$BUILD_DIR"
rm -rf avahi-*

log_info "Avahi-0.8 installed successfully"
create_checkpoint "avahi"
}

# =====================================================================
# libpcap-1.10.5 (Packet capture library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libpcap.html
# =====================================================================
should_skip_package "libpcap" && { log_info "Skipping libpcap (already built)"; } || {
log_step "Building libpcap-1.10.5..."

if [ ! -f /sources/libpcap-1.10.5.tar.xz ]; then
    log_error "libpcap-1.10.5.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libpcap-*
tar -xf /sources/libpcap-1.10.5.tar.xz
cd libpcap-*

./configure --prefix=/usr

make

log_info "Installing libpcap..."
make install

cd "$BUILD_DIR"
rm -rf libpcap-*

log_info "libpcap-1.10.5 installed successfully"
create_checkpoint "libpcap"
}

# =====================================================================
# libunistring-1.3 (Unicode string library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libunistring.html
# Required by: libidn2
# =====================================================================
should_skip_package "libunistring" && { log_info "Skipping libunistring (already built)"; } || {
log_step "Building libunistring-1.3..."

if [ ! -f /sources/libunistring-1.3.tar.xz ]; then
    log_error "libunistring-1.3.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libunistring-*
tar -xf /sources/libunistring-1.3.tar.xz
cd libunistring-*

./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/libunistring-1.3

make

log_info "Installing libunistring..."
make install

cd "$BUILD_DIR"
rm -rf libunistring-*

log_info "libunistring-1.3 installed successfully"
create_checkpoint "libunistring"
}

# =====================================================================
# libnl-3.11.0 (Netlink library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libnl.html
# Required by: wpa_supplicant, NetworkManager
# =====================================================================
should_skip_package "libnl" && { log_info "Skipping libnl (already built)"; } || {
log_step "Building libnl-3.11.0..."

if [ ! -f /sources/libnl-3.11.0.tar.gz ]; then
    log_error "libnl-3.11.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libnl-*
tar -xf /sources/libnl-3.11.0.tar.gz
cd libnl-*

./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-static

make

log_info "Installing libnl..."
make install

cd "$BUILD_DIR"
rm -rf libnl-*

log_info "libnl-3.11.0 installed successfully"
create_checkpoint "libnl"
}

# =====================================================================
# libxml2-2.14.5 (XML parser library - required by libxslt)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libxml2.html
# =====================================================================
should_skip_package "libxml2" && { log_info "Skipping libxml2 (already built)"; } || {
log_step "Building libxml2-2.14.5..."

if [ ! -f /sources/libxml2-2.14.5.tar.xz ]; then
    log_error "libxml2-2.14.5.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libxml2-*
tar -xf /sources/libxml2-2.14.5.tar.xz
cd libxml2-*

# Build with ICU for proper Unicode support (per BLFS 12.4 recommendation)
./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-static  \
            --with-history    \
            --with-icu        \
            PYTHON=/usr/bin/python3 \
            --docdir=/usr/share/doc/libxml2-2.14.5

make

log_info "Installing libxml2..."
make install

# Remove .la file and fix xml2-config to prevent unnecessary ICU linking
rm -vf /usr/lib/libxml2.la
sed '/libs=/s/xml2.*/xml2"/' -i /usr/bin/xml2-config

cd "$BUILD_DIR"
rm -rf libxml2-*

log_info "libxml2-2.14.5 installed successfully"
create_checkpoint "libxml2"
}

# =====================================================================
# libxslt-1.1.43 (XSLT processor)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libxslt.html
# =====================================================================
should_skip_package "libxslt" && { log_info "Skipping libxslt (already built)"; } || {
log_step "Building libxslt-1.1.43..."

if [ ! -f /sources/libxslt-1.1.43.tar.xz ]; then
    log_error "libxslt-1.1.43.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libxslt-*
tar -xf /sources/libxslt-1.1.43.tar.xz
cd libxslt-*

./configure --prefix=/usr                          \
            --disable-static                       \
            --docdir=/usr/share/doc/libxslt-1.1.43 \
            PYTHON=/usr/bin/python3

make

log_info "Installing libxslt..."
make install

cd "$BUILD_DIR"
rm -rf libxslt-*

log_info "libxslt-1.1.43 installed successfully"
create_checkpoint "libxslt"
}

# =====================================================================
# dhcpcd-10.2.4 (DHCP client)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/dhcpcd.html
# =====================================================================
should_skip_package "dhcpcd" && { log_info "Skipping dhcpcd (already built)"; } || {
log_step "Building dhcpcd-10.2.4..."

if [ ! -f /sources/dhcpcd-10.2.4.tar.xz ]; then
    log_error "dhcpcd-10.2.4.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf dhcpcd-*
tar -xf /sources/dhcpcd-10.2.4.tar.xz
cd dhcpcd-*

# Create dhcpcd user
groupadd -g 52 dhcpcd 2>/dev/null || true
useradd -c "dhcpcd Privilege Separation" -g dhcpcd -s /bin/false \
        -u 52 dhcpcd 2>/dev/null || true

./configure --prefix=/usr                \
            --sysconfdir=/etc            \
            --libexecdir=/usr/lib/dhcpcd \
            --dbdir=/var/lib/dhcpcd      \
            --runstatedir=/run           \
            --privsepuser=dhcpcd

make

log_info "Installing dhcpcd..."
make install

cd "$BUILD_DIR"
rm -rf dhcpcd-*

log_info "dhcpcd-10.2.4 installed successfully"
create_checkpoint "dhcpcd"
}

# =====================================================================
# libtasn1-4.20.0 (ASN.1 library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libtasn1.html
# Required by: p11-kit, GnuTLS
# =====================================================================
should_skip_package "libtasn1" && { log_info "Skipping libtasn1 (already built)"; } || {
log_step "Building libtasn1-4.20.0..."

if [ ! -f /sources/libtasn1-4.20.0.tar.gz ]; then
    log_error "libtasn1-4.20.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libtasn1-*
tar -xf /sources/libtasn1-4.20.0.tar.gz
cd libtasn1-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libtasn1..."
make install

cd "$BUILD_DIR"
rm -rf libtasn1-*

log_info "libtasn1-4.20.0 installed successfully"
create_checkpoint "libtasn1"
}

# =====================================================================
# nettle-3.10.2 (Crypto library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/nettle.html
# Required by: GnuTLS
# =====================================================================
should_skip_package "nettle" && { log_info "Skipping nettle (already built)"; } || {
log_step "Building nettle-3.10.2..."

if [ ! -f /sources/nettle-3.10.2.tar.gz ]; then
    log_error "nettle-3.10.2.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf nettle-*
tar -xf /sources/nettle-3.10.2.tar.gz
cd nettle-*

./configure --prefix=/usr --disable-static

make

log_info "Installing nettle..."
make install
chmod -v 755 /usr/lib/lib{hogweed,nettle}.so

cd "$BUILD_DIR"
rm -rf nettle-*

log_info "nettle-3.10.2 installed successfully"
create_checkpoint "nettle"
}

# =====================================================================
# p11-kit-0.25.5 (PKCS#11 library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/p11-kit.html
# Required by: GnuTLS
# Depends on: libtasn1
# =====================================================================
should_skip_package "p11-kit" && { log_info "Skipping p11-kit (already built)"; } || {
log_step "Building p11-kit-0.25.5..."

if [ ! -f /sources/p11-kit-0.25.5.tar.xz ]; then
    log_error "p11-kit-0.25.5.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf p11-kit-*
tar -xf /sources/p11-kit-0.25.5.tar.xz
cd p11-kit-*

# Prepare the distribution specific anchor hook (per BLFS 12.4)
sed '20,$ d' -i trust/trust-extract-compat

cat >> trust/trust-extract-compat << "EOF"
# Copy existing anchor modifications to /etc/ssl/local
/usr/libexec/make-ca/copy-trust-modifications

# Update trust stores
/usr/sbin/make-ca -r
EOF

rm -rf p11-build && mkdir p11-build
cd p11-build

meson setup ..            \
      --prefix=/usr       \
      --buildtype=release \
      -D trust_paths=/etc/pki/anchors

ninja

log_info "Installing p11-kit..."
ninja install

# Create symlink for SSL
ln -sfv /usr/libexec/p11-kit/trust-extract-compat \
        /usr/bin/update-ca-certificates

# Create libnssckbi.so symlink for NSS
ln -sfv ./pkcs11/p11-kit-trust.so /usr/lib/libnssckbi.so

cd "$BUILD_DIR"
rm -rf p11-kit-*

log_info "p11-kit-0.25.5 installed successfully"
create_checkpoint "p11-kit"
}

# =====================================================================
# make-ca-1.16.1 (CA certificates management)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/make-ca.html
# Required by: GnuTLS, OpenSSL for proper TLS verification
# Depends on: p11-kit (runtime)
# =====================================================================
should_skip_package "make-ca" && { log_info "Skipping make-ca (already built)"; } || {
log_step "Installing make-ca-1.16.1..."

if [ ! -f /sources/make-ca-1.16.1.tar.gz ]; then
    log_error "make-ca-1.16.1.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf make-ca-*
tar -xf /sources/make-ca-1.16.1.tar.gz
cd make-ca-*

make install
install -vdm755 /etc/ssl/local

log_info "Running make-ca to populate CA certificates..."
/usr/sbin/make-ca -g || log_warn "make-ca -g failed (may need network access)"

cd "$BUILD_DIR"
rm -rf make-ca-*

log_info "make-ca-1.16.1 installed successfully"
create_checkpoint "make-ca"
}

# =====================================================================
# GnuTLS-3.8.10 (TLS library)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/gnutls.html
# Required by: wget (optional), NetworkManager (optional)
# Depends on: libtasn1, nettle, p11-kit
# =====================================================================
should_skip_package "gnutls" && { log_info "Skipping GnuTLS (already built)"; } || {
log_step "Building GnuTLS-3.8.10..."

if [ ! -f /sources/gnutls-3.8.10.tar.xz ]; then
    log_error "gnutls-3.8.10.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf gnutls-*
tar -xf /sources/gnutls-3.8.10.tar.xz
cd gnutls-*

./configure --prefix=/usr \
            --docdir=/usr/share/doc/gnutls-3.8.10 \
            --disable-guile \
            --disable-rpath \
            --with-default-trust-store-pkcs11="pkcs11:"

make

log_info "Installing GnuTLS..."
make install

cd "$BUILD_DIR"
rm -rf gnutls-*

log_info "GnuTLS-3.8.10 installed successfully"
create_checkpoint "gnutls"
}

# =====================================================================
# libidn2-2.3.8 (IDN library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libidn2.html
# Required by: libpsl, wget
# Depends on: libunistring
# =====================================================================
should_skip_package "libidn2" && { log_info "Skipping libidn2 (already built)"; } || {
log_step "Building libidn2-2.3.8..."

if [ ! -f /sources/libidn2-2.3.8.tar.gz ]; then
    log_error "libidn2-2.3.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libidn2-*
tar -xf /sources/libidn2-2.3.8.tar.gz
cd libidn2-*

./configure --prefix=/usr --disable-static

make

log_info "Installing libidn2..."
make install

cd "$BUILD_DIR"
rm -rf libidn2-*

log_info "libidn2-2.3.8 installed successfully"
create_checkpoint "libidn2"
}

# =====================================================================
# libpsl-0.21.5 (Public Suffix List library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libpsl.html
# Required by: curl, wget
# Depends on: libidn2, libunistring
# =====================================================================
should_skip_package "libpsl" && { log_info "Skipping libpsl (already built)"; } || {
log_step "Building libpsl-0.21.5..."

if [ ! -f /sources/libpsl-0.21.5.tar.gz ]; then
    log_error "libpsl-0.21.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libpsl-*
tar -xf /sources/libpsl-0.21.5.tar.gz
cd libpsl-*

rm -rf build && mkdir build
cd build

meson setup --prefix=/usr --buildtype=release ..

ninja

log_info "Installing libpsl..."
ninja install

cd "$BUILD_DIR"
rm -rf libpsl-*

log_info "libpsl-0.21.5 installed successfully"
create_checkpoint "libpsl"
}

# =====================================================================
# iptables-1.8.11 (Firewall)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/iptables.html
# Required by: NetworkManager (optional)
# Depends on: libmnl
# =====================================================================
should_skip_package "iptables" && { log_info "Skipping iptables (already built)"; } || {
log_step "Building iptables-1.8.11..."

if [ ! -f /sources/iptables-1.8.11.tar.xz ]; then
    log_error "iptables-1.8.11.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf iptables-*
tar -xf /sources/iptables-1.8.11.tar.xz
cd iptables-*

./configure --prefix=/usr      \
            --disable-nftables \
            --enable-libipq

make

log_info "Installing iptables..."
make install

cd "$BUILD_DIR"
rm -rf iptables-*

log_info "iptables-1.8.11 installed successfully"
create_checkpoint "iptables"
}

# =====================================================================
# wpa_supplicant-2.11 (WiFi client)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/wpa_supplicant.html
# Depends on: libnl
# =====================================================================
should_skip_package "wpa_supplicant" && { log_info "Skipping wpa_supplicant (already built)"; } || {
log_step "Building wpa_supplicant-2.11..."

if [ ! -f /sources/wpa_supplicant-2.11.tar.gz ]; then
    log_error "wpa_supplicant-2.11.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf wpa_supplicant-*
tar -xf /sources/wpa_supplicant-2.11.tar.gz
cd wpa_supplicant-*/wpa_supplicant

# Create configuration file
cat > .config << "EOF"
CONFIG_BACKEND=file
CONFIG_CTRL_IFACE=y
CONFIG_DEBUG_FILE=y
CONFIG_DEBUG_SYSLOG=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_DRIVER_WIRED=y
CONFIG_EAP_GTC=y
CONFIG_EAP_LEAP=y
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_OTP=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TLS=y
CONFIG_EAP_TTLS=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_IPV6=y
CONFIG_LIBNL32=y
CONFIG_PEERKEY=y
CONFIG_PKCS12=y
CONFIG_READLINE=y
CONFIG_SMARTCARD=y
CONFIG_WPS=y
CFLAGS += -I/usr/include/libnl3
EOF

make BINDIR=/usr/sbin LIBDIR=/usr/lib

log_info "Installing wpa_supplicant..."
install -v -m755 wpa_{cli,passphrase,supplicant} /usr/sbin/

# Install systemd unit
install -v -m644 systemd/*.service /usr/lib/systemd/system/

cd "$BUILD_DIR"
rm -rf wpa_supplicant-*

log_info "wpa_supplicant-2.11 installed successfully"
create_checkpoint "wpa_supplicant"
}

# =====================================================================
# curl-8.15.0 (HTTP client library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/curl.html
# Required by: libproxy
# Depends on: c-ares (optional), libpsl
# =====================================================================
should_skip_package "curl" && { log_info "Skipping curl (already built)"; } || {
log_step "Building curl-8.15.0..."

if [ ! -f /sources/curl-8.15.0.tar.xz ]; then
    log_error "curl-8.15.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf curl-*
tar -xf /sources/curl-8.15.0.tar.xz
cd curl-*

./configure --prefix=/usr                           \
            --disable-static                        \
            --with-openssl                          \
            --enable-threaded-resolver              \
            --with-ca-path=/etc/ssl/certs

make

log_info "Installing curl..."
make install

cd "$BUILD_DIR"
rm -rf curl-*

log_info "curl-8.15.0 installed successfully"
create_checkpoint "curl"
}

# =====================================================================
# Vala-0.56.18 (Vala compiler)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/vala.html
# Required by: many GNOME applications, libproxy (optional)
# Depends on: GLib with GObject Introspection
# =====================================================================
should_skip_package "vala" && { log_info "Skipping Vala (already built)"; } || {
log_step "Building Vala-0.56.18..."

if [ ! -f /sources/vala-0.56.18.tar.xz ]; then
    log_error "vala-0.56.18.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf vala-*
tar -xf /sources/vala-0.56.18.tar.xz
cd vala-*

# Configure without valadoc (requires Graphviz which we don't have yet)
./configure --prefix=/usr --disable-valadoc

make

log_info "Installing Vala..."
make install

cd "$BUILD_DIR"
rm -rf vala-*

log_info "Vala-0.56.18 installed successfully"
create_checkpoint "vala"
}

# =====================================================================
# gsettings-desktop-schemas-48.0 (GNOME settings schemas)
# https://www.linuxfromscratch.org/blfs/view/12.4/gnome/gsettings-desktop-schemas.html
# Required for libproxy GNOME integration
# =====================================================================
should_skip_package "gsettings-desktop-schemas" && { log_info "Skipping gsettings-desktop-schemas (already built)"; } || {
log_step "Building gsettings-desktop-schemas-48.0..."

if [ ! -f /sources/gsettings-desktop-schemas-48.0.tar.xz ]; then
    log_error "gsettings-desktop-schemas-48.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf gsettings-desktop-schemas-*
tar -xf /sources/gsettings-desktop-schemas-48.0.tar.xz
cd gsettings-desktop-schemas-*

# Fix deprecated entries in schema templates (from BLFS)
sed -i -r 's:"(/system):"/org/gnome\1:g' schemas/*.in

rm -rf build && mkdir build
cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            ..

ninja

log_info "Installing gsettings-desktop-schemas..."
ninja install

# Compile schemas
glib-compile-schemas /usr/share/glib-2.0/schemas

cd "$BUILD_DIR"
rm -rf gsettings-desktop-schemas-*

log_info "gsettings-desktop-schemas-48.0 installed successfully"
create_checkpoint "gsettings-desktop-schemas"
}

# =====================================================================
# libproxy-0.5.10 (Proxy configuration library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libproxy.html
# Optional for wget
# =====================================================================
should_skip_package "libproxy" && { log_info "Skipping libproxy (already built)"; } || {
log_step "Building libproxy-0.5.10..."

if [ ! -f /sources/libproxy-0.5.10.tar.gz ]; then
    log_error "libproxy-0.5.10.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libproxy-*
tar -xf /sources/libproxy-0.5.10.tar.gz
cd libproxy-*

rm -rf build && mkdir build

# Prevent any attempt to use gi-docgen subproject (would require git)
# Remove the wrap file AND remove docs from meson.build
rm -rf subprojects/gi-docgen.wrap 2>/dev/null || true
rm -rf subprojects 2>/dev/null || true

# Patch meson.build to skip docs entirely
sed -i '/subdir.*docs/d' meson.build

cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            ..

ninja

log_info "Installing libproxy..."
ninja install

cd "$BUILD_DIR"
rm -rf libproxy-*

log_info "libproxy-0.5.10 installed successfully"
create_checkpoint "libproxy"
}

# =====================================================================
# wget-1.25.0 (HTTP/FTP downloader)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/wget.html
# Depends on: libpsl (recommended), libidn2 (optional), libproxy (optional)
# =====================================================================
should_skip_package "wget" && { log_info "Skipping wget (already built)"; } || {
log_step "Building wget-1.25.0..."

if [ ! -f /sources/wget-1.25.0.tar.gz ]; then
    log_error "wget-1.25.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf wget-*
tar -xf /sources/wget-1.25.0.tar.gz
cd wget-*

./configure --prefix=/usr      \
            --sysconfdir=/etc  \
            --with-ssl=openssl \
            --enable-libproxy

make

log_info "Installing wget..."
make install

cd "$BUILD_DIR"
rm -rf wget-*

log_info "wget-1.25.0 installed successfully"
create_checkpoint "wget"
}

# =====================================================================
# libndp-1.9 (Neighbor Discovery Protocol library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/libndp.html
# Required by: NetworkManager
# =====================================================================
should_skip_package "libndp" && { log_info "Skipping libndp (already built)"; } || {
log_step "Building libndp-1.9..."

if [ ! -f /sources/libndp-1.9.tar.gz ]; then
    log_error "libndp-1.9.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libndp-*
tar -xf /sources/libndp-1.9.tar.gz
cd libndp-*

# libndp from github needs autoreconf
autoreconf -fiv

./configure --prefix=/usr        \
            --sysconfdir=/etc    \
            --localstatedir=/var \
            --disable-static

make

log_info "Installing libndp..."
make install

cd "$BUILD_DIR"
rm -rf libndp-*

log_info "libndp-1.9 installed successfully"
create_checkpoint "libndp"
}

# =====================================================================
# NetworkManager-1.54.0 (Network management)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/networkmanager.html
# Depends on: curl, dhcpcd, libndp, libnl, libpsl, polkit, wpa_supplicant
# =====================================================================
should_skip_package "networkmanager" && { log_info "Skipping NetworkManager (already built)"; } || {
log_step "Building NetworkManager-1.54.0..."

if [ ! -f /sources/NetworkManager-1.54.0.tar.xz ]; then
    log_error "NetworkManager-1.54.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf NetworkManager-*
tar -xf /sources/NetworkManager-1.54.0.tar.xz
cd NetworkManager-*

# Create networkmanager group
groupadd -fg 86 netdev 2>/dev/null || true

rm -rf build && mkdir build
cd build

# Following BLFS configuration exactly
meson setup ..                        \
      --prefix=/usr                   \
      --buildtype=release             \
      -D libaudit=no                  \
      -D nmtui=false                  \
      -D ovs=false                    \
      -D ppp=false                    \
      -D nbft=false                   \
      -D selinux=false                \
      -D qt=false                     \
      -D session_tracking=systemd     \
      -D nm_cloud_setup=false         \
      -D modem_manager=false          \
      -D crypto=gnutls                \
      -D introspection=false          \
      -D docs=false

ninja

log_info "Installing NetworkManager..."
ninja install

# Create /etc/NetworkManager
install -vdm755 /etc/NetworkManager

# Create basic configuration
cat > /etc/NetworkManager/NetworkManager.conf << "EOF"
[main]
plugins=keyfile
EOF

cd "$BUILD_DIR"
rm -rf NetworkManager-*

log_info "NetworkManager-1.54.0 installed successfully"
create_checkpoint "networkmanager"
}

# #####################################################################
# TIER 3: Graphics Foundation (X11/Wayland)
# #####################################################################

# =====================================================================
# Xorg Build Environment Setup
# =====================================================================
setup_xorg_env() {
    log_step "Setting up Xorg build environment"

    # Set XORG_PREFIX - using /usr for system integration
    export XORG_PREFIX="/usr"
    export XORG_CONFIG="--prefix=$XORG_PREFIX --sysconfdir=/etc \
        --localstatedir=/var --disable-static"

    # Create font directories
    mkdir -pv /usr/share/fonts/{X11-OTF,X11-TTF}

    log_info "Xorg environment configured with XORG_PREFIX=$XORG_PREFIX"
}

# =====================================================================
# util-macros-1.20.2 (Xorg build macros)
# =====================================================================
build_util_macros() {
    should_skip_package "util-macros" && { log_info "util-macros already built, skipping..."; return 0; }

    log_step "Building util-macros-1.20.2"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/util-macros-1.20.2.tar.xz
    cd util-macros-1.20.2

    ./configure $XORG_CONFIG

    make install

    cd "$BUILD_DIR"
    rm -rf util-macros-1.20.2

    log_info "util-macros-1.20.2 installed successfully"
    create_checkpoint "util-macros"
}

# =====================================================================
# xorgproto-2024.1 (Xorg protocol headers)
# =====================================================================
build_xorgproto() {
    should_skip_package "xorgproto" && { log_info "xorgproto already built, skipping..."; return 0; }

    log_step "Building xorgproto-2024.1"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/xorgproto-2024.1.tar.xz
    cd xorgproto-2024.1

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX ..

    ninja install

    cd "$BUILD_DIR"
    rm -rf xorgproto-2024.1

    log_info "xorgproto-2024.1 installed successfully"
    create_checkpoint "xorgproto"
}

# =====================================================================
# Wayland-1.24.0 (Wayland compositor protocol)
# =====================================================================
build_wayland() {
    should_skip_package "wayland" && { log_info "wayland already built, skipping..."; return 0; }

    log_step "Building Wayland-1.24.0"
    cd "$BUILD_DIR"

    tar -xf /sources/wayland-1.24.0.tar.xz
    cd wayland-1.24.0

    mkdir build && cd build

    meson setup ..            \
          --prefix=/usr       \
          --buildtype=release \
          -D documentation=false

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf wayland-1.24.0

    log_info "Wayland-1.24.0 installed successfully"
    create_checkpoint "wayland"
}

# =====================================================================
# Wayland-Protocols-1.45
# =====================================================================
build_wayland_protocols() {
    if should_skip_package "wayland-protocols"; then
        log_info "wayland-protocols already built, skipping..."
        return 0
    fi

    log_step "Building Wayland-Protocols-1.45"
    cd "$BUILD_DIR"

    tar -xf /sources/wayland-protocols-1.45.tar.xz
    cd wayland-protocols-1.45

    mkdir build && cd build

    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf wayland-protocols-1.45

    log_info "Wayland-Protocols-1.45 installed successfully"
    create_checkpoint "wayland-protocols"
}

# =====================================================================
# libXau-1.0.12 (X11 Authorization Library)
# =====================================================================
build_libXau() {
    if should_skip_package "libXau"; then
        log_info "libXau already built, skipping..."
        return 0
    fi

    log_step "Building libXau-1.0.12"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libXau-1.0.12.tar.xz
    cd libXau-1.0.12

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libXau-1.0.12

    log_info "libXau-1.0.12 installed successfully"
    create_checkpoint "libXau"
}

# =====================================================================
# libXdmcp-1.1.5 (X11 Display Manager Control Protocol Library)
# =====================================================================
build_libXdmcp() {
    if should_skip_package "libXdmcp"; then
        log_info "libXdmcp already built, skipping..."
        return 0
    fi

    log_step "Building libXdmcp-1.1.5"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libXdmcp-1.1.5.tar.xz
    cd libXdmcp-1.1.5

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libXdmcp-1.1.5

    log_info "libXdmcp-1.1.5 installed successfully"
    create_checkpoint "libXdmcp"
}

# =====================================================================
# xcb-proto-1.17.0 (XCB Protocol Descriptions)
# =====================================================================
build_xcb_proto() {
    if should_skip_package "xcb-proto"; then
        log_info "xcb-proto already built, skipping..."
        return 0
    fi

    log_step "Building xcb-proto-1.17.0"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/xcb-proto-1.17.0.tar.xz
    cd xcb-proto-1.17.0

    PYTHON=python3 ./configure $XORG_CONFIG

    make install

    # Remove old pkgconfig file if exists
    rm -f $XORG_PREFIX/lib/pkgconfig/xcb-proto.pc

    cd "$BUILD_DIR"
    rm -rf xcb-proto-1.17.0

    log_info "xcb-proto-1.17.0 installed successfully"
    create_checkpoint "xcb-proto"
}

# =====================================================================
# libxcb-1.17.0 (X C Binding Library)
# =====================================================================
build_libxcb() {
    if should_skip_package "libxcb"; then
        log_info "libxcb already built, skipping..."
        return 0
    fi

    log_step "Building libxcb-1.17.0"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libxcb-1.17.0.tar.xz
    cd libxcb-1.17.0

    ./configure $XORG_CONFIG    \
        --without-doxygen

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libxcb-1.17.0

    log_info "libxcb-1.17.0 installed successfully"
    create_checkpoint "libxcb"
}

# =====================================================================
# Pixman-0.46.4 (Low-level pixel manipulation library)
# =====================================================================
build_pixman() {
    if should_skip_package "pixman"; then
        log_info "pixman already built, skipping..."
        return 0
    fi

    log_step "Building Pixman-0.46.4"
    cd "$BUILD_DIR"

    tar -xf /sources/pixman-0.46.4.tar.gz
    cd pixman-0.46.4

    mkdir build && cd build

    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf pixman-0.46.4

    log_info "Pixman-0.46.4 installed successfully"
    create_checkpoint "pixman"
}

# =====================================================================
# libdrm-2.4.125 (Direct Rendering Manager Library)
# =====================================================================
build_libdrm() {
    if should_skip_package "libdrm"; then
        log_info "libdrm already built, skipping..."
        return 0
    fi

    log_step "Building libdrm-2.4.125"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libdrm-2.4.125.tar.xz
    cd libdrm-2.4.125

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX \
                --buildtype=release   \
                -D udev=true          \
                -D valgrind=disabled  ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libdrm-2.4.125

    log_info "libdrm-2.4.125 installed successfully"
    create_checkpoint "libdrm"
}

# =====================================================================
# libxcvt-0.1.3 (VESA CVT Standard Timing Modelines Generator)
# =====================================================================
build_libxcvt() {
    if should_skip_package "libxcvt"; then
        log_info "libxcvt already built, skipping..."
        return 0
    fi

    log_step "Building libxcvt-0.1.3"
    cd "$BUILD_DIR"

    setup_xorg_env

    tar -xf /sources/libxcvt-0.1.3.tar.xz
    cd libxcvt-0.1.3

    mkdir build && cd build

    meson setup --prefix=$XORG_PREFIX --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libxcvt-0.1.3

    log_info "libxcvt-0.1.3 installed successfully"
    create_checkpoint "libxcvt"
}

# =====================================================================
# SPIRV-Headers-1.4.321.0 (SPIR-V Headers)
# =====================================================================
build_spirv_headers() {
    if should_skip_package "spirv-headers"; then
        log_info "spirv-headers already built, skipping..."
        return 0
    fi

    log_step "Building SPIRV-Headers-1.4.321.0"
    cd "$BUILD_DIR"

    tar -xf /sources/SPIRV-Headers-vulkan-sdk-1.4.321.0.tar.gz
    cd SPIRV-Headers-vulkan-sdk-1.4.321.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf SPIRV-Headers-vulkan-sdk-1.4.321.0

    log_info "SPIRV-Headers-1.4.321.0 installed successfully"
    create_checkpoint "spirv-headers"
}

# =====================================================================
# SPIRV-Tools-1.4.321.0 (SPIR-V Tools)
# =====================================================================
build_spirv_tools() {
    if should_skip_package "spirv-tools"; then
        log_info "spirv-tools already built, skipping..."
        return 0
    fi

    log_step "Building SPIRV-Tools-1.4.321.0"
    cd "$BUILD_DIR"

    tar -xf /sources/SPIRV-Tools-vulkan-sdk-1.4.321.0.tar.gz
    cd SPIRV-Tools-vulkan-sdk-1.4.321.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr     \
          -D CMAKE_BUILD_TYPE=Release      \
          -D SPIRV_WERROR=OFF              \
          -D BUILD_SHARED_LIBS=ON          \
          -D SPIRV_TOOLS_BUILD_STATIC=OFF  \
          -D SPIRV-Headers_SOURCE_DIR=/usr \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf SPIRV-Tools-vulkan-sdk-1.4.321.0

    log_info "SPIRV-Tools-1.4.321.0 installed successfully"
    create_checkpoint "spirv-tools"
}

# =====================================================================
# Vulkan-Headers-1.4.321 (Vulkan Header Files)
# =====================================================================
build_vulkan_headers() {
    if should_skip_package "vulkan-headers"; then
        log_info "vulkan-headers already built, skipping..."
        return 0
    fi

    log_step "Building Vulkan-Headers-1.4.321"
    cd "$BUILD_DIR"

    tar -xf /sources/Vulkan-Headers-1.4.321.tar.gz
    cd Vulkan-Headers-1.4.321

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf Vulkan-Headers-1.4.321

    log_info "Vulkan-Headers-1.4.321 installed successfully"
    create_checkpoint "vulkan-headers"
}

# =====================================================================
# glslang-15.4.0 (GLSL Shader Frontend)
# =====================================================================
build_glslang() {
    if should_skip_package "glslang"; then
        log_info "glslang already built, skipping..."
        return 0
    fi

    log_step "Building glslang-15.4.0"
    cd "$BUILD_DIR"

    tar -xf /sources/glslang-15.4.0.tar.gz
    cd glslang-15.4.0

    mkdir build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr     \
          -D CMAKE_BUILD_TYPE=Release      \
          -D ALLOW_EXTERNAL_SPIRV_TOOLS=ON \
          -D BUILD_SHARED_LIBS=ON          \
          -D GLSLANG_TESTS=OFF             \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf glslang-15.4.0

    log_info "glslang-15.4.0 installed successfully"
    create_checkpoint "glslang"
}

# =====================================================================
# Vulkan-Loader-1.4.321 (Vulkan ICD Loader)
# =====================================================================
build_vulkan_loader() {
    if should_skip_package "vulkan-loader"; then
        log_info "vulkan-loader already built, skipping..."
        return 0
    fi

    log_step "Building Vulkan-Loader-1.4.321"
    cd "$BUILD_DIR"

    rm -rf Vulkan-Loader-1.4.321
    tar -xf /sources/Vulkan-Loader-1.4.321.tar.gz
    cd Vulkan-Loader-1.4.321

    mkdir -p build && cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr       \
          -D CMAKE_BUILD_TYPE=Release        \
          -D CMAKE_SKIP_RPATH=ON             \
          -G Ninja ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf Vulkan-Loader-1.4.321

    log_info "Vulkan-Loader-1.4.321 installed successfully"
    create_checkpoint "vulkan-loader"
}

# =====================================================================
# XKeyboardConfig-2.45 - BLFS Chapter 24
# Keyboard configuration database for X Window System
# =====================================================================
build_xkeyboard_config() {
    if should_skip_package "xkeyboard-config"; then
        log_info "xkeyboard-config already built, skipping..."
        return 0
    fi

    log_step "Building XKeyboardConfig-2.45"
    cd "$BUILD_DIR"

    rm -rf xkeyboard-config-2.45
    tar -xf /sources/xkeyboard-config-2.45.tar.xz
    cd xkeyboard-config-2.45

    mkdir -p build && cd build

    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf xkeyboard-config-2.45

    log_info "XKeyboardConfig-2.45 installed successfully"
    create_checkpoint "xkeyboard-config"
}

# =====================================================================
# xcb-util-0.4.1 - BLFS Chapter 24
# XCB utility library - extensions to the XCB library
# =====================================================================
build_xcb_util() {
    if should_skip_package "xcb-util"; then
        log_info "xcb-util already built, skipping..."
        return 0
    fi

    log_step "Building xcb-util-0.4.1"
    cd "$BUILD_DIR"

    rm -rf xcb-util-0.4.1
    tar -xf /sources/xcb-util-0.4.1.tar.xz
    cd xcb-util-0.4.1

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf xcb-util-0.4.1

    log_info "xcb-util-0.4.1 installed successfully"
    create_checkpoint "xcb-util"
}

# =====================================================================
# XCB Utilities - BLFS Chapter 24
# Additional xcb utility libraries (image, keysyms, renderutil, wm, cursor)
# =====================================================================
build_xcb_util_extras() {
    if should_skip_package "xcb-util-extras"; then
        log_info "xcb-util-extras already built, skipping..."
        return 0
    fi

    log_step "Building XCB Utilities (5 packages)"
    cd "$BUILD_DIR"
    setup_xorg_env

    # Build order matters: image and keysyms have no deps on each other
    # renderutil depends on nothing extra, wm depends on nothing extra
    # cursor depends on xcb-util-image and xcb-util-renderutil

    # xcb-util-image
    log_info "Building xcb-util-image-0.4.1..."
    rm -rf xcb-util-image-*
    tar -xf /sources/xcb-util-image-0.4.1.tar.xz
    cd xcb-util-image-0.4.1
    ./configure $XORG_CONFIG
    make && make install
    cd "$BUILD_DIR"
    rm -rf xcb-util-image-0.4.1

    # xcb-util-keysyms
    log_info "Building xcb-util-keysyms-0.4.1..."
    rm -rf xcb-util-keysyms-*
    tar -xf /sources/xcb-util-keysyms-0.4.1.tar.xz
    cd xcb-util-keysyms-0.4.1
    ./configure $XORG_CONFIG
    make && make install
    cd "$BUILD_DIR"
    rm -rf xcb-util-keysyms-0.4.1

    # xcb-util-renderutil
    log_info "Building xcb-util-renderutil-0.3.10..."
    rm -rf xcb-util-renderutil-*
    tar -xf /sources/xcb-util-renderutil-0.3.10.tar.xz
    cd xcb-util-renderutil-0.3.10
    ./configure $XORG_CONFIG
    make && make install
    cd "$BUILD_DIR"
    rm -rf xcb-util-renderutil-0.3.10

    # xcb-util-wm
    log_info "Building xcb-util-wm-0.4.2..."
    rm -rf xcb-util-wm-*
    tar -xf /sources/xcb-util-wm-0.4.2.tar.xz
    cd xcb-util-wm-0.4.2
    ./configure $XORG_CONFIG
    make && make install
    cd "$BUILD_DIR"
    rm -rf xcb-util-wm-0.4.2

    # xcb-util-cursor (depends on image and renderutil)
    log_info "Building xcb-util-cursor-0.1.5..."
    rm -rf xcb-util-cursor-*
    tar -xf /sources/xcb-util-cursor-0.1.5.tar.xz
    cd xcb-util-cursor-0.1.5
    ./configure $XORG_CONFIG
    make && make install
    cd "$BUILD_DIR"
    rm -rf xcb-util-cursor-0.1.5

    log_info "XCB Utilities (5 packages) installed successfully"
    create_checkpoint "xcb-util-extras"
}

# =====================================================================
# Mesa-25.1.8 - BLFS Chapter 24
# OpenGL compatible 3D graphics library
# =====================================================================
build_mesa() {
    if should_skip_package "mesa"; then
        log_info "mesa already built, skipping..."
        return 0
    fi

    log_step "Building Mesa-25.1.8"
    cd "$BUILD_DIR"

    # Install required Python dependencies
    log_info "Installing Python dependencies for Mesa (Mako, PyYAML, MarkupSafe)..."
    pip3 install --root=/ --prefix=/usr mako pyyaml markupsafe

    rm -rf mesa-25.1.8
    tar -xf /sources/mesa-25.1.8.tar.xz
    cd mesa-25.1.8

    mkdir -p build && cd build

    # Configure Mesa with software rendering (softpipe) for broad compatibility
    # Using x11 platform only since we don't have Wayland built yet
    # Disabling Vulkan drivers since we need glslang built first
    # Using softpipe instead of llvmpipe since we don't have LLVM
    meson setup ..                      \
          --prefix=/usr                 \
          --buildtype=release           \
          -D platforms=x11              \
          -D gallium-drivers=softpipe,svga,nouveau,virgl \
          -D vulkan-drivers=            \
          -D valgrind=disabled          \
          -D libunwind=disabled         \
          -D glx=dri                    \
          -D egl=enabled                \
          -D gbm=enabled                \
          -D gles1=enabled              \
          -D gles2=enabled              \
          -D shared-glapi=enabled

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf mesa-25.1.8

    log_info "Mesa-25.1.8 installed successfully"
    create_checkpoint "mesa"
}

# =====================================================================
# libepoxy-1.5.10 - BLFS Chapter 25
# OpenGL function pointer management library (required for Xorg glamor)
# =====================================================================
build_libepoxy() {
    if should_skip_package "libepoxy"; then
        log_info "libepoxy already built, skipping..."
        return 0
    fi

    log_step "Building libepoxy-1.5.10"
    cd "$BUILD_DIR"

    rm -rf libepoxy-*
    tar -xf /sources/libepoxy-1.5.10.tar.xz
    cd libepoxy-1.5.10

    mkdir -p build && cd build

    # Per BLFS: Simple meson build
    meson setup --prefix=/usr --buildtype=release ..

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libepoxy-1.5.10

    log_info "libepoxy-1.5.10 installed successfully"
    create_checkpoint "libepoxy"
}

# =====================================================================
# libpng-1.6.50 - BLFS Chapter 10
# PNG library required by xcursorgen and many graphics applications
# =====================================================================
build_libpng() {
    if should_skip_package "libpng"; then
        log_info "libpng already built, skipping..."
        return 0
    fi

    log_step "Building libpng-1.6.50"
    cd "$BUILD_DIR"

    rm -rf libpng-*
    tar -xf /sources/libpng-1.6.50.tar.xz
    cd libpng-1.6.50

    # Per BLFS: Build with static libraries disabled
    ./configure --prefix=/usr --disable-static

    make
    make install

    cd "$BUILD_DIR"
    rm -rf libpng-1.6.50

    log_info "libpng-1.6.50 installed successfully"
    create_checkpoint "libpng"
}

# =====================================================================
# xcursor-themes-1.0.7 - BLFS Chapter 24
# Animated cursor themes (redglass, whiteglass)
# =====================================================================
build_xcursor_themes() {
    if should_skip_package "xcursor-themes"; then
        log_info "xcursor-themes already built, skipping..."
        return 0
    fi

    log_step "Building xcursor-themes-1.0.7"
    cd "$BUILD_DIR"

    rm -rf xcursor-themes-1.0.7
    tar -xf /sources/xcursor-themes-1.0.7.tar.xz
    cd xcursor-themes-1.0.7

    # Per BLFS: Install in /usr so non-Xorg desktop environments can find them
    ./configure --prefix=/usr

    make
    make install

    cd "$BUILD_DIR"
    rm -rf xcursor-themes-1.0.7

    log_info "xcursor-themes-1.0.7 installed successfully"
    create_checkpoint "xcursor-themes"
}

# =====================================================================
# Xorg-Server-21.1.18 - BLFS Chapter 24
# The core X11 display server
# =====================================================================
build_xorg_server() {
    if should_skip_package "xorg-server"; then
        log_info "xorg-server already built, skipping..."
        return 0
    fi

    log_step "Building Xorg-Server-21.1.18"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xorg-server-*
    tar -xf /sources/xorg-server-21.1.18.tar.xz
    cd xorg-server-21.1.18

    mkdir -p build && cd build

    # Per BLFS: Build with glamor (requires libepoxy) for modesetting driver
    # -D xkb_output_dir=/var/lib/xkb for XKB compiled keymaps
    # Disabling secure-rpc since we don't have libtirpc
    meson setup ..                      \
          --prefix=$XORG_PREFIX         \
          --localstatedir=/var          \
          -D glamor=true                \
          -D xkb_output_dir=/var/lib/xkb \
          -D secure-rpc=false

    ninja
    ninja install

    # Create xorg.conf.d directory for configuration snippets
    mkdir -pv /etc/X11/xorg.conf.d

    cd "$BUILD_DIR"
    rm -rf xorg-server-21.1.18

    log_info "Xorg-Server-21.1.18 installed successfully"
    create_checkpoint "xorg-server"
}

# =====================================================================
# libevdev-1.13.4 - BLFS Chapter 24
# Input device library for evdev devices
# =====================================================================
build_libevdev() {
    if should_skip_package "libevdev"; then
        log_info "libevdev already built, skipping..."
        return 0
    fi

    log_step "Building libevdev-1.13.4"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf libevdev-*
    tar -xf /sources/libevdev-1.13.4.tar.xz
    cd libevdev-1.13.4

    mkdir -p build && cd build

    # Per BLFS: Disable tests (need Check library) and documentation
    meson setup ..                      \
          --prefix=$XORG_PREFIX         \
          --buildtype=release           \
          -D documentation=disabled     \
          -D tests=disabled

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libevdev-1.13.4

    log_info "libevdev-1.13.4 installed successfully"
    create_checkpoint "libevdev"
}

# =====================================================================
# mtdev-1.1.7 - BLFS Chapter 9
# Multitouch device library
# =====================================================================
build_mtdev() {
    if should_skip_package "mtdev"; then
        log_info "mtdev already built, skipping..."
        return 0
    fi

    log_step "Building mtdev-1.1.7"
    cd "$BUILD_DIR"

    rm -rf mtdev-*
    tar -xf /sources/mtdev-1.1.7.tar.bz2
    cd mtdev-1.1.7

    ./configure --prefix=/usr --disable-static

    make
    make install

    cd "$BUILD_DIR"
    rm -rf mtdev-1.1.7

    log_info "mtdev-1.1.7 installed successfully"
    create_checkpoint "mtdev"
}

# =====================================================================
# xf86-input-evdev-2.11.0 - BLFS Chapter 24
# Generic Linux input driver for Xorg
# =====================================================================
build_xf86_input_evdev() {
    if should_skip_package "xf86-input-evdev"; then
        log_info "xf86-input-evdev already built, skipping..."
        return 0
    fi

    log_step "Building xf86-input-evdev-2.11.0"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xf86-input-evdev-*
    tar -xf /sources/xf86-input-evdev-2.11.0.tar.xz
    cd xf86-input-evdev-2.11.0

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf xf86-input-evdev-2.11.0

    log_info "xf86-input-evdev-2.11.0 installed successfully"
    create_checkpoint "xf86-input-evdev"
}

# =====================================================================
# libinput-1.29.0 - BLFS Chapter 24
# Modern input handling library
# =====================================================================
build_libinput() {
    if should_skip_package "libinput"; then
        log_info "libinput already built, skipping..."
        return 0
    fi

    log_step "Building libinput-1.29.0"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf libinput-*
    tar -xf /sources/libinput-1.29.0.tar.gz
    cd libinput-1.29.0

    mkdir -p build && cd build

    # Per BLFS: Disable debug GUI (needs GTK3), tests, and libwacom
    meson setup ..                      \
          --prefix=$XORG_PREFIX         \
          --buildtype=release           \
          -D debug-gui=false            \
          -D tests=false                \
          -D libwacom=false             \
          -D udev-dir=/usr/lib/udev

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf libinput-1.29.0

    log_info "libinput-1.29.0 installed successfully"
    create_checkpoint "libinput"
}

# =====================================================================
# xf86-input-libinput-1.5.0 - BLFS Chapter 24
# Xorg driver wrapper for libinput
# =====================================================================
build_xf86_input_libinput() {
    if should_skip_package "xf86-input-libinput"; then
        log_info "xf86-input-libinput already built, skipping..."
        return 0
    fi

    log_step "Building xf86-input-libinput-1.5.0"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xf86-input-libinput-*
    tar -xf /sources/xf86-input-libinput-1.5.0.tar.xz
    cd xf86-input-libinput-1.5.0

    ./configure $XORG_CONFIG

    make
    make install

    cd "$BUILD_DIR"
    rm -rf xf86-input-libinput-1.5.0

    log_info "xf86-input-libinput-1.5.0 installed successfully"
    create_checkpoint "xf86-input-libinput"
}

# =====================================================================
# Xwayland-24.1.8 - BLFS Chapter 24
# X server running on Wayland for legacy X11 app compatibility
# =====================================================================
build_xwayland() {
    if should_skip_package "xwayland"; then
        log_info "xwayland already built, skipping..."
        return 0
    fi

    log_step "Building Xwayland-24.1.8"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xwayland-*
    tar -xf /sources/xwayland-24.1.8.tar.xz
    cd xwayland-24.1.8

    # Per BLFS: Remove sed that prevents man page install since we have Xorg-Server
    # (man page conflict) - we keep the sed to avoid conflict
    sed -i '/install_man/,$d' meson.build

    mkdir -p build && cd build

    # Per BLFS: Build with glamor (OpenGL accel) and xkb_output_dir
    # Disable secure-rpc since we don't have libtirpc
    meson setup ..                      \
          --prefix=$XORG_PREFIX         \
          --buildtype=release           \
          -D xkb_output_dir=/var/lib/xkb \
          -D secure-rpc=false

    ninja
    ninja install

    cd "$BUILD_DIR"
    rm -rf xwayland-24.1.8

    log_info "Xwayland-24.1.8 installed successfully"
    create_checkpoint "xwayland"
}

# =====================================================================
# xinit-1.4.4 - BLFS Chapter 24
# startx script for launching X sessions
# =====================================================================
build_xinit() {
    if should_skip_package "xinit"; then
        log_info "xinit already built, skipping..."
        return 0
    fi

    log_step "Building xinit-1.4.4"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xinit-*
    tar -xf /sources/xinit-1.4.4.tar.xz
    cd xinit-1.4.4

    # Per BLFS: Configure with xinitdir for X11 app-defaults
    ./configure $XORG_CONFIG --with-xinitdir=/etc/X11/app-defaults

    make
    make install

    # Create default xinitrc if it doesn't exist
    if [ ! -f /etc/X11/app-defaults/xinitrc ]; then
        cat > /etc/X11/app-defaults/xinitrc << 'EOF'
#!/bin/sh
# Default xinitrc - starts a basic X session
# Users should copy this to ~/.xinitrc and customize

# Merge user X resources
if [ -f "$HOME/.Xresources" ]; then
    xrdb -merge "$HOME/.Xresources"
fi

# Start a window manager or desktop environment
# Uncomment one of the following or add your own:
# exec startkde
# exec gnome-session
# exec startxfce4
# exec i3

# Fallback: just run xterm
exec xterm
EOF
        chmod 755 /etc/X11/app-defaults/xinitrc
    fi

    cd "$BUILD_DIR"
    rm -rf xinit-1.4.4

    log_info "xinit-1.4.4 installed successfully"
    create_checkpoint "xinit"
}

# =====================================================================
# xbitmaps - BLFS Chapter 24
# Bitmap images used by X applications (required by Xorg Applications)
# =====================================================================
build_xbitmaps() {
    if should_skip_package "xbitmaps"; then
        log_info "xbitmaps already built, skipping..."
        return 0
    fi

    log_step "Building xbitmaps-1.1.3"
    cd "$BUILD_DIR"
    setup_xorg_env

    rm -rf xbitmaps-*
    tar -xf /sources/xbitmaps-1.1.3.tar.xz
    cd xbitmaps-1.1.3

    ./configure $XORG_CONFIG

    # No make needed - just install
    make install

    cd "$BUILD_DIR"
    rm -rf xbitmaps-1.1.3

    log_info "xbitmaps-1.1.3 installed successfully"
    create_checkpoint "xbitmaps"
}

# =====================================================================
# Xorg Applications - BLFS Chapter 24
# 33 packages including mkfontscale, xcursorgen, xrandr, etc.
# =====================================================================
build_xorg_apps() {
    if should_skip_package "xorg-apps"; then
        log_info "xorg-apps already built, skipping..."
        return 0
    fi

    log_step "Building Xorg Applications (33 packages)"
    cd "$BUILD_DIR"
    setup_xorg_env

    # Package list in correct build order (from BLFS app-7.md5)
    # Note: xcursorgen requires libpng which must be built first
    local xorg_app_packages=(
        "iceauth-1.0.10.tar.xz"
        "mkfontscale-1.2.3.tar.xz"
        "sessreg-1.1.4.tar.xz"
        "setxkbmap-1.3.4.tar.xz"
        "smproxy-1.0.8.tar.xz"
        "xauth-1.1.4.tar.xz"
        "xcmsdb-1.0.7.tar.xz"
        "xcursorgen-1.0.9.tar.xz"
        "xdpyinfo-1.4.0.tar.xz"
        "xdriinfo-1.0.8.tar.xz"
        "xev-1.2.6.tar.xz"
        "xgamma-1.0.8.tar.xz"
        "xhost-1.0.10.tar.xz"
        "xinput-1.6.4.tar.xz"
        "xkbcomp-1.4.7.tar.xz"
        "xkbevd-1.1.6.tar.xz"
        "xkbutils-1.0.6.tar.xz"
        "xkill-1.0.6.tar.xz"
        "xlsatoms-1.1.4.tar.xz"
        "xlsclients-1.1.5.tar.xz"
        "xmessage-1.0.7.tar.xz"
        "xmodmap-1.0.11.tar.xz"
        "xpr-1.2.0.tar.xz"
        "xprop-1.2.8.tar.xz"
        "xrandr-1.5.3.tar.xz"
        "xrdb-1.2.2.tar.xz"
        "xrefresh-1.1.0.tar.xz"
        "xset-1.2.5.tar.xz"
        "xsetroot-1.1.3.tar.xz"
        "xvinfo-1.1.5.tar.xz"
        "xwd-1.0.9.tar.xz"
        "xwininfo-1.1.6.tar.xz"
        "xwud-1.0.7.tar.xz"
    )

    local total_packages=${#xorg_app_packages[@]}
    local count=0

    for package in "${xorg_app_packages[@]}"; do
        count=$((count + 1))
        local packagedir="${package%.tar.*}"
        log_info "Building $packagedir ($count/$total_packages)..."

        rm -rf "$packagedir"
        tar -xf /sources/"$package"
        cd "$packagedir"

        ./configure $XORG_CONFIG
        make
        make install

        cd "$BUILD_DIR"
        rm -rf "$packagedir"
    done

    # Remove the broken xkeystone script (per BLFS instructions)
    rm -f $XORG_PREFIX/bin/xkeystone

    log_info "Xorg Applications (33 packages) installed successfully"
    create_checkpoint "xorg-apps"
}

# =====================================================================
# Xorg Fonts - BLFS Chapter 24
# 9 font packages: font-util, encodings, font-alias, and 6 font packages
# =====================================================================
build_xorg_fonts() {
    if should_skip_package "xorg-fonts"; then
        log_info "xorg-fonts already built, skipping..."
        return 0
    fi

    log_step "Building Xorg Fonts (9 packages)"
    cd "$BUILD_DIR"
    setup_xorg_env

    # Package list in correct build order (from BLFS font-7.md5)
    # font-util must be first, then encodings, then fonts, then font-alias
    local xorg_font_packages=(
        "font-util-1.4.1.tar.xz"
        "encodings-1.1.0.tar.xz"
        "font-adobe-utopia-type1-1.0.5.tar.xz"
        "font-bh-ttf-1.0.4.tar.xz"
        "font-bh-type1-1.0.4.tar.xz"
        "font-ibm-type1-1.0.4.tar.xz"
        "font-misc-ethiopic-1.0.5.tar.xz"
        "font-xfree86-type1-1.0.5.tar.xz"
        "font-alias-1.0.5.tar.xz"
    )

    local count=0
    local total=${#xorg_font_packages[@]}

    for pkg in "${xorg_font_packages[@]}"; do
        count=$((count + 1))
        local pkg_name="${pkg%.tar.*}"

        log_info "Building $pkg_name ($count/$total)..."

        rm -rf "$pkg_name"
        tar -xf "/sources/$pkg"
        cd "$pkg_name"

        ./configure $XORG_CONFIG

        make
        make install

        cd "$BUILD_DIR"
        rm -rf "$pkg_name"
    done

    # Create symlinks to font directories for Fontconfig
    # This is needed if XORG_PREFIX is not /usr
    log_info "Creating font directory symlinks for Fontconfig..."
    install -v -d -m755 /usr/share/fonts

    if [ -d "$XORG_PREFIX/share/fonts/X11/OTF" ]; then
        ln -svfn "$XORG_PREFIX/share/fonts/X11/OTF" /usr/share/fonts/X11-OTF 2>/dev/null || true
    fi
    if [ -d "$XORG_PREFIX/share/fonts/X11/TTF" ]; then
        ln -svfn "$XORG_PREFIX/share/fonts/X11/TTF" /usr/share/fonts/X11-TTF 2>/dev/null || true
    fi

    log_info "Xorg Fonts (9 packages) installed successfully"
    create_checkpoint "xorg-fonts"
}

# =====================================================================
# FreeType-2.13.3 - BLFS Chapter 10
# Required by libXfont2 and many other graphics packages
#
# NOTE: This is the FIRST FreeType build WITHOUT HarfBuzz support.
# FreeType will be rebuilt WITH HarfBuzz support later in Tier 5
# after HarfBuzz is built (circular dependency resolution).
# See: rebuild_freetype() in Tier 5 GTK Stack section
# =====================================================================
build_freetype() {
    if should_skip_package "freetype"; then
        log_info "freetype already built, skipping..."
        return 0
    fi

    log_step "Building FreeType-2.13.3 (without HarfBuzz - will rebuild later)"
    cd "$BUILD_DIR"

    tar -xf /sources/freetype-2.13.3.tar.xz
    cd freetype-2.13.3

    # Enable GX/AAT and OpenType table validation
    sed -ri "s:.*(AUX_MODULES.*valid):\1:" modules.cfg

    # Enable Subpixel Rendering
    sed -r "s:.*(#.*SUBPIXEL_RENDERING) .*:\1:" \
        -i include/freetype/config/ftoption.h

    # Build WITHOUT HarfBuzz and WITHOUT PNG (neither exist yet)
    # FreeType will be rebuilt with HarfBuzz + PNG support after they are installed
    ./configure --prefix=/usr          \
                --enable-freetype-config \
                --disable-static       \
                --without-png          \
                --without-harfbuzz

    make
    make install

    cd "$BUILD_DIR"
    rm -rf freetype-2.13.3

    log_info "FreeType-2.13.3 installed successfully (without HarfBuzz)"
    create_checkpoint "freetype"
}

# Fontconfig-2.17.1 (font configuration library - required by libXft)
build_fontconfig() {
    if should_skip_package "fontconfig"; then
        log_info "fontconfig already built, skipping..."
        return 0
    fi

    log_step "Building Fontconfig-2.17.1"
    cd "$BUILD_DIR"

    tar -xf /sources/fontconfig-2.17.1.tar.xz
    cd fontconfig-2.17.1

    ./configure --prefix=/usr        \
                --sysconfdir=/etc    \
                --localstatedir=/var \
                --disable-docs       \
                --docdir=/usr/share/doc/fontconfig-2.17.1

    make
    make install

    cd "$BUILD_DIR"
    rm -rf fontconfig-2.17.1

    log_info "Fontconfig-2.17.1 installed successfully"
    create_checkpoint "fontconfig"
}

# =====================================================================
# Xorg Libraries (32 packages) - BLFS Chapter 24
# =====================================================================
build_xorg_libraries() {
    if should_skip_package "xorg-libraries"; then
        log_info "xorg-libraries already built, skipping..."
        return 0
    fi

    log_step "Building Xorg Libraries (32 packages)"
    cd "$BUILD_DIR"
    setup_xorg_env

    # Package list in correct build order (from BLFS lib-7.md5)
    # Note: xtrans, libFS, libXpresent use .tar.gz from GitLab with different dir names
    local xorg_lib_packages=(
        "xtrans-1.6.0.tar.gz"
        "libX11-1.8.12.tar.xz"
        "libXext-1.3.6.tar.xz"
        "libFS-1.0.10.tar.gz"
        "libICE-1.1.2.tar.xz"
        "libSM-1.2.6.tar.xz"
        "libXScrnSaver-1.2.4.tar.xz"
        "libXt-1.3.1.tar.xz"
        "libXmu-1.2.1.tar.xz"
        "libXpm-3.5.17.tar.xz"
        "libXaw-1.0.16.tar.xz"
        "libXfixes-6.0.1.tar.xz"
        "libXcomposite-0.4.6.tar.xz"
        "libXrender-0.9.12.tar.xz"
        "libXcursor-1.2.3.tar.xz"
        "libXdamage-1.1.6.tar.xz"
        "libfontenc-1.1.8.tar.xz"
        "libXfont2-2.0.7.tar.xz"
        "libXft-2.3.9.tar.xz"
        "libXi-1.8.2.tar.xz"
        "libXinerama-1.1.5.tar.xz"
        "libXrandr-1.5.4.tar.xz"
        "libXres-1.2.2.tar.xz"
        "libXtst-1.2.5.tar.xz"
        "libXv-1.0.13.tar.xz"
        "libXvMC-1.0.14.tar.xz"
        "libXxf86dga-1.1.6.tar.xz"
        "libXxf86vm-1.1.6.tar.xz"
        "libpciaccess-0.18.1.tar.xz"
        "libxkbfile-1.1.3.tar.xz"
        "libxshmfence-1.3.3.tar.xz"
        "libXpresent-1.0.1.tar.gz"
    )

    local pkg_count=0
    local pkg_total=${#xorg_lib_packages[@]}

    for package in "${xorg_lib_packages[@]}"; do
        pkg_count=$((pkg_count + 1))
        # Strip extension to get base package name
        local packagedir="${package%.tar.*}"
        log_info "Building $packagedir ($pkg_count/$pkg_total)..."

        tar -xf /sources/$package

        # Handle GitLab tarballs which have different directory names
        # GitLab format: libxtrans-xtrans-1.6.0, libfs-libFS-1.0.10, etc.
        # But xorg.freedesktop.org tarballs extract to simple names (xtrans-1.6.0)
        local actual_dir=""

        # First check if the simple directory name exists (xorg.freedesktop.org format)
        if [ -d "$packagedir" ]; then
            actual_dir="$packagedir"
        else
            # Try GitLab format
            case $packagedir in
                xtrans-* )
                    actual_dir="libxtrans-$packagedir"
                    ;;
                libFS-* )
                    actual_dir="libfs-$packagedir"
                    ;;
                libXpresent-* )
                    actual_dir="libxpresent-$packagedir"
                    ;;
                * )
                    actual_dir="$packagedir"
                    ;;
            esac
        fi

        if [ ! -d "$actual_dir" ]; then
            log_error "Directory $actual_dir not found after extraction"
            ls -la
            exit 1
        fi

        pushd "$actual_dir" > /dev/null

        local docdir="--docdir=$XORG_PREFIX/share/doc/$packagedir"

        case $packagedir in
            xtrans-* )
                # xtrans from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for xtrans..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libFS-* )
                # libFS from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for libFS..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libXpresent-* )
                # libXpresent from GitLab needs autoreconf
                if [ ! -f configure ]; then
                    log_info "Running autoreconf for libXpresent..."
                    autoreconf -fiv
                fi
                ./configure $XORG_CONFIG $docdir
                ;;

            libXfont2-[0-9]* )
                ./configure $XORG_CONFIG $docdir --disable-devel-docs
                ;;

            libXt-[0-9]* )
                ./configure $XORG_CONFIG $docdir \
                            --with-appdefaultdir=/etc/X11/app-defaults
                ;;

            libXpm-[0-9]* )
                ./configure $XORG_CONFIG $docdir --disable-open-zfile
                ;;

            libpciaccess* )
                mkdir -p build
                cd build
                meson setup --prefix=$XORG_PREFIX --buildtype=release ..
                ninja
                ninja install
                popd > /dev/null
                rm -rf "$actual_dir"
                ldconfig
                continue
                ;;

            * )
                ./configure $XORG_CONFIG $docdir
                ;;
        esac

        make
        make install
        popd > /dev/null
        rm -rf "$actual_dir"
        ldconfig
    done

    log_info "Xorg Libraries - All 32 packages installed successfully"
    create_checkpoint "xorg-libraries"
}

# =====================================================================
# Build Tier 3 Foundation packages
# =====================================================================
log_info ""
log_info "#####################################################################"
log_info "# TIER 3: Graphics Foundation (X11/Wayland)"
log_info "#####################################################################"
log_info ""

# Setup Xorg environment
setup_xorg_env

# Build Xorg base packages (no dependencies)
build_util_macros
build_xorgproto

# Build Wayland (no Xorg dependencies)
build_wayland
build_wayland_protocols

# Build X11 protocol libraries
build_libXau
build_libXdmcp
build_xcb_proto
build_libxcb

# Build graphics libraries
build_pixman
build_libdrm
build_libxcvt

# Build Vulkan/SPIR-V stack (Phase 1 - before Xorg Libraries)
build_spirv_headers
build_spirv_tools
build_vulkan_headers
build_glslang

# Build FreeType (required by libXfont2 and Fontconfig)
build_freetype

# Build Fontconfig (required by libXft)
build_fontconfig

# Build Xorg Libraries (32 packages) - enables Vulkan-Loader
build_xorg_libraries

# Build Vulkan-Loader (now that libX11 is available)
build_vulkan_loader

# Build XKeyboard-Config (keyboard configuration database)
build_xkeyboard_config

# Build xcb-util (XCB utility library)
build_xcb_util

# Build XCB Utilities (5 additional packages)
build_xcb_util_extras

# Build Mesa (OpenGL 3D graphics library)
build_mesa

# Build libepoxy (OpenGL function pointer management - required for Xorg glamor)
build_libepoxy

# Build libpng (required by xcursorgen)
build_libpng

# Build xbitmaps (required by Xorg Applications)
build_xbitmaps

# Build Xorg Applications (33 packages including mkfontscale, xcursorgen)
build_xorg_apps

# Now build fonts and cursor themes (depend on Xorg Applications)
build_xorg_fonts
build_xcursor_themes

# Build Xorg-Server (the X11 display server)
build_xorg_server

# Build Xorg Input Drivers (keyboard/mouse/touchpad support)
build_libevdev
build_mtdev
build_xf86_input_evdev
build_libinput
build_xf86_input_libinput

# Build Xwayland (X11 compatibility for Wayland compositors)
build_xwayland

# Build xinit (startx script)
build_xinit

log_info ""
log_info "Tier 3 Graphics Foundation (Phase 2) completed!"
log_info "  - Xorg Libraries: 32 packages (libX11, libXext, etc.)"
log_info "  - Vulkan-Loader: Now functional with X11 support"
log_info "  - XKeyboardConfig: Keyboard database"
log_info "  - xcb-util + extras: XCB utility libraries (6 packages)"
log_info "  - Mesa: OpenGL 3D graphics (softpipe, svga, nouveau)"
log_info "  - libepoxy: OpenGL function pointer management"
log_info "  - xbitmaps: X11 bitmap images"
log_info "  - Xorg Applications: 33 packages (mkfontscale, xrandr, etc.)"
log_info "  - Xorg Fonts: 9 font packages"
log_info "  - xcursor-themes: Cursor themes"
log_info "  - Xorg-Server: X11 display server with glamor"
log_info "  - Input Drivers: libevdev, mtdev, evdev, libinput"
log_info "  - Xwayland: X11 compatibility for Wayland"
log_info "  - xinit: startx script for X sessions"
log_info ""

# =====================================================================
# Tier 4: Multimedia Libraries
# =====================================================================

log_step "Starting Tier 4: Multimedia Libraries"

# ALSA (Advanced Linux Sound Architecture)
build_alsa_lib() {
    should_skip_package "alsa-lib" && { log_info "Skipping alsa-lib"; return 0; }
    log_step "Building alsa-lib-1.2.14..."
    cd "$BUILD_DIR" && rm -rf alsa-lib-* && tar -xf /sources/alsa-lib-1.2.14.tar.bz2 && cd alsa-lib-*
    ./configure --prefix=/usr --sysconfdir=/etc --with-confdir=/etc/alsa
    make
    make install
    create_checkpoint "alsa-lib"
}

build_alsa_plugins() {
    should_skip_package "alsa-plugins" && { log_info "Skipping alsa-plugins"; return 0; }
    log_step "Building alsa-plugins-1.2.12..."
    cd "$BUILD_DIR" && rm -rf alsa-plugins-* && tar -xf /sources/alsa-plugins-1.2.12.tar.bz2 && cd alsa-plugins-*
    ./configure --prefix=/usr --sysconfdir=/etc
    make
    make install
    create_checkpoint "alsa-plugins"
}

build_alsa_utils() {
    should_skip_package "alsa-utils" && { log_info "Skipping alsa-utils"; return 0; }
    log_step "Building alsa-utils-1.2.14..."
    cd "$BUILD_DIR" && rm -rf alsa-utils-* && tar -xf /sources/alsa-utils-1.2.14.tar.bz2 && cd alsa-utils-*
    ./configure --prefix=/usr --disable-alsaconf --disable-bat --disable-xmlto --with-curses=ncursesw
    make
    make install
    create_checkpoint "alsa-utils"
}

# Audio Codecs
build_libogg() {
    should_skip_package "libogg" && { log_info "Skipping libogg"; return 0; }
    log_step "Building libogg-1.3.6..."
    cd "$BUILD_DIR" && rm -rf libogg-* && tar -xf /sources/libogg-1.3.6.tar.xz && cd libogg-*
    ./configure --prefix=/usr --disable-static
    make
    make install
    create_checkpoint "libogg"
}

build_libvorbis() {
    should_skip_package "libvorbis" && { log_info "Skipping libvorbis"; return 0; }
    log_step "Building libvorbis-1.3.7..."
    cd "$BUILD_DIR" && rm -rf libvorbis-* && tar -xf /sources/libvorbis-1.3.7.tar.xz && cd libvorbis-*
    ./configure --prefix=/usr --disable-static
    make
    make install
    create_checkpoint "libvorbis"
}

build_flac() {
    should_skip_package "flac" && { log_info "Skipping FLAC"; return 0; }
    log_step "Building FLAC-1.5.0..."
    cd "$BUILD_DIR" && rm -rf flac-* && tar -xf /sources/flac-1.5.0.tar.xz && cd flac-*
    ./configure --prefix=/usr --disable-static
    make
    make install
    create_checkpoint "flac"
}

build_opus() {
    should_skip_package "opus" && { log_info "Skipping Opus"; return 0; }
    log_step "Building Opus-1.5.2..."
    cd "$BUILD_DIR" && rm -rf opus-* && tar -xf /sources/opus-1.5.2.tar.gz && cd opus-*
    ./configure --prefix=/usr --disable-static
    make
    make install
    create_checkpoint "opus"
}

build_libsndfile() {
    should_skip_package "libsndfile" && { log_info "Skipping libsndfile"; return 0; }
    log_step "Building libsndfile-1.2.2..."
    cd "$BUILD_DIR" && rm -rf libsndfile-* && tar -xf /sources/libsndfile-1.2.2.tar.xz && cd libsndfile-*
    # Use C17 standard to avoid C23 'false' keyword conflict in ALAC codec
    ./configure --prefix=/usr --disable-static CFLAGS="-O2 -std=gnu17"
    make
    make install
    create_checkpoint "libsndfile"
}

build_libsamplerate() {
    should_skip_package "libsamplerate" && { log_info "Skipping libsamplerate"; return 0; }
    log_step "Building libsamplerate-0.2.2..."
    cd "$BUILD_DIR" && rm -rf libsamplerate-* && tar -xf /sources/libsamplerate-0.2.2.tar.xz && cd libsamplerate-*
    ./configure --prefix=/usr --disable-static
    make
    make install
    create_checkpoint "libsamplerate"
}

# Lua (scripting language - dependency for WirePlumber)
build_lua() {
    should_skip_package "lua" && { log_info "Skipping Lua"; return 0; }
    log_step "Building Lua-5.4.8..."
    cd "$BUILD_DIR" && rm -rf lua-* && tar -xf /sources/lua-5.4.8.tar.gz && cd lua-*

    # Create pkg-config file
    cat > lua.pc << "EOF"
V=5.4
R=5.4.8

prefix=/usr
INSTALL_BIN=${prefix}/bin
INSTALL_INC=${prefix}/include
INSTALL_LIB=${prefix}/lib
INSTALL_MAN=${prefix}/share/man/man1
INSTALL_LMOD=${prefix}/share/lua/${V}
INSTALL_CMOD=${prefix}/lib/lua/${V}
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Lua
Description: An Extensible Extension Language
Version: ${R}
Requires:
Libs: -L${libdir} -llua -lm -ldl
Cflags: -I${includedir}
EOF

    # Apply patch and build
    patch -Np1 -i /sources/lua-5.4.8-shared_library-1.patch
    make linux
    make INSTALL_TOP=/usr \
         INSTALL_DATA="cp -d" \
         INSTALL_MAN=/usr/share/man/man1 \
         TO_LIB="liblua.so liblua.so.5.4 liblua.so.5.4.8" \
         install

    mkdir -pv /usr/share/doc/lua-5.4.8
    cp -v doc/*.{html,css,gif,png} /usr/share/doc/lua-5.4.8 2>/dev/null || true
    install -v -m644 -D lua.pc /usr/lib/pkgconfig/lua.pc

    create_checkpoint "lua"
}

# Audio Servers
build_pipewire() {
    should_skip_package "pipewire" && { log_info "Skipping PipeWire"; return 0; }
    log_step "Building PipeWire-1.4.7..."
    cd "$BUILD_DIR" && rm -rf pipewire-* && tar -xf /sources/pipewire-1.4.7.tar.bz2 && cd pipewire-*
    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Dsession-managers=[]
    ninja
    ninja install
    create_checkpoint "pipewire"
}

build_wireplumber() {
    should_skip_package "wireplumber" && { log_info "Skipping WirePlumber"; return 0; }
    log_step "Building WirePlumber-0.5.10..."
    cd "$BUILD_DIR" && rm -rf wireplumber-* && tar -xf /sources/wireplumber-0.5.10.tar.bz2 && cd wireplumber-*
    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -D system-lua=true ..
    ninja
    ninja install
    mv -v /usr/share/doc/wireplumber{,-0.5.10}
    create_checkpoint "wireplumber"
}

# Perl XML::Parser (required for PulseAudio man pages)
build_perl_xml_parser() {
    should_skip_package "perl-xml-parser" && { log_info "Skipping Perl XML::Parser"; return 0; }
    log_step "Building Perl XML::Parser-2.47..."
    cd "$BUILD_DIR" && rm -rf XML-Parser-* && tar -xf /sources/XML-Parser-2.47.tar.gz && cd XML-Parser-*
    perl Makefile.PL
    make
    make install
    create_checkpoint "perl-xml-parser"
}

build_pulseaudio() {
    should_skip_package "pulseaudio" && { log_info "Skipping PulseAudio"; return 0; }
    log_step "Building PulseAudio-17.0..."
    cd "$BUILD_DIR" && rm -rf pulseaudio-* && tar -xf /sources/pulseaudio-17.0.tar.xz && cd pulseaudio-*
    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Ddatabase=gdbm -Ddoxygen=false -Dbluez5=disabled -Dtests=false
    ninja
    ninja install
    create_checkpoint "pulseaudio"
}

# GStreamer Framework
build_gstreamer() {
    should_skip_package "gstreamer" && { log_info "Skipping GStreamer"; return 0; }
    log_step "Building GStreamer-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gstreamer-* && tar -xf /sources/gstreamer-1.26.5.tar.xz && cd gstreamer-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release -D gst_debug=false
    ninja
    ninja install
    create_checkpoint "gstreamer"
}

build_gst_plugins_base() {
    should_skip_package "gst-plugins-base" && { log_info "Skipping gst-plugins-base"; return 0; }
    log_step "Building gst-plugins-base-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gst-plugins-base-* && tar -xf /sources/gst-plugins-base-1.26.5.tar.xz && cd gst-plugins-base-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release --wrap-mode=nodownload
    ninja
    ninja install
    create_checkpoint "gst-plugins-base"
}

build_gst_plugins_good() {
    should_skip_package "gst-plugins-good" && { log_info "Skipping gst-plugins-good"; return 0; }
    log_step "Building gst-plugins-good-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gst-plugins-good-* && tar -xf /sources/gst-plugins-good-1.26.5.tar.xz && cd gst-plugins-good-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release --wrap-mode=nodownload
    ninja
    ninja install
    create_checkpoint "gst-plugins-good"
}

build_gst_plugins_bad() {
    should_skip_package "gst-plugins-bad" && { log_info "Skipping gst-plugins-bad"; return 0; }
    log_step "Building gst-plugins-bad-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gst-plugins-bad-* && tar -xf /sources/gst-plugins-bad-1.26.5.tar.xz && cd gst-plugins-bad-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release --wrap-mode=nodownload
    ninja
    ninja install
    create_checkpoint "gst-plugins-bad"
}

build_gst_plugins_ugly() {
    should_skip_package "gst-plugins-ugly" && { log_info "Skipping gst-plugins-ugly"; return 0; }
    log_step "Building gst-plugins-ugly-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gst-plugins-ugly-* && tar -xf /sources/gst-plugins-ugly-1.26.5.tar.xz && cd gst-plugins-ugly-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release --wrap-mode=nodownload
    ninja
    ninja install
    create_checkpoint "gst-plugins-ugly"
}

build_gst_libav() {
    should_skip_package "gst-libav" && { log_info "Skipping gst-libav"; return 0; }
    log_step "Building gst-libav-1.26.5..."
    cd "$BUILD_DIR" && rm -rf gst-libav-* && tar -xf /sources/gst-libav-1.26.5.tar.xz && cd gst-libav-*
    mkdir build && cd build
    meson setup .. --prefix=/usr --buildtype=release --wrap-mode=nodownload
    ninja
    ninja install
    create_checkpoint "gst-libav"
}

# Video Codecs
# Which (required for configure scripts to find yasm/nasm)
build_which() {
    should_skip_package "which" && { log_info "Skipping Which"; return 0; }
    log_step "Building Which-2.23..."
    cd "$BUILD_DIR" && rm -rf which-* && tar -xf /sources/which-2.23.tar.gz && cd which-*
    ./configure --prefix=/usr
    make
    make install
    create_checkpoint "which"
}

# NASM (Assembler - required for optimized x264, x265, libvpx, libaom)
build_nasm() {
    should_skip_package "nasm" && { log_info "Skipping NASM"; return 0; }
    log_step "Building NASM-2.16.03..."
    cd "$BUILD_DIR" && rm -rf nasm-* && tar -xf /sources/nasm-2.16.03.tar.xz && cd nasm-*
    ./configure --prefix=/usr
    make
    make install
    create_checkpoint "nasm"
}

build_x264() {
    should_skip_package "x264" && { log_info "Skipping x264"; return 0; }
    log_step "Building x264-20250815..."
    cd "$BUILD_DIR" && rm -rf x264-* && tar -xf /sources/x264-20250815.tar.xz && cd x264-*
    ./configure --prefix=/usr --enable-shared --disable-cli
    make
    make install
    create_checkpoint "x264"
}

build_x265() {
    should_skip_package "x265" && { log_info "Skipping x265"; return 0; }
    log_step "Building x265-4.1..."
    cd "$BUILD_DIR" && rm -rf x265_* && tar -xf /sources/x265_4.1.tar.gz && cd x265_*

    # Fix CMake policy (BLFS requirement)
    sed -r '/cmake_policy.*(0025|0054)/d' -i source/CMakeLists.txt

    mkdir bld && cd bld
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D GIT_ARCHETYPE=1 \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -W no-dev \
          ../source
    make
    make install
    rm -vf /usr/lib/libx265.a
    create_checkpoint "x265"
}

build_libvpx() {
    should_skip_package "libvpx" && { log_info "Skipping libvpx"; return 0; }
    log_step "Building libvpx-1.15.2..."
    cd "$BUILD_DIR" && rm -rf libvpx-* && tar -xf /sources/libvpx-1.15.2.tar.gz && cd libvpx-*

    # Update timestamps (BLFS requirement)
    find -type f | xargs touch

    # Fix ownership/permissions (BLFS requirement)
    sed -i 's/cp -p/cp/' build/make/Makefile

    mkdir libvpx-build && cd libvpx-build
    ../configure --prefix=/usr --enable-shared --disable-static
    make
    make install
    create_checkpoint "libvpx"
}

build_libaom() {
    should_skip_package "libaom" && { log_info "Skipping libaom"; return 0; }
    log_step "Building libaom-3.12.1..."
    cd "$BUILD_DIR" && rm -rf libaom-* aom-* && tar -xf /sources/libaom-3.12.1.tar.gz && cd libaom-* || cd aom-*

    mkdir aom-build && cd aom-build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release \
          -D BUILD_SHARED_LIBS=1 \
          -D ENABLE_DOCS=no \
          -G Ninja ..
    ninja
    ninja install
    rm -v /usr/lib/libaom.a
    create_checkpoint "libaom"
}

# Hardware Acceleration
build_libva() {
    should_skip_package "libva" && { log_info "Skipping libva"; return 0; }
    log_step "Building libva-2.22.0..."
    cd "$BUILD_DIR" && rm -rf libva-* && tar -xf /sources/libva-2.22.0.tar.gz && cd libva-*

    mkdir -p build && cd build
    meson setup --prefix=$XORG_PREFIX --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "libva"
}

build_libvdpau() {
    should_skip_package "libvdpau" && { log_info "Skipping libvdpau"; return 0; }
    log_step "Building libvdpau-1.5..."
    cd "$BUILD_DIR" && rm -rf libvdpau-* && tar -xf /sources/libvdpau-1.5.tar.bz2 && cd libvdpau-*

    mkdir build && cd build
    meson setup --prefix=$XORG_PREFIX ..
    ninja
    ninja install
    create_checkpoint "libvdpau"
}

# FFmpeg
build_ffmpeg() {
    should_skip_package "ffmpeg" && { log_info "Skipping FFmpeg"; return 0; }
    log_step "Building FFmpeg-7.1.1..."
    cd "$BUILD_DIR" && rm -rf ffmpeg-* && tar -xf /sources/ffmpeg-7.1.1.tar.xz && cd ffmpeg-*
    ./configure --prefix=/usr --enable-shared --disable-static --enable-gpl --enable-version3 --enable-nonfree --disable-debug --enable-libvorbis --enable-libopus --enable-libvpx --enable-libaom --enable-libx264 --enable-libx265
    make
    make install
    create_checkpoint "ffmpeg"
}

# Build multimedia packages - Tier 4
# Phase 1: Foundation
build_lua
build_which
build_nasm

# Phase 2: ALSA + Audio Codecs
build_alsa_lib
build_libogg
build_libvorbis
build_flac
build_opus
build_libsndfile
build_libsamplerate
build_alsa_plugins
build_alsa_utils

# Phase 3: GStreamer Foundation (before PipeWire per BLFS recommendations)
build_gstreamer
build_gst_plugins_base

# Phase 4: Audio Servers (PulseAudio before PipeWire per BLFS recommendations)
build_perl_xml_parser
build_pulseaudio
build_pipewire
build_wireplumber

# Phase 5: Advanced GStreamer Plugins
build_gst_plugins_good
build_gst_plugins_bad
build_gst_plugins_ugly

# Phase 6: Video Codecs
build_x264
build_x265
build_libvpx
build_libaom

# Phase 7: Hardware Acceleration
build_libva
build_libvdpau

# Phase 8: FFmpeg (with all codec support)
build_ffmpeg

# Phase 9: GStreamer FFmpeg Plugin
build_gst_libav

log_info ""
log_info "Tier 4 Multimedia Libraries completed!"
log_info "  - ALSA: alsa-lib, alsa-plugins, alsa-utils"
log_info "  - Audio Codecs: libogg, libvorbis, FLAC, Opus, libsndfile, libsamplerate"
log_info "  - Audio Servers: PipeWire, WirePlumber, PulseAudio"
log_info "  - GStreamer: core + base/good/bad/ugly/libav plugins"
log_info "  - Video Codecs: x264, x265, libvpx, libaom"
log_info "  - Hardware Accel: libva, libvdpau"
log_info "  - FFmpeg: Multimedia framework"
log_info ""

# =====================================================================
# Tier 5: GTK Stack
# =====================================================================

log_info ""
log_info "=========================================="
log_info "Building Tier 5: GTK Stack"
log_info "=========================================="
log_info ""

# Brotli-1.1.0 (Compression library - required by FreeType for WOFF2 fonts)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/brotli.html
build_brotli() {
    should_skip_package "brotli" && { log_info "Skipping Brotli"; return 0; }
    log_step "Building Brotli-1.1.0..."
    cd "$BUILD_DIR" && rm -rf brotli-* && tar -xf /sources/brotli-1.1.0.tar.gz && cd brotli-*

    mkdir build && cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release \
          ..
    make
    make install

    # Create pkg-config files - use lowercase variable names to match .pc.in files
    cd ..
    sed -e "s|@prefix@|/usr|g" \
        -e "s|@exec_prefix@|/usr|g" \
        -e "s|@libdir@|/usr/lib|g" \
        -e "s|@includedir@|/usr/include|g" \
        -e "s|@PACKAGE_VERSION@|1.1.0|g" \
        scripts/libbrotlicommon.pc.in > /usr/lib/pkgconfig/libbrotlicommon.pc

    sed -e "s|@prefix@|/usr|g" \
        -e "s|@exec_prefix@|/usr|g" \
        -e "s|@libdir@|/usr/lib|g" \
        -e "s|@includedir@|/usr/include|g" \
        -e "s|@PACKAGE_VERSION@|1.1.0|g" \
        scripts/libbrotlidec.pc.in > /usr/lib/pkgconfig/libbrotlidec.pc

    sed -e "s|@prefix@|/usr|g" \
        -e "s|@exec_prefix@|/usr|g" \
        -e "s|@libdir@|/usr/lib|g" \
        -e "s|@includedir@|/usr/include|g" \
        -e "s|@PACKAGE_VERSION@|1.1.0|g" \
        scripts/libbrotlienc.pc.in > /usr/lib/pkgconfig/libbrotlienc.pc

    create_checkpoint "brotli"
}

# Graphite2-1.3.14 (TrueType font rendering engine - dependency for HarfBuzz)
build_graphite2() {
    should_skip_package "graphite2" && { log_info "Skipping Graphite2"; return 0; }
    log_step "Building Graphite2-1.3.14..."
    cd "$BUILD_DIR" && rm -rf graphite2-* && tar -xf /sources/graphite2-1.3.14.tgz && cd graphite2-*

    sed -i '/cmptest/d' tests/CMakeLists.txt
    sed -i '/cmake_policy(SET CMP0012 NEW)/d' CMakeLists.txt
    sed -i 's/PythonInterp/Python3/' CMakeLists.txt
    find . -name CMakeLists.txt | xargs sed -i 's/VERSION 2.8.0 FATAL_ERROR/VERSION 4.0.0/'
    sed -i '/Font.h/i #include <cstdint>' tests/featuremap/featuremaptest.cpp

    mkdir build && cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr ..
    make
    make install
    create_checkpoint "graphite2"
}

# =====================================================================
# LLVM-20.1.8 (Low Level Virtual Machine - required for Rust, Mesa, etc.)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/llvm.html
# Required by: Rust, Mesa
# Depends on: CMake
# =====================================================================
build_llvm() {
    should_skip_package "llvm" && { log_info "Skipping LLVM"; return 0; }
    log_step "Building LLVM-20.1.8..."

    # Verify sources exist
    if [ ! -f /sources/llvm-20.1.8.src.tar.xz ] || [ ! -f /sources/llvm-cmake-20.1.8.src.tar.xz ] || \
       [ ! -f /sources/llvm-third-party-20.1.8.src.tar.xz ] || [ ! -f /sources/clang-20.1.8.src.tar.xz ]; then
        log_error "LLVM source files not found in /sources"
        return 1
    fi

    cd "$BUILD_DIR"
    rm -rf llvm-*
    tar -xf /sources/llvm-20.1.8.src.tar.xz
    cd llvm-20.1.8.src

    # Extract CMake modules and third-party dependencies
    tar -xf /sources/llvm-cmake-20.1.8.src.tar.xz
    tar -xf /sources/llvm-third-party-20.1.8.src.tar.xz

    # Modify build system to use extracted directories (BLFS requirement)
    sed '/LLVM_COMMON_CMAKE_UTILS/s@../cmake@cmake-20.1.8.src@' -i CMakeLists.txt
    sed '/LLVM_THIRD_PARTY_DIR/s@../third-party@third-party-20.1.8.src@' -i cmake/modules/HandleLLVMOptions.cmake

    # Install Clang into the source tree
    tar -xf /sources/clang-20.1.8.src.tar.xz -C tools
    mv tools/clang-20.1.8.src tools/clang

    # Install Compiler-RT into the source tree (optional but recommended)
    if [ -f /sources/compiler-rt-20.1.8.src.tar.xz ]; then
        tar -xf /sources/compiler-rt-20.1.8.src.tar.xz -C projects
        mv projects/compiler-rt-20.1.8.src projects/compiler-rt
    fi

    # Fix Python scripts to use Python3
    grep -rl '#!.*python' | xargs sed -i '1s/python$/python3/'

    # Ensure FileCheck program is installed (needed for Rust tests)
    sed 's/utility/tool/' -i utils/FileCheck/CMakeLists.txt

    # Create build directory
    mkdir -v build
    cd build

    # Configure with CMake (BLFS 12.4 llvm.html)
    log_info "Configuring LLVM with CMake... (this may take a while)"
    CC=gcc CXX=g++ \
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_SKIP_INSTALL_RPATH=ON \
          -D LLVM_ENABLE_FFI=ON \
          -D CMAKE_BUILD_TYPE=Release \
          -D LLVM_BUILD_LLVM_DYLIB=ON \
          -D LLVM_LINK_LLVM_DYLIB=ON \
          -D LLVM_ENABLE_RTTI=ON \
          -D LLVM_TARGETS_TO_BUILD="host;AMDGPU" \
          -D LLVM_BINUTILS_INCDIR=/usr/include \
          -D LLVM_INCLUDE_BENCHMARKS=OFF \
          -D CLANG_DEFAULT_PIE_ON_LINUX=ON \
          -D CLANG_CONFIG_FILE_SYSTEM_DIR=/etc/clang \
          -W no-dev -G Ninja ..

    # Build LLVM (this will take ~13 SBU)
    log_info "Building LLVM... (this will take significant time - approximately 13 SBU)"
    ninja

    # Install LLVM
    log_info "Installing LLVM..."
    ninja install

    # Configure Clang to use stack protector (BLFS requirement)
    mkdir -pv /etc/clang
    for i in clang clang++; do
        echo -fstack-protector-strong > /etc/clang/$i.cfg
    done

    cd "$BUILD_DIR"
    rm -rf llvm-*

    log_info "LLVM-20.1.8 installed successfully"
    create_checkpoint "llvm"
}

# Rust-1.91.0 (Rust compiler and cargo - required for cargo-c and librsvg)
# NOTE: Unlike BLFS which installs to /opt/rustc, we install to /usr for FHS compliance
# This follows how major distros (Fedora, Debian, Arch) package Rust
build_rust() {
    should_skip_package "rust" && { log_info "Skipping Rust"; return 0; }
    log_step "Building Rust-1.91.0..."

    # Extract source
    cd "$BUILD_DIR"
    rm -rf rustc-1.91.0-src
    tar -xf /sources/rustc-1.91.0-src.tar.xz
    cd rustc-1.91.0-src

    # Create bootstrap configuration (based on BLFS 12.4 rust.html, modified for /usr prefix)
    cat > bootstrap.toml << "EOF"
# See bootstrap.toml.example for more possible options,
# and see src/bootstrap/defaults/bootstrap.dist.toml for a few options
# automatically set when building from a release tarball
# (unfortunately, we have to override many of them).

# Tell x.py the editors have reviewed the content of this file
# and updated it to follow the major changes of the building system,
# so x.py will not warn us to do such a review.
change-id = 142379

[llvm]
# When using system llvm prefer shared libraries
link-shared = true

# If building the shipped LLVM source, only enable the x86 target
# instead of all the targets supported by LLVM.
targets = "X86"

[target.x86_64-unknown-linux-gnu]
llvm-config = "/usr/bin/llvm-config"

[target.i686-unknown-linux-gnu]
llvm-config = "/usr/bin/llvm-config"

[build]
description = "for RookeryOS (BLFS 12.4 based)"

# Omit docs to save time and space (default is to build them).
docs = false

# Do not query new versions of dependencies online.
locked-deps = true

# Specify which extended tools (those from the default install).
tools = ["cargo", "clippy", "rustdoc", "rustfmt"]

[install]
# Install to /usr following FHS like major distros (Fedora, Debian, Arch)
prefix = "/usr"
docdir = "share/doc/rustc-1.91.0"

[rust]
channel = "stable"

# Enable the same optimizations as the official upstream build.
lto = "thin"
codegen-units = 1

# Don't build lld which does not belong to this package and seems not
# so useful for BLFS.  Even if it turns out to be really useful we'd build
# it as a part of the LLVM package instead.
lld = false

# Don't build llvm-bitcode-linker which is only useful for the NVPTX
# backend that we don't enable.
llvm-bitcode-linker = false
EOF

    # Export environment variables for system libraries (BLFS recommendation)
    [ ! -e /usr/include/libssh2.h ] || export LIBSSH2_SYS_USE_PKG_CONFIG=1
    [ ! -e /usr/include/sqlite3.h ] || export LIBSQLITE3_SYS_USE_PKG_CONFIG=1

    # Build Rust (this will take ~9 SBU)
    log_info "Building Rust... (this will take significant time - approximately 9 SBU)"
    ./x.py build

    # Install Rust to /usr
    log_info "Installing Rust to /usr..."
    ./x.py install

    # Clean up bootstrap
    rm -rf build

    # Fix documentation installation
    rm -fv /usr/share/doc/rustc-1.91.0/*.old
    install -vm644 README.md /usr/share/doc/rustc-1.91.0

    # Ensure completions are in standard locations
    install -vdm755 /usr/share/zsh/site-functions
    install -vdm755 /usr/share/bash-completion/completions

    # Move bash completion if installed to wrong location
    if [ -f /etc/bash_completion.d/cargo ]; then
        mv -v /etc/bash_completion.d/cargo /usr/share/bash-completion/completions
    fi

    # Unset environment variables
    unset LIBSSH2_SYS_USE_PKG_CONFIG
    unset LIBSQLITE3_SYS_USE_PKG_CONFIG

    # Verify cargo is available (should be in /usr/bin now)
    which cargo || { log_error "Cargo not found in PATH after Rust installation"; return 1; }
    cargo --version || { log_error "Cargo not functional after installation"; return 1; }
    log_info "Rust installed to /usr/bin (FHS compliant)"

    create_checkpoint "rust"
}

# HarfBuzz-11.4.1 (OpenType text shaping engine)
#
# CIRCULAR DEPENDENCY: FreeType <-> HarfBuzz <-> Cairo
# Build order per BLFS:
#   1. Build FreeType WITHOUT HarfBuzz (done earlier in build_freetype)
#   2. Build HarfBuzz WITH FreeType support (this function)
#   3. Rebuild FreeType WITH HarfBuzz support (rebuild_freetype below)
#   4. Build Cairo (build_cairo in Phase 2)
#   5. Rebuild HarfBuzz WITH Cairo support (rebuild_harfbuzz below)
#
build_harfbuzz() {
    should_skip_package "harfbuzz" && { log_info "Skipping HarfBuzz"; return 0; }
    log_step "Building HarfBuzz-11.4.1 (with FreeType, without Cairo)..."
    cd "$BUILD_DIR" && rm -rf harfbuzz-* && tar -xf /sources/harfbuzz-11.4.1.tar.xz && cd harfbuzz-*

    mkdir build && cd build
    # Enable FreeType (installed), Graphite2 (installed), GLib/GObject (installed)
    # Disable Cairo (not yet installed - will rebuild HarfBuzz with Cairo later)
    # Disable docs and tests to speed up build
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        -D freetype=enabled \
        -D graphite2=enabled \
        -D glib=enabled \
        -D gobject=enabled \
        -D cairo=disabled \
        -D docs=disabled \
        -D tests=disabled
    ninja
    ninja install
    create_checkpoint "harfbuzz"
}

# Rebuild FreeType-2.13.3 with HarfBuzz support
# This is step 3 of the circular dependency resolution:
#   1. FreeType (without HarfBuzz) - done earlier
#   2. HarfBuzz (with FreeType) - done above
#   3. FreeType (with HarfBuzz) - THIS FUNCTION
rebuild_freetype() {
    should_skip_package "freetype-rebuild" && { log_info "Skipping FreeType rebuild"; return 0; }
    log_step "Rebuilding FreeType-2.13.3 with HarfBuzz support..."
    cd "$BUILD_DIR" && rm -rf freetype-* && tar -xf /sources/freetype-2.13.3.tar.xz && cd freetype-*

    # Enable GX/AAT and OpenType table validation
    sed -ri "s:.*(AUX_MODULES.*valid):\1:" modules.cfg
    # Enable Subpixel Rendering
    sed -r "s:.*(#.*SUBPIXEL_RENDERING) .*:\1:" -i include/freetype/config/ftoption.h

    # Per BLFS: FreeType auto-detects harfbuzz, libpng, brotli, bzip2
    # Don't use --with-* flags as they can cause libtool issues
    ./configure --prefix=/usr --enable-freetype-config --disable-static
    make
    make install
    create_checkpoint "freetype-rebuild"
}

# Rebuild HarfBuzz-11.4.1 with Cairo support
# This is step 5 of the circular dependency resolution:
#   4. Cairo (with HarfBuzz) - done in Phase 2
#   5. HarfBuzz (with Cairo) - THIS FUNCTION
# This enables full HarfBuzz functionality including Cairo rendering
rebuild_harfbuzz() {
    should_skip_package "harfbuzz-rebuild" && { log_info "Skipping HarfBuzz rebuild"; return 0; }
    log_step "Rebuilding HarfBuzz-11.4.1 with Cairo support..."
    cd "$BUILD_DIR" && rm -rf harfbuzz-* && tar -xf /sources/harfbuzz-11.4.1.tar.xz && cd harfbuzz-*

    mkdir build && cd build
    # NOW we can enable Cairo support since Cairo is installed
    meson setup .. \
        --prefix=/usr \
        --buildtype=release \
        -D freetype=enabled \
        -D graphite2=enabled \
        -D glib=enabled \
        -D gobject=enabled \
        -D cairo=enabled \
        -D docs=disabled \
        -D tests=disabled
    ninja
    ninja install
    create_checkpoint "harfbuzz-rebuild"
}

# Rebuild Fontconfig-2.17.1 after FreeType+HarfBuzz rebuild
# This ensures Fontconfig can use the full font rendering capabilities
rebuild_fontconfig() {
    should_skip_package "fontconfig-rebuild" && { log_info "Skipping Fontconfig rebuild"; return 0; }
    log_step "Rebuilding Fontconfig-2.17.1 with FreeType+HarfBuzz..."
    cd "$BUILD_DIR" && rm -rf fontconfig-* && tar -xf /sources/fontconfig-2.17.1.tar.xz && cd fontconfig-*

    ./configure --prefix=/usr \
                --sysconfdir=/etc \
                --localstatedir=/var \
                --disable-docs \
                --docdir=/usr/share/doc/fontconfig-2.17.1
    make
    make install

    # Update font cache
    fc-cache -f

    create_checkpoint "fontconfig-rebuild"
}

# FriBidi-1.0.16 (Unicode Bidirectional Algorithm)
build_fribidi() {
    should_skip_package "fribidi" && { log_info "Skipping FriBidi"; return 0; }
    log_step "Building FriBidi-1.0.16..."
    cd "$BUILD_DIR" && rm -rf fribidi-* && tar -xf /sources/fribidi-1.0.16.tar.xz && cd fribidi-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "fribidi"
}

# Pixman-0.46.4 (Low-level pixel manipulation library)
build_pixman() {
    should_skip_package "pixman" && { log_info "Skipping Pixman"; return 0; }
    log_step "Building Pixman-0.46.4..."
    cd "$BUILD_DIR" && rm -rf pixman-* && tar -xf /sources/pixman-0.46.4.tar.gz && cd pixman-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "pixman"
}

# Fontconfig-2.17.1 (Font configuration library)
build_fontconfig() {
    should_skip_package "fontconfig" && { log_info "Skipping Fontconfig"; return 0; }
    log_step "Building Fontconfig-2.17.1..."
    cd "$BUILD_DIR" && rm -rf fontconfig-* && tar -xf /sources/fontconfig-2.17.1.tar.xz && cd fontconfig-*

    ./configure --prefix=/usr \
                --sysconfdir=/etc \
                --localstatedir=/var \
                --disable-docs \
                --docdir=/usr/share/doc/fontconfig-2.17.1
    make
    make install
    create_checkpoint "fontconfig"
}

# Graphene-1.10.8 (Thin layer of types for graphics)
build_graphene() {
    should_skip_package "graphene" && { log_info "Skipping Graphene"; return 0; }
    log_step "Building Graphene-1.10.8..."
    cd "$BUILD_DIR" && rm -rf graphene-* && tar -xf /sources/graphene-1.10.8.tar.xz && cd graphene-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "graphene"
}

# libxkbcommon-1.11.0 (XKB keymap handling library)
build_libxkbcommon() {
    should_skip_package "libxkbcommon" && { log_info "Skipping libxkbcommon"; return 0; }
    log_step "Building libxkbcommon-1.11.0..."
    cd "$BUILD_DIR" && rm -rf libxkbcommon-* && tar -xf /sources/libxkbcommon-1.11.0.tar.gz && cd libxkbcommon-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Denable-docs=false ..
    ninja
    ninja install
    create_checkpoint "libxkbcommon"
}

# Cairo-1.18.4 (2D graphics library)
build_cairo() {
    should_skip_package "cairo" && { log_info "Skipping Cairo"; return 0; }
    log_step "Building Cairo-1.18.4..."
    cd "$BUILD_DIR" && rm -rf cairo-* && tar -xf /sources/cairo-1.18.4.tar.xz && cd cairo-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "cairo"
}

# Pango-1.56.4 (Text layout library)
build_pango() {
    should_skip_package "pango" && { log_info "Skipping Pango"; return 0; }
    log_step "Building Pango-1.56.4..."
    cd "$BUILD_DIR" && rm -rf pango-* && tar -xf /sources/pango-1.56.4.tar.xz && cd pango-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback -Dintrospection=enabled ..
    ninja
    ninja install
    create_checkpoint "pango"
}

# at-spi2-core-2.56.4 (Assistive Technology Service Provider Interface)
build_atspi() {
    should_skip_package "atspi" && { log_info "Skipping at-spi2-core"; return 0; }
    log_step "Building at-spi2-core-2.56.4..."
    cd "$BUILD_DIR" && rm -rf at-spi2-core-* && tar -xf /sources/at-spi2-core-2.56.4.tar.xz && cd at-spi2-core-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Dgtk2_atk_adaptor=false ..
    ninja
    ninja install
    create_checkpoint "atspi"
}

# libjpeg-turbo-3.0.1 (JPEG image codec)
build_libjpeg_turbo() {
    should_skip_package "libjpeg-turbo" && { log_info "Skipping libjpeg-turbo"; return 0; }
    log_step "Building libjpeg-turbo-3.0.1..."
    cd "$BUILD_DIR" && rm -rf libjpeg-turbo-* && tar -xf /sources/libjpeg-turbo-3.0.1.tar.gz && cd libjpeg-turbo-*

    mkdir build && cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=RELEASE \
          -D ENABLE_STATIC=FALSE \
          -D CMAKE_INSTALL_DEFAULT_LIBDIR=lib \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -D CMAKE_SKIP_INSTALL_RPATH=ON \
          -D CMAKE_INSTALL_DOCDIR=/usr/share/doc/libjpeg-turbo-3.0.1 \
          ..
    make
    make install
    create_checkpoint "libjpeg-turbo"
}

# libtiff-4.7.0 (TIFF image library)
build_libtiff() {
    should_skip_package "libtiff" && { log_info "Skipping libtiff"; return 0; }
    log_step "Building libtiff-4.7.0..."
    cd "$BUILD_DIR" && rm -rf tiff-* && tar -xf /sources/tiff-4.7.0.tar.gz && cd tiff-*

    mkdir -p libtiff-build && cd libtiff-build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -G Ninja \
          -D CMAKE_INSTALL_DOCDIR=/usr/share/doc/libtiff-4.7.0 \
          ..
    ninja
    ninja install
    create_checkpoint "libtiff"
}

# gdk-pixbuf-2.42.12 (Image loading library for GTK)
build_gdk_pixbuf() {
    should_skip_package "gdk-pixbuf" && { log_info "Skipping gdk-pixbuf"; return 0; }
    log_step "Building gdk-pixbuf-2.42.12..."
    cd "$BUILD_DIR" && rm -rf gdk-pixbuf-* && tar -xf /sources/gdk-pixbuf-2.42.12.tar.xz && cd gdk-pixbuf-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Dothers=enabled -Dman=false --wrap-mode=nofallback ..
    ninja
    ninja install
    gdk-pixbuf-query-loaders --update-cache
    create_checkpoint "gdk-pixbuf"
}

# cargo-c-0.10.15 (Helper to build Rust C-ABI libraries)
build_cargo_c() {
    should_skip_package "cargo-c" && { log_info "Skipping cargo-c"; return 0; }
    log_step "Building cargo-c-0.10.15..."

    # Rust is installed to /usr/bin, should already be in PATH

    cd "$BUILD_DIR" && rm -rf cargo-c-* && tar -xf /sources/cargo-c-0.10.15.tar.gz && cd cargo-c-*

    cargo build --release
    install -vDm755 target/release/cargo-cbuild /usr/bin/
    install -vDm755 target/release/cargo-cinstall /usr/bin/
    install -vDm755 target/release/cargo-ctest /usr/bin/
    create_checkpoint "cargo-c"
}

# librsvg-2.61.0 (SVG rendering library)
build_librsvg() {
    should_skip_package "librsvg" && { log_info "Skipping librsvg"; return 0; }
    log_step "Building librsvg-2.61.0..."
    cd "$BUILD_DIR" && rm -rf librsvg-* && tar -xf /sources/librsvg-2.61.0.tar.xz && cd librsvg-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "librsvg"
}

# shared-mime-info-2.4 (MIME database)
build_shared_mime_info() {
    should_skip_package "shared-mime-info" && { log_info "Skipping shared-mime-info"; return 0; }
    log_step "Building shared-mime-info-2.4..."
    cd "$BUILD_DIR" && rm -rf shared-mime-info-* && tar -xf /sources/shared-mime-info-2.4.tar.gz && cd shared-mime-info-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Dupdate-mimedb=true ..
    ninja
    ninja install
    create_checkpoint "shared-mime-info"
}

# ISO Codes-4.18.0 (ISO country/language/currency codes)
build_iso_codes() {
    should_skip_package "iso-codes" && { log_info "Skipping ISO Codes"; return 0; }
    log_step "Building ISO Codes-4.18.0..."
    cd "$BUILD_DIR" && rm -rf iso-codes-* && tar -xf /sources/iso-codes-v4.18.0.tar.gz && cd iso-codes-*

    ./configure --prefix=/usr
    make
    make install LN_S='ln -sfn'
    create_checkpoint "iso-codes"
}

# hicolor-icon-theme-0.18 (Default icon theme)
build_hicolor_icon_theme() {
    should_skip_package "hicolor-icon-theme" && { log_info "Skipping hicolor-icon-theme"; return 0; }
    log_step "Building hicolor-icon-theme-0.18..."
    cd "$BUILD_DIR" && rm -rf hicolor-icon-theme-* && tar -xf /sources/hicolor-icon-theme-0.18.tar.xz && cd hicolor-icon-theme-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "hicolor-icon-theme"
}

# adwaita-icon-theme-48.1 (GNOME icon theme)
build_adwaita_icon_theme() {
    should_skip_package "adwaita-icon-theme" && { log_info "Skipping adwaita-icon-theme"; return 0; }
    log_step "Building adwaita-icon-theme-48.1..."
    cd "$BUILD_DIR" && rm -rf adwaita-icon-theme-* && tar -xf /sources/adwaita-icon-theme-48.1.tar.xz && cd adwaita-icon-theme-*

    mkdir build && cd build
    meson setup --prefix=/usr ..
    ninja
    rm -rf /usr/share/icons/Adwaita/
    ninja install
    create_checkpoint "adwaita-icon-theme"
}

# gsettings-desktop-schemas-48.0 (GSettings schemas for desktop applications)
build_gsettings_desktop_schemas() {
    should_skip_package "gsettings-desktop-schemas" && { log_info "Skipping gsettings-desktop-schemas"; return 0; }
    log_step "Building gsettings-desktop-schemas-48.0..."
    cd "$BUILD_DIR" && rm -rf gsettings-desktop-schemas-* && tar -xf /sources/gsettings-desktop-schemas-48.0.tar.xz && cd gsettings-desktop-schemas-*

    sed -i -r 's:"(/system):"/org/gnome\1:g' schemas/*.in

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    glib-compile-schemas /usr/share/glib-2.0/schemas
    create_checkpoint "gsettings-desktop-schemas"
}

# docbook-xml-4.5 (DocBook XML DTDs - required by docbook-xsl)
# https://www.linuxfromscratch.org/blfs/view/12.4/pst/docbook.html
# Using Debian's tar.gz instead of OASIS zip (avoids need for unzip)
build_docbook_xml() {
    should_skip_package "docbook-xml" && { log_info "Skipping docbook-xml"; return 0; }
    log_step "Installing docbook-xml-4.5..."
    cd "$BUILD_DIR"

    # Create directory structure
    install -v -d -m755 /usr/share/xml/docbook/xml-dtd-4.5
    install -v -d -m755 /etc/xml

    # Extract and install (using tar.gz from Debian instead of zip)
    cd /usr/share/xml/docbook/xml-dtd-4.5
    tar -xf /sources/docbook-xml_4.5.orig.tar.gz --strip-components=1

    # Create XML catalog if it doesn't exist
    if [ ! -f /etc/xml/docbook ]; then
        xmlcatalog --noout --create /etc/xml/docbook
    fi

    # Add entries to docbook catalog
    xmlcatalog --noout --add "public" \
        "-//OASIS//DTD DocBook XML V4.5//EN" \
        "http://www.oasis-open.org/docbook/xml/4.5/docbookx.dtd" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//DTD DocBook XML CALS Table Model V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/calstblx.dtd" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//DTD XML Exchange Table Model 19990315//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/soextblx.dtd" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ELEMENTS DocBook XML Information Pool V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/dbpoolx.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ELEMENTS DocBook XML Document Hierarchy V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/dbhierx.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ELEMENTS DocBook XML HTML Tables V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/htmltblx.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ENTITIES DocBook XML Notations V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/dbnotnx.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ENTITIES DocBook XML Character Entities V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/dbcentx.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "public" \
        "-//OASIS//ENTITIES DocBook XML Additional General Entities V4.5//EN" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5/dbgenent.mod" \
        /etc/xml/docbook

    xmlcatalog --noout --add "rewriteSystem" \
        "http://www.oasis-open.org/docbook/xml/4.5" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5" \
        /etc/xml/docbook

    xmlcatalog --noout --add "rewriteURI" \
        "http://www.oasis-open.org/docbook/xml/4.5" \
        "file:///usr/share/xml/docbook/xml-dtd-4.5" \
        /etc/xml/docbook

    # Create main XML catalog if it doesn't exist
    if [ ! -f /etc/xml/catalog ]; then
        xmlcatalog --noout --create /etc/xml/catalog
    fi

    # Add docbook catalog to main catalog
    xmlcatalog --noout --add "delegatePublic" \
        "-//OASIS//ENTITIES DocBook XML" \
        "file:///etc/xml/docbook" \
        /etc/xml/catalog

    xmlcatalog --noout --add "delegatePublic" \
        "-//OASIS//DTD DocBook XML" \
        "file:///etc/xml/docbook" \
        /etc/xml/catalog

    xmlcatalog --noout --add "delegateSystem" \
        "http://www.oasis-open.org/docbook/" \
        "file:///etc/xml/docbook" \
        /etc/xml/catalog

    xmlcatalog --noout --add "delegateURI" \
        "http://www.oasis-open.org/docbook/" \
        "file:///etc/xml/docbook" \
        /etc/xml/catalog

    # Add support for older DocBook versions (4.1.2 through 4.4)
    for DTDVERSION in 4.1.2 4.2 4.3 4.4; do
        xmlcatalog --noout --add "public" \
            "-//OASIS//DTD DocBook XML V$DTDVERSION//EN" \
            "http://www.oasis-open.org/docbook/xml/$DTDVERSION/docbookx.dtd" \
            /etc/xml/docbook
        xmlcatalog --noout --add "rewriteSystem" \
            "http://www.oasis-open.org/docbook/xml/$DTDVERSION" \
            "file:///usr/share/xml/docbook/xml-dtd-4.5" \
            /etc/xml/docbook
        xmlcatalog --noout --add "rewriteURI" \
            "http://www.oasis-open.org/docbook/xml/$DTDVERSION" \
            "file:///usr/share/xml/docbook/xml-dtd-4.5" \
            /etc/xml/docbook
        xmlcatalog --noout --add "delegateSystem" \
            "http://www.oasis-open.org/docbook/xml/$DTDVERSION/" \
            "file:///etc/xml/docbook" \
            /etc/xml/catalog
        xmlcatalog --noout --add "delegateURI" \
            "http://www.oasis-open.org/docbook/xml/$DTDVERSION/" \
            "file:///etc/xml/docbook" \
            /etc/xml/catalog
    done

    # Create symlinks for CMake FindDocBookXML4 to find the DTDs
    # The Debian tarball puts DTDs in subdirectories, but CMake expects them directly
    # Create schema/dtd directories that KDE's CMake modules look for
    mkdir -p /usr/share/xml/docbook/schema/dtd
    for VERSION in 4.0 4.1.2 4.2 4.3 4.4 4.5; do
        if [ -d "/usr/share/xml/docbook/xml-dtd-4.5/docbook-$VERSION" ]; then
            ln -sfn "/usr/share/xml/docbook/xml-dtd-4.5/docbook-$VERSION" \
                "/usr/share/xml/docbook/schema/dtd/$VERSION"
        fi
    done
    # Also create a direct link from xml-dtd-4.5 to the 4.5 DTD contents for packages
    # that look directly in xml-dtd-4.5 for docbookx.dtd
    if [ -f "/usr/share/xml/docbook/xml-dtd-4.5/docbook-4.5/docbookx.dtd" ]; then
        for f in /usr/share/xml/docbook/xml-dtd-4.5/docbook-4.5/*; do
            fname=$(basename "$f")
            if [ ! -e "/usr/share/xml/docbook/xml-dtd-4.5/$fname" ]; then
                ln -sfn "docbook-4.5/$fname" "/usr/share/xml/docbook/xml-dtd-4.5/$fname"
            fi
        done
    fi

    create_checkpoint "docbook-xml"
}

# docbook-xsl-nons-1.79.2 (DocBook XSLT stylesheets)
# https://www.linuxfromscratch.org/blfs/view/12.4/pst/docbook-xsl.html
# Requires: docbook-xml, libxml2
build_docbook_xsl() {
    should_skip_package "docbook-xsl" && { log_info "Skipping docbook-xsl"; return 0; }
    log_step "Building docbook-xsl-nons-1.79.2..."
    cd "$BUILD_DIR" && rm -rf docbook-xsl-* && tar -xf /sources/docbook-xsl-nons-1.79.2.tar.bz2 && cd docbook-xsl-*

    patch -Np1 -i /sources/docbook-xsl-nons-1.79.2-stack_fix-1.patch

    install -v -m755 -d /usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2
    cp -v -R VERSION assembly common eclipse epub epub3 extensions fo \
             highlighting html htmlhelp images javahelp lib manpages params \
             profiling roundtrip slides template tests tools webhelp website \
             xhtml xhtml-1_1 xhtml5 \
        /usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2

    ln -s VERSION /usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2/VERSION.xsl

    install -v -m644 -D README \
                        /usr/share/doc/docbook-xsl-nons-1.79.2/README.txt
    install -v -m644    RELEASE-NOTES* NEWS* \
                        /usr/share/doc/docbook-xsl-nons-1.79.2

    if [ ! -d /etc/xml ]; then install -v -m755 -d /etc/xml; fi
    if [ ! -f /etc/xml/catalog ]; then
        xmlcatalog --noout --create /etc/xml/catalog
    fi

    xmlcatalog --noout --add "rewriteSystem" \
               "https://cdn.docbook.org/release/xsl-nons/1.79.2" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    xmlcatalog --noout --add "rewriteURI" \
               "https://cdn.docbook.org/release/xsl-nons/1.79.2" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    xmlcatalog --noout --add "rewriteSystem" \
               "https://cdn.docbook.org/release/xsl-nons/current" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    xmlcatalog --noout --add "rewriteURI" \
               "https://cdn.docbook.org/release/xsl-nons/current" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    xmlcatalog --noout --add "rewriteSystem" \
               "http://docbook.sourceforge.net/release/xsl/current" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    xmlcatalog --noout --add "rewriteURI" \
               "http://docbook.sourceforge.net/release/xsl/current" \
               "/usr/share/xml/docbook/xsl-stylesheets-nons-1.79.2" \
        /etc/xml/catalog

    create_checkpoint "docbook-xsl"
}

# itstool-2.0.7 (XML translation tool)
# https://www.linuxfromscratch.org/blfs/view/stable/pst/itstool.html
# Requires: docbook-xml
build_itstool() {
    should_skip_package "itstool" && { log_info "Skipping itstool"; return 0; }
    log_step "Building itstool-2.0.7..."

    if [ ! -f /sources/itstool-2.0.7.tar.bz2 ]; then
        log_error "itstool-2.0.7.tar.bz2 not found in /sources"
        exit 1
    fi

    cd "$BUILD_DIR"
    rm -rf itstool-*
    tar -xf /sources/itstool-2.0.7.tar.bz2
    cd itstool-*

    # Fix compatibility problems with Python-3.12 and later
    sed -i 's/re.sub(/re.sub(r/'         itstool.in
    sed -i 's/re.compile(/re.compile(r/' itstool.in

    PYTHON=/usr/bin/python3 ./configure --prefix=/usr
    make
    make install

    cd "$BUILD_DIR"
    rm -rf itstool-*

    log_info "itstool-2.0.7 installed successfully"
    create_checkpoint "itstool"
}

# 7zip-25.01 (File archiver utility - handles ZIP, 7z, and many other formats)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/7zip.html
# Required for: ibus (UCD.zip extraction)
build_7zip() {
    should_skip_package "7zip" && { log_info "Skipping 7zip"; return 0; }
    log_step "Building 7zip-25.01..."

    if [ ! -f /sources/7zip-25.01.tar.gz ]; then
        log_error "7zip-25.01.tar.gz not found in /sources"
        exit 1
    fi

    cd "$BUILD_DIR"
    rm -rf 7zip-*
    tar -xf /sources/7zip-25.01.tar.gz
    cd 7zip-*

    # Build all components
    (for i in Bundles/{Alone,Alone7z,Format7zF,SFXCon} UI/Console; do
        make -C CPP/7zip/$i -f ../../cmpl_gcc.mak || exit
    done)

    # Install binaries and library
    install -vDm755 CPP/7zip/Bundles/Alone/b/g/7za \
                    CPP/7zip/Bundles/Alone7z/b/g/7zr \
                    CPP/7zip/Bundles/Format7zF/b/g/7z.so \
                    CPP/7zip/UI/Console/b/g/7z \
                    -t /usr/lib/7zip/

    install -vm755 CPP/7zip/Bundles/SFXCon/b/g/7zCon \
                   /usr/lib/7zip/7zCon.sfx

    # Create wrapper scripts in /usr/bin
    for i in 7z 7za 7zr; do
        cat > /usr/bin/$i << EOF
#!/bin/sh
exec /usr/lib/7zip/$i "\$@"
EOF
        chmod 755 /usr/bin/$i
    done

    # Install documentation
    cp -rv DOC -T /usr/share/doc/7zip-25.01

    cd "$BUILD_DIR"
    rm -rf 7zip-*

    log_info "7zip-25.01 installed successfully"
    create_checkpoint "7zip"
}


# ========================================
# Python Test Dependencies (for PyGObject tests)
# Build order: setuptools_scm → editables, pathspec, trove-classifiers → pluggy, hatchling → hatch_vcs → iniconfig → pytest
# ========================================

# Setuptools_scm-8.3.1 (no required dependencies)
build_setuptools_scm() {
    should_skip_package "setuptools_scm" && { log_info "Skipping Setuptools_scm"; return 0; }
    log_step "Building Setuptools_scm-8.3.1..."
    cd "$BUILD_DIR" && rm -rf setuptools_scm-* && tar -xf /sources/setuptools_scm-8.3.1.tar.gz && cd setuptools_scm-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user setuptools_scm
    create_checkpoint "setuptools_scm"
}

# Editables-0.5 (required by hatchling)
build_editables() {
    should_skip_package "editables" && { log_info "Skipping Editables"; return 0; }
    log_step "Building Editables-0.5..."
    cd "$BUILD_DIR" && rm -rf editables-* && tar -xf /sources/editables-0.5.tar.gz && cd editables-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user editables
    create_checkpoint "editables"
}

# Pathspec-0.12.1 (required by hatchling)
build_pathspec() {
    should_skip_package "pathspec" && { log_info "Skipping Pathspec"; return 0; }
    log_step "Building Pathspec-0.12.1..."
    cd "$BUILD_DIR" && rm -rf pathspec-* && tar -xf /sources/pathspec-0.12.1.tar.gz && cd pathspec-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user pathspec
    create_checkpoint "pathspec"
}

# Trove-Classifiers-2025.8.6.13 (required by hatchling)
build_trove_classifiers() {
    should_skip_package "trove_classifiers" && { log_info "Skipping Trove-Classifiers"; return 0; }
    log_step "Building Trove-Classifiers-2025.8.6.13..."
    cd "$BUILD_DIR" && rm -rf trove_classifiers-* && tar -xf /sources/trove_classifiers-2025.8.6.13.tar.gz && cd trove_classifiers-*

    # Hard code version to work around calver module issue
    sed -i '/calver/s/^/#/;$iversion="2025.8.6.13"' setup.py

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user trove-classifiers
    create_checkpoint "trove_classifiers"
}

# Pluggy-1.6.0 (required by pytest, recommends setuptools_scm)
build_pluggy() {
    should_skip_package "pluggy" && { log_info "Skipping Pluggy"; return 0; }
    log_step "Building Pluggy-1.6.0..."
    cd "$BUILD_DIR" && rm -rf pluggy-* && tar -xf /sources/pluggy-1.6.0.tar.gz && cd pluggy-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user pluggy
    create_checkpoint "pluggy"
}

# Hatchling-1.27.0 (required by hatch_vcs)
build_hatchling() {
    should_skip_package "hatchling" && { log_info "Skipping Hatchling"; return 0; }
    log_step "Building Hatchling-1.27.0..."
    cd "$BUILD_DIR" && rm -rf hatchling-* && tar -xf /sources/hatchling-1.27.0.tar.gz && cd hatchling-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user hatchling
    create_checkpoint "hatchling"
}

# Hatch_vcs-0.5.0 (required by iniconfig)
build_hatch_vcs() {
    should_skip_package "hatch_vcs" && { log_info "Skipping Hatch_vcs"; return 0; }
    log_step "Building Hatch_vcs-0.5.0..."
    cd "$BUILD_DIR" && rm -rf hatch_vcs-* && tar -xf /sources/hatch_vcs-0.5.0.tar.gz && cd hatch_vcs-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user hatch_vcs
    create_checkpoint "hatch_vcs"
}

# Iniconfig-2.1.0 (required by pytest)
build_iniconfig() {
    should_skip_package "iniconfig" && { log_info "Skipping Iniconfig"; return 0; }
    log_step "Building Iniconfig-2.1.0..."
    cd "$BUILD_DIR" && rm -rf iniconfig-* && tar -xf /sources/iniconfig-2.1.0.tar.gz && cd iniconfig-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user iniconfig
    create_checkpoint "iniconfig"
}

# Pygments-2.19.2 (syntax highlighter - required by pytest)
build_pygments() {
    should_skip_package "pygments" && { log_info "Skipping Pygments"; return 0; }
    log_step "Building Pygments-2.19.2..."
    cd "$BUILD_DIR" && rm -rf pygments-* && tar -xf /sources/pygments-2.19.2.tar.gz && cd pygments-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user Pygments
    create_checkpoint "pygments"
}

# Pytest-8.4.1 (test framework - optional for PyGObject tests)
build_pytest() {
    should_skip_package "pytest" && { log_info "Skipping Pytest"; return 0; }
    log_step "Building Pytest-8.4.1..."
    cd "$BUILD_DIR" && rm -rf pytest-* && tar -xf /sources/pytest-8.4.1.tar.gz && cd pytest-*

    pip3 wheel -w dist --no-build-isolation --no-deps --no-cache-dir $PWD
    pip3 install --no-index --find-links dist --no-user pytest
    create_checkpoint "pytest"
}

# Install pep8 and pyflakes via pip3 (PyPI packages, not in BLFS book)
build_pep8_pyflakes() {
    should_skip_package "pep8_pyflakes" && { log_info "Skipping pep8 and pyflakes"; return 0; }
    log_step "Installing pep8 and pyflakes via pip3..."

    # Install directly from PyPI
    pip3 install pep8 pyflakes
    create_checkpoint "pep8_pyflakes"
}

# PyCairo-1.28.0 (Python Cairo bindings - recommended for PyGObject)
build_pycairo() {
    should_skip_package "pycairo" && { log_info "Skipping PyCairo"; return 0; }
    log_step "Building PyCairo-1.28.0..."
    cd "$BUILD_DIR" && rm -rf pycairo-* && tar -xf /sources/pycairo-1.28.0.tar.gz && cd pycairo-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "pycairo"
}

# PyGObject-3.52.3 (Python GObject bindings)
build_pygobject() {
    should_skip_package "pygobject" && { log_info "Skipping PyGObject"; return 0; }
    log_step "Building PyGObject-3.52.3..."
    cd "$BUILD_DIR" && rm -rf pygobject-* && tar -xf /sources/pygobject-3.52.3.tar.gz && cd pygobject-*

    mv -v tests/test_gdbus.py{,.nouse}
    mv -v tests/test_overrides_gtk.py{,.nouse}

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release ..
    ninja
    ninja install
    create_checkpoint "pygobject"
}

# shaderc-2025.3 (Shader compiler for Vulkan)
build_shaderc() {
    should_skip_package "shaderc" && { log_info "Skipping shaderc"; return 0; }
    log_step "Building shaderc-2025.3..."
    cd "$BUILD_DIR" && rm -rf shaderc-* && tar -xf /sources/shaderc-2025.3.tar.gz && cd shaderc-*

    sed '/build-version/d'   -i glslc/CMakeLists.txt
    sed '/third_party/d'     -i CMakeLists.txt
    sed 's|SPIRV|glslang/&|' -i libshaderc_util/src/compiler.cc

    echo '"2025.3"' > glslc/src/build-version.inc

    mkdir build && cd build
    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_BUILD_TYPE=Release \
          -D SHADERC_SKIP_TESTS=ON \
          -G Ninja ..
    ninja
    install -vm755 glslc/glslc /usr/bin
    create_checkpoint "shaderc"
}

# GTK-3.24.50 (GTK+ toolkit version 3)
build_gtk3() {
    should_skip_package "gtk3" && { log_info "Skipping GTK-3"; return 0; }
    log_step "Building GTK-3.24.50..."
    cd "$BUILD_DIR" && rm -rf gtk-3* && tar -xf /sources/gtk-3.24.50.tar.xz && cd gtk-*

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release -Dman=true -Dbroadway_backend=true ..
    ninja
    ninja install
    gtk-query-immodules-3.0 --update-cache
    glib-compile-schemas /usr/share/glib-2.0/schemas
    create_checkpoint "gtk3"
}

# GTK-4.18.6 (GTK toolkit version 4)
build_gtk4() {
    should_skip_package "gtk4" && { log_info "Skipping GTK-4"; return 0; }
    log_step "Building GTK-4.18.6..."
    cd "$BUILD_DIR" && rm -rf gtk-4.18.6 && tar -xf /sources/gtk-4.18.6.tar.xz && cd gtk-4.18.6

    sed -e '939 s/= { 0, }//' \
        -e '940 a memset (&transform, 0, sizeof(GtkCssTransform));' \
        -i gtk/gtkcsstransformvalue.c

    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release \
                -Dbroadway-backend=true \
                -Dintrospection=enabled \
                -Dvulkan=enabled \
                ..
    ninja
    ninja install
    glib-compile-schemas /usr/share/glib-2.0/schemas
    create_checkpoint "gtk4"
}

# Execute Tier 5 builds
log_info "Phase 1: Foundation Libraries (FreeType-HarfBuzz circular dependency resolution)"
log_info "  Step 1: FreeType without HarfBuzz was built earlier in Tier 3"
log_info "  Step 2: Building HarfBuzz with FreeType support"
log_info "  Step 3: Rebuilding FreeType with HarfBuzz + Brotli support"
build_brotli            # Needed for FreeType WOFF2 support
build_graphite2
build_llvm
build_rust
build_harfbuzz          # Step 2: Build HarfBuzz with FreeType
rebuild_freetype        # Step 3: Rebuild FreeType with HarfBuzz + Brotli
rebuild_fontconfig      # Step 4: Rebuild Fontconfig with new FreeType
build_fribidi
build_pixman
build_fontconfig
build_graphene
build_libxkbcommon

log_info "Phase 2: Graphics & Rendering (with HarfBuzz-Cairo circular dependency fix)"
build_cairo
rebuild_harfbuzz  # Rebuild HarfBuzz with Cairo support now that Cairo is installed
build_pango
build_atspi

log_info "Phase 3: Image & Icon Support"
build_libjpeg_turbo
build_libtiff
build_shared_mime_info
build_gdk_pixbuf
build_cargo_c
build_librsvg
build_iso_codes
build_hicolor_icon_theme
build_gsettings_desktop_schemas

log_info "Phase 4: Documentation & Test Infrastructure"
build_docbook_xml     # Required by docbook-xsl, itstool
build_itstool         # Required by appstream
build_docbook_xsl
build_7zip            # Required by ibus (for UCD.zip)
build_shaderc

# Python test dependencies (for PyGObject tests)
log_info "Building Python test dependencies..."
build_setuptools_scm
build_editables
build_pathspec
build_trove_classifiers
build_pluggy
build_hatchling
build_hatch_vcs
build_iniconfig
build_pygments
build_pytest
build_pep8_pyflakes

log_info "Phase 5: GTK Toolkits & Python Bindings"
build_gtk3
build_gtk4
build_adwaita_icon_theme
build_pycairo
build_pygobject

log_info ""
log_info "Tier 5 GTK Stack completed!"
log_info "  - Foundation: Brotli, Graphite2, Rust-1.91.0, HarfBuzz (with FreeType), FreeType (rebuilt with HarfBuzz+Brotli), Fontconfig (rebuilt), FriBidi, Pixman, Graphene, libxkbcommon"
log_info "  - Graphics: Cairo, HarfBuzz (rebuilt with Cairo), Pango, at-spi2-core"
log_info "  - Images: libjpeg-turbo, libtiff, gdk-pixbuf, librsvg, shared-mime-info"
log_info "  - Icons: ISO Codes, hicolor-icon-theme, adwaita-icon-theme"
log_info "  - Schemas: gsettings-desktop-schemas"
log_info "  - Tooling: cargo-c, docbook-xml, docbook-xsl, PyGObject, shaderc"
log_info "  - GTK: GTK-3.24.50, GTK-4.18.6"
log_info ""

# #####################################################################
# TIER 6: Additional Libraries for KDE Plasma
# #####################################################################

# =====================================================================
# double-conversion-3.3.1 (IEEE double conversion library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/double-conversion.html
# Required Dependency: CMake
# =====================================================================
should_skip_package "double-conversion" && { log_info "Skipping double-conversion (already built)"; } || {
log_step "Building double-conversion-3.3.1..."

if [ ! -f /sources/double-conversion-3.3.1.tar.gz ]; then
    log_error "double-conversion-3.3.1.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf double-conversion-*
tar -xf /sources/double-conversion-3.3.1.tar.gz
cd double-conversion-*

mkdir build && cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr        \
      -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -D BUILD_SHARED_LIBS=ON             \
      -D BUILD_TESTING=ON                 \
      ..

make

log_info "Running double-conversion tests..."
make test || log_warn "Some tests failed"

log_info "Installing double-conversion..."
make install

cd "$BUILD_DIR"
rm -rf double-conversion-*

log_info "double-conversion-3.3.1 installed successfully"
create_checkpoint "double-conversion"
}

# =====================================================================
# Little CMS-2.17 (lcms2) - Color management library
# https://www.linuxfromscratch.org/blfs/view/12.4/general/lcms2.html
# Optional Dependencies: libjpeg-turbo, libtiff
# =====================================================================
should_skip_package "lcms2" && { log_info "Skipping lcms2 (already built)"; } || {
log_step "Building lcms2-2.17..."

if [ ! -f /sources/lcms2-2.17.tar.gz ]; then
    log_error "lcms2-2.17.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf lcms2-*
tar -xf /sources/lcms2-2.17.tar.gz
cd lcms2-*

./configure --prefix=/usr --disable-static

make

log_info "Running lcms2 tests..."
make check || log_warn "Some tests failed"

log_info "Installing lcms2..."
make install

cd "$BUILD_DIR"
rm -rf lcms2-*

log_info "lcms2-2.17 installed successfully"
create_checkpoint "lcms2"
}

# =====================================================================
# jasper-4.2.8 (JPEG-2000 codec)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/jasper.html
# Required Dependency: CMake
# Recommended Dependency: libjpeg-turbo
# =====================================================================
should_skip_package "jasper" && { log_info "Skipping jasper (already built)"; } || {
log_step "Building jasper-4.2.8..."

if [ ! -f /sources/jasper-version-4.2.8.tar.gz ]; then
    log_error "jasper-version-4.2.8.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf jasper-*
tar -xf /sources/jasper-version-4.2.8.tar.gz
cd jasper-*

mkdir BUILD && cd BUILD

cmake -D CMAKE_INSTALL_PREFIX=/usr    \
      -D CMAKE_BUILD_TYPE=Release     \
      -D CMAKE_SKIP_INSTALL_RPATH=ON  \
      -D JAS_ENABLE_DOC=NO            \
      -D ALLOW_IN_SOURCE_BUILD=YES    \
      -D CMAKE_INSTALL_DOCDIR=/usr/share/doc/jasper-4.2.8 \
      ..

make

log_info "Running jasper tests..."
make test || log_warn "Some tests failed"

log_info "Installing jasper..."
make install

cd "$BUILD_DIR"
rm -rf jasper-*

log_info "jasper-4.2.8 installed successfully"
create_checkpoint "jasper"
}

# =====================================================================
# Boost-1.89.0 (C++ libraries)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/boost.html
# Recommended Dependency: which (should be available from base system)
# =====================================================================
should_skip_package "boost" && { log_info "Skipping boost (already built)"; } || {
log_step "Building Boost-1.89.0..."

if [ ! -f /sources/boost-1.89.0-b2-nodocs.tar.xz ]; then
    log_error "boost-1.89.0-b2-nodocs.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf boost-*
tar -xf /sources/boost-1.89.0-b2-nodocs.tar.xz
cd boost-*

# Apply i686 fix if needed (per BLFS book)
case $(uname -m) in
   i?86)
      sed -e "s/defined(__MINGW32__)/& || defined(__i386__)/" \
          -i ./libs/stacktrace/src/exception_headers.h ;;
esac

./bootstrap.sh --prefix=/usr --with-python=python3

./b2 stage -j$(nproc) threading=multi link=shared

log_info "Cleaning old Boost cmake directories..."
rm -rf /usr/lib/cmake/[Bb]oost*

log_info "Installing Boost..."
./b2 install threading=multi link=shared

cd "$BUILD_DIR"
rm -rf boost-*

log_info "Boost-1.89.0 installed successfully"
create_checkpoint "boost"
}

# =====================================================================
# NSPR-4.37 (Netscape Portable Runtime)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/nspr.html
# Required for NSS (Network Security Services)
# =====================================================================
should_skip_package "nspr" && { log_info "Skipping nspr (already built)"; } || {
log_step "Building NSPR-4.37..."

if [ ! -f /sources/nspr-4.37.tar.gz ]; then
    log_error "nspr-4.37.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf nspr-*
tar -xf /sources/nspr-4.37.tar.gz
cd nspr-*

cd nspr

# Apply sed commands from BLFS book
sed -i '/^RELEASE/s|^|#|' pr/src/misc/Makefile.in
sed -i 's|$(LIBRARY) ||'  config/rules.mk

./configure --prefix=/usr   \
            --with-mozilla  \
            --with-pthreads \
            $([ $(uname -m) = x86_64 ] && echo --enable-64bit)

make

log_info "Installing NSPR..."
make install

cd "$BUILD_DIR"
rm -rf nspr-*

log_info "NSPR-4.37 installed successfully"
create_checkpoint "nspr"
}

# =====================================================================
# liba52-0.8.0 (AC-3 decoder library)
# https://www.linuxfromscratch.org/blfs/view/12.4/multimedia/liba52.html
# Required for VLC multimedia codec support
# =====================================================================
should_skip_package "liba52" && { log_info "Skipping liba52 (already built)"; } || {
log_step "Building liba52-0.8.0..."

if [ ! -f /sources/a52dec-0.8.0.tar.gz ]; then
    log_error "a52dec-0.8.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf a52dec-*
tar -xf /sources/a52dec-0.8.0.tar.gz
cd a52dec-*

./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --enable-shared         \
            --disable-static        \
            CFLAGS="${CFLAGS:--g -O3} -fPIC"

make

log_info "Running liba52 tests..."
make check || log_warn "Some tests failed"

log_info "Installing liba52..."
make install
cp liba52/a52_internal.h /usr/include/a52dec
install -v -m644 -D doc/liba52.txt \
    /usr/share/doc/liba52-0.8.0/liba52.txt

cd "$BUILD_DIR"
rm -rf a52dec-*

log_info "liba52-0.8.0 installed successfully"
create_checkpoint "liba52"
}

# =====================================================================
# libmad-0.15.1b (MPEG audio decoder)
# https://www.linuxfromscratch.org/blfs/view/12.4/multimedia/libmad.html
# Required patch from BLFS
# =====================================================================
should_skip_package "libmad" && { log_info "Skipping libmad (already built)"; } || {
log_step "Building libmad-0.15.1b..."

if [ ! -f /sources/libmad-0.15.1b.tar.gz ]; then
    log_error "libmad-0.15.1b.tar.gz not found in /sources"
    exit 1
fi

if [ ! -f /sources/libmad-0.15.1b-fixes-1.patch ]; then
    log_error "libmad-0.15.1b-fixes-1.patch not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libmad-*
tar -xf /sources/libmad-0.15.1b.tar.gz
cd libmad-*

# Apply BLFS patch and fixes
patch -Np1 -i /sources/libmad-0.15.1b-fixes-1.patch
sed "s@AM_CONFIG_HEADER@AC_CONFIG_HEADERS@g" -i configure.ac
touch NEWS AUTHORS ChangeLog
autoreconf -fi

./configure --prefix=/usr --disable-static

make

log_info "Installing libmad..."
make install

# Create pkg-config file (per BLFS instructions)
cat > /usr/lib/pkgconfig/mad.pc << "EOF"
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: mad
Description: MPEG audio decoder
Requires:
Version: 0.15.1b
Libs: -L${libdir} -lmad
Cflags: -I${includedir}
EOF

cd "$BUILD_DIR"
rm -rf libmad-*

log_info "libmad-0.15.1b installed successfully"
create_checkpoint "libmad"
}

log_info ""
log_info "Tier 6 Additional Libraries completed!"
log_info "  - double-conversion-3.3.1: IEEE double conversion"
log_info "  - lcms2-2.17: Color management"
log_info "  - jasper-4.2.8: JPEG-2000 codec"
log_info "  - Boost-1.89.0: C++ libraries"
log_info "  - NSPR-4.37: Netscape Portable Runtime"
log_info "  - liba52-0.8.0: AC-3 decoder"
log_info "  - libmad-0.15.1b: MPEG audio decoder"
log_info ""

# =====================================================================
# TIER 7: Qt6 and Pre-KDE Dependencies
# =====================================================================
log_info ""
log_info "=========================================="
log_info "Tier 7: Qt6 and Pre-KDE Dependencies"
log_info "=========================================="
log_info ""

# =====================================================================
# libwebp-1.6.0 (WebP image format library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libwebp.html
# =====================================================================
build_libwebp() {
should_skip_package "libwebp" && { log_info "Skipping libwebp (already built)"; return 0; }
log_step "Building libwebp-1.6.0..."

if [ ! -f /sources/libwebp-1.6.0.tar.gz ]; then
    log_error "libwebp-1.6.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libwebp-*
tar -xf /sources/libwebp-1.6.0.tar.gz
cd libwebp-*

./configure --prefix=/usr           \
            --enable-libwebpmux     \
            --enable-libwebpdemux   \
            --enable-libwebpdecoder \
            --enable-libwebpextras  \
            --enable-swap-16bit-csp \
            --disable-static

make
make install

cd "$BUILD_DIR"
rm -rf libwebp-*

log_info "libwebp-1.6.0 installed successfully"
create_checkpoint "libwebp"
}

# =====================================================================
# pciutils-3.14.0 (PCI utilities)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/pciutils.html
# =====================================================================
build_pciutils() {
should_skip_package "pciutils" && { log_info "Skipping pciutils (already built)"; return 0; }
log_step "Building pciutils-3.14.0..."

if [ ! -f /sources/pciutils-3.14.0.tar.gz ]; then
    log_error "pciutils-3.14.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf pciutils-*
tar -xf /sources/pciutils-3.14.0.tar.gz
cd pciutils-*

# Prevent installation of pci.ids to avoid conflict with hwdata
sed -r '/INSTALL/{/PCI_IDS|update-pciids /d; s/update-pciids.8//}' \
    -i Makefile

make PREFIX=/usr                \
     SHAREDIR=/usr/share/hwdata \
     SHARED=yes

make PREFIX=/usr                \
     SHAREDIR=/usr/share/hwdata \
     SHARED=yes                 \
     install install-lib

chmod -v 755 /usr/lib/libpci.so

cd "$BUILD_DIR"
rm -rf pciutils-*

log_info "pciutils-3.14.0 installed successfully"
create_checkpoint "pciutils"
}

# =====================================================================
# NSS-3.115 (Network Security Services)
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/nss.html
# Required patch: nss-standalone-1.patch
# =====================================================================
build_nss() {
should_skip_package "nss" && { log_info "Skipping NSS (already built)"; return 0; }
log_step "Building NSS-3.115..."

if [ ! -f /sources/nss-3.115.tar.gz ]; then
    log_error "nss-3.115.tar.gz not found in /sources"
    return 1
fi

if [ ! -f /sources/nss-standalone-1.patch ]; then
    log_error "nss-standalone-1.patch not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf nss-*
tar -xf /sources/nss-3.115.tar.gz
cd nss-*

patch -Np1 -i /sources/nss-standalone-1.patch

cd nss

make BUILD_OPT=1                      \
     NSPR_INCLUDE_DIR=/usr/include/nspr  \
     USE_SYSTEM_ZLIB=1                   \
     ZLIB_LIBS=-lz                       \
     NSS_ENABLE_WERROR=0                 \
     NSS_DISABLE_GTESTS=1                \
     $([ $(uname -m) = x86_64 ] && echo USE_64=1) \
     $([ -f /usr/include/sqlite3.h ] && echo NSS_USE_SYSTEM_SQLITE=1)

cd ../dist

install -v -m755 Linux*/lib/*.so              /usr/lib
install -v -m644 Linux*/lib/{*.chk,libcrmf.a} /usr/lib

install -v -m755 -d                           /usr/include/nss
cp -v -RL {public,private}/nss/*              /usr/include/nss

install -v -m755 Linux*/bin/{certutil,nss-config,pk12util} /usr/bin

install -v -m644 Linux*/lib/pkgconfig/nss.pc  /usr/lib/pkgconfig

# Link p11-kit trust module if p11-kit is installed
if [ -f /usr/lib/pkcs11/p11-kit-trust.so ]; then
    ln -sfv ./pkcs11/p11-kit-trust.so /usr/lib/libnssckbi.so
fi

cd "$BUILD_DIR"
rm -rf nss-*

log_info "NSS-3.115 installed successfully"
create_checkpoint "nss"
}

# =====================================================================
# libuv-1.51.0 (Asynchronous I/O library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libuv.html
# Required by Node.js when using --shared-libuv
# =====================================================================
build_libuv() {
should_skip_package "libuv" && { log_info "Skipping libuv (already built)"; return 0; }
log_step "Building libuv-1.51.0..."

if [ ! -f /sources/libuv-v1.51.0.tar.gz ]; then
    log_error "libuv-v1.51.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libuv-*
tar -xf /sources/libuv-v1.51.0.tar.gz
cd libuv-*

# Unset ACLOCAL if set (conflicts with autogen.sh per BLFS)
unset ACLOCAL

sh autogen.sh

./configure --prefix=/usr --disable-static

make

make install

cd "$BUILD_DIR"
rm -rf libuv-*

log_info "libuv-1.51.0 installed successfully"
create_checkpoint "libuv"
}

# =====================================================================
# nghttp2-1.66.0 (HTTP/2 C Library)
# https://www.linuxfromscratch.org/blfs/view/12.4/basicnet/nghttp2.html
# Required by Node.js when using --shared-nghttp2
# =====================================================================
build_nghttp2() {
should_skip_package "nghttp2" && { log_info "Skipping nghttp2 (already built)"; return 0; }
log_step "Building nghttp2-1.66.0..."

if [ ! -f /sources/nghttp2-1.66.0.tar.xz ]; then
    log_error "nghttp2-1.66.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf nghttp2-*
tar -xf /sources/nghttp2-1.66.0.tar.xz
cd nghttp2-*

./configure --prefix=/usr     \
            --disable-static  \
            --enable-lib-only \
            --docdir=/usr/share/doc/nghttp2-1.66.0

make

make install

cd "$BUILD_DIR"
rm -rf nghttp2-*

log_info "nghttp2-1.66.0 installed successfully"
create_checkpoint "nghttp2"
}

# =====================================================================
# Node.js-22.18.0 (JavaScript runtime)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/nodejs.html
# =====================================================================
build_nodejs() {
should_skip_package "nodejs" && { log_info "Skipping Node.js (already built)"; return 0; }
log_step "Building Node.js-22.18.0..."

if [ ! -f /sources/node-v22.18.0.tar.xz ]; then
    log_error "node-v22.18.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf node-*
tar -xf /sources/node-v22.18.0.tar.xz
cd node-*

./configure --prefix=/usr          \
            --shared-brotli        \
            --shared-cares         \
            --shared-libuv         \
            --shared-openssl       \
            --shared-nghttp2       \
            --shared-zlib          \
            --with-intl=system-icu

make

make install
ln -sf node /usr/share/doc/node-22.18.0

cd "$BUILD_DIR"
rm -rf node-*

log_info "Node.js-22.18.0 installed successfully"
create_checkpoint "nodejs"
}

# =====================================================================
# Cups-2.4.12 (Common Unix Printing System)
# https://www.linuxfromscratch.org/blfs/view/12.4/pst/cups.html
# =====================================================================
build_cups() {
should_skip_package "cups" && { log_info "Skipping CUPS (already built)"; return 0; }
log_step "Building Cups-2.4.12..."

if [ ! -f /sources/cups-2.4.12-source.tar.gz ]; then
    log_error "cups-2.4.12-source.tar.gz not found in /sources"
    return 1
fi

# Create lp user and lpadmin group if they don't exist
if ! id lp >/dev/null 2>&1; then
    useradd -c "Print Service User" -d /var/spool/cups -g lp -s /bin/false -u 9 lp || true
fi
if ! getent group lpadmin >/dev/null 2>&1; then
    groupadd -g 19 lpadmin || true
fi

cd "$BUILD_DIR"
rm -rf cups-*
tar -xf /sources/cups-2.4.12-source.tar.gz
cd cups-*

./configure --libdir=/usr/lib            \
            --with-rundir=/run/cups      \
            --with-system-groups=lpadmin \
            --with-docdir=/usr/share/cups/doc-2.4.12

make
make install
ln -svnf ../cups/doc-2.4.12 /usr/share/doc/cups-2.4.12

# Create basic client configuration
echo "ServerName /run/cups/cups.sock" > /etc/cups/client.conf

# Create PAM configuration for CUPS
cat > /etc/pam.d/cups << "EOF"
# Begin /etc/pam.d/cups

auth    include system-auth
account include system-account
session include system-session

# End /etc/pam.d/cups
EOF

cd "$BUILD_DIR"
rm -rf cups-*

log_info "Cups-2.4.12 installed successfully"
create_checkpoint "cups"
}

# =====================================================================
# desktop-file-utils-0.28 (Desktop Entry utilities)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/desktop-file-utils.html
# =====================================================================
build_desktop_file_utils() {
should_skip_package "desktop-file-utils" && { log_info "Skipping desktop-file-utils (already built)"; return 0; }
log_step "Building desktop-file-utils-0.28..."

if [ ! -f /sources/desktop-file-utils-0.28.tar.xz ]; then
    log_error "desktop-file-utils-0.28.tar.xz not found in /sources"
    return 1
fi

# Remove old symlink if upgrading
rm -fv /usr/bin/desktop-file-edit 2>/dev/null || true

cd "$BUILD_DIR"
rm -rf desktop-file-utils-*
tar -xf /sources/desktop-file-utils-0.28.tar.xz
cd desktop-file-utils-*

mkdir build
cd    build

meson setup --prefix=/usr --buildtype=release ..
ninja

ninja install

# Create applications directory and update database
install -vdm755 /usr/share/applications
update-desktop-database /usr/share/applications 2>/dev/null || true

cd "$BUILD_DIR"
rm -rf desktop-file-utils-*

log_info "desktop-file-utils-0.28 installed successfully"
create_checkpoint "desktop-file-utils"
}

# =====================================================================
# libmng-2.0.3 (Multiple-image Network Graphics library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libmng.html
# =====================================================================
build_libmng() {
should_skip_package "libmng" && { log_info "Skipping libmng (already built)"; return 0; }
log_step "Building libmng-2.0.3..."

if [ ! -f /sources/libmng-2.0.3.tar.xz ]; then
    log_error "libmng-2.0.3.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libmng-*
tar -xf /sources/libmng-2.0.3.tar.xz
cd libmng-*

./configure --prefix=/usr --disable-static
make
make install

install -v -m755 -d        /usr/share/doc/libmng-2.0.3
install -v -m644 doc/*.txt /usr/share/doc/libmng-2.0.3

cd "$BUILD_DIR"
rm -rf libmng-*

log_info "libmng-2.0.3 installed successfully"
create_checkpoint "libmng"
}

# =====================================================================
# SQLite-3.50.4 (SQL database engine)
# https://www.linuxfromscratch.org/blfs/view/12.4/server/sqlite.html
# Required for Qt6 with -system-sqlite
# =====================================================================
build_sqlite() {
should_skip_package "sqlite" && { log_info "Skipping SQLite (already built)"; return 0; }
log_step "Building SQLite-3.50.4..."

if [ ! -f /sources/sqlite-autoconf-3500400.tar.gz ]; then
    log_error "sqlite-autoconf-3500400.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf sqlite-autoconf-*
tar -xf /sources/sqlite-autoconf-3500400.tar.gz
cd sqlite-autoconf-*

./configure --prefix=/usr     \
            --disable-static  \
            --enable-fts4     \
            --enable-fts5     \
            CPPFLAGS="-DSQLITE_ENABLE_COLUMN_METADATA=1 \
                      -DSQLITE_ENABLE_UNLOCK_NOTIFY=1   \
                      -DSQLITE_ENABLE_DBSTAT_VTAB=1     \
                      -DSQLITE_SECURE_DELETE=1"

make
make install

cd "$BUILD_DIR"
rm -rf sqlite-autoconf-*

log_info "SQLite-3.50.4 installed successfully"
create_checkpoint "sqlite"
}

# =====================================================================
# Qt-6.9.2 (Qt6 cross-platform framework)
# https://www.linuxfromscratch.org/blfs/view/12.4/x/qt6.html
# =====================================================================
build_qt6() {
should_skip_package "qt6" && { log_info "Skipping Qt6 (already built)"; return 0; }
log_step "Building Qt-6.9.2..."

if [ ! -f /sources/qt-everywhere-src-6.9.2.tar.xz ]; then
    log_error "qt-everywhere-src-6.9.2.tar.xz not found in /sources"
    return 1
fi

# Set Qt6 prefix
export QT6PREFIX=/opt/qt6

# Create versioned directory with symlink
mkdir -pv /opt/qt-6.9.2
ln -sfnv qt-6.9.2 /opt/qt6

cd "$BUILD_DIR"
rm -rf qt-everywhere-src-*
tar -xf /sources/qt-everywhere-src-6.9.2.tar.xz
cd qt-everywhere-src-*

# Fix for i686 systems
if [ "$(uname -m)" == "i686" ]; then
    sed -e "/^#elif defined(Q_CC_GNU_ONLY)/s/.*/& \&\&\ 0/" \
         -i qtbase/src/corelib/global/qtypes.h
    export CXXFLAGS+="-DDISABLE_SIMD -DPFFFT_SIMD_DISABLE"
fi

./configure -prefix $QT6PREFIX      \
            -sysconfdir /etc/xdg    \
            -dbus-linked            \
            -openssl-linked         \
            -system-sqlite          \
            -nomake examples        \
            -no-rpath               \
            -no-sbom                \
            -journald               \
            -skip qt3d              \
            -skip qtquick3dphysics  \
            -skip qtwebengine

ninja

ninja install

# Remove build directory references from prl files
find $QT6PREFIX/ -name \*.prl \
   -exec sed -i -e '/^QMAKE_PRL_BUILD_DIR/d' {} \;

# Install icons and desktop files
pushd qttools/src

install -v -Dm644 assistant/assistant/images/assistant-128.png       \
                  /usr/share/pixmaps/assistant-qt6.png

install -v -Dm644 designer/src/designer/images/designer.png          \
                  /usr/share/pixmaps/designer-qt6.png

install -v -Dm644 linguist/linguist/images/icons/linguist-128-32.png \
                  /usr/share/pixmaps/linguist-qt6.png

install -v -Dm644 qdbus/qdbusviewer/images/qdbusviewer-128.png       \
                  /usr/share/pixmaps/qdbusviewer-qt6.png

popd

# Create desktop entries
cat > /usr/share/applications/assistant-qt6.desktop << EOF
[Desktop Entry]
Name=Qt6 Assistant
Comment=Shows Qt6 documentation and examples
Exec=$QT6PREFIX/bin/assistant
Icon=assistant-qt6.png
Terminal=false
Encoding=UTF-8
Type=Application
Categories=Qt;Development;Documentation;
EOF

cat > /usr/share/applications/designer-qt6.desktop << EOF
[Desktop Entry]
Name=Qt6 Designer
GenericName=Interface Designer
Comment=Design GUIs for Qt6 applications
Exec=$QT6PREFIX/bin/designer
Icon=designer-qt6.png
MimeType=application/x-designer;
Terminal=false
Encoding=UTF-8
Type=Application
Categories=Qt;Development;
EOF

cat > /usr/share/applications/linguist-qt6.desktop << EOF
[Desktop Entry]
Name=Qt6 Linguist
Comment=Add translations to Qt6 applications
Exec=$QT6PREFIX/bin/linguist
Icon=linguist-qt6.png
MimeType=text/vnd.trolltech.linguist;application/x-linguist;
Terminal=false
Encoding=UTF-8
Type=Application
Categories=Qt;Development;
EOF

cat > /usr/share/applications/qdbusviewer-qt6.desktop << EOF
[Desktop Entry]
Name=Qt6 QDbusViewer
GenericName=D-Bus Debugger
Comment=Debug D-Bus applications
Exec=$QT6PREFIX/bin/qdbusviewer
Icon=qdbusviewer-qt6.png
Terminal=false
Encoding=UTF-8
Type=Application
Categories=Qt;Development;Debugger;
EOF

# Configure sudo to pass QT6DIR
cat > /etc/sudoers.d/qt << "EOF"
Defaults env_keep += QT6DIR
EOF

# Add Qt6 to ld.so.conf
cat >> /etc/ld.so.conf << "EOF"
# Begin Qt addition

/opt/qt6/lib

# End Qt addition
EOF

ldconfig

# Create profile.d script for Qt6
cat > /etc/profile.d/qt6.sh << "EOF"
# Begin /etc/profile.d/qt6.sh

QT6DIR=/opt/qt6

pathappend $QT6DIR/bin           PATH
pathappend $QT6DIR/lib/pkgconfig PKG_CONFIG_PATH

export QT6DIR

# End /etc/profile.d/qt6.sh
EOF

cd "$BUILD_DIR"
rm -rf qt-everywhere-src-*

log_info "Qt-6.9.2 installed successfully"
create_checkpoint "qt6"
}

# =====================================================================
# extra-cmake-modules-6.17.0 (Extra CMake modules for KDE)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/extra-cmake-modules.html
# Required patch: extra-cmake-modules-6.17.0-upstream_fix-1.patch
# =====================================================================
build_extra_cmake_modules() {
should_skip_package "extra-cmake-modules" && { log_info "Skipping extra-cmake-modules (already built)"; return 0; }
log_step "Building extra-cmake-modules-6.17.0..."

if [ ! -f /sources/extra-cmake-modules-6.17.0.tar.xz ]; then
    log_error "extra-cmake-modules-6.17.0.tar.xz not found in /sources"
    return 1
fi

if [ ! -f /sources/extra-cmake-modules-6.17.0-upstream_fix-1.patch ]; then
    log_error "extra-cmake-modules-6.17.0-upstream_fix-1.patch not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf extra-cmake-modules-*
tar -xf /sources/extra-cmake-modules-6.17.0.tar.xz
cd extra-cmake-modules-*

patch -Np1 -i /sources/extra-cmake-modules-6.17.0-upstream_fix-1.patch

sed -i '/"lib64"/s/64//' kde-modules/KDEInstallDirsCommon.cmake

sed -e '/PACKAGE_INIT/i set(SAVE_PACKAGE_PREFIX_DIR "${PACKAGE_PREFIX_DIR}")' \
    -e '/^include/a set(PACKAGE_PREFIX_DIR "${SAVE_PACKAGE_PREFIX_DIR}")' \
    -i ECMConfig.cmake.in

mkdir build
cd    build

cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_PREFIX_PATH=/opt/qt6 \
      -DBUILD_WITH_QT6=ON ..
make
make install

cd "$BUILD_DIR"
rm -rf extra-cmake-modules-*

log_info "extra-cmake-modules-6.17.0 installed successfully"
create_checkpoint "extra-cmake-modules"
}

# =====================================================================
# qca-2.3.10 (Qt Cryptographic Architecture)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/qca.html
# =====================================================================
build_qca() {
should_skip_package "qca" && { log_info "Skipping qca (already built)"; return 0; }
log_step "Building qca-2.3.10..."

if [ ! -f /sources/qca-2.3.10.tar.xz ]; then
    log_error "qca-2.3.10.tar.xz not found in /sources"
    return 1
fi

# Ensure QT6PREFIX is set
export QT6PREFIX=/opt/qt6

cd "$BUILD_DIR"
rm -rf qca-*
tar -xf /sources/qca-2.3.10.tar.xz
cd qca-*

# Fix CA certificates location
sed -i 's@cert.pem@certs/ca-bundle.crt@' CMakeLists.txt

mkdir build
cd    build

# Use hardcoded paths to avoid any variable expansion issues with newlines
cmake -DCMAKE_INSTALL_PREFIX=/opt/qt6 \
      -DCMAKE_BUILD_TYPE=Release \
      -DQT6=ON \
      -DQCA_INSTALL_IN_QT_PREFIX=ON \
      -DQCA_MAN_INSTALL_DIR=/usr/share/man \
      -DQCA_PLUGINS_INSTALL_DIR=/opt/qt6/lib/qca-qt6 \
      -DQCA_BINARY_INSTALL_DIR=/opt/qt6/bin \
      -DQCA_LIBRARY_INSTALL_DIR=/opt/qt6/lib \
      -DQCA_INCLUDE_INSTALL_DIR=/opt/qt6/include/Qca-qt6 \
      -DQCA_PRIVATE_INCLUDE_INSTALL_DIR=/opt/qt6/include/Qca-qt6/QtCrypto/private \
      -DQCA_DOC_INSTALL_DIR=/opt/qt6/share/doc/qca \
      -DQCA_PREFIX_INSTALL_DIR=/opt/qt6 \
      -DBUILD_WITH_QT6=ON \
      ..

make
make install

cd "$BUILD_DIR"
rm -rf qca-*

log_info "qca-2.3.10 installed successfully"
create_checkpoint "qca"
}

# =====================================================================
# qcoro-0.12.0 (C++20 coroutines for Qt)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/qcoro.html
# =====================================================================
build_qcoro() {
should_skip_package "qcoro" && { log_info "Skipping qcoro (already built)"; return 0; }
log_step "Building qcoro-0.12.0..."

if [ ! -f /sources/qcoro-0.12.0.tar.gz ]; then
    log_error "qcoro-0.12.0.tar.gz not found in /sources"
    return 1
fi

# Ensure QT6PREFIX is set
export QT6PREFIX=/opt/qt6

cd "$BUILD_DIR"
rm -rf qcoro-*
tar -xf /sources/qcoro-0.12.0.tar.gz
cd qcoro-*

mkdir build
cd    build

cmake -D CMAKE_INSTALL_PREFIX=$QT6PREFIX \
      -D CMAKE_BUILD_TYPE=Release     \
      -D BUILD_TESTING=OFF            \
      -D QCORO_BUILD_EXAMPLES=OFF     \
      -D BUILD_SHARED_LIBS=ON         \
       ..

make
make install

cd "$BUILD_DIR"
rm -rf qcoro-*

log_info "qcoro-0.12.0 installed successfully"
create_checkpoint "qcoro"
}

# =====================================================================
# Phonon-4.12.0 (KDE multimedia API)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/phonon.html
# =====================================================================
build_phonon() {
should_skip_package "phonon" && { log_info "Skipping Phonon (already built)"; return 0; }
log_step "Building Phonon-4.12.0..."

if [ ! -f /sources/phonon-4.12.0.tar.xz ]; then
    log_error "phonon-4.12.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf phonon-*
tar -xf /sources/phonon-4.12.0.tar.xz
cd phonon-*

mkdir build
cd    build

cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_PREFIX_PATH=/opt/qt6 \
      -DCMAKE_BUILD_TYPE=Release \
      -DPHONON_BUILD_QT5=OFF \
      -DPHONON_BUILD_QT6=ON \
      -Wno-dev ..

make
make install

cd "$BUILD_DIR"
rm -rf phonon-*

log_info "Phonon-4.12.0 installed successfully"
create_checkpoint "phonon"
}

# =====================================================================
# VLC-3.0.21 (Media player)
# https://www.linuxfromscratch.org/blfs/view/12.4/multimedia/vlc.html
# Required patches: vlc-3.0.21-taglib-1.patch, vlc-3.0.21-fedora_ffmpeg7-1.patch
# =====================================================================
build_vlc() {
should_skip_package "vlc" && { log_info "Skipping VLC (already built)"; return 0; }
log_step "Building VLC-3.0.21..."

if [ ! -f /sources/vlc-3.0.21.tar.xz ]; then
    log_error "vlc-3.0.21.tar.xz not found in /sources"
    return 1
fi

if [ ! -f /sources/vlc-3.0.21-taglib-1.patch ]; then
    log_error "vlc-3.0.21-taglib-1.patch not found in /sources"
    return 1
fi

if [ ! -f /sources/vlc-3.0.21-fedora_ffmpeg7-1.patch ]; then
    log_error "vlc-3.0.21-fedora_ffmpeg7-1.patch not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf vlc-*
tar -xf /sources/vlc-3.0.21.tar.xz
cd vlc-*

# Apply required patches
patch -Np1 -i /sources/vlc-3.0.21-taglib-1.patch
patch -Np1 -i /sources/vlc-3.0.21-fedora_ffmpeg7-1.patch

BUILDCC=gcc ./configure --prefix=/usr --disable-libplacebo

make

make docdir=/usr/share/doc/vlc-3.0.21 install

# Update icon and desktop caches if GTK is available
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -qtf /usr/share/icons/hicolor 2>/dev/null || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q 2>/dev/null || true
fi

cd "$BUILD_DIR"
rm -rf vlc-*

log_info "VLC-3.0.21 installed successfully"
create_checkpoint "vlc"
}

# =====================================================================
# Phonon-backend-vlc-0.12.0 (VLC backend for Phonon)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/phonon-backend-vlc.html
# =====================================================================
build_phonon_backend_vlc() {
should_skip_package "phonon-backend-vlc" && { log_info "Skipping Phonon-backend-vlc (already built)"; return 0; }
log_step "Building Phonon-backend-vlc-0.12.0..."

if [ ! -f /sources/phonon-backend-vlc-0.12.0.tar.xz ]; then
    log_error "phonon-backend-vlc-0.12.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf phonon-backend-vlc-*
tar -xf /sources/phonon-backend-vlc-0.12.0.tar.xz
cd phonon-backend-vlc-*

mkdir build
cd    build

cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_PREFIX_PATH=/opt/qt6 \
      -DCMAKE_BUILD_TYPE=Release \
      -DPHONON_BUILD_QT5=OFF \
      -DPHONON_BUILD_QT6=ON \
      ..

make
make install

cd "$BUILD_DIR"
rm -rf phonon-backend-vlc-*

log_info "Phonon-backend-vlc-0.12.0 installed successfully"
create_checkpoint "phonon-backend-vlc"
}

# =====================================================================
# Polkit-Qt-0.200.0 (PolicyKit Qt bindings)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/polkit-qt.html
# =====================================================================
build_polkit_qt() {
should_skip_package "polkit-qt" && { log_info "Skipping Polkit-Qt (already built)"; return 0; }
log_step "Building Polkit-Qt-0.200.0..."

if [ ! -f /sources/polkit-qt-1-0.200.0.tar.xz ]; then
    log_error "polkit-qt-1-0.200.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf polkit-qt-*
tar -xf /sources/polkit-qt-1-0.200.0.tar.xz
cd polkit-qt-*

mkdir build
cd    build

cmake -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_PREFIX_PATH=/opt/qt6 \
      -DCMAKE_BUILD_TYPE=Release \
      -DQT_MAJOR_VERSION=6 \
      -Wno-dev ..

make
make install

cd "$BUILD_DIR"
rm -rf polkit-qt-*

log_info "Polkit-Qt-0.200.0 installed successfully"
create_checkpoint "polkit-qt"
}

# =====================================================================
# plasma-wayland-protocols-1.18.0 (KDE Wayland protocols)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/plasma-wayland-protocols.html
# =====================================================================
build_plasma_wayland_protocols() {
should_skip_package "plasma-wayland-protocols" && { log_info "Skipping plasma-wayland-protocols (already built)"; return 0; }
log_step "Building plasma-wayland-protocols-1.18.0..."

if [ ! -f /sources/plasma-wayland-protocols-1.18.0.tar.xz ]; then
    log_error "plasma-wayland-protocols-1.18.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf plasma-wayland-protocols-*
tar -xf /sources/plasma-wayland-protocols-1.18.0.tar.xz
cd plasma-wayland-protocols-*

mkdir build
cd    build

cmake -D CMAKE_INSTALL_PREFIX=/usr ..

make install

cd "$BUILD_DIR"
rm -rf plasma-wayland-protocols-*

log_info "plasma-wayland-protocols-1.18.0 installed successfully"
create_checkpoint "plasma-wayland-protocols"
}

# =====================================================================
# Ninja NINJAJOBS patch (rebuild ninja to support NINJAJOBS env var)
# https://www.linuxfromscratch.org/lfs/view/12.4-systemd/chapter08/ninja.html
# Required for QtWebEngine to respect parallel job limits
# =====================================================================
rebuild_ninja_with_ninjajobs() {
should_skip_package "ninja-ninjajobs" && { log_info "Skipping ninja rebuild (already patched)"; return 0; }
log_step "Rebuilding Ninja with NINJAJOBS support..."

if [ ! -f /sources/ninja-1.13.1.tar.gz ]; then
    log_error "ninja-1.13.1.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf ninja-*
tar -xf /sources/ninja-1.13.1.tar.gz
cd ninja-*

# Apply the NINJAJOBS patch from LFS book
# This adds support for the NINJAJOBS environment variable
sed -i '/int Guess/a \
  int   j = 0;\
  char* jobs = getenv( "NINJAJOBS" );\
  if ( jobs != NULL ) j = atoi( jobs );\
  if ( j > 0 ) return j;\
' src/ninja.cc

# Build ninja
python3 configure.py --bootstrap --verbose

# Install the patched ninja
install -vm755 ninja /usr/bin/

cd "$BUILD_DIR"
rm -rf ninja-*

log_info "Ninja rebuilt with NINJAJOBS support"
create_checkpoint "ninja-ninjajobs"
}

# =====================================================================
# QtWebEngine-6.9.2 (Chromium-based web engine for Qt)
# https://www.linuxfromscratch.org/blfs/view/12.4/x/qtwebengine.html
# =====================================================================
build_qtwebengine() {
should_skip_package "qtwebengine" && { log_info "Skipping QtWebEngine (already built)"; return 0; }
log_step "Building QtWebEngine-6.9.2..."

if [ ! -f /sources/qtwebengine-everywhere-src-6.9.2.tar.xz ]; then
    log_error "qtwebengine-everywhere-src-6.9.2.tar.xz not found in /sources"
    return 1
fi

# Ensure QT6PREFIX is set
export QT6PREFIX=/opt/qt6

cd "$BUILD_DIR"

# Check if we can resume a previous build (don't wipe if ninja build dir exists)
if [ -f "qtwebengine-everywhere-src-6.9.2/build/.ninja_log" ] || [ -d "qtwebengine-everywhere-src-6.9.2/build/src" ]; then
    log_info "Resuming previous QtWebEngine build..."
    cd qtwebengine-everywhere-src-6.9.2/build
else
    # Fresh build - extract and configure
    log_info "Starting fresh QtWebEngine build..."
    rm -rf qtwebengine-*
    tar -xf /sources/qtwebengine-everywhere-src-6.9.2.tar.xz
    cd qtwebengine-*

    mkdir -p build
    cd    build

    # QtWebEngine (Chromium) is EXTREMELY memory-intensive
    # Chromium jumbo builds use ~3-4GB RAM per compilation job
    # With 64GB RAM: 64/3.5 ≈ 18 jobs max to avoid OOM
    # Use NINJAJOBS env var which nested chromium ninja builds will respect
    export NINJAJOBS=12
    export NINJAFLAGS="-j12"
    log_info "Building QtWebEngine with NINJAJOBS=$NINJAJOBS (conservative for OOM safety)"

    cmake -DCMAKE_MESSAGE_LOG_LEVEL=STATUS \
          -DCMAKE_PREFIX_PATH=/opt/qt6 \
          -DQT_FEATURE_webengine_system_ffmpeg=OFF \
          -DQT_FEATURE_webengine_system_icu=ON \
          -DQT_FEATURE_webengine_system_libevent=ON \
          -DQT_FEATURE_webengine_proprietary_codecs=ON \
          -DQT_FEATURE_webengine_webrtc_pipewire=ON \
          -DQT_BUILD_EXAMPLES_BY_DEFAULT=OFF \
          -DQT_GENERATE_SBOM=OFF \
          -G Ninja ..
fi

# Set NINJAJOBS for the actual build (both fresh and resumed)
# Keep it conservative - Chromium Blink jumbo files use ~3-4GB RAM each
export NINJAJOBS=12
export NINJAFLAGS="-j12"

# Run with NINJAJOBS environment variable set for nested builds
log_info "Running ninja build with NINJAJOBS=$NINJAJOBS..."
if ! NINJAJOBS=$NINJAJOBS ninja -j$NINJAJOBS; then
    log_error "QtWebEngine ninja build failed - you can resume by re-running the build"
    return 1
fi

log_info "Running ninja install..."
if ! ninja install; then
    log_error "QtWebEngine ninja install failed"
    return 1
fi

cd "$BUILD_DIR"
rm -rf qtwebengine-*

log_info "QtWebEngine-6.9.2 installed successfully"
create_checkpoint "qtwebengine"
}

# =====================================================================
# html5lib-1.1 (Python HTML5 parser - required for QtWebEngine)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/python-modules.html#html5lib
# =====================================================================
build_html5lib() {
should_skip_package "html5lib" && { log_info "Skipping html5lib (already built)"; return 0; }
log_step "Building html5lib-1.1..."

if [ ! -f /sources/html5lib-1.1.tar.gz ]; then
    log_error "html5lib-1.1.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf html5lib-*
tar -xf /sources/html5lib-1.1.tar.gz
cd html5lib-*

pip3 install --no-build-isolation .

cd "$BUILD_DIR"
rm -rf html5lib-*

log_info "html5lib-1.1 installed successfully"
create_checkpoint "html5lib"
}

# =====================================================================
# Tier 8: KDE Frameworks 6 Dependencies
# =====================================================================

# =====================================================================
# intltool-0.51.0 (Internationalization utilities)
# Required by: sound-theme-freedesktop
# https://launchpad.net/intltool
# =====================================================================
build_intltool() {
should_skip_package "intltool" && { log_info "Skipping intltool (already built)"; return 0; }
log_step "Building intltool-0.51.0..."

if [ ! -f /sources/intltool-0.51.0.tar.gz ]; then
    log_error "intltool-0.51.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf intltool-*
tar -xf /sources/intltool-0.51.0.tar.gz
cd intltool-*

# Fix a warning that causes crashes in some packages (from older BLFS)
sed -i 's/\x27LI\x27/\\&LU/' intltool-update.in

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf intltool-*

log_info "intltool-0.51.0 installed successfully"
create_checkpoint "intltool"
}

# =====================================================================
# sound-theme-freedesktop-0.8 (XDG Sound Theme)
# https://www.linuxfromscratch.org/blfs/view/12.4/multimedia/sound-theme-freedesktop.html
# =====================================================================
build_sound_theme_freedesktop() {
should_skip_package "sound-theme-freedesktop" && { log_info "Skipping sound-theme-freedesktop (already built)"; return 0; }
log_step "Building sound-theme-freedesktop-0.8..."

if [ ! -f /sources/sound-theme-freedesktop-0.8.tar.bz2 ]; then
    log_error "sound-theme-freedesktop-0.8.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf sound-theme-freedesktop-*
tar -xf /sources/sound-theme-freedesktop-0.8.tar.bz2
cd sound-theme-freedesktop-*

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf sound-theme-freedesktop-*

log_info "sound-theme-freedesktop-0.8 installed successfully"
create_checkpoint "sound-theme-freedesktop"
}

# =====================================================================
# libcanberra-0.30 (XDG Sound Theme Implementation)
# https://www.linuxfromscratch.org/blfs/view/12.4/multimedia/libcanberra.html
# =====================================================================
build_libcanberra() {
should_skip_package "libcanberra" && { log_info "Skipping libcanberra (already built)"; return 0; }
log_step "Building libcanberra-0.30..."

if [ ! -f /sources/libcanberra-0.30.tar.xz ]; then
    log_error "libcanberra-0.30.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libcanberra-*
tar -xf /sources/libcanberra-0.30.tar.xz
cd libcanberra-*

# Apply wayland patch
if [ -f /sources/libcanberra-0.30-wayland-1.patch ]; then
    patch -Np1 -i /sources/libcanberra-0.30-wayland-1.patch
fi

./configure --prefix=/usr --disable-oss
make
make docdir=/usr/share/doc/libcanberra-0.30 install

cd "$BUILD_DIR"
rm -rf libcanberra-*

log_info "libcanberra-0.30 installed successfully"
create_checkpoint "libcanberra"
}

# =====================================================================
# libical-3.0.20 (iCalendar protocols implementation)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libical.html
# =====================================================================
build_libical() {
should_skip_package "libical" && { log_info "Skipping libical (already built)"; return 0; }
log_step "Building libical-3.0.20..."

if [ ! -f /sources/libical-3.0.20.tar.gz ]; then
    log_error "libical-3.0.20.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libical-*
tar -xf /sources/libical-3.0.20.tar.gz
cd libical-*

mkdir build && cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr  \
      -D CMAKE_BUILD_TYPE=Release   \
      -D SHARED_ONLY=yes            \
      -D ICAL_BUILD_DOCS=false      \
      -D GOBJECT_INTROSPECTION=true \
      -D ICAL_GLIB_VAPI=true        \
      ..

# Use -j1 as recommended by BLFS
make -j1
make install

cd "$BUILD_DIR"
rm -rf libical-*

log_info "libical-3.0.20 installed successfully"
create_checkpoint "libical"
}

# =====================================================================
# lmdb-0.9.33 (Lightning Memory-Mapped Database)
# https://www.linuxfromscratch.org/blfs/view/12.4/server/lmdb.html
# =====================================================================
build_lmdb() {
should_skip_package "lmdb" && { log_info "Skipping lmdb (already built)"; return 0; }
log_step "Building lmdb-0.9.33..."

if [ ! -f /sources/LMDB_0.9.33.tar.bz2 ]; then
    log_error "LMDB_0.9.33.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf openldap-*
tar -xf /sources/LMDB_0.9.33.tar.bz2
cd openldap-*/libraries/liblmdb

make
# Remove static library from install target
sed -i 's| liblmdb.a||' Makefile
make prefix=/usr install

cd "$BUILD_DIR"
rm -rf openldap-*

log_info "lmdb-0.9.33 installed successfully"
create_checkpoint "lmdb"
}

# =====================================================================
# libqrencode-4.1.1 (QR code encoding library)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libqrencode.html
# =====================================================================
build_libqrencode() {
should_skip_package "libqrencode" && { log_info "Skipping libqrencode (already built)"; return 0; }
log_step "Building libqrencode-4.1.1..."

if [ ! -f /sources/libqrencode-4.1.1.tar.gz ]; then
    log_error "libqrencode-4.1.1.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libqrencode-*
tar -xf /sources/libqrencode-4.1.1.tar.gz
cd libqrencode-*

sh autogen.sh
./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf libqrencode-*

log_info "libqrencode-4.1.1 installed successfully"
create_checkpoint "libqrencode"
}

# =====================================================================
# Aspell-0.60.8.1 (Spell checker)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/aspell.html
# =====================================================================
build_aspell() {
should_skip_package "aspell" && { log_info "Skipping aspell (already built)"; return 0; }
log_step "Building aspell-0.60.8.1..."

if [ ! -f /sources/aspell-0.60.8.1.tar.gz ]; then
    log_error "aspell-0.60.8.1.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf aspell-*
tar -xf /sources/aspell-0.60.8.1.tar.gz
cd aspell-*

# Fix for gcc-15
sed -e 's/; i.*size)/, e = end(); i != e; ++i, ++size_)/' \
    -i modules/speller/default/vector_hash-t.hpp

./configure --prefix=/usr
make
make install
ln -svfn aspell-0.60 /usr/lib/aspell

# Install ispell and spell wrapper scripts
install -v -m 755 scripts/ispell /usr/bin/
install -v -m 755 scripts/spell /usr/bin/

# Install English dictionary
if [ -f /sources/aspell6-en-2020.12.07-0.tar.bz2 ]; then
    cd "$BUILD_DIR"
    tar -xf /sources/aspell6-en-2020.12.07-0.tar.bz2
    cd aspell6-en-*
    ./configure
    make
    make install
fi

cd "$BUILD_DIR"
rm -rf aspell-* aspell6-*

log_info "aspell-0.60.8.1 installed successfully"
create_checkpoint "aspell"
}

# =====================================================================
# libgudev-238 (GObject bindings for libudev)
# Required by: ModemManager, UPower, UDisks
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libgudev.html
# =====================================================================
build_libgudev() {
should_skip_package "libgudev" && { log_info "Skipping libgudev (already built)"; return 0; }
log_step "Building libgudev-238..."

if [ ! -f /sources/libgudev-238.tar.xz ]; then
    log_error "libgudev-238.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libgudev-*
tar -xf /sources/libgudev-238.tar.xz
cd libgudev-*

mkdir build && cd build

meson setup --prefix=/usr --buildtype=release ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libgudev-*

log_info "libgudev-238 installed successfully"
create_checkpoint "libgudev"
}

# =====================================================================
# libusb-1.0.29 (USB device access library)
# Required by: UPower
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libusb.html
# =====================================================================
build_libusb() {
should_skip_package "libusb" && { log_info "Skipping libusb (already built)"; return 0; }
log_step "Building libusb-1.0.29..."

if [ ! -f /sources/libusb-1.0.29.tar.bz2 ]; then
    log_error "libusb-1.0.29.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libusb-*
tar -xf /sources/libusb-1.0.29.tar.bz2
cd libusb-*

./configure --prefix=/usr --disable-static
make
make install

cd "$BUILD_DIR"
rm -rf libusb-*

log_info "libusb-1.0.29 installed successfully"
create_checkpoint "libusb"
}

# =====================================================================
# libmbim-1.32.0 (MBIM protocol library for mobile broadband)
# Required by: ModemManager
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libmbim.html
# =====================================================================
build_libmbim() {
should_skip_package "libmbim" && { log_info "Skipping libmbim (already built)"; return 0; }
log_step "Building libmbim-1.32.0..."

if [ ! -f /sources/libmbim-1.32.0.tar.gz ]; then
    log_error "libmbim-1.32.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libmbim-*
tar -xf /sources/libmbim-1.32.0.tar.gz
cd libmbim-*

mkdir build && cd build

meson setup --prefix=/usr --buildtype=release -D bash_completion=false -D man=false ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libmbim-*

log_info "libmbim-1.32.0 installed successfully"
create_checkpoint "libmbim"
}

# =====================================================================
# libqmi-1.36.0 (QMI protocol library for mobile broadband)
# Required by: ModemManager
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libqmi.html
# =====================================================================
build_libqmi() {
should_skip_package "libqmi" && { log_info "Skipping libqmi (already built)"; return 0; }
log_step "Building libqmi-1.36.0..."

if [ ! -f /sources/libqmi-1.36.0.tar.gz ]; then
    log_error "libqmi-1.36.0.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libqmi-*
tar -xf /sources/libqmi-1.36.0.tar.gz
cd libqmi-*

mkdir build && cd build

meson setup --prefix=/usr \
    --buildtype=release \
    -D bash_completion=false \
    -D qrtr=false \
    -D man=false ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libqmi-*

log_info "libqmi-1.36.0 installed successfully"
create_checkpoint "libqmi"
}

# =====================================================================
# libatasmart-0.19 (ATA S.M.A.R.T. library)
# Required by: libblockdev -> UDisks
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libatasmart.html
# =====================================================================
build_libatasmart() {
should_skip_package "libatasmart" && { log_info "Skipping libatasmart (already built)"; return 0; }
log_step "Building libatasmart-0.19..."

if [ ! -f /sources/libatasmart-0.19.tar.xz ]; then
    log_error "libatasmart-0.19.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libatasmart-*
tar -xf /sources/libatasmart-0.19.tar.xz
cd libatasmart-*

./configure --prefix=/usr --disable-static
make
make docdir=/usr/share/doc/libatasmart-0.19 install

cd "$BUILD_DIR"
rm -rf libatasmart-*

log_info "libatasmart-0.19 installed successfully"
create_checkpoint "libatasmart"
}

# =====================================================================
# libbytesize-2.11 (Byte size operations library)
# Required by: libblockdev -> UDisks
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libbytesize.html
# =====================================================================
build_libbytesize() {
should_skip_package "libbytesize" && { log_info "Skipping libbytesize (already built)"; return 0; }
log_step "Building libbytesize-2.11..."

if [ ! -f /sources/libbytesize-2.11.tar.gz ]; then
    log_error "libbytesize-2.11.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libbytesize-*
tar -xf /sources/libbytesize-2.11.tar.gz
cd libbytesize-*

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf libbytesize-*

log_info "libbytesize-2.11 installed successfully"
create_checkpoint "libbytesize"
}

# =====================================================================
# keyutils-1.6.3 (Kernel key management utilities)
# Required by: libnvme -> libblockdev -> UDisks
# https://www.linuxfromscratch.org/blfs/view/git/general/keyutils.html
# =====================================================================
build_keyutils() {
should_skip_package "keyutils" && { log_info "Skipping keyutils (already built)"; return 0; }
log_step "Building keyutils-1.6.3..."

if [ ! -f /sources/keyutils-1.6.3.tar.gz ]; then
    log_error "keyutils-1.6.3.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf keyutils-*
tar -xf /sources/keyutils-1.6.3.tar.gz
cd keyutils-*

make
make NO_ARLIB=1 LIBDIR=/usr/lib BINDIR=/usr/bin SBINDIR=/usr/sbin install

cd "$BUILD_DIR"
rm -rf keyutils-*

log_info "keyutils-1.6.3 installed successfully"
create_checkpoint "keyutils"
}

# =====================================================================
# libaio-0.3.113 (Linux-native async I/O library)
# Required by: LVM2
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libaio.html
# =====================================================================
build_libaio() {
should_skip_package "libaio" && { log_info "Skipping libaio (already built)"; return 0; }
log_step "Building libaio-0.3.113..."

if [ ! -f /sources/libaio-0.3.113.tar.gz ]; then
    log_error "libaio-0.3.113.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libaio-*
tar -xf /sources/libaio-0.3.113.tar.gz
cd libaio-*

# Disable installation of static library
sed -i '/install.*libaio.a/s/^/#/' src/Makefile

make
make install

cd "$BUILD_DIR"
rm -rf libaio-*

log_info "libaio-0.3.113 installed successfully"
create_checkpoint "libaio"
}

# =====================================================================
# popt-1.19 (command-line option parsing library)
# Required by: cryptsetup
# https://www.linuxfromscratch.org/blfs/view/12.4/general/popt.html
# =====================================================================
build_popt() {
should_skip_package "popt" && { log_info "Skipping popt (already built)"; return 0; }
log_step "Building popt-1.19..."

if [ ! -f /sources/popt-1.19.tar.gz ]; then
    log_error "popt-1.19.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf popt-*
tar -xf /sources/popt-1.19.tar.gz
cd popt-*

./configure --prefix=/usr --disable-static
make
make install

cd "$BUILD_DIR"
rm -rf popt-*

log_info "popt-1.19 installed successfully"
create_checkpoint "popt"
}

# =====================================================================
# json-c-0.18 (JSON C library)
# Required by: cryptsetup
# https://www.linuxfromscratch.org/blfs/view/12.4/general/json-c.html
# =====================================================================
build_json_c() {
should_skip_package "json-c" && { log_info "Skipping json-c (already built)"; return 0; }
log_step "Building json-c-0.18..."

if [ ! -f /sources/json-c-0.18.tar.gz ]; then
    log_error "json-c-0.18.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf json-c-*
tar -xf /sources/json-c-0.18.tar.gz
cd json-c-*

# Fix for CMake-4.0
sed -i 's/VERSION 2.8/VERSION 4.0/' apps/CMakeLists.txt
sed -i 's/VERSION 3.9/VERSION 4.0/' tests/CMakeLists.txt

mkdir build && cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BUILD_STATIC_LIBS=OFF     \
      ..

make
make install

cd "$BUILD_DIR"
rm -rf json-c-*

log_info "json-c-0.18 installed successfully"
create_checkpoint "json-c"
}

# =====================================================================
# LVM2-2.03.34 (Logical Volume Manager - provides device-mapper)
# Required by: cryptsetup, libblockdev
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/lvm2.html
# =====================================================================
build_lvm2() {
should_skip_package "lvm2" && { log_info "Skipping LVM2 (already built)"; return 0; }
log_step "Building LVM2-2.03.34..."

if [ ! -f /sources/LVM2.2.03.34.tgz ]; then
    log_error "LVM2.2.03.34.tgz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf LVM2.*
tar -xf /sources/LVM2.2.03.34.tgz
cd LVM2.*

PATH+=:/usr/sbin
./configure --prefix=/usr       \
            --enable-cmdlib     \
            --enable-pkgconfig  \
            --enable-udev_sync

make
make install
make install_systemd_units

# Fix default configuration
sed -e '/locking_dir =/{s/#//;s/var/run/}' \
    -i /etc/lvm/lvm.conf

cd "$BUILD_DIR"
rm -rf LVM2.*

log_info "LVM2-2.03.34 installed successfully"
create_checkpoint "lvm2"
}

# =====================================================================
# cryptsetup-2.8.1 (disk encryption)
# Required by: libblockdev
# https://www.linuxfromscratch.org/blfs/view/12.4/postlfs/cryptsetup.html
# =====================================================================
build_cryptsetup() {
should_skip_package "cryptsetup" && { log_info "Skipping cryptsetup (already built)"; return 0; }
log_step "Building cryptsetup-2.8.1..."

if [ ! -f /sources/cryptsetup-2.8.1.tar.xz ]; then
    log_error "cryptsetup-2.8.1.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf cryptsetup-*
tar -xf /sources/cryptsetup-2.8.1.tar.xz
cd cryptsetup-*

./configure --prefix=/usr       \
            --disable-ssh-token \
            --disable-asciidoc

make
make install

cd "$BUILD_DIR"
rm -rf cryptsetup-*

log_info "cryptsetup-2.8.1 installed successfully"
create_checkpoint "cryptsetup"
}

# =====================================================================
# libyaml-0.2.5 (YAML 1.1 parser and emitter)
# Required by: libblockdev -> UDisks
# https://www.linuxfromscratch.org/blfs/view/systemd/general/libyaml.html
# =====================================================================
build_libyaml() {
should_skip_package "libyaml" && { log_info "Skipping libyaml (already built)"; return 0; }
log_step "Building libyaml-0.2.5..."

if [ ! -f /sources/yaml-0.2.5.tar.gz ]; then
    log_error "yaml-0.2.5.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf yaml-*
tar -xf /sources/yaml-0.2.5.tar.gz
cd yaml-*

./configure --prefix=/usr --disable-static
make
make install

cd "$BUILD_DIR"
rm -rf yaml-*

log_info "libyaml-0.2.5 installed successfully"
create_checkpoint "libyaml"
}

# =====================================================================
# libnvme-1.15 (NVMe device management library)
# Required by: libblockdev -> UDisks
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libnvme.html
# =====================================================================
build_libnvme() {
should_skip_package "libnvme" && { log_info "Skipping libnvme (already built)"; return 0; }
log_step "Building libnvme-1.15..."

if [ ! -f /sources/libnvme-1.15.tar.gz ]; then
    log_error "libnvme-1.15.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libnvme-*
tar -xf /sources/libnvme-1.15.tar.gz
cd libnvme-*

mkdir build && cd build

meson setup --prefix=/usr --buildtype=release -D libdbus=auto ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libnvme-*

log_info "libnvme-1.15 installed successfully"
create_checkpoint "libnvme"
}

# =====================================================================
# libblockdev-3.3.1 (Block device library)
# Required by: UDisks
# https://www.linuxfromscratch.org/blfs/view/12.4/general/libblockdev.html
# =====================================================================
build_libblockdev() {
should_skip_package "libblockdev" && { log_info "Skipping libblockdev (already built)"; return 0; }
log_step "Building libblockdev-3.3.1..."

if [ ! -f /sources/libblockdev-3.3.1.tar.gz ]; then
    log_error "libblockdev-3.3.1.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libblockdev-*
tar -xf /sources/libblockdev-3.3.1.tar.gz
cd libblockdev-*

# Build with crypto/lvm support now that dependencies are installed
./configure --prefix=/usr      \
            --sysconfdir=/etc  \
            --with-python3     \
            --without-escrow   \
            --without-gtk-doc  \
            --without-lvm_dbus \
            --without-nvdimm   \
            --without-tools    \
            --without-smartmontools

make
make install

cd "$BUILD_DIR"
rm -rf libblockdev-*

log_info "libblockdev-3.3.1 installed successfully"
create_checkpoint "libblockdev"
}

# =====================================================================
# UDisks-2.10.2 (Disk management daemon)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/udisks2.html
# =====================================================================
build_udisks() {
should_skip_package "udisks" && { log_info "Skipping UDisks (already built)"; return 0; }
log_step "Building UDisks-2.10.2..."

if [ ! -f /sources/udisks-2.10.2.tar.bz2 ]; then
    log_error "udisks-2.10.2.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf udisks-*
tar -xf /sources/udisks-2.10.2.tar.bz2
cd udisks-*

./configure --prefix=/usr        \
            --sysconfdir=/etc    \
            --localstatedir=/var \
            --disable-static     \
            --enable-available-modules

make
make install

cd "$BUILD_DIR"
rm -rf udisks-*

log_info "UDisks-2.10.2 installed successfully"
create_checkpoint "udisks"
}

# =====================================================================
# BlueZ-5.83 (Bluetooth protocol stack)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/bluez.html
# =====================================================================
build_bluez() {
should_skip_package "bluez" && { log_info "Skipping bluez (already built)"; return 0; }
log_step "Building BlueZ-5.83..."

if [ ! -f /sources/bluez-5.83.tar.xz ]; then
    log_error "bluez-5.83.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf bluez-*
tar -xf /sources/bluez-5.83.tar.xz
cd bluez-*

./configure --prefix=/usr         \
            --sysconfdir=/etc     \
            --localstatedir=/var  \
            --disable-manpages    \
            --enable-library

make
make install
ln -svf ../libexec/bluetooth/bluetoothd /usr/sbin

# Install main configuration file
install -v -dm755 /etc/bluetooth
install -v -m644 src/main.conf /etc/bluetooth/main.conf

cd "$BUILD_DIR"
rm -rf bluez-*

log_info "BlueZ-5.83 installed successfully"
create_checkpoint "bluez"
}

# =====================================================================
# ModemManager-1.24.2 (Mobile broadband modem management)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/ModemManager.html
# =====================================================================
build_modemmanager() {
should_skip_package "modemmanager" && { log_info "Skipping ModemManager (already built)"; return 0; }
log_step "Building ModemManager-1.24.2..."

if [ ! -f /sources/ModemManager-1.24.2.tar.gz ]; then
    log_error "ModemManager-1.24.2.tar.gz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf ModemManager-*
tar -xf /sources/ModemManager-1.24.2.tar.gz
cd ModemManager-*

mkdir build && cd build

meson setup ..                 \
      --prefix=/usr            \
      --buildtype=release      \
      -D bash_completion=false \
      -D qrtr=false

ninja
ninja install

cd "$BUILD_DIR"
rm -rf ModemManager-*

log_info "ModemManager-1.24.2 installed successfully"
create_checkpoint "modemmanager"
}

# =====================================================================
# UPower-1.90.9 (Power management)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/upower.html
# =====================================================================
build_upower() {
should_skip_package "upower" && { log_info "Skipping UPower (already built)"; return 0; }
log_step "Building UPower-1.90.9..."

if [ ! -f /sources/upower-v1.90.9.tar.bz2 ]; then
    log_error "upower-v1.90.9.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf upower-*
tar -xf /sources/upower-v1.90.9.tar.bz2
cd upower-*

mkdir build && cd build

meson setup ..            \
      --prefix=/usr       \
      --buildtype=release \
      -D gtk-doc=false    \
      -D man=false

ninja
ninja install

cd "$BUILD_DIR"
rm -rf upower-*

log_info "UPower-1.90.9 installed successfully"
create_checkpoint "upower"
}

# =====================================================================
# breeze-icons-6.17.0 (KDE Breeze icon theme)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/breeze-icons.html
# =====================================================================
build_breeze_icons() {
should_skip_package "breeze-icons" && { log_info "Skipping breeze-icons (already built)"; return 0; }
log_step "Building breeze-icons-6.17.0..."

if [ ! -f /sources/breeze-icons-6.17.0.tar.xz ]; then
    log_error "breeze-icons-6.17.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf breeze-icons-*
tar -xf /sources/breeze-icons-6.17.0.tar.xz
cd breeze-icons-*

mkdir build && cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BINARY_ICONS_RESOURCE=ON  \
      ..

make
make install

cd "$BUILD_DIR"
rm -rf breeze-icons-*

log_info "breeze-icons-6.17.0 installed successfully"
create_checkpoint "breeze-icons"
}

# =====================================================================
# npth-1.8 (New Portable Threads Library)
# Required by: GnuPG
# https://www.linuxfromscratch.org/blfs/view/svn/general/npth.html
# =====================================================================
build_npth() {
should_skip_package "npth" && { log_info "Skipping npth (already built)"; return 0; }
log_step "Building npth-1.8..."

if [ ! -f /sources/npth-1.8.tar.bz2 ]; then
    log_error "npth-1.8.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf npth-*
tar -xf /sources/npth-1.8.tar.bz2
cd npth-*

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf npth-*

log_info "npth-1.8 installed successfully"
create_checkpoint "npth"
}

# =====================================================================
# libassuan-3.0.2 (IPC library for GnuPG)
# Required by: GnuPG, pinentry, gpgme
# https://www.linuxfromscratch.org/blfs/view/svn/general/libassuan.html
# =====================================================================
build_libassuan() {
should_skip_package "libassuan" && { log_info "Skipping libassuan (already built)"; return 0; }
log_step "Building libassuan-3.0.2..."

if [ ! -f /sources/libassuan-3.0.2.tar.bz2 ]; then
    log_error "libassuan-3.0.2.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libassuan-*
tar -xf /sources/libassuan-3.0.2.tar.bz2
cd libassuan-*

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf libassuan-*

log_info "libassuan-3.0.2 installed successfully"
create_checkpoint "libassuan"
}

# =====================================================================
# libksba-1.6.7 (X.509 and CMS library)
# Required by: GnuPG
# https://www.linuxfromscratch.org/blfs/view/svn/general/libksba.html
# =====================================================================
build_libksba() {
should_skip_package "libksba" && { log_info "Skipping libksba (already built)"; return 0; }
log_step "Building libksba-1.6.7..."

if [ ! -f /sources/libksba-1.6.7.tar.bz2 ]; then
    log_error "libksba-1.6.7.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf libksba-*
tar -xf /sources/libksba-1.6.7.tar.bz2
cd libksba-*

./configure --prefix=/usr
make
make install

cd "$BUILD_DIR"
rm -rf libksba-*

log_info "libksba-1.6.7 installed successfully"
create_checkpoint "libksba"
}

# =====================================================================
# pinentry-1.3.2 (PIN entry dialogs for GnuPG)
# Required by: GnuPG (recommended)
# https://www.linuxfromscratch.org/blfs/view/svn/general/pinentry.html
# =====================================================================
build_pinentry() {
should_skip_package "pinentry" && { log_info "Skipping pinentry (already built)"; return 0; }
log_step "Building pinentry-1.3.2..."

if [ ! -f /sources/pinentry-1.3.2.tar.bz2 ]; then
    log_error "pinentry-1.3.2.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf pinentry-*
tar -xf /sources/pinentry-1.3.2.tar.bz2
cd pinentry-*

./configure --prefix=/usr --enable-pinentry-tty
make
make install

cd "$BUILD_DIR"
rm -rf pinentry-*

log_info "pinentry-1.3.2 installed successfully"
create_checkpoint "pinentry"
}

# =====================================================================
# GnuPG-2.5.14 (GNU Privacy Guard with Post-Quantum Cryptography)
# Required by: gpgme
# https://gnupg.org/
# NOTE: Version 2.5.14 includes Kyber/ML-KEM post-quantum key exchange support
# =====================================================================
build_gnupg() {
should_skip_package "gnupg" && { log_info "Skipping GnuPG (already built)"; return 0; }
log_step "Building GnuPG-2.5.14 (with Kyber/ML-KEM PQC support)..."

if [ ! -f /sources/gnupg-2.5.14.tar.bz2 ]; then
    log_error "gnupg-2.5.14.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf gnupg-*
tar -xf /sources/gnupg-2.5.14.tar.bz2
cd gnupg-*

mkdir build && cd build

../configure --prefix=/usr            \
             --localstatedir=/var     \
             --sysconfdir=/etc        \
             --docdir=/usr/share/doc/gnupg-2.5.14

make
make install

cd "$BUILD_DIR"
rm -rf gnupg-*

log_info "GnuPG-2.5.14 installed successfully (Kyber/ML-KEM enabled)"
create_checkpoint "gnupg"
}

# =====================================================================
# gpgme-2.0.0 (GPGME library)
# Required by: gpgmepp
# https://www.linuxfromscratch.org/blfs/view/svn/postlfs/gpgme.html
# =====================================================================
build_gpgme() {
should_skip_package "gpgme" && { log_info "Skipping gpgme (already built)"; return 0; }
log_step "Building gpgme-2.0.0..."

if [ ! -f /sources/gpgme-2.0.0.tar.bz2 ]; then
    log_error "gpgme-2.0.0.tar.bz2 not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf gpgme-*
tar -xf /sources/gpgme-2.0.0.tar.bz2
cd gpgme-*

mkdir build && cd build

../configure --prefix=/usr --disable-static

make
make install

cd "$BUILD_DIR"
rm -rf gpgme-*

log_info "gpgme-2.0.0 installed successfully"
create_checkpoint "gpgme"
}

# =====================================================================
# gpgmepp-2.0.0 (C++ bindings for GPGME)
# Required by: KDE Frameworks (KWallet, etc.)
# https://www.linuxfromscratch.org/blfs/view/svn/postlfs/gpgmepp.html
# =====================================================================
build_gpgmepp() {
should_skip_package "gpgmepp" && { log_info "Skipping gpgmepp (already built)"; return 0; }
log_step "Building gpgmepp-2.0.0..."

if [ ! -f /sources/gpgmepp-2.0.0.tar.xz ]; then
    log_error "gpgmepp-2.0.0.tar.xz not found in /sources"
    return 1
fi

cd "$BUILD_DIR"
rm -rf gpgmepp-*
tar -xf /sources/gpgmepp-2.0.0.tar.xz
cd gpgmepp-*

mkdir build && cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr ..

make
make install

cd "$BUILD_DIR"
rm -rf gpgmepp-*

log_info "gpgmepp-2.0.0 installed successfully"
create_checkpoint "gpgmepp"
}

# =====================================================================
# zxing-cpp-2.3.0 (barcode/QR code processing library)
# Required for: KDE Prison framework
# https://www.linuxfromscratch.org/blfs/view/12.4/general/zxing-cpp.html
# =====================================================================
build_zxing_cpp() {
should_skip_package "zxing-cpp" && { log_info "Skipping zxing-cpp (already built)"; return 0; }
log_step "Building zxing-cpp-2.3.0..."

if [ ! -f /sources/zxing-cpp-2.3.0.tar.gz ]; then
    log_error "zxing-cpp-2.3.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf zxing-cpp-*
tar -xf /sources/zxing-cpp-2.3.0.tar.gz
cd zxing-cpp-*

mkdir build
cd build
cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release \
      -D ZXING_EXAMPLES=OFF \
      -W no-dev .. &&
make $MAKEFLAGS &&
make install

cd "$BUILD_DIR"
rm -rf zxing-cpp-*

log_info "zxing-cpp-2.3.0 installed successfully"
create_checkpoint "zxing-cpp"
}

# =====================================================================
# libsecret-0.21.7 (GNOME secret storage library)
# Required for: KDE kwallet
# https://www.linuxfromscratch.org/blfs/view/12.4/gnome/libsecret.html
# =====================================================================
build_libsecret() {
should_skip_package "libsecret" && { log_info "Skipping libsecret (already built)"; return 0; }
log_step "Building libsecret-0.21.7..."

if [ ! -f /sources/libsecret-0.21.7.tar.xz ]; then
    log_error "libsecret-0.21.7.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libsecret-*
tar -xf /sources/libsecret-0.21.7.tar.xz
cd libsecret-*

# Remove existing build directory if present (tarball includes one)
rm -rf build
mkdir build
cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            -D gtk_doc=false    \
            -D manpage=false    \
            ..

ninja
ninja install

cd "$BUILD_DIR"
rm -rf libsecret-*
ldconfig

log_info "libsecret-0.21.7 installed successfully"
create_checkpoint "libsecret"
}

# =====================================================================
# Perl Modules for KDE Frameworks
# =====================================================================

# MIME-Base32-1.303 (dependency of URI)
build_mime_base32() {
should_skip_package "mime-base32" && { log_info "Skipping MIME-Base32 (already built)"; return 0; }
log_step "Building MIME-Base32-1.303..."

if [ ! -f /sources/MIME-Base32-1.303.tar.gz ]; then
    log_error "MIME-Base32-1.303.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf MIME-Base32-*
tar -xf /sources/MIME-Base32-1.303.tar.gz
cd MIME-Base32-*

perl Makefile.PL &&
make $MAKEFLAGS &&
make install

cd "$BUILD_DIR"
rm -rf MIME-Base32-*

log_info "MIME-Base32-1.303 installed successfully"
create_checkpoint "mime-base32"
}

# URI-5.32 (required for KDE Frameworks)
build_uri_perl() {
should_skip_package "uri-perl" && { log_info "Skipping URI Perl module (already built)"; return 0; }
log_step "Building URI-5.32..."

if [ ! -f /sources/URI-5.32.tar.gz ]; then
    log_error "URI-5.32.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf URI-*
tar -xf /sources/URI-5.32.tar.gz
cd URI-*

perl Makefile.PL &&
make $MAKEFLAGS &&
make install

cd "$BUILD_DIR"
rm -rf URI-*

log_info "URI-5.32 installed successfully"
create_checkpoint "uri-perl"
}

# =====================================================================
# KDE Frameworks 6.17.0 - Generic build function
# =====================================================================

# Generic KF6 build function - handles standard CMake-based KF6 packages
build_kf6_package() {
    local pkg_name="$1"
    local pkg_version="${2:-6.17.0}"
    local extra_cmake_args="${3:-}"

    local checkpoint_name="kf6-${pkg_name}"

    should_skip_package "$checkpoint_name" && { log_info "Skipping ${pkg_name} (already built)"; return 0; }
    log_step "Building ${pkg_name}-${pkg_version}..."

    local tarball="/sources/${pkg_name}-${pkg_version}.tar.xz"
    if [ ! -f "$tarball" ]; then
        log_error "${pkg_name}-${pkg_version}.tar.xz not found in /sources"
        exit 1
    fi

    cd "$BUILD_DIR"
    rm -rf ${pkg_name}-*
    tar -xf "$tarball"
    cd ${pkg_name}-*

    mkdir build
    cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
          -D CMAKE_SKIP_INSTALL_RPATH=ON \
          -D CMAKE_BUILD_TYPE=Release \
          -D BUILD_TESTING=OFF \
          -D BUILD_PYTHON_BINDINGS=OFF \
          -W no-dev \
          $extra_cmake_args ..

    make $MAKEFLAGS
    make install

    cd "$BUILD_DIR"
    rm -rf ${pkg_name}-*
    ldconfig

    log_info "${pkg_name}-${pkg_version} installed successfully"
    create_checkpoint "$checkpoint_name"
}

# Special handler for kapidox (Python module, not CMake)
# NOTE: kapidox is for documentation generation only, requires doxypypy, doxyqml, requests
# Making this optional since it's not needed for runtime
build_kapidox() {
should_skip_package "kf6-kapidox" && { log_info "Skipping kapidox (already built)"; return 0; }
log_step "Building kapidox-6.17.0 (optional - doc generation only)..."

if [ ! -f /sources/kapidox-6.17.0.tar.xz ]; then
    log_info "kapidox-6.17.0.tar.xz not found - skipping (optional package)"
    create_checkpoint "kf6-kapidox"
    return 0
fi

cd "$BUILD_DIR"
rm -rf kapidox-*
tar -xf /sources/kapidox-6.17.0.tar.xz
cd kapidox-*

# kapidox requires doxypypy and other Python dependencies we don't have
# Skip it since it's only for documentation generation
log_info "Skipping kapidox installation (requires doxypypy for doc generation)"
log_info "KDE Frameworks will build without API documentation support"

cd "$BUILD_DIR"
rm -rf kapidox-*

create_checkpoint "kf6-kapidox"
}

# =====================================================================
# KDE Frameworks 6 Environment Setup
# =====================================================================

setup_kf6_environment() {
log_step "Setting up KDE Frameworks 6 environment..."

# Create KF6 profile script for /usr installation
cat > /etc/profile.d/kf6.sh << "KFEOF"
# Begin /etc/profile.d/kf6.sh
export KF6_PREFIX=/usr
# End /etc/profile.d/kf6.sh
KFEOF

# Extend qt6.sh for KF6
cat >> /etc/profile.d/qt6.sh << "QTEOF"

# Begin kf6 extension for /etc/profile.d/qt6.sh
pathappend /usr/lib/plugins        QT_PLUGIN_PATH
pathappend /usr/lib/qt6/plugins    QT_PLUGIN_PATH

pathappend /usr/lib/qt6/qml        QML2_IMPORT_PATH
# End extension for /etc/profile.d/qt6.sh
QTEOF

# Add to sudoers if not already present
if [ -d /etc/sudoers.d ]; then
    if ! grep -q "QT_PLUGIN_PATH" /etc/sudoers.d/qt 2>/dev/null; then
        cat >> /etc/sudoers.d/qt << "SUDOEOF"
Defaults env_keep += QT_PLUGIN_PATH
Defaults env_keep += QML2_IMPORT_PATH
SUDOEOF
    fi

    if ! grep -q "KF6_PREFIX" /etc/sudoers.d/kde 2>/dev/null; then
        cat > /etc/sudoers.d/kde << "SUDOEOF"
Defaults env_keep += KF6_PREFIX
SUDOEOF
    fi
fi

# Source the environment
export KF6_PREFIX=/usr
export QT_PLUGIN_PATH="/usr/lib/plugins:/usr/lib/qt6/plugins"
export QML2_IMPORT_PATH="/usr/lib/qt6/qml"

log_info "KDE Frameworks 6 environment configured"
}

# =====================================================================
# Execute Tier 7 builds
# =====================================================================

log_info "Phase 1: Pre-Qt Dependencies"
build_libwebp
build_pciutils
# SQLite must be built BEFORE NSS so NSS uses system SQLite (avoids symbol versioning issues)
build_sqlite
build_nss
build_libmng
build_desktop_file_utils
build_html5lib

log_info "Phase 2: libuv, nghttp2, Node.js and CUPS"
build_libuv
build_nghttp2
build_nodejs
build_cups

log_info "Phase 3: Qt6 Framework"
build_qt6

log_info "Phase 4: KDE Foundation Libraries"
build_extra_cmake_modules
build_qca
build_qcoro
build_phonon
build_polkit_qt
build_plasma_wayland_protocols

log_info "Phase 5: Multimedia and Web Engine"
build_vlc
build_phonon_backend_vlc
rebuild_ninja_with_ninjajobs  # Required for QtWebEngine to respect NINJAJOBS
build_qtwebengine

log_info ""
log_info "Tier 7: Qt6 and Pre-KDE Dependencies completed!"

# =====================================================================
# Execute Tier 8 builds: KDE Frameworks 6 Dependencies
# =====================================================================

log_info "Phase 6: KDE Frameworks 6 Dependencies"
build_intltool
build_sound_theme_freedesktop
build_libcanberra
build_libical
build_lmdb
build_libqrencode
build_aspell

# Hardware management libraries (libgudev is required by ModemManager, UPower, UDisks)
build_libgudev
build_libusb
build_libmbim
build_libqmi
build_bluez
build_modemmanager
build_upower

# UDisks and its dependencies (for disk management)
build_libatasmart
build_libbytesize
build_keyutils
build_libaio
build_popt
build_json_c
build_lvm2
build_cryptsetup
build_libyaml
build_libnvme
build_libblockdev
build_udisks

build_breeze_icons

# GnuPG cryptography stack (for gpgmepp -> KDE Frameworks)
build_npth
build_libassuan
build_libksba
build_pinentry
build_gnupg
build_gpgme
build_gpgmepp

# zxing-cpp (barcode/QR library for KDE Prison)
build_zxing_cpp

# libsecret (GNOME secret storage library for KDE kwallet)
build_libsecret

log_info ""
log_info "Tier 8: KDE Frameworks 6 Dependencies completed!"
log_info "  - intltool-0.51.0: Internationalization utilities"
log_info "  - sound-theme-freedesktop-0.8: XDG sound theme"
log_info "  - libcanberra-0.30: Sound theme implementation"
log_info "  - libical-3.0.20: iCalendar library"
log_info "  - lmdb-0.9.33: Lightning Memory-Mapped Database"
log_info "  - libqrencode-4.1.1: QR code library"
log_info "  - Aspell-0.60.8.1: Spell checker"
log_info "  - libgudev-238: GObject bindings for libudev"
log_info "  - libusb-1.0.29: USB device access library"
log_info "  - libmbim-1.32.0: MBIM protocol library"
log_info "  - libqmi-1.36.0: QMI protocol library"
log_info "  - BlueZ-5.83: Bluetooth protocol stack"
log_info "  - ModemManager-1.24.2: Mobile broadband management"
log_info "  - UPower-1.90.9: Power management"
log_info "  - libatasmart-0.19: ATA S.M.A.R.T. library"
log_info "  - libbytesize-2.11: Byte size operations"
log_info "  - keyutils-1.6.3: Kernel key management"
log_info "  - libaio-0.3.113: Async I/O library"
log_info "  - popt-1.19: Command-line parsing"
log_info "  - json-c-0.18: JSON C library"
log_info "  - LVM2-2.03.34: Logical Volume Manager"
log_info "  - cryptsetup-2.8.1: Disk encryption"
log_info "  - libyaml-0.2.5: YAML parser and emitter"
log_info "  - libnvme-1.15: NVMe device management"
log_info "  - libblockdev-3.3.1: Block device library"
log_info "  - UDisks-2.10.2: Disk management daemon"
log_info "  - breeze-icons-6.17.0: KDE icon theme"
log_info "  - npth-1.8: Portable threading library"
log_info "  - libassuan-3.0.2: IPC library for GnuPG"
log_info "  - libksba-1.6.7: X.509 library for GnuPG"
log_info "  - pinentry-1.3.2: PIN entry dialog"
log_info "  - GnuPG-2.5.14: GNU Privacy Guard (Kyber/ML-KEM PQC)"
log_info "  - gpgme-2.0.0: GnuPG Made Easy"
log_info "  - gpgmepp-2.0.0: C++ bindings for GPGME"
log_info "  - zxing-cpp-2.3.0: Barcode/QR code library"
log_info ""

# =====================================================================
# Tier 9: KDE Frameworks 6.17.0
# =====================================================================

log_info ""
log_info "#####################################################################"
log_info "# TIER 9: KDE Frameworks 6.17.0"
log_info "#####################################################################"
log_info ""

# Setup KF6 environment first
setup_kf6_environment

# Perl modules required for KF6
log_info "Phase 1: Perl modules for KDE Frameworks"
build_mime_base32
build_uri_perl

# KF6 Tier 1: Foundation Frameworks (21 packages, no KF6 dependencies)
log_info "Phase 2: KF6 Tier 1 - Foundation Frameworks (21 packages)"
build_kf6_package "attica"
build_kapidox
build_kf6_package "karchive"
build_kf6_package "kcodecs"
build_kf6_package "kconfig"
build_kf6_package "kcoreaddons"
build_kf6_package "kdbusaddons"
build_kf6_package "kdnssd"
build_kf6_package "kguiaddons"
build_kf6_package "ki18n"
build_kf6_package "kidletime"
build_kf6_package "kimageformats"
build_kf6_package "kitemmodels"
build_kf6_package "kitemviews"
build_kf6_package "kplotting"
build_kf6_package "kwidgetsaddons"
build_kf6_package "kwindowsystem"
build_kf6_package "networkmanager-qt"
build_kf6_package "solid"
build_kf6_package "sonnet"
build_kf6_package "threadweaver"

log_info "KF6 Tier 1 complete (21 packages)"

# KF6 Tier 2: Core Frameworks (22 packages, depend on Tier 1)
log_info "Phase 3: KF6 Tier 2 - Core Frameworks (22 packages)"
build_kf6_package "kauth"
build_kf6_package "kcompletion"
build_kf6_package "kcrash"
build_kf6_package "kdoctools"
build_kf6_package "kpty"
build_kf6_package "kunitconversion"
build_kf6_package "kcolorscheme"
build_kf6_package "kconfigwidgets"
build_kf6_package "kservice"
build_kf6_package "kglobalaccel"
build_kf6_package "kpackage"
build_kf6_package "kdesu"
build_kf6_package "kiconthemes"
build_kf6_package "knotifications"
build_kf6_package "kjobwidgets"
build_kf6_package "ktextwidgets"
build_kf6_package "kxmlgui"
build_kf6_package "kbookmarks"
build_kf6_package "kwallet"
build_kf6_package "kded"
build_kf6_package "kio"
build_kf6_package "kdeclarative"
build_kf6_package "kcmutils"

log_info "KF6 Tier 2 complete (22 packages)"

# KF6 Tier 3: Integration Frameworks (10 packages)
log_info "Phase 4: KF6 Tier 3 - Integration Frameworks (10 packages)"
build_kf6_package "kirigami"
build_kf6_package "syndication"
build_kf6_package "knewstuff"
build_kf6_package "frameworkintegration"
build_kf6_package "kparts"
build_kf6_package "syntax-highlighting"
build_kf6_package "ktexteditor"
build_kf6_package "modemmanager-qt"
build_kf6_package "kcontacts"
build_kf6_package "kpeople"

log_info "KF6 Tier 3 complete (10 packages)"

# KF6 Tier 4: Extended Frameworks (16 packages)
log_info "Phase 5: KF6 Tier 4 - Extended Frameworks (16 packages)"
build_kf6_package "bluez-qt"
build_kf6_package "kfilemetadata"
build_kf6_package "baloo"
build_kf6_package "krunner"
build_kf6_package "prison"
build_kf6_package "qqc2-desktop-style"
build_kf6_package "kholidays"
build_kf6_package "purpose"
build_kf6_package "kcalendarcore"
build_kf6_package "kquickcharts"
build_kf6_package "knotifyconfig"
build_kf6_package "kdav"
build_kf6_package "kstatusnotifieritem"
build_kf6_package "ksvg"
build_kf6_package "ktexttemplate"
build_kf6_package "kuserfeedback"

log_info "KF6 Tier 4 complete (16 packages)"

log_info ""
log_info "=========================================="
log_info "KDE Frameworks 6.17.0 Build Complete!"
log_info "=========================================="
log_info "Total: 69 packages + 2 Perl modules"
log_info "  - Tier 1 Foundation: 21 packages"
log_info "  - Tier 2 Core: 22 packages"
log_info "  - Tier 3 Integration: 10 packages"
log_info "  - Tier 4 Extended: 16 packages"
log_info ""

log_info "KDE Frameworks 6.17.0 Build Complete!"

# =====================================================================
# Tier 10: Plasma Prerequisites
# =====================================================================

log_info ""
log_info "#####################################################################"
log_info "# TIER 10: Plasma Prerequisites"
log_info "#####################################################################"
log_info ""

# NOTE: duktape and libproxy are already built in Tier 2 networking section
# so we don't need separate build functions for them here

# Build kdsoap (Qt SOAP library)
build_kdsoap() {
should_skip_package "blfs-kdsoap" && { log_info "Skipping kdsoap (already built)"; return 0; }
log_step "Building kdsoap-2.2.0..."

cd "$BUILD_DIR"
rm -rf kdsoap-*
tar -xf /sources/kdsoap-2.2.0.tar.gz
cd kdsoap-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release  \
      -D KDSoap_QT6=ON             \
      -D CMAKE_INSTALL_DOCDIR=/usr/share/doc/kdsoap-2.2.0 \
      -W no-dev ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf kdsoap-*
ldconfig

log_info "kdsoap-2.2.0 installed successfully"
create_checkpoint "blfs-kdsoap"
}

# Build kdsoap-ws-discovery-client (WS-Discovery protocol)
build_kdsoap_ws_discovery_client() {
should_skip_package "blfs-kdsoap-ws-discovery-client" && { log_info "Skipping kdsoap-ws-discovery-client (already built)"; return 0; }
log_step "Building kdsoap-ws-discovery-client-0.4.0..."

cd "$BUILD_DIR"
rm -rf kdsoap-ws-discovery-client-*
tar -xf /sources/kdsoap-ws-discovery-client-0.4.0.tar.xz
cd kdsoap-ws-discovery-client-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr    \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release     \
      -D CMAKE_SKIP_INSTALL_RPATH=ON  \
      -D QT_MAJOR_VERSION=6           \
      -W no-dev ..

make $MAKEFLAGS
make install

# Move docs to versioned directory
if [ -d /usr/share/doc/KDSoapWSDiscoveryClient ]; then
    mv -v /usr/share/doc/KDSoapWSDiscoveryClient /usr/share/doc/KDSoapWSDiscoveryClient-0.4.0
fi

cd "$BUILD_DIR"
rm -rf kdsoap-ws-discovery-client-*
ldconfig

log_info "kdsoap-ws-discovery-client-0.4.0 installed successfully"
create_checkpoint "blfs-kdsoap-ws-discovery-client"
}

# Build oxygen-icons
build_oxygen_icons() {
should_skip_package "blfs-oxygen-icons" && { log_info "Skipping oxygen-icons (already built)"; return 0; }
log_step "Building oxygen-icons-6.0.0..."

cd "$BUILD_DIR"
rm -rf oxygen-icons-*
tar -xf /sources/oxygen-icons-6.0.0.tar.xz
cd oxygen-icons-*

# Enable scalable icons
sed -i '/( oxygen/ s/)/scalable )/' CMakeLists.txt

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -W no-dev ..
make install

cd "$BUILD_DIR"
rm -rf oxygen-icons-*

log_info "oxygen-icons-6.0.0 installed successfully"
create_checkpoint "blfs-oxygen-icons"
}

# Build kirigami-addons
build_kirigami_addons() {
should_skip_package "blfs-kirigami-addons" && { log_info "Skipping kirigami-addons (already built)"; return 0; }
log_step "Building kirigami-addons-1.9.0..."

cd "$BUILD_DIR"
rm -rf kirigami-addons-*
tar -xf /sources/kirigami-addons-1.9.0.tar.xz
cd kirigami-addons-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BUILD_TESTING=OFF         \
      -W no-dev ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf kirigami-addons-*
ldconfig

log_info "kirigami-addons-1.9.0 installed successfully"
create_checkpoint "blfs-kirigami-addons"
}

# Build plasma-activities
build_plasma_activities() {
should_skip_package "blfs-plasma-activities" && { log_info "Skipping plasma-activities (already built)"; return 0; }
log_step "Building plasma-activities-6.4.4..."

cd "$BUILD_DIR"
rm -rf plasma-activities-*
tar -xf /sources/plasma-activities-6.4.4.tar.xz
cd plasma-activities-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BUILD_TESTING=OFF         \
      -W no-dev ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf plasma-activities-*
ldconfig

log_info "plasma-activities-6.4.4 installed successfully"
create_checkpoint "blfs-plasma-activities"
}

# Build plasma-activities-stats
build_plasma_activities_stats() {
should_skip_package "blfs-plasma-activities-stats" && { log_info "Skipping plasma-activities-stats (already built)"; return 0; }
log_step "Building plasma-activities-stats-6.4.4..."

cd "$BUILD_DIR"
rm -rf plasma-activities-stats-*
tar -xf /sources/plasma-activities-stats-6.4.4.tar.xz
cd plasma-activities-stats-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BUILD_TESTING=OFF         \
      -W no-dev ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf plasma-activities-stats-*
ldconfig

log_info "plasma-activities-stats-6.4.4 installed successfully"
create_checkpoint "blfs-plasma-activities-stats"
}

# Build kio-extras
build_kio_extras() {
should_skip_package "blfs-kio-extras" && { log_info "Skipping kio-extras (already built)"; return 0; }
log_step "Building kio-extras-25.08.0..."

cd "$BUILD_DIR"
rm -rf kio-extras-*
tar -xf /sources/kio-extras-25.08.0.tar.xz
cd kio-extras-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
      -D CMAKE_BUILD_TYPE=Release  \
      -D BUILD_TESTING=OFF         \
      -W no-dev ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf kio-extras-*
ldconfig

log_info "kio-extras-25.08.0 installed successfully"
create_checkpoint "blfs-kio-extras"
}

# =====================================================================
# lm-sensors-3.6.2 (hardware monitoring - required by libksysguard)
# https://www.linuxfromscratch.org/blfs/view/stable/general/lm-sensors.html
# =====================================================================
build_lm_sensors() {
should_skip_package "lm-sensors" && { log_info "Skipping lm-sensors (already built)"; return 0; }
log_step "Building lm-sensors-3.6.2..."

if [ ! -f /sources/lm-sensors-3-6-2.tar.gz ]; then
    log_error "lm-sensors-3-6-2.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf lm-sensors-*
tar -xf /sources/lm-sensors-3-6-2.tar.gz
cd lm-sensors-*

# Build lm-sensors with make (not cmake)
make PREFIX=/usr        \
     BUILD_STATIC_LIB=0 \
     MANDIR=/usr/share/man

make PREFIX=/usr        \
     BUILD_STATIC_LIB=0 \
     MANDIR=/usr/share/man install

cd "$BUILD_DIR"
rm -rf lm-sensors-*
ldconfig

log_info "lm-sensors-3.6.2 installed successfully"
create_checkpoint "lm-sensors"
}

# =====================================================================
# libsass-3.6.6 (Sass CSS compiler library - required by sassc)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/sassc.html
# =====================================================================
build_libsass() {
should_skip_package "libsass" && { log_info "Skipping libsass (already built)"; return 0; }
log_step "Building libsass-3.6.6..."

if [ ! -f /sources/libsass-3.6.6.tar.gz ]; then
    log_error "libsass-3.6.6.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libsass-*
tar -xf /sources/libsass-3.6.6.tar.gz
cd libsass-*

autoreconf -fi

./configure --prefix=/usr --disable-static

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf libsass-*
ldconfig

log_info "libsass-3.6.6 installed successfully"
create_checkpoint "libsass"
}

# =====================================================================
# sassc-3.6.2 (Sass CSS compiler - required by breeze-gtk)
# https://www.linuxfromscratch.org/blfs/view/12.4/general/sassc.html
# =====================================================================
build_sassc() {
should_skip_package "sassc" && { log_info "Skipping sassc (already built)"; return 0; }
log_step "Building sassc-3.6.2..."

if [ ! -f /sources/sassc-3.6.2.tar.gz ]; then
    log_error "sassc-3.6.2.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf sassc-*
tar -xf /sources/sassc-3.6.2.tar.gz
cd sassc-*

autoreconf -fi

./configure --prefix=/usr

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf sassc-*

log_info "sassc-3.6.2 installed successfully"
create_checkpoint "sassc"
}

# =====================================================================
# hwdata-0.398 (hardware identification database - required by libdisplay-info)
# https://www.linuxfromscratch.org/blfs/view/stable/general/hwdata.html
# =====================================================================
build_hwdata() {
should_skip_package "hwdata" && { log_info "Skipping hwdata (already built)"; return 0; }
log_step "Building hwdata-0.398..."

if [ ! -f /sources/hwdata-0.398.tar.gz ]; then
    log_error "hwdata-0.398.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf hwdata-*
tar -xf /sources/hwdata-0.398.tar.gz
cd hwdata-*

./configure --prefix=/usr --disable-blacklist

make install

cd "$BUILD_DIR"
rm -rf hwdata-*

log_info "hwdata-0.398 installed successfully"
create_checkpoint "hwdata"
}

# =====================================================================
# libdisplay-info-0.3.0 (EDID and DisplayID library - required by kwin)
# https://www.linuxfromscratch.org/blfs/view/stable/general/libdisplay-info.html
# =====================================================================
build_libdisplay_info() {
should_skip_package "libdisplay-info" && { log_info "Skipping libdisplay-info (already built)"; return 0; }
log_step "Building libdisplay-info-0.3.0..."

if [ ! -f /sources/libdisplay-info-0.3.0.tar.xz ]; then
    log_error "libdisplay-info-0.3.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libdisplay-info-*
tar -xf /sources/libdisplay-info-0.3.0.tar.xz
cd libdisplay-info-*

mkdir build
cd build

meson setup --prefix=/usr --buildtype=release ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libdisplay-info-*
ldconfig

log_info "libdisplay-info-0.3.0 installed successfully"
create_checkpoint "libdisplay-info"
}

# pulseaudio-qt-1.7.0 (Qt bindings for PulseAudio - required by plasma-pa)
# https://www.linuxfromscratch.org/blfs/view/svn/kde/pulseaudio-qt.html

build_pulseaudio_qt() {
should_skip_package "pulseaudio-qt" && { log_info "Skipping pulseaudio-qt (already built)"; return 0; }
log_step "Building pulseaudio-qt-1.7.0..."

if [ ! -f /sources/pulseaudio-qt-1.7.0.tar.xz ]; then
    log_error "pulseaudio-qt-1.7.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf pulseaudio-qt-*
tar -xf /sources/pulseaudio-qt-1.7.0.tar.xz
cd pulseaudio-qt-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release \
      -D BUILD_TESTING=OFF \
      -W no-dev \
      ..

make
make install

cd "$BUILD_DIR"
rm -rf pulseaudio-qt-*
ldconfig

log_info "pulseaudio-qt-1.7.0 installed successfully"
create_checkpoint "pulseaudio-qt"
}

# libwacom-2.17.0 (Wacom tablet library - required by plasma-desktop)
# https://www.linuxfromscratch.org/blfs/view/svn/general/libwacom.html

build_libwacom() {
should_skip_package "libwacom" && { log_info "Skipping libwacom (already built)"; return 0; }
log_step "Building libwacom-2.17.0..."

if [ ! -f /sources/libwacom-2.17.0.tar.xz ]; then
    log_error "libwacom-2.17.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libwacom-*
tar -xf /sources/libwacom-2.17.0.tar.xz
cd libwacom-*

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D tests=disabled \
            ..

ninja
ninja install

cd "$BUILD_DIR"
rm -rf libwacom-*
ldconfig

log_info "libwacom-2.17.0 installed successfully"
create_checkpoint "libwacom"
}

# xf86-input-wacom-1.2.3 (Xorg Wacom driver - required by wacomtablet)
# https://www.linuxfromscratch.org/blfs/view/svn/x/x7driver.html

build_xf86_input_wacom() {
should_skip_package "xf86-input-wacom" && { log_info "Skipping xf86-input-wacom (already built)"; return 0; }
log_step "Building xf86-input-wacom-1.2.3..."

if [ ! -f /sources/xf86-input-wacom-1.2.3.tar.bz2 ]; then
    log_error "xf86-input-wacom-1.2.3.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf xf86-input-wacom-*
tar -xf /sources/xf86-input-wacom-1.2.3.tar.bz2
cd xf86-input-wacom-*

./configure --prefix=/usr \
            --with-xorg-module-dir=/usr/lib/xorg/modules \
            --with-sdkdir=/usr/include/xorg \
            --with-systemd-unit-dir=/usr/lib/systemd/system \
            --with-udev-rules-dir=/usr/lib/udev/rules.d

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf xf86-input-wacom-*
ldconfig

log_info "xf86-input-wacom-1.2.3 installed successfully"
create_checkpoint "xf86-input-wacom"
}

# OpenCV-4.12.0 (Computer vision library - required by spectacle)
# https://www.linuxfromscratch.org/blfs/view/svn/general/opencv.html

build_opencv() {
should_skip_package "opencv" && { log_info "Skipping opencv (already built)"; return 0; }
log_step "Building opencv-4.12.0..."

if [ ! -f /sources/opencv-4.12.0.tar.gz ]; then
    log_error "opencv-4.12.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf opencv-*
tar -xf /sources/opencv-4.12.0.tar.gz
cd opencv-*

# Extract contrib modules if available
if [ -f /sources/opencv_contrib-4.12.0.tar.gz ]; then
    log_info "Extracting OpenCV contrib modules..."
    tar -xf /sources/opencv_contrib-4.12.0.tar.gz -C ..
fi

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release \
      -D ENABLE_CXX11=ON \
      -D BUILD_PERF_TESTS=OFF \
      -D BUILD_TESTS=OFF \
      -D BUILD_EXAMPLES=OFF \
      -D BUILD_opencv_java=OFF \
      -D BUILD_opencv_python2=OFF \
      -D BUILD_opencv_python3=OFF \
      -D WITH_FFMPEG=ON \
      -D WITH_GSTREAMER=OFF \
      -D WITH_V4L=ON \
      -D WITH_OPENGL=ON \
      -D WITH_GTK=OFF \
      -D WITH_QT=OFF \
      -D OPENCV_EXTRA_MODULES_PATH=../../opencv_contrib-4.12.0/modules \
      -W no-dev \
      ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf opencv-*
rm -rf opencv_contrib-*
ldconfig

log_info "opencv-4.12.0 installed successfully"
create_checkpoint "opencv"
}

# =====================================================================
# glu-9.0.3 (OpenGL Utility Library - required for 3D graphics)
# https://www.linuxfromscratch.org/blfs/view/stable/x/glu.html
# =====================================================================
build_glu() {
should_skip_package "glu" && { log_info "Skipping glu (already built)"; return 0; }
log_step "Building glu-9.0.3..."

if [ ! -f /sources/glu-9.0.3.tar.xz ]; then
    log_error "glu-9.0.3.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf glu-*
tar -xf /sources/glu-9.0.3.tar.xz
cd glu-*

mkdir build
cd build

meson setup --prefix=/usr --buildtype=release -D gl_provider=gl ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf glu-*
ldconfig

log_info "glu-9.0.3 installed successfully"
create_checkpoint "glu"
}

# =====================================================================
# CrackLib-2.10.3 (Password Strength Checking Library)
# https://www.linuxfromscratch.org/blfs/view/stable/postlfs/cracklib.html
# Required by: libpwquality
# =====================================================================
build_cracklib() {
should_skip_package "cracklib" && { log_info "Skipping CrackLib (already built)"; return 0; }
log_step "Building CrackLib-2.10.3..."

if [ ! -f /sources/cracklib-2.10.3.tar.xz ]; then
    log_error "cracklib-2.10.3.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf cracklib-*
tar -xf /sources/cracklib-2.10.3.tar.xz
cd cracklib-*

# Build with Python bindings disabled (not needed for libpwquality)
autoreconf -fiv

PYTHON=python3 ./configure --prefix=/usr \
            --disable-static \
            --with-default-dict=/usr/lib/cracklib/pw_dict

make $MAKEFLAGS
make install

# Install the recommended cracklib dictionary
install -v -m644 -D dicts/cracklib-small \
    /usr/share/dict/cracklib-small
ln -sfv cracklib-small /usr/share/dict/words

# Create the word list and dictionary
install -v -m755 -d /usr/lib/cracklib
create-cracklib-dict /usr/share/dict/cracklib-small

cd "$BUILD_DIR"
rm -rf cracklib-*
ldconfig

log_info "CrackLib-2.10.3 installed successfully"
create_checkpoint "cracklib"
}

# =====================================================================
# libpwquality-1.4.5 (Password Quality Checking Library)
# https://www.linuxfromscratch.org/blfs/view/stable/postlfs/libpwquality.html
# =====================================================================
build_libpwquality() {
should_skip_package "libpwquality" && { log_info "Skipping libpwquality (already built)"; return 0; }
log_step "Building libpwquality-1.4.5..."

if [ ! -f /sources/libpwquality-1.4.5.tar.bz2 ]; then
    log_error "libpwquality-1.4.5.tar.bz2 not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libpwquality-*
tar -xf /sources/libpwquality-1.4.5.tar.bz2
cd libpwquality-*

./configure --prefix=/usr \
            --disable-static \
            --with-securedir=/usr/lib/security \
            --with-python-binary=python3

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf libpwquality-*
ldconfig

log_info "libpwquality-1.4.5 installed successfully"
create_checkpoint "libpwquality"
}

# =====================================================================
# libqalculate-5.7.0 (Multi-purpose calculator library - for Plasma)
# https://www.linuxfromscratch.org/blfs/view/stable/general/libqalculate.html
# =====================================================================
build_libqalculate() {
should_skip_package "libqalculate" && { log_info "Skipping libqalculate (already built)"; return 0; }
log_step "Building libqalculate-5.7.0..."

if [ ! -f /sources/libqalculate-5.7.0.tar.gz ]; then
    log_error "libqalculate-5.7.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libqalculate-*
tar -xf /sources/libqalculate-5.7.0.tar.gz
cd libqalculate-*

./configure --prefix=/usr \
            --disable-static

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf libqalculate-*
ldconfig

log_info "libqalculate-5.7.0 installed successfully"
create_checkpoint "libqalculate"
}

# =====================================================================
# taglib-2.1.1 (Audio Meta-Data Library - required by Plasma)
# https://www.linuxfromscratch.org/blfs/view/stable/multimedia/taglib.html
# =====================================================================
build_taglib() {
should_skip_package "taglib" && { log_info "Skipping taglib (already built)"; return 0; }
log_step "Building taglib-2.1.1..."

if [ ! -f /sources/taglib-2.1.1.tar.gz ]; then
    log_error "taglib-2.1.1.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf taglib-*
tar -xf /sources/taglib-2.1.1.tar.gz
cd taglib-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release \
      -D BUILD_SHARED_LIBS=ON \
      -W no-dev \
      ..

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf taglib-*
ldconfig

log_info "taglib-2.1.1 installed successfully"
create_checkpoint "taglib"
}

# =====================================================================
# json-glib-1.10.6 (JSON library for GLib - required by various GNOME apps)
# https://www.linuxfromscratch.org/blfs/view/stable/general/json-glib.html
# =====================================================================
build_json_glib() {
should_skip_package "json-glib" && { log_info "Skipping json-glib (already built)"; return 0; }
log_step "Building json-glib-1.10.6..."

if [ ! -f /sources/json-glib-1.10.6.tar.xz ]; then
    log_error "json-glib-1.10.6.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf json-glib-*
tar -xf /sources/json-glib-1.10.6.tar.xz
cd json-glib-*

mkdir build
cd build

meson setup --prefix=/usr --buildtype=release -D man=false ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf json-glib-*
ldconfig

log_info "json-glib-1.10.6 installed successfully"
create_checkpoint "json-glib"
}

# =====================================================================
# libxmlb-0.3.23 (XMLb library - required by AppStream)
# https://www.linuxfromscratch.org/blfs/view/stable/general/libxmlb.html
# =====================================================================
build_libxmlb() {
should_skip_package "libxmlb" && { log_info "Skipping libxmlb (already built)"; return 0; }
log_step "Building libxmlb-0.3.23..."

if [ ! -f /sources/libxmlb-0.3.23.tar.xz ]; then
    log_error "libxmlb-0.3.23.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libxmlb-*
tar -xf /sources/libxmlb-0.3.23.tar.xz
cd libxmlb-*

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D gtkdoc=false \
            -D stemmer=false \
            -D introspection=true \
            ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf libxmlb-*
ldconfig

log_info "libxmlb-0.3.23 installed successfully"
create_checkpoint "libxmlb"
}

# =====================================================================
# fuse-3.17.4 (Filesystem in Userspace - required by various apps)
# https://www.linuxfromscratch.org/blfs/view/stable/postlfs/fuse3.html
# =====================================================================
build_fuse3() {
should_skip_package "fuse3" && { log_info "Skipping fuse3 (already built)"; return 0; }
log_step "Building fuse-3.17.4..."

if [ ! -f /sources/fuse-3.17.4.tar.gz ]; then
    log_error "fuse-3.17.4.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf fuse-*
tar -xf /sources/fuse-3.17.4.tar.gz
cd fuse-*

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D examples=false \
            ..
ninja
ninja install

# Install udev rules
install -v -m644 ../util/udev.rules /etc/udev/rules.d/99-fuse.rules || true

cd "$BUILD_DIR"
rm -rf fuse-*
ldconfig

log_info "fuse-3.17.4 installed successfully"
create_checkpoint "fuse3"
}

# =====================================================================
# power-profiles-daemon-0.30 (Power profiles management)
# https://www.linuxfromscratch.org/blfs/view/stable/general/power-profiles-daemon.html
# =====================================================================
build_power_profiles_daemon() {
should_skip_package "power-profiles-daemon" && { log_info "Skipping power-profiles-daemon (already built)"; return 0; }
log_step "Building power-profiles-daemon-0.30..."

if [ ! -f /sources/power-profiles-daemon-0.30.tar.gz ]; then
    log_error "power-profiles-daemon-0.30.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf power-profiles-daemon-*
tar -xf /sources/power-profiles-daemon-0.30.tar.gz
cd power-profiles-daemon-*

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D gtk_doc=false \
            -D tests=false \
            ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf power-profiles-daemon-*
ldconfig

log_info "power-profiles-daemon-0.30 installed successfully"
create_checkpoint "power-profiles-daemon"
}

# =====================================================================
# accountsaervice-23.13.9 (D-Bus interface for user account management)
# https://www.linuxfromscratch.org/blfs/view/stable/general/accountsservice.html
# =====================================================================
build_accountsservice() {
should_skip_package "accountsservice" && { log_info "Skipping accountsservice (already built)"; return 0; }
log_step "Building accountsservice-23.13.9..."

if [ ! -f /sources/accountsservice-23.13.9.tar.xz ]; then
    log_error "accountsservice-23.13.9.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf accountsservice-* accountsservice-*
tar -xf /sources/accountsservice-23.13.9.tar.xz
cd accountsservice-* || cd accountsservice-*

# BLFS: Rename dbusmock directory to prevent build failure when dbusmock is not installed
mv tests/dbusmock{,-tests}

# BLFS: Fix test script for the renamed directory and Python 3.12+
sed -e '/accounts_service\.py/s/dbusmock/dbusmock-tests/' \
    -e 's/assertEquals/assertEqual/'                      \
    -i tests/test-libaccountsservice.py

# BLFS: Fix test that fails without en_IE.UTF-8 locale
sed -i '/^SIMULATED_SYSTEM_LOCALE/s/en_IE.UTF-8/en_HK.iso88591/' tests/test-daemon.py

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D admin_group=wheel \
            -D docbook=false \
            -D gtk_doc=false \
            ..

# BLFS: Fix mocklibc for GCC 14+
grep 'print_indent'     ../subprojects/mocklibc-1.0/src/netgroup.c \
     | sed 's/ {/;/' >> ../subprojects/mocklibc-1.0/src/netgroup.h &&
sed -i '1i#include <stdio.h>'                                      \
    ../subprojects/mocklibc-1.0/src/netgroup.h

ninja
ninja install

cd "$BUILD_DIR"
rm -rf accountsservice-* AccountsService-*
ldconfig

log_info "AccountsService-23.13.9 installed successfully"
create_checkpoint "accountsservice"
}

# =====================================================================
# smartmontools-7.5 (S.M.A.R.T. disk monitoring tools)
# https://www.linuxfromscratch.org/blfs/view/stable/general/smartmontools.html
# =====================================================================
build_smartmontools() {
should_skip_package "smartmontools" && { log_info "Skipping smartmontools (already built)"; return 0; }
log_step "Building smartmontools-7.5..."

if [ ! -f /sources/smartmontools-7.5.tar.gz ]; then
    log_error "smartmontools-7.5.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf smartmontools-*
tar -xf /sources/smartmontools-7.5.tar.gz
cd smartmontools-*

./configure --prefix=/usr \
            --sysconfdir=/etc \
            --with-systemdsystemunitdir=/usr/lib/systemd/system

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf smartmontools-*

log_info "smartmontools-7.5 installed successfully"
create_checkpoint "smartmontools"
}

# =====================================================================
# Bubblewrap-0.11.0 (Sandboxing tool for unprivileged containers)
# https://www.linuxfromscratch.org/blfs/view/stable/general/bubblewrap.html
# Required by: xdg-desktop-portal (recommended for security)
# =====================================================================
build_bubblewrap() {
should_skip_package "bubblewrap" && { log_info "Skipping bubblewrap (already built)"; return 0; }
log_step "Building Bubblewrap-0.11.0..."

if [ ! -f /sources/bubblewrap-0.11.0.tar.xz ]; then
    log_error "bubblewrap-0.11.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf bubblewrap-*
tar -xf /sources/bubblewrap-0.11.0.tar.xz
cd bubblewrap-*

mkdir build
cd build

meson setup --prefix=/usr --buildtype=release ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf bubblewrap-*
ldconfig

log_info "Bubblewrap-0.11.0 installed successfully"
create_checkpoint "bubblewrap"
}

# =====================================================================
# xdg-desktop-portal-1.20.3 (Portal frontend service - desktop integration)
# https://www.linuxfromscratch.org/blfs/view/stable/general/xdg-desktop-portal.html
# =====================================================================
build_xdg_desktop_portal() {
should_skip_package "xdg-desktop-portal" && { log_info "Skipping xdg-desktop-portal (already built)"; return 0; }
log_step "Building xdg-desktop-portal-1.20.3..."

if [ ! -f /sources/xdg-desktop-portal-1.20.3.tar.xz ]; then
    log_error "xdg-desktop-portal-1.20.3.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf xdg-desktop-portal-*
tar -xf /sources/xdg-desktop-portal-1.20.3.tar.xz
cd xdg-desktop-portal-*

mkdir build
cd build

# BLFS: Use -D tests=disabled to avoid requiring optional test dependencies
meson setup --prefix=/usr \
            --buildtype=release \
            -D tests=disabled \
            ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf xdg-desktop-portal-*
ldconfig

log_info "xdg-desktop-portal-1.20.3 installed successfully"
create_checkpoint "xdg-desktop-portal"
}

# =====================================================================
# AppStream-1.0.6 (Software component metadata)
# https://www.linuxfromscratch.org/blfs/view/stable/general/appstream.html
# =====================================================================
build_appstream() {
should_skip_package "appstream" && { log_info "Skipping appstream (already built)"; return 0; }
log_step "Building AppStream-1.0.6..."

if [ ! -f /sources/AppStream-1.0.6.tar.xz ]; then
    log_error "AppStream-1.0.6.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf AppStream-*
tar -xf /sources/AppStream-1.0.6.tar.xz
cd AppStream-*

mkdir build
cd build

meson setup --prefix=/usr \
            --buildtype=release \
            -D apidocs=false \
            -D stemming=false \
            ..
ninja
ninja install

cd "$BUILD_DIR"
rm -rf AppStream-*
ldconfig

log_info "AppStream-1.0.6 installed successfully"
create_checkpoint "appstream"
}

# =====================================================================
# xdotool-3.20211022.1 (X11 automation tool - optional for Plasma)
# =====================================================================
build_xdotool() {
should_skip_package "xdotool" && { log_info "Skipping xdotool (already built)"; return 0; }
log_step "Building xdotool-3.20211022.1..."

if [ ! -f /sources/xdotool-3.20211022.1.tar.gz ]; then
    log_error "xdotool-3.20211022.1.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf xdotool-*
tar -xf /sources/xdotool-3.20211022.1.tar.gz
cd xdotool-*

# BLFS instructions
make WITHOUT_RPATH_FIX=1
make PREFIX=/usr INSTALLMAN=/usr/share/man install

cd "$BUILD_DIR"
rm -rf xdotool-*
ldconfig

log_info "xdotool-3.20211022.1 installed successfully"
create_checkpoint "xdotool"
}

# =====================================================================
# libnotify-0.8.6 (Desktop notification library)
# https://www.linuxfromscratch.org/blfs/view/12.4/x/libnotify.html
# Required by: ibus (recommended)
# =====================================================================
build_libnotify() {
should_skip_package "libnotify" && { log_info "Skipping libnotify (already built)"; return 0; }
log_step "Building libnotify-0.8.6..."

if [ ! -f /sources/libnotify-0.8.6.tar.xz ]; then
    log_error "libnotify-0.8.6.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf libnotify-*
tar -xf /sources/libnotify-0.8.6.tar.xz
cd libnotify-*

mkdir build && cd build

meson setup --prefix=/usr       \
            --buildtype=release \
            -D gtk_doc=false    \
            -D man=false        \
            ..

ninja
ninja install

cd "$BUILD_DIR"
rm -rf libnotify-*

log_info "libnotify-0.8.6 installed successfully"
create_checkpoint "libnotify"
}

# =====================================================================
# dconf-0.40.0 (Low-level configuration system)
# https://www.linuxfromscratch.org/blfs/view/12.4/gnome/dconf.html
# Required by: ibus
# =====================================================================
build_dconf() {
should_skip_package "dconf" && { log_info "Skipping dconf (already built)"; return 0; }
log_step "Building dconf-0.40.0..."

if [ ! -f /sources/dconf-0.40.0.tar.xz ]; then
    log_error "dconf-0.40.0.tar.xz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf dconf-*
tar -xf /sources/dconf-0.40.0.tar.xz
cd dconf-*

mkdir build && cd build

meson setup --prefix=/usr            \
            --buildtype=release      \
            -D bash_completion=false \
            ..

ninja
ninja install

cd "$BUILD_DIR"
rm -rf dconf-*

log_info "dconf-0.40.0 installed successfully"
create_checkpoint "dconf"
}

# =====================================================================
# ibus-1.5.32 (Intelligent Input Bus - input method framework)
# https://www.linuxfromscratch.org/blfs/view/stable/general/ibus.html
# =====================================================================
build_ibus() {
should_skip_package "ibus" && { log_info "Skipping ibus (already built)"; return 0; }
log_step "Building ibus-1.5.32..."

if [ ! -f /sources/ibus-1.5.32.tar.gz ]; then
    log_error "ibus-1.5.32.tar.gz not found in /sources"
    exit 1
fi

# Install Unicode Character Database (required by ibus)
if [ -f /sources/UCD.zip ]; then
    mkdir -p /usr/share/unicode/ucd
    7z x /sources/UCD.zip -o/usr/share/unicode/ucd -y
fi

cd "$BUILD_DIR"
rm -rf ibus-*
tar -xf /sources/ibus-1.5.32.tar.gz
cd ibus-*

# Fix issue with deprecated schema entries
sed -e 's@/desktop/ibus@/org/freedesktop/ibus@g' \
    -i data/dconf/org.freedesktop.ibus.gschema.xml

# Remove gtk-doc references if not installed
if ! [ -e /usr/bin/gtkdocize ]; then
    sed '/docs/d;/GTK_DOC/d' -i Makefile.am configure.ac
fi

# Run autogen.sh per BLFS
SAVE_DIST_FILES=1 NOCONFIGURE=1 ./autogen.sh

PYTHON=python3                     \
./configure --prefix=/usr          \
            --sysconfdir=/etc      \
            --disable-python2      \
            --disable-appindicator \
            --disable-gtk2         \
            --disable-emoji-dict

make $MAKEFLAGS
make install

# Update GTK+ immodules cache if gtk3 is installed
if [ -x /usr/bin/gtk-query-immodules-3.0 ]; then
    gtk-query-immodules-3.0 --update-cache
fi

cd "$BUILD_DIR"
rm -rf ibus-*
ldconfig

log_info "ibus-1.5.32 installed successfully"
create_checkpoint "ibus"
}

# =====================================================================
# socat-1.8.0.0 (Multipurpose relay - bidirectional data transfer)
# https://www.linuxfromscratch.org/blfs/view/stable/general/socat.html
# =====================================================================
build_socat() {
should_skip_package "socat" && { log_info "Skipping socat (already built)"; return 0; }
log_step "Building socat-1.8.0.0..."

if [ ! -f /sources/socat-1.8.0.0.tar.gz ]; then
    log_error "socat-1.8.0.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf socat-*
tar -xf /sources/socat-1.8.0.0.tar.gz
cd socat-*

./configure --prefix=/usr

make $MAKEFLAGS
make install

cd "$BUILD_DIR"
rm -rf socat-*

log_info "socat-1.8.0.0 installed successfully"
create_checkpoint "socat"
}

# =====================================================================
# pygdbmi-0.11.0.0 (Python GDB Machine Interface - for debugging)
# =====================================================================
build_pygdbmi() {
should_skip_package "pygdbmi" && { log_info "Skipping pygdbmi (already built)"; return 0; }
log_step "Building pygdbmi-0.11.0.0..."

if [ ! -f /sources/pygdbmi-0.11.0.0.tar.gz ]; then
    log_error "pygdbmi-0.11.0.0.tar.gz not found in /sources"
    exit 1
fi

cd "$BUILD_DIR"
rm -rf pygdbmi-*
tar -xf /sources/pygdbmi-0.11.0.0.tar.gz
cd pygdbmi-*

pip3 install --no-build-isolation --prefix=/usr .

cd "$BUILD_DIR"
rm -rf pygdbmi-*

log_info "pygdbmi-0.11.0.0 installed successfully"
create_checkpoint "pygdbmi"
}


# =====================================================================
# SDDM - Simple Desktop Display Manager (TIER 12)
# =====================================================================

# sddm-0.21.0 (Display Manager for KDE Plasma)
# https://www.linuxfromscratch.org/blfs/view/svn/x/sddm.html

build_sddm() {
should_skip_package "sddm" && { log_info "Skipping sddm (already built)"; return 0; }
log_step "Building sddm-0.21.0..."

if [ ! -f /sources/sddm-0.21.0.tar.gz ]; then
    log_error "sddm-0.21.0.tar.gz not found in /sources"
    exit 1
fi

# Create sddm user and group
if ! getent group sddm > /dev/null 2>&1; then
    groupadd -g 64 sddm
fi

if ! getent passwd sddm > /dev/null 2>&1; then
    useradd -c "SDDM Daemon" \
            -d /var/lib/sddm \
            -u 64 \
            -g sddm \
            -s /bin/false \
            sddm
fi

cd "$BUILD_DIR"
rm -rf sddm-*
tar -xf /sources/sddm-0.21.0.tar.gz
cd sddm-*

mkdir build
cd build

cmake -D CMAKE_INSTALL_PREFIX=/usr \
      -D CMAKE_BUILD_TYPE=Release \
      -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
      -D BUILD_WITH_QT6=ON \
      -D ENABLE_JOURNALD=ON \
      -D BUILD_MAN_PAGES=OFF \
      -D DATA_INSTALL_DIR=/usr/share/sddm \
      -D DBUS_CONFIG_FILENAME=sddm_org.freedesktop.DisplayManager.conf \
      -W no-dev \
      ..

make $MAKEFLAGS
make install

# Install PAM configuration
cat > /etc/pam.d/sddm << "EOF"
# Begin /etc/pam.d/sddm

auth     requisite      pam_nologin.so
auth     required       pam_env.so

auth     required       pam_succeed_if.so uid >= 1000 quiet
auth     include        system-auth

account  include        system-account
password include        system-password

session  required       pam_limits.so
session  include        system-session

# End /etc/pam.d/sddm
EOF

cat > /etc/pam.d/sddm-autologin << "EOF"
# Begin /etc/pam.d/sddm-autologin

auth     requisite      pam_nologin.so
auth     required       pam_env.so

auth     required       pam_succeed_if.so uid >= 1000 quiet
auth     required       pam_permit.so

account  include        system-account

password required       pam_deny.so

session  required       pam_limits.so
session  include        system-session

# End /etc/pam.d/sddm-autologin
EOF

cat > /etc/pam.d/sddm-greeter << "EOF"
# Begin /etc/pam.d/sddm-greeter

auth     required       pam_env.so
auth     required       pam_permit.so

account  required       pam_permit.so
password required       pam_deny.so

session  required       pam_unix.so
-session optional       pam_systemd.so

# End /etc/pam.d/sddm-greeter
EOF

# Create sddm configuration directory
install -v -dm755 /etc/sddm.conf.d

# Set default session to plasma
cat > /etc/sddm.conf.d/kde_settings.conf << "EOF"
[Autologin]
Relogin=false
Session=
User=

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=breeze
CursorTheme=breeze_cursors

[Users]
MaximumUid=60513
MinimumUid=1000
EOF

# Create state directory
install -v -dm755 -o sddm -g sddm /var/lib/sddm

# Enable sddm systemd service
systemctl enable sddm.service || true

# Set graphical.target as the default so SDDM starts on boot
systemctl set-default graphical.target || true

# Set system default locale (locale data created in Glibc build)
cat > /etc/locale.conf << "EOF"
LANG=en_US.UTF-8
EOF

cd "$BUILD_DIR"
rm -rf sddm-*
ldconfig

log_info "sddm-0.21.0 installed successfully"
create_checkpoint "sddm"
}
# =====================================================================
# KDE Plasma 6.4.4 - Generic build function
# =====================================================================

# Generic Plasma build function - handles standard CMake-based Plasma packages
build_plasma_package() {
    local pkg_name="$1"
    local pkg_version="${2:-6.4.4}"
    local extra_cmake_args="${3:-}"

    local checkpoint_name="plasma-${pkg_name}"

    should_skip_package "$checkpoint_name" && { log_info "Skipping ${pkg_name} (already built)"; return 0; }
    log_step "Building ${pkg_name}-${pkg_version}..."

    local tarball="/sources/${pkg_name}-${pkg_version}.tar.xz"
    if [ ! -f "$tarball" ]; then
        log_error "${pkg_name}-${pkg_version}.tar.xz not found in /sources"
        exit 1
    fi

    cd "$BUILD_DIR"
    rm -rf ${pkg_name}-*
    tar -xf "$tarball"
    cd ${pkg_name}-*

    mkdir build
    cd build

    cmake -D CMAKE_INSTALL_PREFIX=/usr \
          -D CMAKE_INSTALL_LIBEXECDIR=libexec \
          -D CMAKE_PREFIX_PATH="/usr;/opt/qt6" \
          -D CMAKE_SKIP_INSTALL_RPATH=ON \
          -D CMAKE_BUILD_TYPE=Release \
          -D BUILD_QT5=OFF \
          -D BUILD_TESTING=OFF \
          -W no-dev \
          $extra_cmake_args ..

    make $MAKEFLAGS
    make install

    cd "$BUILD_DIR"
    rm -rf ${pkg_name}-*
    ldconfig

    log_info "${pkg_name}-${pkg_version} installed successfully"
    create_checkpoint "$checkpoint_name"
}

# Execute Tier 10 builds
# NOTE: duktape and libproxy are already built in Tier 2, so we skip them here

log_info "Phase 1: Support Libraries (kdsoap only - duktape/libproxy already in Tier 2)"
build_kdsoap
build_kdsoap_ws_discovery_client

log_info "Phase 2: Icon Themes"
build_oxygen_icons

log_info "Phase 3: KDE Addons and Activities"
build_kirigami_addons
build_plasma_activities
build_plasma_activities_stats

log_info "Phase 4: KIO Extensions"
build_kio_extras

log_info "Phase 5: Hardware Monitoring"
build_lm_sensors

log_info "Phase 6: Sass CSS Compiler"
build_libsass
build_sassc

log_info "Phase 7: Hardware Identification Database"
build_hwdata

log_info "Phase 8: Display Information Library"
build_libdisplay_info

log_info "Phase 9: Additional Plasma Dependencies"
build_glu
build_cracklib
build_libpwquality
build_libqalculate
build_taglib
build_json_glib
build_libxmlb
build_fuse3
build_power_profiles_daemon
build_accountsservice
build_smartmontools
build_bubblewrap
build_xdg_desktop_portal
build_appstream
build_xdotool
build_libnotify
build_dconf
build_ibus
build_socat
build_pygdbmi

log_info ""
log_info "=========================================="
log_info "Tier 10: Plasma Prerequisites Complete!"
log_info "=========================================="
log_info "  (duktape and libproxy built in Tier 2)"
log_info "  - kdsoap-2.2.0: Qt SOAP library"
log_info "  - kdsoap-ws-discovery-client-0.4.0: WS-Discovery"
log_info "  - oxygen-icons-6.0.0: Alternative icon theme"
log_info "  - kirigami-addons-1.9.0: Kirigami UI addons"
log_info "  - plasma-activities-6.4.4: KDE Activities"
log_info "  - plasma-activities-stats-6.4.4: Activity statistics"
log_info "  - kio-extras-25.08.0: Extra KIO protocols"
log_info "  - lm-sensors-3.6.2: Hardware monitoring"
log_info "  - libsass-3.6.6: Sass CSS compiler library"
log_info "  - sassc-3.6.2: Sass CSS compiler"
log_info "  - hwdata-0.398: Hardware identification database"
log_info "  - libdisplay-info-0.3.0: EDID/DisplayID library"
log_info "  - glu-9.0.3: OpenGL Utility Library"
log_info "  - libpwquality-1.4.5: Password quality checking"
log_info "  - libqalculate-5.7.0: Calculator library"
log_info "  - taglib-2.1.1: Audio meta-data library"
log_info "  - json-glib-1.10.6: JSON library for GLib"
log_info "  - libxmlb-0.3.23: XML binary library"
log_info "  - fuse-3.17.4: Filesystem in userspace"
log_info "  - power-profiles-daemon-0.30: Power management"
log_info "  - accountsservice-23.13.9: User account management"
log_info "  - smartmontools-7.5: Disk monitoring"
log_info "  - xdg-desktop-portal-1.20.3: Desktop integration"
log_info "  - appstream-1.0.6: Software metadata"
log_info "  - xdotool-3.20211022.1: X11 automation"
log_info "  - ibus-1.5.32: Input method framework"
log_info "  - socat-1.8.0.0: Data relay tool"
log_info "  - pygdbmi-0.11.0.0: Python GDB interface"
log_info ""

# =====================================================================
# Tier 11: KDE Plasma 6.4.4 (56 packages)
# https://www.linuxfromscratch.org/blfs/view/12.4/kde/plasma-all.html
# =====================================================================

log_info ""
log_info "#####################################################################"
log_info "# TIER 11: KDE Plasma 6.4.4"
log_info "#####################################################################"
log_info ""

# Phase 1: Core Libraries
log_info "Phase 1: Plasma Core Libraries"
build_plasma_package "kdecoration"
build_plasma_package "libkscreen"
build_plasma_package "libksysguard"
build_plasma_package "breeze"
build_plasma_package "breeze-gtk"
build_plasma_package "layer-shell-qt"
build_plasma_package "libplasma"

log_info "Plasma Phase 1 complete (Core Libraries)"

# Phase 2: System Services
log_info "Phase 2: System Services"
build_plasma_package "kscreenlocker"
build_plasma_package "kinfocenter"
build_plasma_package "kglobalacceld"
build_plasma_package "kwayland"
build_plasma_package "aurorae"
build_plasma_package "kwin"
build_plasma_package "plasma5support"

log_info "Plasma Phase 2 complete (System Services)"

# Phase 3: Media and Workspace
log_info "Phase 3: Media and Workspace"
build_plasma_package "kpipewire"
build_plasma_package "plasma-workspace"
build_plasma_package "plasma-disks"
build_plasma_package "bluedevil"
build_plasma_package "kde-gtk-config"
build_plasma_package "kmenuedit"
build_plasma_package "kscreen"
build_plasma_package "kwallet-pam"
build_plasma_package "kwrited"

log_info "Plasma Phase 3 complete (Media and Workspace)"

# Phase 4: Network and Audio
log_info "Phase 4: Network and Audio"
build_plasma_package "milou"
build_plasma_package "plasma-nm"
build_pulseaudio_qt
build_plasma_package "plasma-pa"
build_plasma_package "plasma-workspace-wallpapers"
build_plasma_package "polkit-kde-agent-1"
build_plasma_package "powerdevil"

log_info "Plasma Phase 4 complete (Network and Audio)"

# Phase 5: Desktop
log_info "Phase 5: Desktop"
build_libwacom
build_plasma_package "plasma-desktop"
build_plasma_package "kgamma"
build_plasma_package "ksshaskpass"
build_plasma_package "sddm-kcm"
build_plasma_package "kactivitymanagerd"
build_plasma_package "plasma-integration"
build_plasma_package "xdg-desktop-portal-kde"

log_info "Plasma Phase 5 complete (Desktop)"

# Phase 6: System Tools
log_info "Phase 6: System Tools"
build_plasma_package "drkonqi"
build_plasma_package "plasma-vault"
build_plasma_package "kde-cli-tools"
build_plasma_package "systemsettings"
build_plasma_package "plasma-thunderbolt"
build_plasma_package "plasma-firewall"
build_plasma_package "plasma-systemmonitor"

log_info "Plasma Phase 6 complete (System Tools)"

# Phase 7: Styles and Stats
log_info "Phase 7: Styles and Stats"
build_plasma_package "qqc2-breeze-style"
build_plasma_package "ksystemstats"
build_plasma_package "oxygen-sounds"
build_plasma_package "kdeplasma-addons"
build_plasma_package "plasma-welcome"
build_plasma_package "ocean-sound-theme"

log_info "Plasma Phase 7 complete (Styles and Stats)"

# Phase 8: Applications
log_info "Phase 8: Applications"
build_plasma_package "print-manager"
build_xf86_input_wacom
build_plasma_package "wacomtablet"
build_plasma_package "oxygen"
build_opencv
build_plasma_package "spectacle"

log_info "Plasma Phase 8 complete (Applications)"

log_info ""
log_info "=========================================="
log_info "Tier 11: KDE Plasma 6.4.4 Complete!"
log_info "=========================================="
log_info "  56 Plasma packages built successfully"
log_info "=========================================="


# =====================================================================
# TIER 12: Display Manager (SDDM)
# =====================================================================
log_info ""
log_info "=========================================="
log_info "Tier 12: Display Manager (SDDM)"
log_info "=========================================="

build_sddm

log_info ""
log_info "=========================================="
log_info "Tier 12: SDDM Complete!"
log_info "=========================================="
log_info "  Display manager installed and enabled"
log_info "=========================================="

# =====================================================================
# Summary
# =====================================================================
log_info ""
log_info "=========================================="
log_info "BLFS Build Complete!"
log_info "=========================================="
log_info ""
log_info "Installed packages:"

# List installed BLFS packages
for checkpoint in /.checkpoints/blfs-*.checkpoint; do
    if [ -f "$checkpoint" ]; then
        pkg=$(basename "$checkpoint" .checkpoint | sed 's/^blfs-//')
        log_info "  - $pkg"
    fi
done

log_info ""
log_info "Tier 1 - Security & Core:"
log_info "  - Linux-PAM: Pluggable authentication"
log_info "  - Shadow: Rebuilt with PAM support"
log_info "  - systemd: Rebuilt with PAM support"
log_info "  - libgpg-error, libgcrypt: Cryptography"
log_info "  - sudo, polkit: Privilege management"
log_info "  - pcre2, duktape, glib2: Core libraries"
log_info "  - cmake: Build system"
log_info ""
log_info "Tier 2 - Networking & Protocols:"
log_info "  - libmnl, libnl: Netlink libraries"
log_info "  - libevent, c-ares: Event/DNS libraries"
log_info "  - libtasn1, nettle, p11-kit, GnuTLS: TLS stack"
log_info "  - libunistring, libidn2, libpsl: Unicode/IDN"
log_info "  - iptables: Firewall"
log_info "  - dhcpcd: DHCP client"
log_info "  - wpa_supplicant: WiFi client"
log_info "  - curl, wget: HTTP clients"
log_info "  - libproxy: Proxy configuration"
log_info "  - NetworkManager: Network management"
log_info ""
log_info "Tier 3 - Graphics Foundation (X11/Wayland):"
log_info "  - util-macros, xorgproto: Xorg build infrastructure"
log_info "  - Wayland, Wayland-Protocols: Wayland compositor"
log_info "  - libXau, libXdmcp: X11 auth libraries"
log_info "  - xcb-proto, libxcb: XCB protocol"
log_info "  - Pixman: Pixel manipulation"
log_info "  - libdrm, libxcvt: DRM and CVT libraries"
log_info "  - SPIRV-Headers, SPIRV-Tools: SPIR-V support"
log_info "  - Vulkan-Headers, glslang: Vulkan/GLSL"
log_info "  - Xorg Libraries (32 packages): libX11, libXext, libXt, etc."
log_info "  - Vulkan-Loader: Vulkan ICD loader"
log_info ""
log_info "Tier 7 - Qt6 and Pre-KDE:"
log_info "  - libwebp, pciutils, NSS, SQLite"
log_info "  - libuv, nghttp2, Node.js, CUPS"
log_info "  - Qt-6.9.2: Full Qt6 framework"
log_info "  - extra-cmake-modules, qca, qcoro"
log_info "  - Phonon, VLC, Phonon-backend-vlc"
log_info "  - Polkit-Qt, plasma-wayland-protocols"
log_info "  - QtWebEngine-6.9.2: Web engine"
log_info ""
log_info "Tier 8 - KDE Frameworks 6 Dependencies:"
log_info "  - sound-theme-freedesktop, libcanberra"
log_info "  - libical, lmdb, libqrencode"
log_info "  - Aspell, BlueZ, ModemManager, UPower"
log_info "  - breeze-icons"
log_info ""
log_info "Tier 9 - KDE Frameworks 6.17.0 (69 packages)"
log_info ""
log_info "Tier 10 - Plasma Prerequisites:"
log_info "  - kdsoap, oxygen-icons, kirigami-addons"
log_info "  - plasma-activities, kio-extras"
log_info ""
log_info "Tier 11 - KDE Plasma 6.4.4 (56 packages):"
log_info "  - Desktop shell, window manager, system settings"
log_info "  - Network, Bluetooth, power management"
log_info "  - System monitor, file manager integration"
log_info "=========================================="

exit 0
