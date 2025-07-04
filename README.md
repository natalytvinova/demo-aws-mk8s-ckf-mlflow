# Multicloud E2E RAG demo

## Infrastructure Installation

### Create the jumphost

Skip if you already have a jumphost or decide to use your local machine.

For **AWS**, go to the `aws-jumphost` folder.

Run Terraform scripts:

```bash
terraform init
terraform apply
```

Export the public ip of the jumphost and SSH using defined key

```bash
export JUMPHOST_IP=$(terraform output -raw instance_public_ip)
export PATH_TO_KEY=...

ssh -i $PATH_TO_KEY ubuntu@$JUMPHOST_IP
```

Install common packages for jumphost from project root directory

```bash
cd ./..
bash jumphost-common.sh
```

### Juju cloud configuration

Juju cloud credentials need to be configured separately for each of the clouds, more info can be found [here](https://juju.is/docs/juju/juju-add-credential)

For **AWS**, configure the aws cloud config file based on [template](`./aws-jumphost/aws-credentials.tmp`) with your AWS IAM user credentails and add them to the cloud:

```bash
juju add-credential aws -f ./aws-jumphost/aws-credentials.yaml
```

### Deploy Kubernetes cluster

Bootstrap juju controller

```bash
juju bootstrap aws/eu-west-1 aws-controller --bootstrap-constraints 'cores=2 mem=4G'
```

Deploy kubernetes cluster with Juju and Microk8s

```bash
juju add-model mk8s aws

juju deploy ./k8s/k8s-bundle.yaml --model mk8s

juju ssh -m mk8s microk8s/leader -- sudo microk8s status
```

We are using hostpath storage to eliminate the dependency on the external cloud. The root disk is 100GB to acomodate both Kubernetes hostpath storage and Docker Image caching.

Wait untill all Pods are created and configure additional microk8s plugins

note due to [Issue 303](https://github.com/canonical/microk8s-core-addons/issues/303) you will need to pass the version argument to the GPU addon. 
```bash
juju ssh -m mk8s microk8s/leader -- sudo microk8s enable ingress metallb:10.64.140.43-10.64.140.49
juju ssh -m mk8s microk8s/leader -- sudo microk8s enable gpu --version 24.6.2

juju expose microk8s
```

Save kubeconfig into the kube config default, if you do not use jumphost consider using different location.

```bash
juju ssh -m mk8s microk8s/leader -- sudo microk8s config > ~/.kube/config
```

Validate the available GPUs, there should be at least 1 available GPU:

```bash
kubectl describe nodes  |  tr -d '\000' | sed -n -e '/^Name/,/Roles/p' -e '/^Capacity/,/Allocatable/p' -e '/^Allocated resources/,/Events/p'  | grep -e Name  -e  nvidia.com  | perl -pe 's/\n//'  |  perl -pe 's/Name:/\n/g' | sed 's/nvidia.com\/gpu:\?//g'  | sed '1s/^/Node Available(GPUs)  Used(GPUs)/' | sed 's/$/ 0 0 0/'  | awk '{print $1, $2, $3}'  | column -t
```

Taint GPU nodes with PreferNoSchedule:
```bash
kubectl get nodes -l "nvidia.com/gpu.present=true" -o jsonpath='{.items[*].metadata.name}' \
    | xargs -I{} kubectl taint nodes {} node-preference=gpu:PreferNoSchedule --overwrite
```

Optionally, install volcano scheduler if you need more advanced scheduling policies for your workloads.

```bash
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml
```

### Connect to UIs

Follow this instruction once to get access to expose MetalLB IPs to your local machine.

First, add your public key to the Kubernetes leader node. I will use my launchpad ID, you can also add your public key directly to the ~/.ssh/authorized_keys on the remote host.

```bash
juju ssh -m mk8s microk8s/leader -- ssh-import-id barteus
```

Next step is expose them to your computer via sshuttle. Use new terminal window on your local computer. You will need root access to your computer, because sshuttle will add additional entries to your IP tables.

On the jumphost run:

```shell
MK8S_LEADER_IP=$(juju status -m mk8s microk8s/leader --format json | jq -r '.machines[] | .["dns-name"]')
echo sshuttle -r ubuntu@$MK8S_LEADER_IP 10.0.0.0/8 172.31.0.0/16
```

On your local computer in new terminal run:

```bash
sshuttle -r ubuntu@$MK8S_LEADER_IP 10.0.0.0/8 172.31.0.0/16
```

### Deploy COS

Add deployed K8s as a cloud

```bash
juju add-k8s mk8s --cluster-name=microk8s-cluster --client --controller aws-controller
```

Deploy the Observability stack

```bash
juju add-model cos mk8s

juju deploy cos-lite --model cos \
  --trust \
  --overlay ./cos/offers-overlay.yaml \
  --overlay ./cos/storage-small-overlay.yaml
```

To access the COS, go to the section "Access the UIs"

Get the IP of the COS entrypoint. In the catalog you can find links to other services.

```bash
juju run -m cos traefik/0 show-proxied-endpoints --format=yaml --model cos \
  | yq '."traefik/0".results."proxied-endpoints"' \
  | jq
```

**Grafana** admin user details can be extracted using Juju action:

```bash
echo Grafana access
juju run grafana/leader get-admin-password --model cos
```
### Deploy Kubeflow and MLflow

Deploy Kubeflow, MLflow and integrate with COS

```bash
juju add-model kubeflow mk8s

juju deploy -m kubeflow --debug ./ckf/bundle.yaml \
    --overlay ./ckf/authentication-overlay.yaml \
    --overlay ./ckf/cos-integration.yaml \
    --overlay ./ckf/mlflow-integration.yaml \
    --trust
```

Kubeflow access to the UI:

```bash
echo Kubeflow access
echo IP: $(kubectl -n kubeflow get svc istio-ingressgateway-workload -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo User: $(juju config dex-auth static-username)
echo Password $(juju config dex-auth static-password)
```

### Deploy Opensearch

Create a new model and set cloudinit-userdata for it. Deploy opensearch.

```bash
juju add-model os aws

juju model-config --model os --file=./opensearch/cloudinit-userdata.yaml

juju deploy -m os ./opensearch/bundle.yaml
```

Ignore the error with replicas, or edit the bundle to deploy Opensearch in HA mode.

When deployment is GREEN, get the access information:

```bash
juju run opensearch/0 get-password > ./opensearch/os-creds.yaml

export OS_IP=$(juju status -m os opensearch/0 --format json | jq -r '.machines[] | .["dns-name"]')
export OS_PORT=9200
export OS_USERNAME=$(cat ./opensearch/os-creds.yaml | yq -C ".username")
export OS_PASSWORD=$(cat ./opensearch/os-creds.yaml | yq -C ".password")

echo Endpoints: $OS_IP:$OS_PORT
echo Username: $OS_USERNAME
echo Password: $OS_PASSWORD

cat ./opensearch/os-creds.yaml | yq -C ".ca-chain" | tee ./opensearch/os-cert.yaml
echo Certificate saved under ./opensearch/os-cert.yaml
```

Connect using curl to check connectivity:

```bash
curl -k --cacert ./opensearch/os-cert.yaml -XGET https://$OS_USERNAME:$OS_PASSWORD@$OS_IP:$OS_PORT/
```

Create Opensearch secret and PodDefaults in the "admin" user namespace in Kubeflow. This requires that you log into the Kubeflow for the first time before running the script below.

```bash
sh ./opensearch/os-pod-default.sh
```

### Configure Object storage Bucket and Opensearch Index

Go to the **Kubeflow Dashboard** and create a Kubeflow Notebook with all PodDefaults enabled (Allow access to Kubeflow pipeline, Minio, MLflow, Opensearch).

In the Kubeflow notebook clone this repo and go to the `notebooks` folder. Next, run `setup-bucket.ipynb` to create bucket and upload all files in the documents folder to it. If you want to have more documents uploaded, change the content of the `documents` folder.

Go to the **Kubeflow Pipelines** tab in Kubeflow Dashboard and create the new pipeline. You can download the ingestion-pipelines.yaml file from the repository. Alternativly you can run the `ingestion-pipeline.ipynb`.

To execute the pipeline and create a run, you might need to create experiment first and than create a pipeline run using that Experiment and Pipeline.

### Deploy ML models

Check if KServe works by following the script `kserve-test.sh`. Update the authentication token from your browser.

```bash
bash ./models/setup.sh
```

### Adjusting the model

If you want to make the modifications to the model, follow these steps. For this tutorial we used [Llama model 3.2-1B](https://huggingface.co/meta-llama/Llama-3.2-1B).
After requesting access to this model, login to Huggingface-cli:
```commandline
huggingface-cli login
```

And load the model:
```python
from transformers import AutoTokenizer, AutoModelForCausalLM

tokenizer = AutoTokenizer.from_pretrained("meta-llama/Llama-3.2-1B-Instruct")
model = AutoModelForCausalLM.from_pretrained("meta-llama/Llama-3.2-1B-Instruct")
```

Dockerfile along with the used files are included in the `models/llama-image` directory. Put the llama-model you extracted in the previous steps to `models/llama-image/llama-model` directory. The directory of your image should look like this:
```commandline
tree llama-image
llama-image
├── Dockerfile
├── entrypoint.sh
└── llama-model
    ├── LICENSE.txt
    ├── README.md
    ├── USE_POLICY.md
    ├── config.json
    ├── generation_config.json
    ├── gitattributes
    ├── model.safetensors
    ├── special_tokens_map.json
    ├── tokenizer.json
    └── tokenizer_config.json

2 directories, 12 files
```

Build the image and push to your repo:

sudo docker build . -t natalytvinova/llama-vllm:latest
sudo docker push natalytvinova/llama-vllm:latest

And replace the image in the `models/setup.sh`.

### Deploy Chat UI

Deploy the UI and expose it outside of the cluster using the script:

```bash
bash ./ui/setup.sh
```

If you want to build or adjust the Chatbot UI. Go into UI, build new image and upload it to your registry:

```bash
docker build . -t natalytvinova/llm-chatbot:latest
docker push natalytvinova/llm-chatbot:latest
```

And replace the image in the `ui/setup.sh`.
## Cleanup

Remove in the AWS cloud console:
- machines
- security groups

All the resources are pre-fixed with `juju-<model-uuid>`

Remove configuration on the jumphost.

```bash
rm -Rf ~/.local/share/juju/
```

##### Cloud costs
Estimated costs for the usage of the public cloud with this setup as it is. 

AWS / Compute (1.0853$/h | ~26$/d | ~182$/w | ~807$/mo)
- 3x t3.large (0.0912$/Hour)
- 2x m7i.large ( 0.11235$/Hour)
- 1x g4dn.xlarge ( 0.587$/Hour)

> WARN: DO NOT FORGET TO DESTROY THE ENVIRONMENT ONCE FINISHED.

> NOTE: It can be tweaked.

### Manual cleanup of Argo Workflows completed pods:

Without removing completed Pods the PVCs will not be removed even if stated in the pipeline definition. 

Run it only when no Pipeline Run is executed.

```bash
kubectl delete po -n admin -l workflows.argoproj.io/completed=true
```
