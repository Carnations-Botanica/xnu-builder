#!/usr/bin/env bash
builder_version=1.0.3
set -o errexit
set -o nounset
set -o pipefail
if [[ "${TRACE-0}" == "1" ]]; then
    set -o xtrace
fi

# clear

# Builder Variables that can be altered by the builder
: ${KERNEL_CONFIG:=DEVELOPMENT}
: ${ARCH_CONFIG:=X86_64}
: ${MACHINE_CONFIG:=NONE}
: ${MACOS_VERSION:="14.5"}

# Builder Variables that cannot be altered by the builder
WORK_DIR="$PWD"
CACHE_DIR="${WORK_DIR}/.cache"
BUILD_DIR="${WORK_DIR}/build"
FAKEROOT_DIR="${WORK_DIR}/fakeroot"
DSTROOT="${FAKEROOT_DIR}"
HAVE_WE_INSTALLED_HEADERS_YET="${FAKEROOT_DIR}/.xnu_headers_installed"
HEADERS_INSTALLED_STATUS="false"
KERNEL_FRAMEWORK_ROOT='/System/Library/Frameworks/Kernel.framework/Versions/A'
KC_VARIANT="$KERNEL_CONFIG"
KERNEL_TYPE="${KC_VARIANT}.$MACHINE_CONFIG"
TIGHTBEAMC="tightbeamc-not-supported"
xnu_built_version=""
kernel_config_folder=""
kerneltypekc=""
kernel_path=""
BKE=""
SKE=""
boot_volume=""
part_of_whole=""
volume_name=""
main_apfs_volume=""
APFSMountPoint=""

# Function to update the functions above, via command args
update_globals() {
    if [[ "$ACTION" == "build" ]]; then
        case "$ARCH_CONFIG" in
            X86_64)
                MACHINE_CONFIG="NONE"  # Only valid option for X86_64
                ;;
            ARM64)
                # No default machine config, user must specify
                if [ "$MACHINE_CONFIG" == "NONE" ]; then
                    error "Machine configuration is required for ARM64."
                    show_valid_machines
                    exit 1
                fi
                ;;
            *)
                error "Invalid architecture specified. Use X86_64 or ARM64."
                show_help
                exit 1
                ;;
        esac

        if [[ "$ARCH_CONFIG" == "X86_64" && "$MACHINE_CONFIG" != "NONE" ]]; then
            error "Machine configuration is not applicable for X86_64."
            show_help
            exit 1
        fi
    fi
}

# Function to print running status
running() {
    echo -e "\033[38;5;237m==> $1\033[0m"
}

# Function to print success messages
success() {
    echo -e "\033[38;2;192;255;192m[SUCCESS] $1\033[0m"
}

# Function to print error messages
error() {
    echo -e "\033[0;31m[ERROR] $1\033[0m" >&2
}

# Function to print warning messages
warning() {
    echo -e "\033[38;2;255;33;203m[WARNING] $1\033[0m"
}

# Function to print info messages
info() {
    echo -e "\033[38;2;255;233;161m[INFO] $1\033[0m"
}

# Function to update the global variable about header installation status
headers_status() {
    if [ -f "${HAVE_WE_INSTALLED_HEADERS_YET}" ]; then
        HEADERS_INSTALLED_STATUS="true"  # Headers are installed
    else
        HEADERS_INSTALLED_STATUS="false"  # Headers are not installed
    fi
}

# Function to display help message
show_help() {
    echo "Usage:   ./build.sh <action> [options]"
    echo "Example: ./build.sh fetch"
    echo "Example: ./build.sh clean"
    echo "Example: ./build.sh install"
    echo "Example: ./build.sh build -k DEVELOPMENT -a X86_64"
    echo "Example: ./build.sh build -k RELEASE -a ARM64 -m VMAPPLE"
    echo ""
    echo "Actions:"
    echo "  fetch       Fetch the Carnations XNU Source Code"
    echo "  clean       Clean build artifacts"
    echo "  build       Build the source code"
    echo "  install     Install the built Kernel"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -v, --version      Show the version of the script"
    echo "  -k, --kerneltype   Set kernel type (RELEASE / DEVELOPMENT)"
    echo "  -a, --arch         Set architecture (x86_64 / ARM64)"
    echo "  -m, --machine      Set machine configuration (For ARM64 only)"
}

show_valid_machines() {
    echo "Valid Machine configurations are:"
    echo ""
    echo "BCM2837 (Generic ARM Platform)"
    echo "T8101 (Apple A14 Bionic)"
    echo "T8103 (Apple M1)"
    echo "T8112 (Apple M2)"
    echo "T6000 (Apple M1 Pro)"
    echo "T6020 (Apple M2 Pro)"
    echo "VMAPPLE (Apple Virtual Machine)"
    echo ""
    echo "Try again with a valid Machine configuration."
}

