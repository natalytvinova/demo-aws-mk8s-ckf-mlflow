#!/bin/bash

exec python3 -m vllm.entrypoints.openai.api_server \
  --model /model \
  --port 8000 \
  --dtype half \
  --gpu-memory-utilization 0.96 \
  --enforce-eager \
  --max-num-batched-tokens 8196