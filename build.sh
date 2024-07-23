#!/usr/bin/env bash
builder_version=1.0.0
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
    echo "Usage:   ./build.sh [options] <action>"
    echo "Example: ./build.sh fetch"
    echo "Example: ./build.sh clean"
    echo "Example: ./build.sh build -k DEVELOPMENT -a X86_64"
    echo "Example: ./build.sh build -k RELEASE -a ARM64 -m VMAPPLE"
    echo ""
    echo "Actions:"
    echo "  fetch       Fetch the Carnations XNU Source Code"
    echo "  clean       Clean build artifacts"
    echo "  build       Build the source code"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -v, --version      Show the version of the script"
    echo "  -k, --kerneltype   Set kernel type (RELEASE / DEVELOPMENT)"
    echo "  -a, --arch         Set architecture (x86_64 / ARM64)"
    echo "  -m, --machine      Set machine configuration (T8101, T8103, T6000, VMAPPLE for ARM64 only)"
}

show_valid_machines() {
    echo "Valid Machine configurations are:"
    echo ""
    echo "T8101 (Apple A14 Bionic)"
    echo "T8103 (Apple M1)"
    echo "T6000 (Apple M1 Pro)"
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
            sucess "Homebrew installation completed."
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

init_venv() {
    info "A venv is required to continue, now checking or creating one."
    if [ ! -d "${WORK_DIR}/venv" ]; then
        running "Creating a new virtual environment..."
        python3 -m venv "${WORK_DIR}/venv"
    fi
    success "Activating existing virtual environment!"
    source "${WORK_DIR}/venv/bin/activate"
}

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

build_xnu() {
    if [ ! -f "${BUILD_DIR}/xnu-10063.121.3~5/kernel.${KERNEL_TYPE}" ]; then
        info "Building XNU kernel..."
        
        SRCROOT="${WORK_DIR}/xnu"
        OBJROOT="${BUILD_DIR}/xnu-10063.121.3~5"
        SYMROOT="${BUILD_DIR}/xnu.sym"
        
        cd "${SRCROOT}"
        make install -j8 VERBOSE=YES SDKROOT=macosx TARGET_CONFIGS="$KERNEL_CONFIG $ARCH_CONFIG $MACHINE_CONFIG" CONCISE=0 LOGCOLORS=y BUILD_WERROR=0 BUILD_LTO=0 SRCROOT="${SRCROOT}" OBJROOT="${OBJROOT}" SYMROOT="${SYMROOT}" DSTROOT="${DSTROOT}" FAKEROOT_DIR="${FAKEROOT_DIR}" KDKROOT="${KDKROOT}" TIGHTBEAMC=${TIGHTBEAMC} RC_DARWIN_KERNEL_VERSION=${RC_DARWIN_KERNEL_VERSION}
        cd "${WORK_DIR}"
    else
        info "XNU kernel.${KERNEL_TYPE} has already been built. No action required."
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
            MACHINE_CONFIG="$2"
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
    error "An action (fetch, clean or build) is required."
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
        success "XNU Build Done!"
        ;;
    fetch)
        echo "Fetching XNU Source from Carnations-Botanica..."
        get_xnu_source
        ;;
    *)
        error "Invalid action specified."
        show_help
        exit 1
        ;;
esac
