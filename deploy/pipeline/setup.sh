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
APT_OFFLINE_DIR="$ARTIFACTS_DIR/apt-offline"
mkdir -p "$ARTIFACTS_DIR" "$APT_OFFLINE_DIR"

# ✅ Define filenames
APT_UPDATE_SIG="$APT_OFFLINE_DIR/apt-offline-update.sig"
APT_PACKAGE_SIG="$APT_OFFLINE_DIR/apt-offline-packages.sig"
APT_DOWNLOADS="$APT_OFFLINE_DIR/apt-offline-downloads"
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"

# ✅ Ensure apt-offline is installed on the offline PC
echo "📦 Ensuring apt-offline is installed..."
if ! command -v apt-offline &> /dev/null; then
    echo "❌ ERROR: apt-offline is not installed. Please install it manually first."
    exit 1
fi

# ✅ Step 1: Generate Update Signature (on offPC)
echo "📝 Generating apt-offline update request file..."
sudo apt-offline set "$APT_UPDATE_SIG" --update --upgrade --deep-clean

# ✅ Step 2: Generate Package Signature (on offPC)
echo "📝 Generating apt-offline package request file..."
sudo apt-offline set "$APT_PACKAGE_SIG" --install-packages "kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

echo "✅ Move '$APT_UPDATE_SIG' and '$APT_PACKAGE_SIG' to the online computer (onPC)."

# 🚀 **On the Online Computer (onPC)**
echo "🚀 Switching to ONLINE COMPUTER (onPC)..."
echo "📦 Using apt-offline to download updates and packages..."

# ✅ Download all required updates & package dependencies (on onPC)
mkdir -p "$APT_DOWNLOADS"
sudo apt-offline get "$APT_UPDATE_SIG" --threads 4 --bundle "$APT_DOWNLOADS/apt-offline-updates.zip"
sudo apt-offline get "$APT_PACKAGE_SIG" --threads 4 --bundle "$APT_DOWNLOADS/apt-offline-packages.zip"

echo "✅ Move '$APT_DOWNLOADS' folder back to the offline computer (offPC)."

# 🚀 **Back on the Offline Computer (offPC)**
echo "🚀 Switching back to OFFLINE COMPUTER (offPC)..."
echo "📦 Installing updates and packages..."

# ✅ Step 3: Apply Updates (on offPC)
sudo apt-offline install "$APT_DOWNLOADS/apt-offline-updates.zip"

# ✅ Step 4: Install Packages (on offPC)
sudo apt-offline install "$APT_DOWNLOADS/apt-offline-packages.zip"

# ✅ **Create offline package archive**
echo "📦 Creating offline package archive: $TAR_FILE"
tar -czvf "$TAR_FILE" -C "$APT_DOWNLOADS" .

# ✅ **Generate Install Script**
echo "📜 Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "🚀 Installing all .deb files using apt-offline"

# ✅ Suppress frontend issues (Debconf)
export DEBIAN_FRONTEND=noninteractive

# ✅ Apply Updates
echo "📦 Applying updates..."
sudo apt-offline install /test-env/artifacts/apt-offline-updates.zip

# ✅ Install Packages
echo "📦 Installing Kubernetes and dependencies..."
sudo apt-offline install /test-env/artifacts/apt-offline-packages.zip

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
