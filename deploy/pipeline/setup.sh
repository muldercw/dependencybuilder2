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
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
    chmod 644 /etc/apt/sources.list.d/kubernetes.list
    apt-get update -y

    PKGS="kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

    echo "📥 Downloading Kubernetes packages..."
    apt-get download --allow-downgrades --allow-change-held-packages $PKGS

    for pkg in $PKGS; do
        echo "📥 Downloading dependencies for: $pkg"
        DEPS=$(apt-cache depends --recurse --no-suggests --no-conflicts --no-replaces --no-breaks --no-enhances --no-pre-depends "$pkg" | grep "^\w" | sort -u)
        apt-get download --allow-downgrades --allow-change-held-packages $DEPS || echo "⚠️ Warning: Some dependencies could not be downloaded"
    done

elif [[ "$OS" == "rocky" ]]; then
    echo "🔗 Configuring Kubernetes repository for Rocky Linux..."
    dnf install -y dnf-plugins-core
    echo "[kubernetes] name=Kubernetes baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/ enabled=1 gpgcheck=1 gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/repodata/repomd.xml.key" | tee /etc/yum.repos.d/kubernetes.repo


    echo "🔄 Refreshing DNF metadata..."
    dnf clean all && dnf makecache --refresh



    PKGS="kubeadm kubelet kubectl cri-tools conntrack-tools iptables iproute. ethtool"

    echo "📥 Downloading Kubernetes packages for architecture: $ARCH..."
    dnf download --resolve --arch=${ARCH} $PKGS


elif [[ "$OS" == "fedora" ]]; then
    echo "🔗 Configuring Kubernetes repository for Fedora..."
    echo -e "[kubernetes]\nname=Kubernetes Repository\nbaseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/\nenabled=1\ngpgcheck=0" | tee /etc/yum.repos.d/kubernetes.repo > /dev/null

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

    # ✅ Fix: Do NOT use `apt-cache` for Arch!
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

echo "🚀 Installing only available packages from /test-env/artifacts/"
PKG_DIR="/test-env/artifacts/"

# ✅ **Step 1: Debug OS Detection**
echo "🔍 Checking OS information..."

# **Ensure /etc/os-release exists before sourcing it**
if [[ -f "/etc/os-release" ]]; then
    echo "ℹ️ Contents of /etc/os-release:"
    cat /etc/os-release
    OS_ID=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')  # Extract ID manually
else
    echo "⚠️ Warning: /etc/os-release not found!"
    OS_ID=""
fi

# **Fallback OS detection methods**
if [[ -z "$OS_ID" ]] && command -v lsb_release &> /dev/null; then
    OS_ID=$(lsb_release -si | awk '{print tolower($1)}')
elif [[ -z "$OS_ID" ]] && [[ -f "/etc/debian_version" ]]; then
    OS_ID="debian"
elif [[ -z "$OS_ID" ]] && [[ -f "/etc/redhat-release" ]]; then
    OS_ID="rhel"
elif [[ -z "$OS_ID" ]] && [[ -f "/etc/SuSE-release" ]]; then
    OS_ID="suse"
elif [[ -z "$OS_ID" ]] && command -v uname &> /dev/null; then
    OS_KERNEL=$(uname -s)
    if [[ "$OS_KERNEL" == "Linux" ]]; then
        OS_ID="linux"
    fi
fi

# **Print detected OS**
if [[ -z "$OS_ID" ]]; then
    echo "❌ ERROR: Unable to detect OS."
    exit 1
fi

echo "🔍 Detected OS: $OS_ID"

# ✅ **Step 2: Determine Package Manager**
if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    PKG_MANAGER="dpkg"
elif [[ "$OS_ID" == "rhel" || "$OS_ID" == "rocky" || "$OS_ID" == "centos" ]]; then
    PKG_MANAGER="dnf"
elif [[ "$OS_ID" == "fedora" ]]; then
    PKG_MANAGER="dnf_fedora"
elif [[ "$OS_ID" == "arch" ]]; then
    PKG_MANAGER="pacman"
elif [[ "$OS_ID" == "suse" || "$OS_ID" == "opensuse" ]]; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS: $OS_ID"
    exit 1
fi

echo "📂 Installing Kubernetes using: $PKG_MANAGER"

# ✅ **Step 3: Install Kubernetes Components**
if [[ "$PKG_MANAGER" == "dpkg" ]]; then
    echo "📦 Installing .deb packages..."
    find "$PKG_DIR" -type f -name "*.deb" -exec dpkg -i {} + || echo "⚠️ Warning Some packages may have failed to install."
    echo "🔧 Fixing broken dependencies..."
    apt-get -y install --fix-broken || echo "⚠️ Warning Some dependencies may still be missing."

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo "📦 Installing .rpm packages..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "dnf_fedora" ]]; then
    echo "🔄 Refreshing Fedora metadata... (SKIPPED - Airgapped Mode)"
    echo "📦 Installing .rpm packages..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    echo "🔍 Checking pacman database..."
    if [[ ! -f /var/lib/pacman/sync/core.db ]]; then
        echo "⚠️ Skipping database sync (air-gapped mode)..."
    fi
    echo "📦 Installing pre-downloaded .pkg.tar.zst packages..."
    find "$PKG_DIR" -type f -name "*.pkg.tar.zst" -exec pacman -U --noconfirm {} + || echo "⚠️ Warning Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "🔄 Refreshing Zypper metadata... (SKIPPED - Airgapped Mode)"
    echo "📦 Installing .rpm packages..."
    zypper --non-interactive install "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."
fi

# ✅ **Final Verification**
echo "🔍 Verifying installed Kubernetes components..."
case "$PKG_MANAGER" in
    dpkg) dpkg -l | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Warning Some Kubernetes components may not be installed." ;;
    pacman) pacman -Q | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Warning Some Kubernetes components may not be installed." ;;
    dnf|dnf_fedora|zypper) rpm -qa | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Warning Some Kubernetes components may not be installed." ;;
esac

echo "✅ Kubernetes installation complete."

EOF

chmod +x "$INSTALL_SCRIPT"

echo "✅ Kubernetes Offline Build Complete."