# Function to display version message
show_version() {
    echo "Builder Version: $builder_version"
}

# Function to print welcome message
welcome() {
    echo "Welcome to the Carnations XNU Source Builder!"
    echo "You are currently using Builder version: $builder_version"
    echo ""

    echo "Copyright (c) 2024 - BSD 3-Clause License"
    echo "The Carnations Botánica Foundation. All rights reserved."
    echo ""

    echo "Special credits to: blacktop, pwn0rz for the initial iterations!"
    echo "This is a rewrite of both, with core concepts and ideas based off of their"
    echo "work! If you intend to build other XNU source than Carnations based, use"
    echo "the hard work they've put in to get a solid list of versions building!"
    echo ""
}

print_builder_variables() {
    running "Working Directory returned value: $WORK_DIR"
    running "Cache Directory returned value: $CACHE_DIR"
    running "Build Directory returned value: $BUILD_DIR"
    running "Fake Root Directory returned value: $FAKEROOT_DIR"
    running "DST Root Directory returned value: $DSTROOT"
    running "Kernel Variant returned value: $KC_VARIANT"
    running "Architecture Configuration returned value: $ARCH_CONFIG"
    running "Machine Configuration returned value: $MACHINE_CONFIG"
    running "Product Version returned: macOS $MACOS_VERSION"
}

