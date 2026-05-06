#!/bin/bash
set -u
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "[!] .env not found. Run ./setup.sh first."
  exit 1
fi

set -a; source .env; set +a

NUM_JOBS=${1:-${DEFAULT_JOBS:-6}}
MAX_DURATION=${2:-${DEFAULT_DURATION:-1800}}
VIDEO=${3:-${DEFAULT_VIDEO:-bbunny_4k.mkv}}
NS=$NAMESPACE
DESIRED_REPLICAS=$WORKER_REPLICAS

TS=$(date +%Y%m%d-%H%M%S)
OUT="$PWD/runs/run-$TS"
mkdir -p "$OUT"

echo "Run: $TS  Video: $VIDEO  Jobs: $NUM_JOBS  Max: ${MAX_DURATION}s"

get_active_pods() {
  for pod in $(kubectl get pods -n $NS -l app=ffmpeg-worker --no-headers 2>/dev/null \
               | awk '$3=="Running" {print $1}'); do
    TERM=$(kubectl get pod -n $NS $pod -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
    [ -z "$TERM" ] && echo "$pod"
  done
}

do_cleanup() {
  echo "[CLEANUP] === Starting cleanup for $NS ==="

  # Step 1: Scale workers to 0, clear queue
  echo "[CLEANUP] Scaling workers to 0..."
  kubectl scale deployment ffmpeg-worker -n $NS --replicas=0 > /dev/null 2>&1 || true
  echo "[CLEANUP] Clearing queue..."
  kubectl exec -n $NS deploy/redis -- redis-cli DEL transcoding-jobs > /dev/null 2>&1 || true

  # Step 2: Brief grace wait
  echo "[CLEANUP] Waiting up to 30s for graceful termination..."
  kubectl wait --for=delete pods -l app=ffmpeg-worker -n $NS --timeout=30s 2>/dev/null || true

  # Step 3: Force-delete any pod still terminating
  STUCK=$(kubectl get pods -n $NS -l app=ffmpeg-worker --no-headers 2>/dev/null | grep Terminating | awk '{print $1}')
  if [ -n "$STUCK" ]; then
    echo "[CLEANUP] Force-deleting stuck pods: $STUCK"
    for pod in $STUCK; do
      kubectl delete pod $pod -n $NS --grace-period=0 --force 2>/dev/null || true
    done
    sleep 3
  fi

  # Step 4: Kill leftover ffmpeg processes (real ffmpeg, not conmon)
  echo "[CLEANUP] Killing leftover ffmpeg processes..."
  for attempt in 1 2 3 4 5; do
    REMAINING=$(pgrep -x ffmpeg 2>/dev/null | wc -l)
    [ "$REMAINING" = "0" ] && break
    sudo pkill -9 -x ffmpeg 2>/dev/null || true
    sleep $attempt
  done
  REMAINING=$(pgrep -x ffmpeg 2>/dev/null | wc -l)
  echo "[CLEANUP] Leftover ffmpeg processes: $REMAINING"

  # Step 5: Clean up stale conmon helpers
  STALE_CONMON=$(ps -eo pid,cmd 2>/dev/null | grep conmon | grep ffmpeg-worker | grep -v grep | awk '{print $1}')
  if [ -n "$STALE_CONMON" ]; then
    echo "[CLEANUP] Cleaning up stale conmon helpers..."
    sudo kill -9 $STALE_CONMON 2>/dev/null || true
  fi

  # Step 6: Report
  echo
  echo "[CLEANUP] === Final state ==="
  kubectl get pods -n $NS 2>/dev/null
  echo
  free -h
  echo
  echo "[CLEANUP] Done."
}

if ! kubectl get namespace $NS > /dev/null 2>&1; then
  echo "[!] Namespace not found. Run ./setup.sh first."
  exit 1
fi

CURRENT_REPLICAS=$(kubectl get deployment ffmpeg-worker -n $NS -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
if [ "${CURRENT_REPLICAS:-0}" -lt $DESIRED_REPLICAS ]; then
  echo "Scaling workers to $DESIRED_REPLICAS..."
  kubectl scale deployment ffmpeg-worker -n $NS --replicas=$DESIRED_REPLICAS > /dev/null
  kubectl rollout status deployment/ffmpeg-worker -n $NS --timeout=120s
fi

{
  kubectl get pods -n $NS -o wide
  echo
  kubectl get deployment ffmpeg-worker -n $NS -o yaml
} > "$OUT/00-initial-state.txt" 2>&1

echo "Submitting $NUM_JOBS jobs..."
kubectl exec -n $NS deploy/redis -- redis-cli DEL transcoding-jobs > /dev/null
for i in $(seq 1 $NUM_JOBS); do
  kubectl exec -n $NS deploy/redis -- redis-cli RPUSH transcoding-jobs "{\"file\":\"$VIDEO\"}" > /dev/null
done

LOG_PIDS=()
sleep 3
for pod in $(get_active_pods); do
  kubectl logs -n $NS $pod -f --tail=200 > "$OUT/log-$pod.txt" 2>&1 &
  LOG_PIDS+=($!)
done

METRIC_FILE="$OUT/metrics.log"
SUMMARY_FILE="$OUT/summary.csv"
echo "timestamp,elapsed_s,node_cpu_m,node_mem_mi,queue_len,worker_pods,total_worker_cpu_m,total_worker_mem_mi" > "$SUMMARY_FILE"

START_TS=$(date +%s)
IDLE_COUNT=0

on_interrupt() {
  echo
  echo "Interrupted. Cleaning up..."
  for pid in "${LOG_PIDS[@]}"; do kill $pid 2>/dev/null; done
  finish_run
  exit 0
}
trap on_interrupt INT TERM

finish_run() {
  {
    kubectl get pods -n $NS -o wide
    echo
    for pod in $(kubectl get pods -n $NS -l app=ffmpeg-worker --no-headers 2>/dev/null | awk '{print $1}'); do
      echo "--- $pod ---"
      kubectl describe pod -n $NS $pod | grep -A 8 -E "Last State|Restart Count|Limits|Requests"
    done
    mc ls ffmpeg-stress/videos-output 2>/dev/null
  } > "$OUT/99-final-state.txt" 2>&1

  for pid in "${LOG_PIDS[@]}"; do kill $pid 2>/dev/null; done
  do_cleanup

  bash "$PWD/scripts/analyze-run.sh" "$OUT" | tee "$OUT/SUMMARY.txt"

  echo "EXPERIMENT COMPLETE  Results: $OUT"
  ls -1 "$OUT" | sed 's/^/  - /'
}

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))

  if [ $ELAPSED -gt $MAX_DURATION ]; then
    echo "Timeout."
    break
  fi

  TIMESTAMP=$(date +%H:%M:%S)
  NODE_LINE=$(kubectl top nodes --no-headers 2>/dev/null | head -1)
  NODE_CPU=$(echo "$NODE_LINE" | awk '{print $2}' | sed 's/m$//')
  NODE_MEM=$(echo "$NODE_LINE" | awk '{print $4}' | sed 's/Mi$//')
  QLEN=$(kubectl exec -n $NS deploy/redis -- redis-cli LLEN transcoding-jobs 2>/dev/null)
  WORKER_LINES=$(kubectl top pods -n $NS --no-headers 2>/dev/null | grep ffmpeg-worker)
  WORKER_COUNT=$(echo "$WORKER_LINES" | grep -c ffmpeg-worker)
  WORKER_CPU=$(echo "$WORKER_LINES" | awk '{gsub("m","",$2); sum+=$2} END {print sum+0}')
  WORKER_MEM=$(echo "$WORKER_LINES" | awk '{gsub("Mi","",$3); sum+=$3} END {print sum+0}')

  {
    echo "=== $TIMESTAMP (elapsed=${ELAPSED}s) ==="
    kubectl top nodes 2>/dev/null
    kubectl top pods -n $NS 2>/dev/null
    echo "Queue: $QLEN"
    echo
  } >> "$METRIC_FILE"

  echo "$TIMESTAMP,$ELAPSED,$NODE_CPU,$NODE_MEM,$QLEN,$WORKER_COUNT,$WORKER_CPU,$WORKER_MEM" >> "$SUMMARY_FILE"

  printf "[%s] elapsed=%-5ss queue=%-3s node_cpu=%-6sm node_mem=%-6sMi worker_cpu=%-6sm worker_mem=%-6sMi\n" \
    "$TIMESTAMP" "$ELAPSED" "$QLEN" "$NODE_CPU" "$NODE_MEM" "$WORKER_CPU" "$WORKER_MEM"

  if [ $ELAPSED -gt ${MIN_RUNTIME:-120} ] && [ "$QLEN" = "0" ] && [ "${WORKER_CPU:-0}" -lt 200 ]; then
    IDLE_COUNT=$((IDLE_COUNT + 1))
    if [ $IDLE_COUNT -ge 6 ]; then
      echo "Done."
      break
    fi
  else
    IDLE_COUNT=0
  fi

  sleep ${SAMPLE_INTERVAL:-5}
done

finish_run
