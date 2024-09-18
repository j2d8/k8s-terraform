# EKS Cluster with Karpenter and GPU Slicing

This repository contains Terraform code to deploy an EKS cluster with Karpenter on AWS, supporting both x86 and ARM (Graviton) instances, as well as GPU Slicing for cost-efficient AI workloads.

---

## Goals

- Automate EKS cluster setup with Karpenter and Graviton on AWS
- GPU Slicing on EKS

---

## Prerequisites

- Terraform v1.0+
- AWS CLI configured with appropriate credentials
- kubectl installed

---

## Usage

1. Initialize Terraform:

   ```
   terraform init
   ```

2. Review the planned changes:

   ```
   terraform plan
   ```

3. Apply the changes:

   ```
   terraform apply
   ```

4. Once completed, configure kubectl to connect to the cluster:
   ```
   aws eks --region us-west-1 update-kubeconfig --name <CLUSTER_NAME>
   # example
   aws eks --region us-west-1 update-kubeconfig --name k8s-terraform
   ```

---

## Cluster Configuration

- The EKS cluster is deployed using Kubernetes version 1.28.
- The cluster uses the default VPC and subnets.
- Karpenter is deployed as the cluster autoscaler.
- GPU Slicing is enabled for cost-efficient AI workloads.

---

## Node Groups

### Managed Node Group

- Uses m7g.large instances (Graviton3)
- AMI type: AL2_ARM_64
- Min size: 1, Max size: 3, Desired size: 2
- Labeled with `karpenter.sh/controller: "true"`
- Tainted with `karpenter.sh/controller: "true":NoSchedule`

### Karpenter Node Pools

Three Karpenter node pools are configured:

1. x86 processors:

   - Uses amd64 architecture
   - Instance types with 2 or 4 CPUs
   - Instance generation > 6
   - Supports both spot and on-demand instances

2. ARM processors:

   - Uses arm64 architecture
   - Instance types with 2 or 4 CPUs
   - Instance generation 7
   - Supports both spot and on-demand instances

3. GPU instances with GPU Slicing:
   - Uses GPU-enabled instances (e.g., g4dn family)
   - Supports GPU Slicing for efficient resource utilization
   - Instance types: g4dn.xlarge, g4dn.2xlarge, g4dn.4xlarge
   - Supports both spot and on-demand instances
   - Configured to allow multiple pods to share a single GPU

---

## Running pods on x86 or ARM

To run a pod on a specific instance type (x86 or ARM), use nodeSelectors in your Kubernetes manifest.

### Example for x86:

```bash
cat <<EOF > inflate-amd64.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate-amd64
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate-amd64
  template:
    metadata:
      labels:
        app: inflate-amd64
    spec:
      nodeSelector:
        intent: apps
        kubernetes.io/arch: amd64
        karpenter.sh/capacity-type: on-demand
      containers:
      - image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
        name: inflate-amd64
        resources:
          requests:
            cpu: "1"
            memory: 256M
EOF
kubectl apply -f inflate-amd64.yaml
```

### Example for ARM:

```bash
cat <<EOF > inflate-arm64.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate-arm64
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate-arm64
  template:
    metadata:
      labels:
        app: inflate-arm64
    spec:
      nodeSelector:
        intent: apps
        kubernetes.io/arch: arm64
        node.kubernetes.io/instance-type: c6g.xlarge
      containers:
      - image: public.ecr.aws/eks-distro/kubernetes/pause:3.2
        name: inflate-arm64
        resources:
          requests:
            cpu: "1"
            memory: 256M
EOF
kubectl apply -f inflate-arm64.yaml
```

### Example for GPU:

This is an example for:

```
One of our clients has multiple GPU-intensive AI workloads that run on EKS.
Their CTO heard there is an option to cut GPU costs by enabling GPU Slicing.
We want to help them optimize their cost efficiency.
Research the topic, and describe how they can enable GPU Slicing on their EKS clusters.
Some of the EKS clusters have Karpenter Autoscaler, they’d like to leverage GPU Slicing on these clusters as well. If this is feasible, please provide instructions on how to implement it.
```

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  restartPolicy: Never
  containers:
    - name: cuda-container
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda10.2
      resources:
        limits:
          nvidia.com/gpu: 1 # requesting 1 GPU
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOF
kubectl apply -f gpu-pod.yaml
```

[source](https://ec2spotworkshops.com/karpenter/050_karpenter/multiple_architectures.html)

---

## Connecting to the Cluster

Once all of the resources have been successfully provisioned, Terraform will output a command to update your kubeconfig. It will look something like this:

```
aws eks --region <REGION> update-kubeconfig --name <CLUSTER_NAME> --alias <CLUSTER_NAME>
```

---

## References

- [Karpenter Documentation](https://karpenter.sh/docs/)
- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/karpenter/)
- [AWS EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html)

---

## GPU Slicing for Cost-Efficient AI Workloads

To address the need for cost-efficient GPU utilization in AI workloads, we can implement GPU Slicing on EKS clusters with Karpenter. This allows multiple pods to share a single GPU, potentially reducing costs and improving resource utilization.

### Implementing GPU Slicing with EKS and Karpenter

1. Configure Karpenter for GPU instances:

   - Update the EC2NodeClass to include GPU-enabled instance types (e.g., g4dn family).
   - Create a NodePool specifically for GPU instances, ensuring it's configured to work with the GPU EC2NodeClass.

2. Set up the NVIDIA Device Plugin with GPU Slicing:

   - Create a ConfigMap with the GPU Slicing configuration, specifying the number of slices per GPU.
   - Deploy the NVIDIA Device Plugin as a DaemonSet, using the GPU Slicing configuration.

3. Adjust workload specifications:

   - Modify your GPU workloads to request fractional GPU resources instead of whole GPUs.
   - Update tolerations if necessary to ensure pods can be scheduled on GPU nodes.

4. Monitor and optimize:
   - Keep track of GPU utilization and workload performance.
   - Adjust the GPU Slicing configuration as needed based on your specific workload requirements.

### How it Works

GPU Slicing allows multiple pods to share a single GPU by dividing its resources. Karpenter provisions the appropriate GPU-enabled nodes, while the NVIDIA Device Plugin manages the GPU sharing. This setup enables more efficient use of GPU resources, potentially reducing costs by running more workloads on fewer GPU instances.

### Considerations

- GPU Slicing is most effective for workloads that don't require full GPU performance continuously.
- The impact on performance can vary depending on the nature of your AI workloads.
- Regular monitoring is crucial to ensure workloads are getting the required performance with GPU Slicing enabled.
- Ensure your GPU node images have the necessary NVIDIA drivers and software pre-installed.

### Implementation Steps

1. Apply the Karpenter configurations for GPU instances.
2. Install and configure the NVIDIA Device Plugin with GPU Slicing enabled.
3. Deploy your AI workloads with fractional GPU requests.
4. Monitor performance and adjust configurations as needed.

By implementing GPU Slicing with Karpenter on EKS, you can optimize GPU usage, potentially reducing costs for GPU-intensive AI workloads that don't require dedicated GPUs.

---

## Additional References for GPU Slicing

- [NVIDIA MPS Documentation](https://docs.nvidia.com/deploy/mps/index.html)
- [Kubernetes Device Plugin Framework](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)

---
