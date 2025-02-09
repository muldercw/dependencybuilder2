#!/bin/bash
set -e

OS=$1
K8S_VERSION=$2
DEP_FILE="dependencies.yaml"
PKG_DIR="offline_packages"
ARCHIVE_FILE="offline_packages_${OS}_${K8S_VERSION}.tar.gz"
INSTALL_SCRIPT="install_${OS}_${K8S_VERSION}.sh"
CHECKSUM_FILE="checksums_${OS}_${K8S_VERSION}.sha256"

echo "Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION"

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

# Add Kubernetes repository
echo "Adding Kubernetes repository for $OS..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

    # Create keyring directory if needed
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    # Add repository
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -y

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF
    sudo dnf makecache

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    sudo pacman-key --init
    sudo pacman-key --recv-keys 3E1BA8D5E6EBF356
    sudo pacman-key --lsign-key 3E1BA8D5E6EBF356
    echo "[kubernetes]
Server = https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/arch/" | sudo tee -a /etc/pacman.conf
    sudo pacman -Sy --noconfirm

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    sudo zypper addrepo -g -f https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/ kubernetes
    sudo zypper refresh
fi

# Create directory for offline package downloads
mkdir -p $PKG_DIR

# Download dependencies including containerd
echo "Downloading dependencies for Kubernetes and containerd..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    sudo apt install -y containerd kubeadm kubelet kubectl
    apt-get download kubeadm kubelet kubectl containerd -o Dir::Cache::Archives=./$PKG_DIR

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    sudo dnf install -y containerd kubeadm kubelet kubectl
    dnf download --destdir=./$PKG_DIR containerd kubeadm kubelet kubectl

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    sudo pacman -Sy --noconfirm containerd kubeadm kubelet kubectl
    pacman -Sw --noconfirm --cachedir=./$PKG_DIR containerd kubeadm kubelet kubectl

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    sudo zypper install -y containerd kubeadm kubelet kubectl
    zypper download -d --destdir=./$PKG_DIR containerd kubeadm kubelet kubectl
fi

# Archive the offline package directory
tar -czvf $ARCHIVE_FILE -C $PKG_DIR .

echo "Offline package archive created: $ARCHIVE_FILE"

# Generate the offline installation script
echo "#!/bin/bash
set -e
echo \"Starting offline installation for $OS with Kubernetes $K8S_VERSION...\"

# Extract the package archive
mkdir -p offline_packages
tar -xzvf $ARCHIVE_FILE -C offline_packages

# Install all downloaded packages
echo \"Installing packages...\"
sudo $INSTALL_CMD offline_packages/*.{deb,rpm,pkg.tar.zst}

# Configure containerd
echo \"Configuring containerd...\"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo \"Installation complete.\"

# Verify Kubernetes installation
echo \"Verifying Kubernetes installation...\"
kubeadm version
kubectl version --client
kubelet --version
containerd --version
" > $INSTALL_SCRIPT

chmod +x $INSTALL_SCRIPT
echo "Installation script created: $INSTALL_SCRIPT"

# Generate SHA256 checksum
sha256sum $ARCHIVE_FILE $INSTALL_SCRIPT > $CHECKSUM_FILE
echo "Checksums generated: $CHECKSUM_FILE"

# Cleanup
docker stop kube-container