# Function to install dependencies
install_deps() {
    info "Checking if dependencies need to be installed..."

    # Check if Homebrew is installed
    if [ ! -x "$(command -v brew)" ]; then
        error "Homebrew is not installed."
        read -p "Install Homebrew now? (y/n): " -n 1 -r
        echo # move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            running "Installing Homebrew"
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            # Ensure Homebrew is in the PATH
            export PATH="/usr/local/bin:$PATH"
            success "Homebrew installation completed."
        else
            exit 1
        fi
    else
        success "Homebrew is already installed."
    fi

    # Check if required commands are installed
    PACKAGES=(jq gum xcodes cmake ninja)
    MISSING_PACKAGES=()
    for pkg in "${PACKAGES[@]}"; do
        if [ ! -x "$(command -v $pkg)" ]; then
            MISSING_PACKAGES+=($pkg)
        else
            success "$pkg is already installed."
        fi
    done

    if [ ${#MISSING_PACKAGES[@]} -ne 0 ]; then
        running "Installing missing packages: ${MISSING_PACKAGES[*]}"
        brew install "${MISSING_PACKAGES[@]}"
        success "Package installation completed."
    else
        success "All required packages are already installed."
    fi

    # Check if Xcode is installed
    if compgen -G "/Applications/Xcode*.app" >/dev/null; then
        success "Xcode is already installed: $(xcode-select -p)"
    else
        error "Xcode is not installed."
        info "Please download the latest Xcode from https://xcodereleases.com/"
    fi
}

# Function to install the Kernel Dev Kit based on the macOS Version Variable
install_kdk() {
    if [ -z "$MACOS_VERSION" ]; then
        echo "MACOS_VERSION variable does not exist! Something went wrong..."
        exit 1
    fi

    # Define constants for macOS 14.5 as the default
    RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-145/release.json'
    KDK_NAME='Kernel Debug Kit 14.5 build 23F79'
    KDKROOT='/Library/Developer/KDKs/KDK_14.5_23F79.kdk'
    RC_DARWIN_KERNEL_VERSION='23.5.0'

    case ${MACOS_VERSION} in
    '12.5')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-125/release.json'
        KDK_NAME='Kernel Debug Kit 12.5 build 21G72'
        KDKROOT='/Library/Developer/KDKs/KDK_12.5_21G72.kdk'
        RC_DARWIN_KERNEL_VERSION='22.6.0'
        ;;
    '13.0')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-130/release.json'
        KDK_NAME='Kernel Debug Kit 13.0 build 22A380'
        KDKROOT='/Library/Developer/KDKs/KDK_13.0_22A380.kdk'
        RC_DARWIN_KERNEL_VERSION='22.1.0'
        ;;
    '13.1')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-131/release.json'
        KDK_NAME='Kernel Debug Kit 13.1 build 22C65'
        KDKROOT='/Library/Developer/KDKs/KDK_13.1_22C65.kdk'
        RC_DARWIN_KERNEL_VERSION='22.2.0'
        ;;
    '13.2')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-132/release.json'
        KDK_NAME='Kernel Debug Kit 13.2 build 22D49'
        KDKROOT='/Library/Developer/KDKs/KDK_13.2_22D49.kdk'
        RC_DARWIN_KERNEL_VERSION='22.3.0'
        ;;
    '13.3')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-133/release.json'
        KDK_NAME='Kernel Debug Kit 13.3 build 22E252'
        KDKROOT='/Library/Developer/KDKs/KDK_13.3_22E252.kdk'
        RC_DARWIN_KERNEL_VERSION='22.4.0'
        ;;
    '13.4')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-134/release.json'
        KDK_NAME='Kernel Debug Kit 13.4 build 22F66'
        KDKROOT='/Library/Developer/KDKs/KDK_13.4_22F66.kdk'
        RC_DARWIN_KERNEL_VERSION='22.5.0'
        ;;
    '13.5')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-135/release.json'
        KDK_NAME='Kernel Debug Kit 13.5 build 22G74'
        KDKROOT='/Library/Developer/KDKs/KDK_13.5_22G74.kdk'
        RC_DARWIN_KERNEL_VERSION='22.6.0'
        ;;
    '14.0')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-140/release.json'
        KDK_NAME='Kernel Debug Kit 14.0 build 23A344'
        KDKROOT='/Library/Developer/KDKs/KDK_14.0_23A344.kdk'
        RC_DARWIN_KERNEL_VERSION='23.0.0'
        ;;
    '14.1')
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-141/release.json'
        KDK_NAME='Kernel Debug Kit 14.1 build 23B74'
        KDKROOT='/Library/Developer/KDKs/KDK_14.1_23B74.kdk'
        RC_DARWIN_KERNEL_VERSION='23.1.0'
        ;;
    '14.2')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-142/release.json'
        KDK_NAME='Kernel Debug Kit 14.2 build 23C64'
        KDKROOT='/Library/Developer/KDKs/KDK_14.2_23C64.kdk'
        RC_DARWIN_KERNEL_VERSION='23.2.0'
        ;;
    '14.3')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-143/release.json'
        KDK_NAME='Kernel Debug Kit 14.3 build 23D56'
        KDKROOT='/Library/Developer/KDKs/KDK_14.3_23D56.kdk'
        RC_DARWIN_KERNEL_VERSION='23.3.0'
        ;;
    '14.4')
        success "Valid KDK download for $MACOS_VERSION found!"
        RELEASE_URL='https://raw.githubusercontent.com/apple-oss-distributions/distribution-macOS/macos-144/release.json'
        KDK_NAME='Kernel Debug Kit 14.4 build 23E214'
        KDKROOT='/Library/Developer/KDKs/KDK_14.4_23E214.kdk'
        RC_DARWIN_KERNEL_VERSION='23.4.0'
        ;;
    '14.5')
        success "Valid KDK download for $MACOS_VERSION found!"
        ;;
    *)
        error "$MACOS_VERSION does not have an associated KDK to use."
        exit 1
        ;;
    esac
    
    # Print information about the installation
    info "Checking if the Kernel Debug Kit (KDK) is installed for macOS ${MACOS_VERSION}"
    
    # Check if KDK is already installed, if not, install it as its required.
    if [ ! -d "$KDKROOT" ]; then
        KDK_URL=$(curl -s "https://raw.githubusercontent.com/dortania/KdkSupportPkg/gh-pages/manifest.json" | jq -r --arg KDK_NAME "$KDK_NAME" '.[] | select(.name==$KDK_NAME) | .url')
        
        if [ -z "$KDK_URL" ]; then
            error "Failed to find URL for $KDK_NAME"
            exit 1
        fi
        
        running "Downloading '$KDK_NAME' to /tmp"
        curl --progress-bar --max-time 900 --connect-timeout 60 -L -o /tmp/KDK.dmg "${KDK_URL}"
        
        running "Installing KDK"
        hdiutil attach /tmp/KDK.dmg
        
        if [ ! -d "/Library/Developer/KDKs" ]; then
            sudo mkdir -p /Library/Developer/KDKs
            sudo chmod 755 /Library/Developer/KDKs
        fi
        
        sudo installer -pkg '/Volumes/Kernel Debug Kit/KernelDebugKit.pkg' -target /
        hdiutil detach '/Volumes/Kernel Debug Kit'
        ls -lah /Library/Developer/KDKs
    else
        success "Kernel Debug Kit for macOS ${MACOS_VERSION} is already installed."
    fi
}

# Function to git clone the XNU Source from Carnations
get_xnu_source() {
    if [ -d "${WORK_DIR}/xnu" ]; then
        # If the directory already exists, inform the user and exit
        info "XNU Source code directory already exists. No action needed."
    else
        # If the directory does not exist, attempt to clone the repository
        error "XNU Source code directory is missing! Attempting to pull it."
        info "Cloning XNU from Carnations Botanica's GitHub Organization..."
        git clone https://github.com/Carnations-Botanica/xnu.git "${WORK_DIR}/xnu"
        
        # Check if the cloning was successful
        if [ $? -eq 0 ]; then
            info "XNU source code cloned successfully into ${WORK_DIR}/xnu."
        else
            error "Failed to clone XNU source code. Please check the repository URL and your network connection."
            exit 1
        fi
    fi
}

