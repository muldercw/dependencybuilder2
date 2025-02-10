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

# Detect OS & Package Manager
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="dpkg"
elif command -v dnf &> /dev/null; then
    if grep -qi "fedora" /etc/os-release; then
        PKG_MANAGER="dnf_fedora"
    else
        PKG_MANAGER="dnf"
    fi
elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
elif command -v zypper &> /dev/null; then
    PKG_MANAGER="zypper"
else
    echo "❌ ERROR: Unsupported OS"
    exit 1
fi

echo "📂 Installing Kubernetes using: $PKG_MANAGER"

# 📌 **Ubuntu/Debian (dpkg)**
if [[ "$PKG_MANAGER" == "dpkg" ]]; then
    echo "📦 Installing .deb packages..."
    find "$PKG_DIR" -type f -name "*.deb" -exec dpkg -i {} + || echo "⚠️ Warning Some packages may have failed to install."
    echo "🔧 Fixing broken dependencies..."
    apt-get -y install --fix-broken || echo "⚠️ Warning Some dependencies may still be missing."

# 📌 **CentOS/Rocky (dnf)**
elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo "📦 Installing .rpm packages..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."

# 📌 **Fedora (dnf but different)**
elif [[ "$PKG_MANAGER" == "dnf_fedora" ]]; then
    echo "🔄 Refreshing Fedora metadata..."
    dnf makecache --refresh || echo "⚠️ Warning Could not refresh Fedora metadata!"
    echo "📦 Installing .rpm packages..."
    dnf install -y "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."

# 📌 **Arch Linux (pacman)**
elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    echo "🔍 Checking pacman database..."
    if [[ ! -f /var/lib/pacman/sync/core.db ]]; then
        echo "⚠️ Pacman database missing! Initializing..."
        pacman -Sy --noconfirm
    fi
    echo "📦 Installing .pkg.tar.zst packages..."
    find "$PKG_DIR" -type f -name "*.pkg.tar.zst" -exec pacman -U --noconfirm {} + || echo "⚠️ Warning Some packages may have failed to install."

# 📌 **OpenSUSE (zypper)**
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "🔄 Refreshing Zypper metadata..."
    zypper refresh --gpg-auto-import-keys || echo "⚠️ Warning Could not refresh metadata!"
    echo "📦 Installing .rpm packages..."
    zypper --non-interactive install "$PKG_DIR"/*.rpm || echo "⚠️ Warning Some packages may have failed to install."
fi

# ✅ Final Verification
echo "🔍 Verifying installed Kubernetes components..."
dpkg -l | grep -E "kubeadm|kubelet|kubectl|containerd" 2>/dev/null || echo "⚠️ Warning Some Kubernetes components may not be installed."

echo "✅ Kubernetes installation complete."

EOF

chmod +x "$INSTALL_SCRIPT"

echo "✅ Kubernetes Offline Build Complete."
