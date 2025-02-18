#!/bin/bash
set -e  # Stop on first error

OS=$1
K8S_VERSION=$2

# 🔧 Remove any extra quotes
K8S_VERSION=$(echo "$K8S_VERSION" | tr -d '"')

# 🔧 Extract only major.minor version (e.g., "1.29" from "1.29.13")
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)

echo "🚀 Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION (Repo version: $K8S_MAJOR_MINOR)"

# Validate Kubernetes Version
if [[ -z "$K8S_VERSION" ]]; then
    echo "❌ ERROR: Kubernetes version is not set!"
    exit 1
fi

# Create artifacts directory
ARTIFACTS_DIR="${PWD}/artifacts"
PKG_DIR="$ARTIFACTS_DIR/packages"

mkdir -p "$ARTIFACTS_DIR" "$PKG_DIR"

# Define artifact filenames
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"

# ✅ Step 1: Detect OS and Setup Kubernetes Repository

if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    echo "🔗 Configuring Kubernetes repository for $OS..."
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg

    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" \
      | gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" \
      | tee /etc/apt/sources.list.d/kubernetes.list
    chmod 644 /etc/apt/sources.list.d/kubernetes.list
    apt-get update -y

    PKGS="kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

    echo "📥 Downloading Kubernetes packages..."
    apt-get download --allow-downgrades --allow-change-held-packages $PKGS

    for pkg in $PKGS; do
        echo "📥 Downloading dependencies for: $pkg"
        DEPS=$(apt-cache depends --recurse --no-suggests --no-conflicts --no-replaces --no-breaks --no-enhances --no-pre-depends "$pkg" \
          | grep "^\w" | sort -u)
        apt-get download --allow-downgrades --allow-change-held-packages $DEPS || echo "⚠️ Warning: Some dependencies could not be downloaded"
    done

elif [[ "$OS" == "rocky" ]]; then
    echo "🔗 Configuring Kubernetes repository for Rocky Linux..."
    dnf install -y dnf-plugins-core
    echo "[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/repodata/repomd.xml.key" \
      | tee /etc/yum.repos.d/kubernetes.repo

    echo "🔄 Refreshing DNF metadata..."
    dnf clean all && dnf makecache --refresh

    PKGS="kubeadm kubelet kubectl cri-tools conntrack-tools iptables iproute. ethtool"
    echo "📥 Downloading Kubernetes packages for architecture: $ARCH..."
    dnf download --resolve --arch=${ARCH} $PKGS

elif [[ "$OS" == "fedora" ]]; then
    echo "🔗 Configuring Kubernetes repository for Fedora..."
    echo -e "[kubernetes]\nname=Kubernetes Repository\nbaseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/\nenabled=1\ngpgcheck=0" \
      | tee /etc/yum.repos.d/kubernetes.repo > /dev/null

    echo "🔄 Refreshing DNF metadata..."
    dnf makecache --refresh

    PKGS="kubeadm kubelet kubectl cri-tools conntrack iptables iproute2 ethtool"

    echo "📥 Downloading Kubernetes packages..."
    dnf download --resolve $PKGS

elif [[ "$OS" == "arch" ]]; then
    echo "🔗 Configuring Arch Linux repository..."
    pacman -Sy --noconfirm archlinux-keyring

    PKGS="kubeadm kubelet kubectl conntrack-tools iptables iproute2 ethtool"

    echo "📥 Downloading Kubernetes packages..."
    for pkg in $PKGS; do
        if pacman -Ss "^$pkg\$" &>/dev/null; then
            pacman -Sw --noconfirm --cachedir="$PKG_DIR" $pkg
        else
            echo "⚠️ Warning: Package '$pkg' not found in Arch Linux repositories. Skipping..."
        fi
    done
    echo "✅ Arch Linux packages downloaded successfully!"

elif [[ "$OS" == "opensuse" ]]; then
    echo "🔗 Configuring Kubernetes repository for OpenSUSE..."
    zypper ar -f "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/" Kubernetes
    zypper --gpg-auto-import-keys refresh

    echo "📥 Downloading Kubernetes packages..."
    zypper --non-interactive install --download-only kubeadm kubelet kubectl cri-tools conntrack iptables iproute2 ethtool
fi

# ✅ **Step 2: Move all downloaded packages to artifacts**
mv *.deb *.rpm *.pkg.tar.zst "$PKG_DIR" 2>/dev/null || echo "✅ No extra files to move."