# Function to check and init a venv, or create one if it doesn't exist
init_venv() {
    info "A venv is required to continue, now checking or creating one."
    if [ ! -d "${WORK_DIR}/venv" ]; then
        running "Creating a new virtual environment..."
        python3 -m venv "${WORK_DIR}/venv"
    fi
    success "Activating existing virtual environment!"
    source "${WORK_DIR}/venv/bin/activate"
}

# Function to build bootstrap_cmds dependency
build_bootstrap_cmds() {
    if [ "$(find "${FAKEROOT_DIR}" -name 'mig' | wc -l)" -gt 0 ]; then
        success "bootstrap_cmds have been previously built. No action required."
        return
    fi

    info "Building bootstrap_cmds..."

    if [ ! -d "${WORK_DIR}/bootstrap_cmds" ]; then
        BOOTSTRAP_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="bootstrap_cmds") | .tag')
        git clone --branch "${BOOTSTRAP_VERSION}" https://github.com/apple-oss-distributions/bootstrap_cmds.git "${WORK_DIR}/bootstrap_cmds"
    fi

    SRCROOT="${WORK_DIR}/bootstrap_cmds"
    OBJROOT="${BUILD_DIR}/bootstrap_cmds.obj"
    SYMROOT="${BUILD_DIR}/bootstrap_cmds.sym"

    sed -i '' 's|-o root -g wheel||g' "${WORK_DIR}/bootstrap_cmds/xcodescripts/install-mig.sh"

    CLONED_BOOTSTRAP_VERSION=$(cd "${WORK_DIR}/bootstrap_cmds"; git describe --always 2>/dev/null)

    cd "${SRCROOT}"
    xcodebuild install -sdk macosx -project mig.xcodeproj ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" RC_ProjectNameAndSourceVersion="${CLONED_BOOTSTRAP_VERSION}"
    cd "${WORK_DIR}"
}

# Function to build dtrace dependency
build_dtrace() {
    if [ "$(find "${FAKEROOT_DIR}" -name 'ctfmerge' | wc -l)" -gt 0 ]; then
        success "dtrace has been previously built. No action required."
        return
    fi

    running "Building dtrace..."

    if [ ! -d "${WORK_DIR}/dtrace" ]; then
        DTRACE_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="dtrace") | .tag')
        git clone --branch "${DTRACE_VERSION}" https://github.com/apple-oss-distributions/dtrace.git "${WORK_DIR}/dtrace"
    fi

    SRCROOT="${WORK_DIR}/dtrace"
    OBJROOT="${BUILD_DIR}/dtrace.obj"
    SYMROOT="${BUILD_DIR}/dtrace.sym"

    cd "${SRCROOT}"
    xcodebuild install -sdk macosx -target ctfconvert -target ctfdump -target ctfmerge ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}"
    cd "${WORK_DIR}"
}

# Function to build AvailabilityVersions dependency
build_availabilityversions() {
    if [ "$(find "${FAKEROOT_DIR}" -name 'availability.pl' | wc -l)" -gt 0 ]; then
        success "AvailabilityVersions has been previously built. No action required."
        return
    fi

    running "Building AvailabilityVersions..."

    if [ ! -d "${WORK_DIR}/AvailabilityVersions" ]; then
        AVAILABILITYVERSIONS_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="AvailabilityVersions") | .tag')
        git clone --branch "${AVAILABILITYVERSIONS_VERSION}" https://github.com/apple-oss-distributions/AvailabilityVersions.git "${WORK_DIR}/AvailabilityVersions"
    fi

    SRCROOT="${WORK_DIR}/AvailabilityVersions"
    OBJROOT="${BUILD_DIR}/"
    SYMROOT="${BUILD_DIR}/"

    cd "${SRCROOT}"
    make install -j8 OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}"
    cd "${WORK_DIR}"
}

# Function to install the XNU Headers
install_xnu_headers() {
    if [ ! -f "${HAVE_WE_INSTALLED_HEADERS_YET}" ]; then
        info "Installing XNU Headers..."

        SRCROOT="${WORK_DIR}/xnu"
        OBJROOT="${BUILD_DIR}/xnu-hdrs.obj"
        SYMROOT="${BUILD_DIR}/xnu-hdrs.sym"
        
        cd "${SRCROOT}"
        make installhdrs SDKROOT=macosx ARCH_CONFIGS="X86_64 ARM64" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION}
        cd "${WORK_DIR}"
        
        touch "${HAVE_WE_INSTALLED_HEADERS_YET}"
    else
        success "XNU Headers have already been installed. No action required."
    fi
}

