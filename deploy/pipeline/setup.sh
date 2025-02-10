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
set -e  # Stop on first error

echo "🚀 Debugging: Searching for all .deb files"

# 📂 Print directory tree for debugging
echo "📂 Listing all files recursively from /test-env/artifacts/:"
find /test-env/artifacts/ -type f -print

echo "🔧 Fixing permissions for .deb packages..."
chmod -R u+rwX /test-env/artifacts  # Give user read/write/execute permissions
ls -lah /test-env/artifacts # Verify ownership & permissions

# 🔎 Use 'find' and directly write to paths.txt (avoids variable issues)
echo "🔍 Searching for .deb files..."
find /test-env/artifacts/ -type f -name "*.deb" -print > /test-env/artifacts/paths.txt 2>/dev/null

# 📂 Print paths.txt content to verify it was correctly written
echo "📝 Verifying paths.txt contents..."
cat /test-env/artifacts/paths.txt || echo "❌ ERROR: paths.txt not found!"

# ✅ Check if paths.txt is non-empty
if [[ ! -s /test-env/artifacts/paths.txt ]]; then
    echo "❌ ERROR: No .deb packages found! paths.txt is empty."
    exit 1
fi

echo "✅ Successfully saved .deb file paths:"
cat /test-env/artifacts/paths.txt

# 🚀 INSTALLING PACKAGES
echo "📦 Beginning installation of .deb packages..."

echo "🚀 Starting installation of .deb packages..."

# Ensure paths.txt exists and is not empty
if [[ ! -s /test-env/artifacts/paths.txt ]]; then
    echo "❌ ERROR: paths.txt is missing or empty! Exiting..."
    exit 1
fi

echo "📝 Verifying paths.txt contents before reading..."
cat -A /test-env/artifacts/paths.txt  # Shows hidden characters like ^M (Windows newlines)

# 🔄 Convert file to clean Unix format (force removal of Windows line endings)
echo "🔄 Cleaning up paths.txt to ensure proper line endings..."
sed -i 's/\r$//' /test-env/artifacts/paths.txt  # Remove carriage returns
sed -i 's/[[:space:]]*$//' /test-env/artifacts/paths.txt  # Remove trailing spaces

echo "📝 Verifying paths.txt contents after fix..."
cat -A /test-env/artifacts/paths.txt  # Verify changes applied

echo "📦 Beginning installation of .deb packages..."
while IFS= read -r PACKAGE_PATH || [[ -n "$PACKAGE_PATH" ]]; do
    echo "🔹 Debug: Read raw line -> '$PACKAGE_PATH'"

    # Strip out remaining unwanted characters
    PACKAGE_PATH=$(echo "$PACKAGE_PATH" | tr -d '\r' | xargs)

    # Skip empty lines
    if [[ -z "$PACKAGE_PATH" ]]; then
        echo "⚠️ Skipping empty line"
        continue
    fi

    # 🚨 Verify the file exists
    if [[ ! -f "$PACKAGE_PATH" ]]; then
        echo "❌ ERROR: File not found - $PACKAGE_PATH"
        continue
    fi

    echo "✅ Installing: $PACKAGE_PATH"
    dpkg -i "$PACKAGE_PATH" || echo "⚠️ Warning: Failed to install $PACKAGE_PATH"

    echo "-----------------------------------"
done < cat /test-env/artifacts/paths.txt  # Ensures it's read as expected

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

echo "Installation complete."
