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

# Ensure required package managers are installed
if [[ "$PKG_MANAGER" == "dnf" ]] && ! command -v dnf &> /dev/null; then
    echo "dnf is missing! Installing..."
    sudo yum install -y dnf || sudo apt install -y dnf || echo "Could not install dnf!"
elif [[ "$PKG_MANAGER" == "zypper" ]] && ! command -v zypper &> /dev/null; then
    echo "zypper is missing! Installing..."
    sudo apt install -y zypper || sudo pacman -Sy --noconfirm zypper || echo "Could not install zypper!"
elif [[ "$PKG_MANAGER" == "pacman" ]] && ! command -v pacman &> /dev/null; then
    echo "pacman is missing! Installing..."
    sudo apt install -y pacman || echo "Could not install pacman!"
fi

# Validate Kubernetes Version Before Proceeding
if [[ -z "$K8S_VERSION" ]]; then
    echo "Error: Kubernetes version is not set! Check your kubeversion.yaml file."
    exit 1
fi

# Add Kubernetes repository
echo "Adding Kubernetes repository for $OS..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    sudo apt-get update
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

    sudo mkdir -p -m 755 /etc/apt/keyrings
    echo "Validating Kubernetes repository URL..."
    
    KUBE_URL="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key"

    if ! curl -IfsSL "$KUBE_URL"; then
        echo "Error: The Kubernetes repository URL returned 403 Forbidden!"
        echo "Check if Kubernetes version '$K8S_VERSION' exists."
        exit 1
    fi

    echo "Downloading Kubernetes repository key..."
    curl -fsSL "$KUBE_URL" | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update -y

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    sudo mkdir -p /etc/yum.repos.d
    echo -e "[kubernetes]\nname=Kubernetes\nbaseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key" | sudo tee /etc/yum.repos.d/kubernetes.repo
    sudo dnf makecache

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    sudo mkdir -p /etc/zypp/repos.d
    echo "[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key" | sudo tee /etc/zypp/repos.d/kubernetes.repo
    sudo zypper refresh

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    sudo pacman-key --init
    sudo pacman-key --recv-keys 3E1BA8D5E6EBF356
    sudo pacman-key --lsign-key 3E1BA8D5E6EBF356
    echo "[kubernetes]
Server = https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/arch/" | sudo tee -a /etc/pacman.conf
    sudo pacman -Sy --noconfirm
fi

# Download dependencies including containerd
mkdir -p $PKG_DIR
echo "Downloading dependencies for Kubernetes and containerd..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    sudo apt install -y containerd kubeadm kubelet kubectl
    apt-get download kubeadm kubelet kubectl containerd -o Dir::Cache::Archives=./$PKG_DIR

elif [[ "$PKG_MANAGER" == "dnf" || "$PKG_MANAGER" == "zypper" ]]; then
    sudo $PKG_MANAGER install -y containerd kubeadm kubelet kubectl
    sudo $PKG_MANAGER download --destdir=./$PKG_DIR containerd kubeadm kubelet kubectl

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    sudo pacman -Sy --noconfirm containerd kubeadm kubelet kubectl
    pacman -Sw --noconfirm --cachedir=./$PKG_DIR containerd kubeadm kubelet kubectl
fi

# Archive the offline package directory
tar -czvf $ARCHIVE_FILE -C $PKG_DIR .

echo "Offline package archive created: $ARCHIVE_FILE"
