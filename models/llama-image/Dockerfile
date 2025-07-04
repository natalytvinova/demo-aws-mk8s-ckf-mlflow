FROM nvcr.io/nvidia/pytorch:23.06-py3  

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN pip install --upgrade pip && \
    pip install "vllm>=0.4.0" transformers accelerate

ENV DEBIAN_FRONTEND=noninteractive

COPY llama-model /model
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh
ENV MODEL_PATH=/model

EXPOSE 8000

CMD ["/entrypoint.sh"]