#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-to-video> [bucket-key-name]"
  exit 1
fi

FILE=$1
KEY=${2:-$(basename "$FILE")}

[ ! -f "$FILE" ] && { echo "File not found: $FILE"; exit 1; }

pkill -f "kubectl port-forward.*minio.*9000" 2>/dev/null || true
kubectl port-forward -n "$NAMESPACE" svc/minio 9000:9000 > /tmp/pf-upload.log 2>&1 &
PF_PID=$!
sleep 3

mc alias set ffmpeg-stress http://localhost:9000 "$MINIO_USER" "$MINIO_PASSWORD" 2>/dev/null
mc cp "$FILE" "ffmpeg-stress/videos-input/$KEY"
mc ls ffmpeg-stress/videos-input/

kill $PF_PID 2>/dev/null || true
echo "Uploaded as: $KEY"
