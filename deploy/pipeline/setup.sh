#!/bin/bash
set -e

OS=$1
K8S_VERSION=$2

# 🔧 Strip any extra quotes around the Kubernetes version
K8S_VERSION=$(echo "$K8S_VERSION" | tr -d '"')

# 🔧 Extract only major.minor version for repo setup (e.g., "1.29" from "1.29.13")
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d'.' -f1,2)

echo "Starting setup for OS: $OS with Kubernetes version: $K8S_VERSION (Repo version: $K8S_MAJOR_MINOR)"

# Validate Kubernetes Version
if [[ -z "$K8S_VERSION" ]]; then
    echo "Error: Kubernetes version is not set! Ensure the GitHub Actions workflow is correctly passing it."
    exit 1
fi

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

# Ensure package managers are installed
if [[ "$PKG_MANAGER" == "dnf" && ! -x "$(command -v dnf)" ]]; then
    echo "Installing dnf..."
    sudo yum install -y dnf || sudo apt install -y dnf || echo "Could not install dnf!"
elif [[ "$PKG_MANAGER" == "zypper" && ! -x "$(command -v zypper)" ]]; then
    echo "Installing zypper..."
    sudo apt install -y zypper || echo "Could not install zypper!"
elif [[ "$PKG_MANAGER" == "pacman" && ! -x "$(command -v pacman)" ]]; then
    echo "Installing pacman..."
    sudo apt install -y pacman || echo "Could not install pacman!"
fi

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

# Download and Install Kubernetes Components
echo "Installing Kubernetes components for $OS..."

if [[ "$PKG_MANAGER" == "apt" ]]; then
    # ✅ Ensure all components use the correct version
    sudo apt-get install -y --allow-downgrades kubeadm=${K8S_VERSION}-1.1 kubelet=${K8S_VERSION}-1.1 kubectl=${K8S_VERSION}-1.1 cri-tools conntrack

    # ✅ Check installed versions
    echo "Checking installed Kubernetes component versions..."
    kubeadm version
    kubectl version --client
    kubelet --version

elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    sudo dnf install -y kubeadm-$K8S_VERSION kubelet-$K8S_VERSION kubectl-$K8S_VERSION cri-tools conntrack
    sudo systemctl enable kubelet

elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    sudo pacman -Sy --noconfirm kubeadm kubelet kubectl cri-tools conntrack-tools
    sudo systemctl enable kubelet

elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    sudo zypper install -y kubeadm kubelet kubectl cri-tools conntrack-tools
    sudo systemctl enable kubelet
fi

# Configure containerd
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# ✅ Generate dependencies.yaml
echo "Generating dependencies.yaml..."

DEPENDENCIES_FILE="dependencies.yaml"

echo "# Kubernetes Dependencies for $OS (K8S v$K8S_VERSION)" > "$DEPENDENCIES_FILE"
echo "kubeadm: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubelet: $K8S_VERSION" >> "$DEPENDENCIES_FILE"
echo "kubectl: $K8S_VERSION" >> "$DEPENDENCIES_FILE"

# ✅ Add OS-specific dependencies
if [[ "$PKG_MANAGER" == "apt" ]]; then
    echo "cri-tools: $(apt-cache madison cri-tools | head -n1 | awk '{print $3}')" >> "$DEPENDENCIES_FILE"
    echo "conntrack: $(apt-cache madison conntrack | head -n1 | awk '{print $3}')" >> "$DEPENDENCIES_FILE"
elif [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo "cri-tools: $(dnf list cri-tools --showduplicates | tail -n1 | awk '{print $2}')" >> "$DEPENDENCIES_FILE"
    echo "conntrack: $(dnf list conntrack --showduplicates | tail -n1 | awk '{print $2}')" >> "$DEPENDENCIES_FILE"
elif [[ "$PKG_MANAGER" == "pacman" ]]; then
    echo "cri-tools: $(pacman -Si cri-tools | grep Version | awk '{print $3}')" >> "$DEPENDENCIES_FILE"
    echo "conntrack: $(pacman -Si conntrack-tools | grep Version | awk '{print $3}')" >> "$DEPENDENCIES_FILE"
elif [[ "$PKG_MANAGER" == "zypper" ]]; then
    echo "cri-tools: $(zypper se -s cri-tools | grep -vE "S | Name" | awk '{print $7}' | head -n1)" >> "$DEPENDENCIES_FILE"
    echo "conntrack: $(zypper se -s conntrack-tools | grep -vE "S | Name" | awk '{print $7}' | head -n1)" >> "$DEPENDENCIES_FILE"
fi

echo "Dependencies file created: $DEPENDENCIES_FILE"
cat "$DEPENDENCIES_FILE"

echo "Installation complete."
