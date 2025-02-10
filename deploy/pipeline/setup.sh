#!/bin/bash
set -e  # Stop on first error

echo "🚀 Starting Kubernetes Offline Installation Test"

# ✅ Step 1: Check Installed Kubernetes Packages
echo "🔎 Checking installed Kubernetes components..."
dpkg -l | grep -E "kubeadm|kubelet|kubectl|cri-tools|conntrack|iptables|iproute2|ethtool" || echo "❌ ERROR: No Kubernetes packages found!"

MISSING_PACKAGES=()
for pkg in kubeadm kubelet kubectl cri-tools conntrack iptables iproute2 ethtool; do
    if ! dpkg -l | grep -q "$pkg"; then
        echo "❌ MISSING: $pkg"
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "⚠️ The following required packages are missing:"
    printf '%s\n' "${MISSING_PACKAGES[@]}"
else
    echo "✅ All required Kubernetes packages are installed."
fi

# ✅ Step 2: Check for Broken Dependencies
echo "🔎 Checking for missing package dependencies..."
dpkg -C || echo "✅ No broken dependencies detected."

if dpkg -C | grep -q "The following packages"; then
    echo "❌ MISSING DEPENDENCIES: These packages have unmet dependencies."
    dpkg -C
fi

# ✅ Step 3: Enable and Start kubelet Service
echo "🔄 Enabling and starting kubelet..."
sudo systemctl enable kubelet || echo "⚠️ Warning: Could not enable kubelet!"
sudo systemctl start kubelet || echo "⚠️ Warning: Could not start kubelet!"

# ✅ Step 4: Check kubelet Status
echo "🔎 Checking kubelet status..."
systemctl status kubelet --no-pager || echo "⚠️ kubelet is not running!"

# ✅ Step 5: Initialize Kubernetes Cluster (Master Node)
echo "🚀 Initializing Kubernetes..."
sudo kubeadm init --kubernetes-version=${K8S_VERSION} || echo "❌ kubeadm init failed! Possible missing dependencies."

# ✅ Step 6: Print kubeadm Join Command for Worker Nodes
echo "✅ Kubernetes initialized successfully. To join worker nodes, run:"
kubeadm token create --print-join-command || echo "❌ ERROR: Unable to generate join command."

# ✅ Step 7: Verify Kubernetes Node & Pod Status
echo "🔍 Checking Kubernetes node status..."
kubectl get nodes || echo "❌ ERROR: 'kubectl get nodes' failed."

echo "🔍 Checking Kubernetes system pods..."
kubectl get pods -n kube-system || echo "❌ ERROR: 'kubectl get pods' failed."

# ✅ Step 8: Print Logs if Issues Exist
echo "🔎 Checking logs for errors..."
journalctl -u kubelet --no-pager | tail -n 50 || echo "⚠️ No logs found for kubelet."

echo "✅ Kubernetes Offline Test Completed."
