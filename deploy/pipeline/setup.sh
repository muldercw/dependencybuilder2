#!/bin/bash
set -e  # Stop on first error

OS=$1
K8S_VERSION=$2

# 🔧 Remove any extra quotes
K8S_VERSION=$(echo "$K8S_VERSION" | tr -d '"')

# 🔧 Extract only major.minor version (e.g., "1.29" from "1.29.13")
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)

echo "🚀 Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION (Repo version: $K8S_MAJOR_MINOR)"

# ✅ Validate Kubernetes Version
if [[ -z "$K8S_VERSION" ]]; then
    echo "❌ ERROR: Kubernetes version is not set!"
    exit 1
fi

# ✅ Create artifacts directory
ARTIFACTS_DIR="${PWD}/artifacts"
DEB_DIR="$ARTIFACTS_DIR/deb-packages"
mkdir -p "$ARTIFACTS_DIR" "$DEB_DIR"

# ✅ Define filenames
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"

# ✅ Validate OS
if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    echo "❌ ERROR: Unsupported OS: $OS"
    exit 1
fi

# ✅ Add Kubernetes APT Repository
echo "📦 Adding Kubernetes repository for $OS..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y

# ✅ **Step 1: Install Kubernetes First**
echo "📦 Installing Kubernetes version $K8S_VERSION..."
sudo apt-get install -y --allow-downgrades --allow-change-held-packages kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool

# ✅ **Step 2: Download ALL Required Packages & Dependencies**
echo "📦 Downloading Kubernetes and ALL dependencies for offline installation..."

# Define required packages
KUBE_PACKAGES="kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

# **Generate full list of dependencies (recursively)**
ALL_PACKAGES=$(for pkg in $KUBE_PACKAGES; do
    apt-cache depends --recurse --no-suggests --no-conflicts --no-replaces --no-breaks --no-enhances --no-pre-depends "$pkg" | grep "^\w" | sort -u
done | sort -u)

echo "📜 Full list of packages to download:"
echo "$ALL_PACKAGES"

# ✅ **Download each package**
for pkg in $ALL_PACKAGES; do
    echo "📥 Downloading: $pkg"
    sudo apt-get download --allow-downgrades --allow-change-held-packages "$pkg" || echo "⚠️ Warning: Failed to download $pkg"
done

# ✅ Move all downloaded `.deb` files to artifacts directory
mv *.deb "$DEB_DIR"

# ✅ **Create offline package archive**
echo "📦 Creating offline package archive: $TAR_FILE"
sudo tar --exclude="*/partial/*" --ignore-failed-read -czvf "$TAR_FILE" -C "$DEB_DIR" .

# ✅ **Generate Install Script**
echo "📜 Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "🚀 Debugging: Installing all .deb files recursively"

# ✅ Fix permissions
chmod -R u+rwX /test-env/artifacts
ls -lah /test-env/artifacts  # Verify ownership & permissions

# ✅ Suppress frontend issues (Debconf)
export DEBIAN_FRONTEND=noninteractive

# ✅ Install all .deb packages, allowing downgrades and ignoring conflicts
echo "📦 Installing all .deb packages from /test-env/artifacts/..."
dpkg -R --install /test-env/artifacts/ || echo "⚠️ Warning: Some packages may have failed to install."

# ✅ Fix any broken dependencies
echo "🔧 Fixing broken dependencies..."
apt-get -y install --fix-broken || echo "⚠️ Warning: Some dependencies may still be missing."

# ✅ Force configuration of unconfigured packages
echo "🔄 Configuring unconfigured packages..."
dpkg --configure -a || echo "⚠️ Warning: Some packages may still be unconfigured."

# ✅ Verify installation
echo "🔍 Verifying installed Kubernetes components..."
dpkg -l | grep -E "kubeadm|kubelet|kubectl"

echo "✅ All installations complete."

EOF

chmod +x "$INSTALL_SCRIPT"

# ✅ **Generate SHA256 Checksum**
echo "📝 Generating SHA256 checksum file: $CHECKSUM_FILE"
sha256sum "$TAR_FILE" "$INSTALL_SCRIPT" > "$CHECKSUM_FILE"

# ✅ **Generate Dependencies YAML**
echo "📝 Generating dependencies.yaml..."
echo "# Kubernetes Dependencies for $OS (K8S v$K8S_VERSION)" > "$DEPENDENCIES_FILE"
echo "kubeadm: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubelet: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubectl: $K8S_VERSION" >> "$DEPENDENCIES_FILE"

echo "✅ Installation complete."
