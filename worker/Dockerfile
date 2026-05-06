FROM jrottenberg/ffmpeg:6-ubuntu

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip && \
    pip3 install --break-system-packages --no-cache-dir redis minio && \
    rm -rf /var/lib/apt/lists/*

COPY worker.py /worker.py

ENTRYPOINT ["python3", "/worker.py"]
