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
DEB_DIR="$ARTIFACTS_DIR/deb-packages"

mkdir -p "$ARTIFACTS_DIR" "$DEB_DIR"

# Define artifact filenames
TAR_FILE="$ARTIFACTS_DIR/offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="$ARTIFACTS_DIR/install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="$ARTIFACTS_DIR/checksums_${OS}_${K8S_VERSION}.sha256"
DEPENDENCIES_FILE="$ARTIFACTS_DIR/dependencies.yaml"

# Validate OS
if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    echo "❌ ERROR: Unsupported OS: $OS"
    exit 1
fi

# ✅ **Step 1: Add Kubernetes APT Repo**
echo "🔗 Adding Kubernetes repository for $OS..."
apt-get update
apt-get install -y apt-transport-https ca-certificates curl gnupg

mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
chmod 644 /etc/apt/sources.list.d/kubernetes.list
apt-get update -y

# ✅ **Step 2: Install Kubernetes (for version validation)**
echo "📦 Installing Kubernetes version $K8S_VERSION..."
apt-get install -y --allow-downgrades --allow-change-held-packages kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool

# ✅ **Step 3: Download Exact Package Versions (All Dependencies)**
echo "📥 Fetching Kubernetes and dependencies for offline installation..."

# Define required packages
KUBE_PACKAGES="kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack iptables iproute2 ethtool"

# ✅ Fix permissions for apt downloads
echo "🔧 Fixing permissions for APT downloads..."
chmod -R a+rwx /var/cache/apt/archives
chown -R _apt:root /var/cache/apt/archives

# **Download all packages (ignoring cache)**
echo "📥 Downloading Kubernetes packages..."
apt-get download --allow-downgrades --allow-change-held-packages $KUBE_PACKAGES

# **Recursively fetch dependencies for each package**
for pkg in $KUBE_PACKAGES; do
    echo "📥 Downloading dependencies for: $pkg"
    
    # Fix permissions before downloading
    chmod -R a+rwx /var/cache/apt/archives
    chown -R _apt:root /var/cache/apt/archives

    # Download dependencies recursively
    DEPS=$(apt-cache depends --recurse --no-suggests --no-conflicts --no-replaces --no-breaks --no-enhances --no-pre-depends "$pkg" | grep "^\w" | sort -u)
    
    apt-get download --allow-downgrades --allow-change-held-packages $DEPS || echo "⚠️ Warning: Some dependencies could not be downloaded"
done

# ✅ Move all downloaded `.deb` files to artifacts
mv *.deb "$DEB_DIR"

# ✅ **Step 4: Create offline package archive**
echo "📦 Creating offline package archive: $TAR_FILE"
tar --exclude="*/partial/*" --ignore-failed-read -czvf "$TAR_FILE" -C "$DEB_DIR" .

# ✅ **Step 5: Generate Install Script**
echo "📝 Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e  # Stop on first error

echo "🚀 Debugging: Installing only available .deb files from /test-env/artifacts/"

# 📂 List all .deb files to verify what's available
echo "📂 Listing all .deb files in /test-env/artifacts/:"
find /test-env/artifacts/ -type f -name "*.deb" -print

# 🔧 Fix permissions for .deb packages
echo "🔧 Fixing permissions for .deb packages..."
chmod -R u+rwX /test-env/artifacts  # Ensure read/write/execute permissions
ls -lah /test-env/artifacts  # Verify ownership & permissions

# ✅ Validate that .deb files exist before proceeding
if ! find /test-env/artifacts/ -type f -name "*.deb" | grep -q .; then
    echo "❌ ERROR: No .deb packages found! Exiting..."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 📦 **Installing only available .deb packages**
echo "📦 Installing .deb packages found in /test-env/artifacts/..."
find /test-env/artifacts/ -type f -name "*.deb" -exec dpkg -i {} + || echo "⚠️ Warning: Some packages may have failed to install."

# 🔧 **Fix any broken dependencies (but only using local files)**
echo "🔧 Checking for missing dependencies..."
if ! apt-get --dry-run install --fix-broken | grep -q "0 newly installed"; then
    echo "⚠️ Warning: Some dependencies may still be missing!"
    echo "🔎 Listing missing dependencies:"
    apt-get --dry-run install --fix-broken | grep "Depends:" || echo "✅ No missing dependencies found."
else
    echo "✅ No missing dependencies detected."
fi

# 🔄 **Configure unconfigured packages**
echo "🔄 Configuring unconfigured packages..."
dpkg --configure -a || echo "⚠️ Warning: Some packages may still be unconfigured."

# 🔍 **Verify installed Kubernetes components**
echo "🔍 Verifying installed Kubernetes components..."
dpkg -l | grep -E "kubeadm|kubelet|kubectl|containerd" || echo "⚠️ Warning: Some Kubernetes components may not be installed."

echo "✅ Validation complete."


EOF

chmod +x "$INSTALL_SCRIPT"

# ✅ **Step 6: Generate SHA256 Checksum**
echo "🔍 Generating SHA256 checksum file: $CHECKSUM_FILE"
sha256sum "$TAR_FILE" "$INSTALL_SCRIPT" > "$CHECKSUM_FILE"

# ✅ **Step 7: Generate dependencies.yaml**
echo "📜 Generating dependencies.yaml..."
echo "# Kubernetes Dependencies for $OS (K8S v$K8S_VERSION)" > "$DEPENDENCIES_FILE"
echo "kubeadm: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubelet: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubectl: $K8S_VERSION" >> "$DEPENDENCIES_FILE"

echo "✅ Kubernetes Offline Build Complete."