# Function to install libsystem Headers
install_libsystem_headers() {
    if [ ! -d "${FAKEROOT_DIR}/System/Library/Frameworks/System.framework" ]; then
        info "Installing Libsystem Headers..."
        
        if [ ! -d "${WORK_DIR}/Libsystem" ]; then
            LIBSYSTEM_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="Libsystem") | .tag')
            git clone --branch "${LIBSYSTEM_VERSION}" https://github.com/apple-oss-distributions/Libsystem.git "${WORK_DIR}/Libsystem"
        fi
        
        sed -i '' 's|^#include.*BSD.xcconfig.*||g' "${WORK_DIR}/Libsystem/Libsystem.xcconfig"
        
        SRCROOT="${WORK_DIR}/Libsystem"
        OBJROOT="${BUILD_DIR}/Libsystem.obj"
        SYMROOT="${BUILD_DIR}/Libsystem.sym"
        
        cd "${SRCROOT}"
        xcodebuild installhdrs -sdk macosx ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"
    else
        success "Libsystem Headers have already been installed. No action required."
    fi
}

# Function to install libsyscall Headers
install_libsyscall_headers() {
    if [ ! -f "${FAKEROOT_DIR}/usr/include/os/proc.h" ]; then
        info "Installing libsyscall Headers..."
        
        SRCROOT="${WORK_DIR}/xnu/libsyscall"
        OBJROOT="${BUILD_DIR}/libsyscall.obj"
        SYMROOT="${BUILD_DIR}/libsyscall.sym"
        
        cd "${SRCROOT}"
        xcodebuild installhdrs -sdk macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" ARCHS="arm64 arm64e" VALID_ARCHS="arm64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"
    else
        success "Libsyscall Headers have already been installed. No action required."
    fi
}

# Function to build and install libplatform
build_libplatform() {
    if [ ! -f "${FAKEROOT_DIR}/usr/local/include/_simple.h" ]; then
        info "Building libplatform..."
        
        if [ ! -d "${WORK_DIR}/libplatform" ]; then
            LIBPLATFORM_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="libplatform") | .tag')
            git clone --branch "${LIBPLATFORM_VERSION}" https://github.com/apple-oss-distributions/libplatform.git "${WORK_DIR}/libplatform"
        fi
        
        SRCROOT="${WORK_DIR}/libplatform"
        
        cd "${SRCROOT}"
        ditto "${SRCROOT}/include" "${DSTROOT}/usr/local/include"
        ditto "${SRCROOT}/private" "${DSTROOT}/usr/local/include"
        cd "${WORK_DIR}"
    else
        success "libplatform has already been built. No action required."
    fi
}

# Function to build and install libdispatch
build_libdispatch() {
    if [ ! -f "${FAKEROOT_DIR}/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
        info "Building libdispatch..."

        if [ ! -d "${WORK_DIR}/libdispatch" ]; then
            LIBDISPATCH_VERSION=$(curl -s $RELEASE_URL | jq -r '.projects[] | select(.project=="libdispatch") | .tag')
            git clone --branch "${LIBDISPATCH_VERSION}" https://github.com/apple-oss-distributions/libdispatch.git "${WORK_DIR}/libdispatch"
        fi
        
        SRCROOT="${WORK_DIR}/libdispatch"
        OBJROOT="${BUILD_DIR}/libfirehose_kernel.obj"
        SYMROOT="${BUILD_DIR}/libfirehose_kernel.sym"
        
        # libfirehose_kernel patch
        sed -i '' 's|$(SDKROOT)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|$(FAKEROOT_DIR)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|g' "${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig"
        sed -i '' 's|$(SDKROOT)/usr/local/include|$(FAKEROOT_DIR)/usr/local/include|g' "${SRCROOT}/xcodeconfig/libfirehose_kernel.xcconfig"
        
        cd "${SRCROOT}"
        xcodebuild install -target libfirehose_kernel -sdk macosx ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}"
        cd "${WORK_DIR}"
        
        mv "${FAKEROOT_DIR}/usr/local/lib/kernel/liblibfirehose_kernel.a" "${FAKEROOT_DIR}/usr/local/lib/kernel/libfirehose_kernel.a"
    else
        success "libdispatch has already been built. No action required."
    fi
}

# Main function to build XNU source
build_xnu() {
    if [ ! -f "${BUILD_DIR}/xnu-10063.121.3~5/kernel.${KERNEL_TYPE}" ]; then
        info "Building XNU kernel..."
        
        SRCROOT="${WORK_DIR}/xnu"
        OBJROOT="${BUILD_DIR}/xnu-10063.121.3~5"
        SYMROOT="${BUILD_DIR}/xnu.sym"
        
        cd "${SRCROOT}"
        make install -j12 VERBOSE=YES SDKROOT=macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" CONCISE=0 LOGCOLORS=y BUILD_WERROR=0 BUILD_LTO=0 SRCROOT="${SRCROOT}" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION}
        cd "${WORK_DIR}"
    else
        info "XNU kernel.${KERNEL_TYPE} has already been built. No action required."
    fi
}

