#!/bin/bash
set -u
cd "$(dirname "$0")"
[ ! -f .env ] && { echo ".env missing"; exit 1; }
set -a; source .env; set +a

echo "This will DELETE the '$NAMESPACE' namespace."
read -p "Continue? (yes/no): " ans
[ "$ans" = "yes" ] || exit 1

kubectl scale deployment ffmpeg-worker -n "$NAMESPACE" --replicas=0 > /dev/null 2>&1 || true
sudo pkill -9 ffmpeg 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" --timeout=120s
rm -rf .rendered
echo "Done."
