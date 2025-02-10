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

# ✅ Define artifact filenames
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"

# ✅ Validate OS
if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    echo "❌ ERROR: Unsupported OS: $OS"
    exit 1
fi

# ✅ Install Keryx for Dependency Management
echo "📦 Installing Keryx for package downloading..."
sudo apt-get update && sudo apt-get install -y keryx

# ✅ Add Kubernetes APT Repository
echo "📦 Adding Kubernetes repository for $OS..."
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y

# 🚀 **Step 1: Prepare Keryx Package List**
echo "📦 Preparing package list for Kubernetes version $K8S_VERSION..."
PACKAGE_LIST="$ARTIFACTS_DIR/kube-packages.list"

cat <<EOF > "$PACKAGE_LIST"
kubeadm=${K8S_VERSION}-1.1
kubelet=${K8S_VERSION}-1.1
kubectl=${K8S_VERSION}-1.1
cri-tools
conntrack
iptables
iproute2
ethtool
EOF

# 🚀 **Step 2: Use Keryx to Download All Dependencies**
echo "📦 Using Keryx to download all required packages..."
keryx -o "$DEB_DIR" -f "$PACKAGE_LIST"

# ✅ **Create offline package archive**
echo "📦 Creating offline package archive: $TAR_FILE"
tar -czvf "$TAR_FILE" -C "$DEB_DIR" .

# ✅ **Generate Install Script**
echo "📜 Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "🚀 Installing all .deb files using Keryx"

# ✅ Suppress frontend issues (Debconf)
export DEBIAN_FRONTEND=noninteractive

# ✅ Fix permissions for all .deb files
echo "🔧 Fixing permissions for .deb packages..."
chmod -R u+rwX /test-env/artifacts
ls -lah /test-env/artifacts

# ✅ Install all .deb packages using Keryx
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