# Function to check for folder existence and create it if it doesn't exist
check_and_create_folder() {
    local folder_path=$1
    if [[ ! -d "$folder_path" ]]; then
        mkdir -p "$folder_path"
        success "Folder created: $folder_path"
    else
        error "Folder already exists: $folder_path"
    fi
}

# Function to check for folder existence and delete it if it exists
check_and_delete_folder() {
    local folder_path=$1
    if [[ -d "$folder_path" ]]; then
        rm -rf "$folder_path"
       success "Folder deleted: $folder_path"
    else
        error "Folder does not exist: $folder_path"
    fi
}

# Function to detect Build Artifacts
build_checker() {
    # Scan the BUILD_DIR for directories starting with "xnu-" followed by numbers
    for dir in "${BUILD_DIR}"/xnu-*; do
        if [[ -d "$dir" && "$dir" =~ xnu-[0-9]+ ]]; then
            # Extract the version from the directory name
            xnu_built_version="${dir##*/}"
            success "Detected XNU Build Version: ${xnu_built_version}"
            break
        fi
    done

    # Print message if no xnu build is found
    if [ -z "$xnu_built_version" ]; then
        error "No compiled XNU build detected in ${BUILD_DIR}"
        return 1
    fi

    # Check for folder starting with KERNEL_CONFIG (DEVELOPMENT or RELEASE)
    for config_dir in "${BUILD_DIR}/${xnu_built_version}/${KERNEL_CONFIG}"*; do
        if [[ -d "$config_dir" ]]; then
            kernel_config_folder="$config_dir"
            success "Detected Kernel Folder: ${kernel_config_folder}"
            break
        fi
    done

    # Print message if no kernel config folder is found
    if [ -z "$kernel_config_folder" ]; then
        error "No ${KERNEL_CONFIG} folder detected in ${BUILD_DIR}/${xnu_built_version}"
        return 1
    fi
}

# Function to build Kernel Caches
kc_build() {
    kerneltypekc=$(echo "$KERNEL_CONFIG" | tr '[:upper:]' '[:lower:]')
    
    if [ "$MACHINE_CONFIG" != "NONE" ]; then
        machconfkc=$(echo "$MACHINE_CONFIG" | tr '[:upper:]' '[:lower:]')
        kernel_path="$kernel_config_folder/kernel.$kerneltypekc.$machconfkc"
    else
        kernel_path="$kernel_config_folder/kernel.$kerneltypekc"
    fi

    # Test if the kernel file exists
    if [ -f "$kernel_path" ]; then
        success "Kernel file found: $kernel_path"

        BKE="$kernel_config_folder/BootKernelExtensions.kc"
        SKE="$kernel_config_folder/SystemKernelExtensions.kc"

        # Create Kernel Cache using kmutil
        running "Creating Kernel Cache files with kmutil..."

        # Print Variables for Debugging
        info "Boot KernelExtensions returned path: $BKE"
        info "System KernelExtensions returned path: $SKE"
        
        if [ "$MACHINE_CONFIG" != "NONE" ]; then
            error "kmutil for ARM64 has not been configured yet."
            return 1
        else
            kmutil create -a x86_64 -Z -n boot sys \
            -B "$BKE" \
            -S "$SKE" \
            -k "$kernel_path" \
            --variant-suffix "$kerneltypekc" \
            --elide-identifier com.apple.driver.AppleIntelTGLGraphicsFramebuffer \
            --elide-identifier com.apple.driver.ExclaveSEPManagerProxy \
            --elide-identifier com.apple.driver.EXDisplayPipe \
            --elide-identifier com.apple.ExclaveKextClient \
            --elide-identifier com.apple.EXBrightKext

            # Update Variables
            BKE="$kernel_config_folder/BootKernelExtensions.kc.$kerneltypekc"
            SKE="$kernel_config_folder/SystemKernelExtensions.kc.$kerneltypekc"
        fi
    else
        error "Kernel file does not exist: $kernel_path"
    fi

    # Check the result of kmutil command
    if [[ $? -eq 0 ]]; then
        success "kmutil successfully built the kernel cache."
    else
        echo "Failed to execute kmutil command."
        exit 1
    fi
}

