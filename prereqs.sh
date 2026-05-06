cat > ~/work/ffmpeg-stress-test/scripts/install-prereqs.sh <<'PREREQ_END'
#!/bin/bash
# ============================================================
#  Install host prerequisites (run once on a new VM)
#  Does NOT install Kubernetes itself — assumes K8s is already running
# ============================================================
set -e

echo "================================================================"
echo "  Installing host prerequisites for FFmpeg stress test"
echo "================================================================"

# 1. Check kubectl
if ! command -v kubectl &> /dev/null; then
  echo "[!] kubectl not found. You need a working Kubernetes cluster first."
  echo "    See: https://kubernetes.io/docs/setup/"
  exit 1
fi
echo "[OK] kubectl: $(kubectl version --client --short 2>/dev/null | head -1)"

# 2. Check Docker
if ! command -v docker &> /dev/null; then
  echo "[INSTALL] Installing Docker..."
  sudo apt-get update
  sudo apt-get install -y docker.io
  sudo usermod -aG docker "$USER"
  echo "[!] You may need to log out and back in for docker group membership"
fi
echo "[OK] docker: $(docker --version)"

# 3. Check MinIO client (mc)
if ! command -v mc &> /dev/null; then
  echo "[INSTALL] Installing mc (MinIO client)..."
  wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /tmp/mc
  chmod +x /tmp/mc
  sudo mv /tmp/mc /usr/local/bin/mc
fi
echo "[OK] mc: $(mc --version | head -1)"

# 4. Check local Docker registry
if ! docker ps --format '{{.Names}}' | grep -q '^registry$'; then
  echo "[INSTALL] Starting local Docker registry on port 5000..."
  docker run -d -p 5000:5000 --restart=always --name registry registry:2
fi
echo "[OK] Local Docker registry running on :5000"

# 5. Check metrics-server
if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  echo "[INSTALL] Installing metrics-server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  echo "[!] Wait ~30 seconds before running setup.sh"
fi
echo "[OK] metrics-server installed"

# 6. Optional: ffprobe (for inspecting videos before upload)
if ! command -v ffprobe &> /dev/null; then
  echo "[INFO] ffprobe not installed — optional, useful for verifying videos before upload"
  echo "       To install: sudo apt install -y ffmpeg"
fi

echo
echo "================================================================"
echo "  Prerequisites OK. Next: ./setup.sh"
echo "================================================================"
PREREQ_END

chmod +x ~/work/ffmpeg-stress-test/scripts/install-prereqs.sh
