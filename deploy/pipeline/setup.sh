#!/bin/bash
set -e  # Stop on first error

OS=$1
K8S_VERSION=$2

# 🔧 Remove any extra quotes
K8S_VERSION=$(echo "$K8S_VERSION" | tr -d '"')

# 🔧 Extract only major.minor version (e.g., "1.29" from "1.29.13")
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)

echo "Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION (Repo version: $K8S_MAJOR_MINOR)"

# Validate Kubernetes Version
if [[ -z "$K8S_VERSION" ]]; then
    echo "❌ ERROR: Kubernetes version is not set!"
    exit 1
fi

# Create artifacts directory
ARTIFACTS_DIR="${PWD}/artifacts"
mkdir -p "$ARTIFACTS_DIR"

# Define artifact filenames
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"
DEB_DIR="$ARTIFACTS_DIR/deb-packages"

mkdir -p "$DEB_DIR"

# Validate OS
if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    echo "❌ ERROR: Unsupported OS: $OS"
    exit 1
fi

# Kubernetes APT Repo
echo "Adding Kubernetes repository for $OS..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y

# 🔽 **Download Required Packages & Dependencies**
echo "📦 Downloading Kubernetes and dependencies for offline installation..."

# Define required packages
KUBE_PACKAGES="kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

# Download all packages and dependencies WITHOUT installing
sudo apt-get download $KUBE_PACKAGES

# Download dependencies for each package
for pkg in $KUBE_PACKAGES; do
    sudo apt-get download $(apt-cache depends --recurse --no-suggests --no-conflicts --no-replaces --no-breaks --no-enhances --no-pre-depends "$pkg" | grep "^\w" | sort -u)
done

# Move all downloaded `.deb` files to artifacts
mv *.deb "$DEB_DIR"

# ✅ Create offline package archive
echo "📦 Creating offline package archive: $TAR_FILE"
sudo tar --exclude="*/partial/*" --ignore-failed-read -czvf "$TAR_FILE" -C "$DEB_DIR" .

# ✅ Generate install script
echo "Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "🚀 Debugging: Installing all .deb files recursively"

# 📂 Print directory tree for debugging
echo "📂 Listing all files in /test-env/artifacts/:"
find /test-env/artifacts/ -type f -print

# 🔧 Fix permissions for all .deb files
echo "🔧 Fixing permissions for .deb packages..."
chmod -R u+rwX /test-env/artifacts  # Ensure read/write/execute permissions
ls -lah /test-env/artifacts  # Verify ownership & permissions

# ✅ Install all packages with dependencies
echo "📦 Installing all .deb packages..."
dpkg -R --install /test-env/artifacts/ || echo "⚠️ Warning: Some packages may have failed to install."

echo "✅ All installations complete."
EOF

chmod +x "$INSTALL_SCRIPT"

# ✅ Generate SHA256 checksum
echo "Generating SHA256 checksum file: $CHECKSUM_FILE"
sha256sum "$TAR_FILE" "$INSTALL_SCRIPT" > "$CHECKSUM_FILE"

# ✅ Generate dependencies.yaml
echo "Generating dependencies.yaml..."
echo "# Kubernetes Dependencies for $OS (K8S v$K8S_VERSION)" > "$DEPENDENCIES_FILE"
echo "kubeadm: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubelet: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubectl: $K8S_VERSION" >> "$DEPENDENCIES_FILE"

echo "✅ Installation complete."
