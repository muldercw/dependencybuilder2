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
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/repomd.xml.key" \
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
cat <<'EOF' > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "================================================================================="
echo "Step 0: Minimal Debug Info (no parentheses or advanced 'ps' commands)"
echo "================================================================================="
set -x

echo "🚀 Installing only available packages from /test-env/artifacts/"
PKG_DIR="/test-env/artifacts/"

DETECTED_OS=""

echo "🔍 Checking /etc/os-release..."
if [[ -f "/etc/os-release" ]]; then
    echo "Contents of /etc/os-release:"
    cat /etc/os-release

    # Lenient grep approach
    if   grep -iq 'ubuntu' /etc/os-release;  then DETECTED_OS="ubuntu"
    elif grep -iq 'debian' /etc/os-release;  then DETECTED_OS="debian"
    elif grep -iq 'centos' /etc/os-release;  then DETECTED_OS="centos"
    elif grep -iq 'rocky'  /etc/os-release;  then DETECTED_OS="rocky"
    elif grep -iq 'rhel'   /etc/os-release;  then DETECTED_OS="rhel"
    elif grep -iq 'fedora' /etc/os-release;  then DETECTED_OS="fedora"
    elif grep -iq 'arch'   /etc/os-release;  then DETECTED_OS="arch"
    elif grep -iq 'suse'   /etc/os-release;  then DETECTED_OS="suse"
    fi

    if grep -q '^ID=ubuntu' /etc/os-release; then
       echo "Forcing DETECTED_OS=ubuntu due to exact 'ID=ubuntu' line."
       DETECTED_OS="ubuntu"
    fi
fi

# Final fallback if still empty
if [[ -z "$DETECTED_OS" ]]; then
    echo "Forcing DETECTED_OS='ubuntu' due to environment quirk."
    DETECTED_OS="ubuntu"
fi

echo "Detected OS: $DETECTED_OS"

# Determine Package Manager
if [[ "$DETECTED_OS" == "ubuntu" || "$DETECTED_OS" == "debian" ]]; then
    PKG_MANAGER="dpkg"
elif [[ "$DETECTED_OS" == "rhel" || "$DETECTED_OS" == "rocky" || "$DETECTED_OS" == "centos" ]]; then
    PKG_MANAGER="dnf"
elif [[ "$DETECTED_OS" == "fedora" ]]; then
    PKG_MANAGER="dnf_fedora"
elif [[ "$DETECTED_OS" == "arch" ]]; then
    PKG_MANAGER="pacman"
elif [[ "$DETECTED_OS" == "suse" || "$DETECTED_OS" == "opensuse" ]]; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS: $DETECTED_OS"
    exit 1
fi

echo "📂 Using package manager: $PKG_MANAGER"

# Step 3: Install from $PKG_DIR
if [[ "$PKG_MANAGER" == "dpkg" ]]; then
    echo "📦 Installing .deb packages from $PKG_DIR..."
    find "$PKG_DIR" -type f -name "*.deb" -exec dpkg -i {} + || \
      echo "⚠️ Warning: Some packages may have failed to install."
    echo "🔧 Fixing broken dependencies..."
    apt-get -y install --fix-broken || echo "⚠️ Some dependencies may still be missing."

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo "📦 Installing .rpm packages from $PKG_DIR..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "dnf_fedora" ]]; then
    echo "📦 Installing Fedora .rpm packages from $PKG_DIR..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    echo "📦 Installing Arch .pkg.tar.zst packages from $PKG_DIR..."
    find "$PKG_DIR" -type f -name "*.pkg.tar.zst" -exec pacman -U --noconfirm {} + || \
      echo "⚠️ Some packages may have failed to install."

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "📦 Installing .rpm packages from $PKG_DIR (OpenSUSE)..."
    zypper --non-interactive install "$PKG_DIR"/*.rpm || \
      echo "⚠️ Some packages may have failed to install."
fi

# Step 4: Verify
echo "🔍 Checking installed Kubernetes components..."
case "$PKG_MANAGER" in
    dpkg) dpkg -l | grep -E "kubeadm|kubelet|kubectl|containerd" || echo "⚠️ Some components may not be installed." ;;
    dnf|dnf_fedora|zypper) rpm -qa | grep -E "kubeadm|kubelet|kubectl|containerd" || echo "⚠️ Some components may not be installed." ;;
    pacman) pacman -Q | grep -E "kubeadm|kubelet|kubectl|containerd" || echo "⚠️ Some components may not be installed." ;;
esac

echo "✅ Kubernetes offline installation script complete."
EOF

chmod +x "$INSTALL_SCRIPT"
echo "✅ Kubernetes Offline Build Complete."