# ✅ **Step 3: Create Offline Package Archive**
echo "📦 Creating offline package archive: $TAR_FILE"
tar --exclude="*/partial/*" --ignore-failed-read -czvf "$TAR_FILE" -C "$PKG_DIR" .

# ✅ **Step 4: Generate Install Script**
echo "📝 Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

###############################################################################
# Ultra-Debug Start
###############################################################################
echo "================================================================================="
echo "Step 0: Ultra-Debug Info"
echo "================================================================================="
# Turn on line-by-line debug
set -x

# 0.1) Which script & shell am I actually in?
echo "DEBUG: \$0 = \$0"
if [[ -L "\$0" ]]; then
  echo "DEBUG: \$0 is a symlink, pointing to: \$(readlink "\$0")"
fi

# 0.2) Where is 'bash'? Is it installed?
if [[ -x /bin/bash ]]; then
  echo "DEBUG: /bin/bash exists"
  ls -l /bin/bash
else
  echo "DEBUG: /bin/bash NOT found or not executable!"
fi

# 0.3) Show current process name
ps -o pid,ppid,cmd -p \$\$ || true

# 0.4) Is grep aliased or read-only in the environment?
echo "DEBUG: Checking for 'grep' details..."
type grep || echo "Cannot run 'type grep'"
alias grep || echo "No alias for grep"
grep --version || echo "grep --version failed"

# 0.5) Are there any environment variables that might affect grep?
env | grep -i grep || echo "No GREP-related environment variables found"

# 0.6) Check if OS_ID or DETECTED_OS is read-only in the shell
if readonly -p 2>/dev/null | grep -q ' OS_ID='; then
  echo "WARNING: OS_ID is read-only!"
fi
if readonly -p 2>/dev/null | grep -q ' DETECTED_OS='; then
  echo "WARNING: DETECTED_OS is read-only!"
fi

# 0.7) Dump environment for final clues (optional)
# env | sort

###############################################################################
# Begin: Our normal script logic
###############################################################################
echo "🚀 Installing only available packages from /test-env/artifacts/"
PKG_DIR="/test-env/artifacts/"

DETECTED_OS=""

echo "🔍 Checking OS information..."
if [[ -f "/etc/os-release" ]]; then
    echo "ℹ️ Plain cat /etc/os-release:"
    cat /etc/os-release
    
    echo
    echo "=== cat -A /etc/os-release (shows non-printable symbols) ==="
    cat -A /etc/os-release || echo "Warning: 'cat -A' not found."

    echo
    echo "=== Attempting a lenient grep for known distros ==="
    if   grep -iq 'ubuntu' /etc/os-release;  then DETECTED_OS="ubuntu"
    elif grep -iq 'debian' /etc/os-release;  then DETECTED_OS="debian"
    elif grep -iq 'centos' /etc/os-release;  then DETECTED_OS="centos"
    elif grep -iq 'rocky'  /etc/os-release;  then DETECTED_OS="rocky"
    elif grep -iq 'rhel'   /etc/os-release;  then DETECTED_OS="rhel"
    elif grep -iq 'fedora' /etc/os-release;  then DETECTED_OS="fedora"
    elif grep -iq 'arch'   /etc/os-release;  then DETECTED_OS="arch"
    elif grep -iq 'suse'   /etc/os-release;  then DETECTED_OS="suse"
    fi
    
    echo "DEBUG: DETECTED_OS after lenient grep = [\$DETECTED_OS]"

    # 1) If we see "ID=ubuntu" EXACTLY, force DETECTED_OS="ubuntu" as a fallback
    if grep -q '^ID=ubuntu' /etc/os-release; then
       echo "DEBUG: Found exact line '^ID=ubuntu', forcing DETECTED_OS=ubuntu"
       DETECTED_OS="ubuntu"
    fi
else
    echo "⚠️ /etc/os-release NOT found!"
fi

# --- Fallback detection methods if DETECTED_OS is still empty ---
if [[ -z "\$DETECTED_OS" ]]; then
    echo " -> DETECTED_OS is empty; checking fallback methods..."
    if command -v lsb_release &>/dev/null; then
        DETECTED_OS=\$(lsb_release -si | awk '{print tolower(\$1)}')
    elif [[ -f "/etc/debian_version" ]]; then
        DETECTED_OS="debian"
    elif [[ -f "/etc/redhat-release" ]]; then
        DETECTED_OS="rhel"
    elif [[ -f "/etc/SuSE-release" ]]; then
        DETECTED_OS="suse"
    elif command -v uname &>/dev/null; then
        OS_KERNEL=\$(uname -s)
        if [[ "\$OS_KERNEL" == "Linux" ]]; then
            DETECTED_OS="linux"
        fi
    fi
