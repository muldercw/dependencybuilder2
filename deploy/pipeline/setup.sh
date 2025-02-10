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

# Determine Package Manager
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    PKG_MANAGER="apt"
elif [[ "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "fedora" ]]; then
    PKG_MANAGER="dnf"
elif [[ "$OS" == "arch" ]]; then
    PKG_MANAGER="pacman"
elif [[ "$OS" == "opensuse" ]]; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS: $OS"
    exit 1
fi

echo "🔎 Using package manager: $PKG_MANAGER"

# ✅ **Step 1: Add Kubernetes Repository & Fetch Packages**
if [[ "$PKG_MANAGER" == "apt" ]]; then
    echo "🔗 Adding Kubernetes repository for $OS..."
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

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo "🔗 Enabling Kubernetes repository for $OS..."
    dnf install -y dnf-plugins-core
    dnf config-manager --add-repo "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/rpm/"

    PKGS="kubeadm-${K8S_VERSION} kubelet-${K8S_VERSION} kubectl-${K8S_VERSION} cri-tools conntrack iptables iproute ethtool"

    echo "📥 Downloading Kubernetes packages..."
    dnf download --resolve $PKGS

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    echo "🔗 Configuring Arch Linux repository..."
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Sy --noconfirm archlinux-keyring

    PKGS="kubeadm kubelet kubectl cri-tools conntrack-tools iptables iproute2 ethtool"

    echo "📥 Downloading Kubernetes packages and dependencies..."
    pacman -Sw --noconfirm --cachedir="$PKG_DIR" $PKGS

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "🔗 Enabling Kubernetes repository for OpenSUSE..."
    zypper --gpg-auto-import-keys refresh
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

# Detect package manager
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="dpkg"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
elif command -v zypper &> /dev/null; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS"
    exit 1
fi

echo "📂 Installing Kubernetes using: \$PKG_MANAGER"

if [[ "\$PKG_MANAGER" == "dpkg" ]]; then
    find /test-env/artifacts/ -type f -name "*.deb" -exec dpkg -i {} + || echo "⚠️ Warning: Some packages may have failed to install."
elif [[ "\$PKG_MANAGER" == "dnf" ]]; then
    dnf install -y /test-env/artifacts/*.rpm
elif [[ "\$PKG_MANAGER" == "pacman" ]]; then
    pacman -U --noconfirm /test-env/artifacts/*.pkg.tar.zst
elif [[ "\$PKG_MANAGER" == "zypper" ]]; then
    zypper install --no-confirm /test-env/artifacts/*.rpm
fi

echo "✅ Kubernetes installation complete."

EOF

chmod +x "$INSTALL_SCRIPT"

# ✅ **Step 5: Generate Checksum**
echo "🔍 Generating SHA256 checksum file: $CHECKSUM_FILE"
sha256sum "$TAR_FILE" "$INSTALL_SCRIPT" > "$CHECKSUM_FILE"

# ✅ **Step 6: Generate dependencies.yaml**
echo "📜 Generating dependencies.yaml..."
echo "# Kubernetes Dependencies for $OS (K8S v$K8S_VERSION)" > "$DEPENDENCIES_FILE"

echo "✅ Kubernetes Offline Build Complete."