find_mount_rw_bootdisk() {
    info "Getting Root APFS Volume this system is currently booted from..."

    # Get the identifier of the boot volume
    boot_volume=$(diskutil info / | grep 'Device Identifier' | awk '{print $3}')
    running "Boot Volume Device Identifier: $boot_volume"

    # Get the part of whole disk number
    part_of_whole=$(diskutil info "$boot_volume" | grep 'Part of Whole' | awk '{print $4}')
    running "Part of Whole Disk: $part_of_whole"

    # Get the volume name and trim spaces
    volume_name=$(diskutil info "$boot_volume" | grep 'Volume Name' | awk -F': ' '{print $2}' | xargs)
    running "Volume Name: $volume_name"

    # List all partitions on the whole disk and identify the main APFS volume
    main_apfs_volume=""
    running "Partitions on $part_of_whole:"
    while read -r line; do
        running "$line"
        if [[ "$line" == *"$volume_name"* ]]; then
            main_apfs_volume=$(echo "$line" | awk '{print $NF}')
        fi
    done < <(diskutil list "$part_of_whole")

    success "Root APFS Volume: $main_apfs_volume"

    # Define the folder path relative to the working directory
    APFSMountPoint="$WORK_DIR/APFSMountPoint"
    success "APFSMountPoint returned path: $APFSMountPoint"

    # Check and create the folder if missing
    check_and_create_folder "$APFSMountPoint"

    # Verify the main_apfs_volume value before mounting
    if [ -z "$main_apfs_volume" ]; then
        error "main_apfs_volume is empty! Cannot continue..."
        exit 1
    else
        info "main_apfs_volume value: /dev/$main_apfs_volume"
    fi

    # Adding a short delay
    sleep 1

    # Attempt to mount the main APFS volume to the APFS mount point
    if sudo mount -o nobrowse -t apfs /dev/"$main_apfs_volume" "$APFSMountPoint"; then
        success "Mounted Root APFS Volume at: $APFSMountPoint"
    else
        error "Failed to mount APFS Volume as R/W! Cannot continue..."
        exit 1
    fi
}

copy_xnu_to_disk() {
    # Extract the file names from the variables
    kernel_fileName=$(basename "$kernel_path")
    BootKernelExtensions_fileName=$(basename "$BKE")
    SystemKernelExtensions_fileName=$(basename "$SKE")

    # Print Variables for debugging
    running "kernel_fileName returned name: $kernel_fileName"
    running "BootKernelExtensions_fileName returned name: $BootKernelExtensions_fileName"
    running "SystemKernelExtensions_fileName returned name: $SystemKernelExtensions_fileName"
    
    # Copy the kernel file and check the result
    info "Copying $kernel_fileName to $APFSMountPoint/System/Library/Kernels/$kernel_fileName"
    sudo cp "$kernel_path" "$APFSMountPoint/System/Library/Kernels/$kernel_fileName"
    if [[ $? -eq 0 ]]; then
        success "Successfully copied $kernel_fileName!"
    else
        error "Failed to copy $kernel_fileName to disk!"
        exit 1
    fi

    # Copy the BootKernelExtensions file and check the result
    info "Copying $BootKernelExtensions_fileName to $APFSMountPoint/System/Library/KernelCollections/$BootKernelExtensions_fileName"
    sudo cp "$BKE" "$APFSMountPoint/System/Library/KernelCollections/$BootKernelExtensions_fileName"
    if [[ $? -eq 0 ]]; then
        success "Successfully copied $kernel_fileName!"
    else
        error "Failed to copy $kernel_fileName to disk!"
        exit 1
    fi

    # Copy the SystemKernelExtensions file and check the result
    info "Copying $SystemKernelExtensions_fileName to $APFSMountPoint/System/Library/KernelCollections/$SystemKernelExtensions_fileName"
    sudo cp "$SKE" "$APFSMountPoint/System/Library/KernelCollections/$SystemKernelExtensions_fileName"
    if [[ $? -eq 0 ]]; then
        success "Successfully copied $SystemKernelExtensions_fileName!"
    else
        error "Failed to copy $SystemKernelExtensions_fileName to disk!"
        exit 1
    fi
}

bless_bootdisk() {
    running "Running bless command to create latest APFS snapshot to boot..."
    sudo bless --folder "$APFSMountPoint/System/Library/CoreServices" --bootefi --create-snapshot
    if [[ $? -eq 0 ]]; then
        success "Successfully created snapshot with bless!"
    else
        error "Failed to create snapshot with bless!"
        exit 1
    fi
}

sanity_check_bootargs() {
    # Check boot-args for kcsuffix=development
    boot_args=$(nvram boot-args | awk -F'boot-args' '{print $2}' | xargs)
    running "Current boot-args: $boot_args"

    # Check for kcsuffix=development
    if [[ "$boot_args" != *"kcsuffix=development"* ]]; then
        warning "Warning: kcsuffix=development is not set in boot-args. You may not be booting into the installed kernel."
    else
        # Check for wlan.skywalk.enable=0 in boot-args
        if [[ "$boot_args" != *"wlan.skywalk.enable=0"* ]]; then
            warning "Warning: wlan.skywalk.enable=0 is not set in boot-args. You may encounter a Kernel Panic loop due to Skywalk not being included in XNU Open Source."
        fi

        # Check for dk=0 in boot-args
        if [[ "$boot_args" != *"dk=0"* ]]; then
            warning "Warning: dk=0 is not set in boot-args. You may have issues loading kexts."
        fi
    fi

    success "boot-args are configured properly for optimal booting success!"
}