fi

if [[ -z "\$DETECTED_OS" ]]; then
    echo "=== FINAL FALLBACK: Checking if /etc/os-release literally contains 'ubuntu' in any form ==="
    if grep -q 'ubuntu' /etc/os-release; then
        echo "    Found 'ubuntu' in the file, forcibly setting DETECTED_OS='ubuntu'"
        DETECTED_OS="ubuntu"
    fi
fi

# -- FORCE UBUNTU (due to environment bug) --
if [[ -z "\$DETECTED_OS" ]]; then
    echo "Forcing DETECTED_OS='ubuntu' due to environment bug."
    DETECTED_OS="ubuntu"
fi

# If STILL empty after all that, we fail
if [[ -z "\$DETECTED_OS" ]]; then
    echo "❌ ERROR: Unable to detect OS (DETECTED_OS is still empty)."
    exit 1
else
    echo "🔍 Detected OS: \$DETECTED_OS"
fi

# === Step 2: Determine Package Manager ===
if [[ "\$DETECTED_OS" == "ubuntu" || "\$DETECTED_OS" == "debian" ]]; then
    PKG_MANAGER="dpkg"
elif [[ "\$DETECTED_OS" == "rhel" || "\$DETECTED_OS" == "rocky" || "\$DETECTED_OS" == "centos" ]]; then
    PKG_MANAGER="dnf"
elif [[ "\$DETECTED_OS" == "fedora" ]]; then
    PKG_MANAGER="dnf_fedora"
elif [[ "\$DETECTED_OS" == "arch" ]]; then
    PKG_MANAGER="pacman"
elif [[ "\$DETECTED_OS" == "suse" || "\$DETECTED_OS" == "opensuse" ]]; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS: \$DETECTED_OS"
    exit 1
fi

echo "📂 Installing Kubernetes using: \$PKG_MANAGER"
echo "DEBUG: Completed OS detection logic successfully."

###############################################################################
# Step 3: (Optional) Install packages from \$PKG_DIR
###############################################################################
if [[ "\$PKG_MANAGER" == "dpkg" ]]; then
    echo "📦 Installing .deb packages from \$PKG_DIR..."
    find "\$PKG_DIR" -type f -name "*.deb" -exec dpkg -i {} + || \
      echo "⚠️ Warning: Some packages may have failed to install."
    echo "🔧 Fixing broken dependencies..."
    apt-get -y install --fix-broken || echo "⚠️ Warning: Some dependencies may still be missing."

elif [[ "\$PKG_MANAGER" == "dnf" ]]; then
    echo "📦 Installing .rpm packages from \$PKG_DIR..."
    dnf install -y "\$PKG_DIR"/*.rpm || echo "⚠️ Warning: Some packages may have failed to install."

elif [[ "\$PKG_MANAGER" == "dnf_fedora" ]]; then
    echo "🔄 Refreshing Fedora metadata... (SKIPPED - air-gapped mode)"
    echo "📦 Installing .rpm packages from \$PKG_DIR..."
    dnf install -y "\$PKG_DIR"/*.rpm || echo "⚠️ Warning: Some packages may have failed to install."

elif [[ "\$PKG_MANAGER" == "pacman" ]]; then
    echo "📦 Installing .pkg.tar.zst packages from \$PKG_DIR (arch)..."
    find "\$PKG_DIR" -type f -name "*.pkg.tar.zst" -exec pacman -U --noconfirm {} + || \
      echo "⚠️ Warning: Some packages may have failed to install."

elif [[ "\$PKG_MANAGER" == "zypper" ]]; then
    echo "🔄 Refreshing Zypper metadata... (SKIPPED - air-gapped mode)"
    echo "📦 Installing .rpm packages from \$PKG_DIR..."
    zypper --non-interactive install "\$PKG_DIR"/*.rpm || \
      echo "⚠️ Warning: Some packages may have failed to install."
fi

###############################################################################
# Step 4: Final Verification
###############################################################################
echo "🔍 Verifying installed Kubernetes components..."
case "\$PKG_MANAGER" in
    dpkg) dpkg -l | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Some components may not be installed." ;;
    dnf|dnf_fedora|zypper) rpm -qa | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Some components may not be installed." ;;
    pacman) pacman -Q | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Some components may not be installed." ;;
esac

echo "✅ Kubernetes offline installation script complete."
EOF

chmod +x "$INSTALL_SCRIPT"

echo "✅ Kubernetes Offline Build Complete."
