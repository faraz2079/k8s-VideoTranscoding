import os, subprocess, redis, tempfile, json, sys, signal, time
from minio import Minio

sys.stdout.reconfigure(line_buffering=True)

REDIS_HOST     = os.environ.get('REDIS_HOST', 'redis')
MINIO_HOST     = os.environ.get('MINIO_HOST', 'minio:9000')
MINIO_USER     = os.environ.get('MINIO_USER', 'admin')
MINIO_PASSWORD = os.environ.get('MINIO_PASSWORD', 'admin12345')
INPUT_BUCKET   = os.environ.get('INPUT_BUCKET',  'videos-input')
OUTPUT_BUCKET  = os.environ.get('OUTPUT_BUCKET', 'videos-output')

r  = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)
mc = Minio(MINIO_HOST, access_key=MINIO_USER, secret_key=MINIO_PASSWORD, secure=False)

current_proc = None

def shutdown(signum, frame):
    print("[SHUTDOWN] signal " + str(signum) + ", terminating ffmpeg...", flush=True)
    if current_proc and current_proc.poll() is None:
        current_proc.terminate()
        try:
            current_proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            current_proc.kill()
    print("[SHUTDOWN] Clean exit.", flush=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT,  shutdown)

print("Worker started, waiting for jobs...", flush=True)

while True:
    _, job_json = r.blpop('transcoding-jobs')
    job = json.loads(job_json)
    src_key = job['file']
    t0 = time.time()
    print("[START] " + src_key, flush=True)

    with tempfile.TemporaryDirectory() as tmp:
        src = tmp + "/in.mp4"
        dst = tmp + "/out.mkv"
        mc.fget_object(INPUT_BUCKET, src_key, src)

        cmd = [
            "ffmpeg", "-y", "-i", src,
            "-vf", "hqdn3d=4:3:6:4.5,scale=3840:2160:flags=lanczos",
            "-c:v", "libx265",
            "-preset", "medium",
            "-pix_fmt", "yuv420p",
            "-x265-params", "rc-lookahead=40:bframes=4:ref=3:rd=3:pools=4",
            "-crf", "22",
            "-c:a", "aac", "-b:a", "192k",
            dst
        ]

        current_proc = subprocess.Popen(cmd)
        current_proc.wait()

        if current_proc.returncode != 0:
            print("[ERROR] ffmpeg exit code " + str(current_proc.returncode), flush=True)
            current_proc = None
            continue

        out_key = src_key.rsplit('.', 1)[0] + '_4k.mkv'
        mc.fput_object(OUTPUT_BUCKET, out_key, dst)
        dur = time.time() - t0
        print("[DONE] " + src_key + " -> " + out_key + " (" + str(round(dur,1)) + "s)", flush=True)

    current_proc = None
