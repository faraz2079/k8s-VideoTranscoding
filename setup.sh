#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "[!] .env not found. Copying from .env.example..."
  cp .env.example .env
  echo "[!] Edit .env if needed, then re-run ./setup.sh"
  exit 1
fi

set -a; source .env; set +a

echo "Setup: namespace=$NAMESPACE  image=$IMAGE"

render() {
  sed -e "s|__NAMESPACE__|$NAMESPACE|g" \
      -e "s|__IMAGE__|$IMAGE|g" \
      -e "s|__WORKER_REPLICAS__|$WORKER_REPLICAS|g" \
      -e "s|__WORKER_CPU_REQUEST__|$WORKER_CPU_REQUEST|g" \
      -e "s|__WORKER_CPU_LIMIT__|$WORKER_CPU_LIMIT|g" \
      -e "s|__WORKER_MEM_REQUEST__|$WORKER_MEM_REQUEST|g" \
      -e "s|__WORKER_MEM_LIMIT__|$WORKER_MEM_LIMIT|g" \
      -e "s|__MINIO_USER__|$MINIO_USER|g" \
      -e "s|__MINIO_PASSWORD__|$MINIO_PASSWORD|g" \
      "$1" > "$2"
}

mkdir -p .rendered
render manifests/namespace.yaml                  .rendered/namespace.yaml
render manifests/minio.yaml                      .rendered/minio.yaml
render manifests/redis.yaml                      .rendered/redis.yaml
render manifests/worker-deployment.yaml.template .rendered/worker-deployment.yaml

echo "[1/6] Namespace..."
kubectl apply -f .rendered/namespace.yaml

echo "[2/6] Building image..."
docker build -t "$IMAGE" worker/

if [ "${PUSH_IMAGE:-false}" = "true" ]; then
  echo "[3/6] Pushing image..."
  docker push "$IMAGE"
fi

echo "[4/6] Deploying MinIO and Redis..."
kubectl apply -f .rendered/minio.yaml
kubectl apply -f .rendered/redis.yaml
kubectl rollout status deployment/minio -n "$NAMESPACE" --timeout=120s
kubectl rollout status deployment/redis -n "$NAMESPACE" --timeout=60s

echo "[5/6] Deploying worker (scaled to 0)..."
kubectl apply -f .rendered/worker-deployment.yaml
kubectl scale deployment ffmpeg-worker -n "$NAMESPACE" --replicas=0

echo "[6/6] Creating MinIO buckets..."
pkill -f "kubectl port-forward.*minio" 2>/dev/null || true
kubectl port-forward -n "$NAMESPACE" svc/minio 9000:9000 > /tmp/pf-setup.log 2>&1 &
PF_PID=$!
sleep 4
mc alias set ffmpeg-stress http://localhost:9000 "$MINIO_USER" "$MINIO_PASSWORD" 2>/dev/null || true
mc mb -p ffmpeg-stress/videos-input  2>/dev/null || true
mc mb -p ffmpeg-stress/videos-output 2>/dev/null || true
kill $PF_PID 2>/dev/null || true

if [ ! -f /etc/sudoers.d/ffmpeg-stress ]; then
  echo "Configuring passwordless cleanup commands..."
  cat <<SUDOERS | sudo tee /etc/sudoers.d/ffmpeg-stress > /dev/null
$USER ALL=(ALL) NOPASSWD: /usr/bin/pkill
$USER ALL=(ALL) NOPASSWD: /usr/bin/kill
$USER ALL=(ALL) NOPASSWD: /bin/kill
SUDOERS
  sudo chmod 440 /etc/sudoers.d/ffmpeg-stress

  # Remove the old single-rule file if it exists
  [ -f /etc/sudoers.d/pkill-ffmpeg ] && sudo rm /etc/sudoers.d/pkill-ffmpeg
fi

echo "Setup complete. Next: ./scripts/upload-video.sh /path/to/video.mkv  then  ./run.sh"
