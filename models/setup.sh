#!/bin/bash

kubectl apply -n admin -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: llama3-2-1b
spec:
  supportedModelFormats:
    - name: llama3-2-1b
      version: "1"
  multiModel: false
  containers:
    - name: kserve-container
      image: docker.io/natalytvinova/llama-vllm
      imagePullPolicy: Always
      ports:
        - containerPort: 8000
          protocol: TCP
          name: http1
      volumeMounts:
        - mountPath: /dev/shm
          name: dshm
      livenessProbe:
        httpGet:
          path: /health
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 10
      readinessProbe:
        httpGet:
          path: /v1/models
          port: 8000
        initialDelaySeconds: 60
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 6
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
        sizeLimit: 16Gi
  annotations:
    prometheus.kserve.io/path: /metrics
    prometheus.kserve.io/port: "8000"
    serving.kserve.io/enable-metric-aggregation: "true"
    serving.kserve.io/enable-prometheus-scraping: "true"
EOF

kubectl apply -n admin -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llama3-2-1b
  annotations:
    autoscaling.knative.dev/target: "10"
    sidecar.istio.io/inject: "false"
spec:
  predictor:
    minReplicas: 1
    model:
      modelFormat:
        name: llama3-2-1b
      resources:
        limits:
          nvidia.com/gpu: "1"
        requests:
          nvidia.com/gpu: "1"
      runtime: llama3-2-1b
    tolerations:
      - key: "node-preference"
        operator: "Equal"
        value: "true"
        effect: "PreferNoSchedule"
EOF