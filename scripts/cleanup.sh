#!/bin/bash
# Manual cleanup — fully releases all CPU/RAM held by FFmpeg workers
set -u

cd "$(dirname "$0")/.."
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

NS=$NAMESPACE

echo "[CLEANUP] === Starting cleanup for $NS ==="

echo "[CLEANUP] Scaling workers to 0..."
kubectl scale deployment ffmpeg-worker -n $NS --replicas=0 > /dev/null 2>&1 || true
kubectl exec -n $NS deploy/redis -- redis-cli DEL transcoding-jobs > /dev/null 2>&1 || true

echo "[CLEANUP] Waiting up to 30s for graceful termination..."
kubectl wait --for=delete pods -l app=ffmpeg-worker -n $NS --timeout=30s 2>/dev/null || true

# Force-delete stuck pods
STUCK=$(kubectl get pods -n $NS -l app=ffmpeg-worker --no-headers 2>/dev/null | grep Terminating | awk '{print $1}')
if [ -n "$STUCK" ]; then
  echo "[CLEANUP] Force-deleting stuck pods: $STUCK"
  for pod in $STUCK; do
    kubectl delete pod $pod -n $NS --grace-period=0 --force 2>/dev/null || true
  done
  sleep 3
fi

# Kill leftover ffmpeg processes
echo "[CLEANUP] Killing leftover ffmpeg processes..."
for attempt in 1 2 3 4 5; do
  REMAINING=$(pgrep -x ffmpeg 2>/dev/null | wc -l)
  [ "$REMAINING" = "0" ] && break
  sudo pkill -9 -x ffmpeg 2>/dev/null || true
  sleep $attempt
done
echo "[CLEANUP] Leftover ffmpeg: $(pgrep -x ffmpeg 2>/dev/null | wc -l)"

# Clean up stale conmon helpers
STALE_CONMON=$(ps -eo pid,cmd 2>/dev/null | grep conmon | grep ffmpeg-worker | grep -v grep | awk '{print $1}')
if [ -n "$STALE_CONMON" ]; then
  echo "[CLEANUP] Cleaning up stale conmon helpers..."
  sudo kill -9 $STALE_CONMON 2>/dev/null || true
fi

# Drop OS page cache
echo "[CLEANUP] Dropping OS page cache..."
sudo sync 2>/dev/null || true
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

echo
echo "[CLEANUP] === Final state ==="
kubectl get pods -n $NS 2>/dev/null
echo
free -h
echo
echo "[CLEANUP] Done."
