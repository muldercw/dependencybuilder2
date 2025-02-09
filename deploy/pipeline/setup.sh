#!/bin/bash
set -e

OS=$1
K8S_VERSION=$2

# 🔧 Remove any extra quotes around the Kubernetes version
K8S_VERSION=$(echo "$K8S_VERSION" | tr -d '"')

# 🔧 Extract only major.minor version for repo setup (e.g., "1.29" from "1.29.13")
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)

echo "Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION (Repo version: $K8S_MAJOR_MINOR)"

# Validate Kubernetes Version
if [[ -z "$K8S_VERSION" ]]; then
    echo "Error: Kubernetes version is not set! Ensure the GitHub Actions workflow is correctly passing it."
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

# Define package manager commands
declare -A OS_MAP
OS_MAP[ubuntu]="apt"
OS_MAP[debian]="apt"
OS_MAP[almalinux]="dnf"
OS_MAP[centos]="dnf"
OS_MAP[rocky]="dnf"
OS_MAP[fedora]="dnf"
OS_MAP[arch]="pacman"
OS_MAP[opensuse]="zypper"

declare -A INSTALL_CMDS
INSTALL_CMDS[apt]="dpkg -i"
INSTALL_CMDS[dnf]="dnf install -y"
INSTALL_CMDS[pacman]="pacman -U --noconfirm"
INSTALL_CMDS[zypper]="zypper install --no-confirm"

# Validate OS
if [[ -z "${OS_MAP[$OS]}" ]]; then
    echo "Unsupported OS: $OS"
    exit 1
fi

PKG_MANAGER="${OS_MAP[$OS]}"
INSTALL_CMD="${INSTALL_CMDS[$PKG_MANAGER]}"

# Validate Kubernetes repository URL before proceeding
KUBE_URL="https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key"

if ! curl -IfsSL "$KUBE_URL"; then
    echo "Error: The Kubernetes repository URL returned 403 Forbidden!"
    echo "Check if Kubernetes version '$K8S_MAJOR_MINOR' exists."
    exit 1
fi

# Add Kubernetes repository
echo "Adding Kubernetes repository for $OS..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL "$KUBE_URL" | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -y
fi

# Install Kubernetes Components
echo "Installing Kubernetes components for $OS..."
sudo apt-get install -y --allow-downgrades kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack

# ✅ Fix permission errors by ignoring inaccessible files
echo "Creating offline package archive: $TAR_FILE"
sudo tar --exclude="*/partial/*" --ignore-failed-read -czf "$TAR_FILE" /var/cache/apt/archives || echo "Warning: No APT cache found for offline packages."

# ✅ Generate install script
echo "Generating installation script: $INSTALL_SCRIPT"
cat <<EOF > "$INSTALL_SCRIPT"
#!/bin/bash
set -e

echo "Installing offline Kubernetes for ubuntu (v${K8S_VERSION})"

# Detect if running inside a container
if [ -f /.dockerenv ]; then
    echo "Detected container environment. Running without sudo..."
    SUDO=""
else
    SUDO="sudo"
fi

# 🔍 Debug: List all files in artifacts directory
echo "📂 Listing all files and subdirectories in /test-env/artifacts/ before installation:"
ls -lahR /test-env/artifacts/

# 🛠 Ensure the correct directory exists before searching
DEB_DIR="/test-env/artifacts/var/cache/apt/archives"
if [[ ! -d "$DEB_DIR" ]]; then
    echo "❌ Error: Expected package directory $DEB_DIR does not exist!"
    exit 1
fi

# 🔎 Search for .deb packages in the correct directory
echo "🔎 Searching for .deb packages in $DEB_DIR ..."
DEB_FILES=$(find "$DEB_DIR" -type f -name "*.deb")

# 🔍 Ensure we found valid .deb files
if [[ -z "$DEB_FILES" ]]; then
    echo "⚠️ Warning: No .deb packages found in $DEB_DIR! Skipping offline installation."
    exit 0
fi

# 📦 Print found .deb files before installation
echo "📦 Found the following .deb files:"
echo "$DEB_FILES"

# 🔽 Install each .deb package
for file in $DEB_FILES; do
    if [[ -f "$file" ]]; then
        echo "📦 Installing: $file"
        $SUDO dpkg -i "$file" || true  # Continue even if some dependencies are missing
    else
        echo "⚠️ Warning: Skipping invalid file path: '$file'"
    fi
done

# 🔧 Fix missing dependencies
echo "🔧 Resolving dependencies..."
$SUDO apt-get install -f -y

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

echo "Installation complete."