install_routine() {
    build_checker
    
    # Check MACHINE_CONFIG and run kc_build if built for X86_64
    if [[ "$MACHINE_CONFIG" == "NONE" ]]; then
        kc_build
    fi
    
    find_mount_rw_bootdisk
    copy_xnu_to_disk
    bless_bootdisk
    sanity_check_bootargs
    prompt_reboot
}

prompt_install() {
    while true; do
        read -p "Do you want to install the built kernel now? (y/n) [y]: " user_input
        user_input=${user_input:-y} # Default to 'y' if no input is given, its important to build with the flags used to build.

        case "$user_input" in
            [Yy]* ) install_routine; break;;
            [Nn]* ) echo "Install skipped."; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

prompt_reboot() {
    while true; do
        read -p "Do you want to reboot now? (y/n) [n]: " user_input
        user_input=${user_input:-n} # Default to 'n' if no input is given

        case "$user_input" in
            [Yy]* ) sudo reboot; break;;
            [Nn]* ) unmount_apfsmountpoint; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

unmount_apfsmountpoint() {
    running "Unmounting APFS Volume..."

    # Attempt to mount the main APFS volume to the APFS mount point
    if sudo umount "$APFSMountPoint"; then
        success "Successfully unmounted Root APFS Volume at: $APFSMountPoint"
    else
        error "Failed to unmount APFS Volume! A reboot is highly recommended..."
        exit 1
    fi
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        clean)
            ACTION="clean"
            ;;
        build)
            ACTION="build"
            ;;
        fetch)
            ACTION="fetch"
            ;;
        install)
            ACTION="install"
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -k|--kerneltype)
            KERNEL_CONFIG="$2"
            shift
            ;;
        -a|--arch)
            ARCH_CONFIG="$2"
            shift
            ;;
        -m|--machine)
            if [[ "$2" == "help" ]]; then
                show_valid_machines
                shift
            else
                MACHINE_CONFIG="$2"
                shift
            fi
            shift
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

# Ensure a valid action is provided
if [ -z "${ACTION-}" ]; then
    error "An action (fetch, clean, build, or install) is required."
    show_help
    exit 1
fi

# Update global variables based on parsed arguments only for build action
if [ "$ACTION" == "build" ]; then
    update_globals
fi

# Add case functionality to handle actions passed via args
case "$ACTION" in
    clean)
        info "Cleaning built artifacts..."
        
        declare -a paths_to_delete=(
                "${BUILD_DIR}"
                "${FAKEROOT_DIR}"
                "${WORK_DIR}/bootstrap_cmds"
                "${WORK_DIR}/dtrace"
                "${WORK_DIR}/AvailabilityVersions"
                "${WORK_DIR}/Libsystem"
                "${WORK_DIR}/libplatform"
                "${WORK_DIR}/libdispatch"
            )

        for path in "${paths_to_delete[@]}"; do
            info "Will delete ${path}"
        done

        read -p "Are you sure? " -n 1 -r
        echo # (optional) move to a new line
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for path in "${paths_to_delete[@]}"; do
                info "Deleting ${path}"
                rm -rf "${path}"
            done
        fi
        
        success "Working Directory has been cleaned!"
        ;;
    build)
        welcome
        headers_status

       # Notify user if defaults are used
        if [ "$KERNEL_CONFIG" == "DEVELOPMENT" ] && [ "$ARCH_CONFIG" == "X86_64" ] && [ "$MACHINE_CONFIG" == "NONE" ]; then
            info "No specific configuration provided. Falling back to defaults!"
            print_builder_variables
        else
            # Notify user of current configuration values
            info "Custom configuration provided."
            print_builder_variables
        fi
        
        install_deps
        install_kdk
        get_xnu_source
        init_venv
        build_bootstrap_cmds
        build_dtrace
        build_availabilityversions
        install_xnu_headers
        install_libsyscall_headers
        build_libplatform
        build_libdispatch
        build_xnu
        success "XNU Build Done! You can now install it."

        prompt_install
        ;;
    fetch)
        echo "Fetching XNU Source from Carnations-Botanica..."
        get_xnu_source
        ;;
    install)
        build_checker
        
        # Check MACHINE_CONFIG and run kc_build if built for X86_64
        if [[ "$MACHINE_CONFIG" == "NONE" ]]; then
            kc_build
        fi
        
        find_mount_rw_bootdisk
        copy_xnu_to_disk
        bless_bootdisk
        sanity_check_bootargs
        prompt_reboot
        ;;
    *)
        error "Invalid action specified."
        show_help
        exit 1
        ;;
esac
