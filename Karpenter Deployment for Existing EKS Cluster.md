# Karpenter Deployment for Existing EKS Cluster

**Production-ready Terraform modules for deploying Karpenter autoscaler on existing EKS clusters**

[![Terraform](https://img.shields.io/badge/Terraform-≥1.0-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)
[![Karpenter](https://img.shields.io/badge/Karpenter-1.0.1-326CE5)](https://karpenter.sh/)

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Detailed Installation](#detailed-installation)
- [Configuration](#configuration)
- [Module Structure](#module-structure)
- [Examples](#examples)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

## 🎯 Overview

This repository provides production-ready Terraform modules to deploy **Karpenter**, a Kubernetes cluster autoscaler, on existing AWS EKS clusters. Karpenter automatically provisions right-sized compute resources based on your workload requirements.

### Why Karpenter?

- **Fast Scale-Up**: Provisions nodes in seconds vs minutes
- **Cost Optimization**: Automatically selects optimal instance types
- **Consolidation**: Repacks pods to reduce underutilized nodes
- **Spot Instance Support**: Native integration with EC2 Spot
- **Flexibility**: Fine-grained control over node provisioning

## ✨ Features

✅ **Modular Design**: Reusable Terraform modules  
✅ **Production-Ready**: IAM roles, security groups, and interruption handling  
✅ **IRSA Enabled**: IAM Roles for Service Accounts configured  
✅ **Spot Interruption Handling**: SQS + EventBridge integration  
✅ **Multiple Node Classes**: Examples for various workload types  
✅ **Security Best Practices**: IMDSv2, encryption, least privilege IAM  
✅ **Observability**: CloudWatch metrics and logging  
✅ **Easy Management**: Makefile and scripts for common operations  

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        EKS Cluster                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Karpenter Controller                    │   │
│  │  (Runs on existing node group with IRSA)             │   │
│  └────────────┬────────────────────────┬────────────────┘   │
│               │                        │                    │
│  ┌────────────▼────────────┐  ┌───────▼──────────────┐      │
│  │     NodePool (Spot)     │  │  NodePool (OnDemand) │      │
│  └────────────┬────────────┘  └───────┬──────────────┘      │
│               │                        │                    │
│  ┌────────────▼────────────────────────▼─────────────┐      │
│  │              EC2NodeClass                         │      │
│  │  (Defines AMI, subnets, security groups, etc.)    │      │
│  └───────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          │               │               │
┌─────────▼──────┐ ┌─────▼──────┐ ┌─────▼──────┐
│  IAM Roles     │ │ SQS Queue  │ │ EventBridge│
│  - Controller  │ │ (Interrupt)│ │   Rules    │
│  - Node        │ └────────────┘ └────────────┘
└────────────────┘
```

## 📦 Prerequisites

### Required Software

- **Terraform** >= 1.0
- **kubectl** >= 1.24
- **AWS CLI** >= 2.0
- **Helm** >= 3.9
- **jq** (optional, for scripts)

### AWS Requirements

1. **Existing EKS Cluster** (1.24 or higher)
2. **OIDC Provider** configured for the cluster
3. **VPC with Private Subnets** for node placement
4. **AWS IAM Permissions** to create roles, policies, SQS queues, etc.

### Cluster Requirements

Your EKS cluster must have:
- At least one node group (to run Karpenter controller)
- OIDC provider configured
- aws-auth ConfigMap or Access Entries configured

## 🚀 Quick Start

### Option 1: Automated Setup (Recommended)

```bash
# 1. Clone the repository
git clone <repository-url>
cd karpenter-terraform

# 2. Make preparation script executable
chmod +x prepare-karpenter.sh

# 3. Run preparation (will tag resources and create terraform.tfvars)
./prepare-karpenter.sh -c your-cluster-name -r us-east-1

# 4. Review the generated terraform.tfvars
cat terraform.tfvars

# 5. Deploy using Makefile
make init
make plan
make apply

# 6. Verify installation
make verify
```

### Option 2: Manual Setup

```bash
# 1. Ensure OIDC provider exists
aws eks describe-cluster --name your-cluster --query "cluster.identity.oidc.issuer"

# 2. Tag subnets
aws ec2 create-tags \
    --resources subnet-xxx subnet-yyy \
    --tags Key=karpenter.sh/discovery,Value=your-cluster

# 3. Tag security group
aws ec2 create-tags \
    --resources sg-xxx \
    --tags Key=karpenter.sh/discovery,Value=your-cluster

# 4. Create terraform.tfvars
cat > terraform.tfvars <<EOF
region       = "us-east-1"
cluster_name = "your-cluster"
environment  = "production"
EOF

# 5. Deploy
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## 📖 Detailed Installation

### Step 1: Verify Prerequisites

```bash
# Check AWS credentials
aws sts get-caller-identity

# Check kubectl access
kubectl get nodes

# Check OIDC provider
aws eks describe-cluster --name your-cluster \
  --query "cluster.identity.oidc.issuer" --output text
```

### Step 2: Tag AWS Resources

Karpenter discovers resources using tags:

```bash
# Get your cluster's VPC
VPC_ID=$(aws eks describe-cluster --name your-cluster \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Get private subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].[SubnetId,CidrBlock,AvailabilityZone]' \
  --output table

# Tag subnets (replace with your subnet IDs)
aws ec2 create-tags \
    --resources subnet-xxx subnet-yyy subnet-zzz \
    --tags Key=karpenter.sh/discovery,Value=your-cluster

# Get and tag cluster security group
CLUSTER_SG=$(aws eks describe-cluster --name your-cluster \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 create-tags \
    --resources $CLUSTER_SG \
    --tags Key=karpenter.sh/discovery,Value=your-cluster
```

### Step 3: Configure Terraform

Create `terraform.tfvars`:

```hcl
region       = "us-east-1"
cluster_name = "production-cluster"
environment  = "production"

# Karpenter version
karpenter_version  = "1.0.1"
karpenter_replicas = 2

# Resource configuration
karpenter_controller_resources = {
  requests = {
    cpu    = "1"
    memory = "1Gi"
  }
  limits = {
    cpu    = "1"
    memory = "1Gi"
  }
}

# For EKS 1.24+ use access entries (recommended)
enable_eks_access_entry   = true
enable_aws_auth_configmap = false
```

### Step 4: Initialize and Apply

```bash
# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# Plan deployment
terraform plan -out=tfplan

# Review the plan output carefully

# Apply
terraform apply tfplan
```

### Step 5: Verify Installation

```bash
# Check Karpenter pods
kubectl get pods -n karpenter

# Should show 2 running pods:
# NAME                         READY   STATUS    RESTARTS   AGE
# karpenter-5d8f9c8d9b-abcde   1/1     Running   0          2m
# karpenter-5d8f9c8d9b-fghij   1/1     Running   0          2m

# Check NodePool
kubectl get nodepools
kubectl describe nodepool default

# Check EC2NodeClass
kubectl get ec2nodeclasses
kubectl describe ec2nodeclass default

# View Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f
```
### Advanced NodePool Configuration Examples:
###############################################
# nodepool-examples.yaml
# Advanced Karpenter NodePool configurations
###############################################

---
# 1. General Purpose - Cost Optimized (Spot Heavy)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-spot
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      # Tolerate spot interruptions
      taints:
        - key: karpenter.sh/spot
          effect: NoSchedule
  limits:
    cpu: "1000"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  weight: 50

---
# 2. On-Demand Fallback for Critical Workloads
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-ondemand
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  limits:
    cpu: "500"
    memory: 500Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
    # Budget for controlled disruptions
    budgets:
      - nodes: "10%"
  weight: 10

---
# 3. ARM64 Cost-Optimized Pool (Graviton)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: arm-spot
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["c6g", "c7g", "m6g", "m7g", "r6g", "r7g", "t4g"]
      taints:
        - key: kubernetes.io/arch
          value: arm64
          effect: NoSchedule
  limits:
    cpu: "500"
    memory: 500Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  weight: 100

---
# 4. Compute-Intensive Workloads
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: compute-intensive
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: compute-nodeclass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: Gt
          values: ["8"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["6"]
      taints:
        - key: workload-type
          value: compute-intensive
          effect: NoSchedule
      # Startup taint to prevent scheduling before ready
      startupTaints:
        - key: node.kubernetes.io/not-ready
          effect: NoSchedule
  limits:
    cpu: "200"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m

---
# 5. Memory-Intensive Workloads
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: memory-intensive
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: memory-nodeclass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["r", "x"]
        - key: karpenter.k8s.aws/instance-memory
          operator: Gt
          values: ["32768"]
      taints:
        - key: workload-type
          value: memory-intensive
          effect: NoSchedule
  limits:
    cpu: "100"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10m

---
# 6. GPU Workloads (ML/AI)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-nodeclass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g4dn", "g5", "p3", "p4d"]
        - key: karpenter.k8s.aws/instance-gpu-count
          operator: Gt
          values: ["0"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
        - key: workload-type
          value: gpu
          effect: NoSchedule
  limits:
    cpu: "200"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30m
    budgets:
      - nodes: "0"
        schedule: "0 9-17 * * mon-fri"
        duration: 8h

---
# 7. Burstable Workloads (Small, cost-effective)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: burstable
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["t3", "t3a", "t4g"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large", "xlarge"]
  limits:
    cpu: "100"
    memory: 200Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 15s

---
# 8. Database/Stateful Workloads (High IOPS)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: stateful
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: stateful-nodeclass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["i", "d", "im", "is"]
        - key: karpenter.k8s.aws/instance-local-nvme
          operator: Gt
          values: ["0"]
      taints:
        - key: workload-type
          value: stateful
          effect: NoSchedule
  limits:
    cpu: "100"
    memory: 500Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1h
    # Prevent disruption during business hours
    budgets:
      - nodes: "0"
        schedule: "0 9-17 * * mon-fri"
        duration: 8h

---
# 9. Windows Workloads
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: windows
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: windows-nodeclass
      requirements:
        - key: kubernetes.io/os
          operator: In
          values: ["windows"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
      taints:
        - key: os
          value: windows
          effect: NoSchedule
  limits:
    cpu: "200"
    memory: 400Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m

---
# 10. CI/CD Build Agents
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: cicd-builders
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: cicd-nodeclass
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-cpu
          operator: In
          values: ["4", "8", "16"]
      taints:
        - key: workload-type
          value: cicd
          effect: NoSchedule
      labels:
        workload-type: cicd
        node-lifecycle: spot
  limits:
    cpu: "500"
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
    # Allow aggressive scaling for CI/CD
    expireAfter: 1h

---
###############################################
# EC2NodeClass Examples
###############################################

---
# Default EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh <CLUSTER_NAME>
  tags:
    karpenter.sh/discovery: <CLUSTER_NAME>
    ManagedBy: Karpenter
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 2
    httpTokens: required

---
# Compute-Intensive EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: compute-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
        subnet-type: private
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    # Optimize for compute workloads
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p
    /etc/eks/bootstrap.sh <CLUSTER_NAME> \
      --kubelet-extra-args '--cpu-manager-policy=static'
  tags:
    NodeType: compute-intensive
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        encrypted: true
        deleteOnTermination: true

---
# Memory-Intensive EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: memory-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    # Optimize for memory workloads
    echo 'vm.swappiness=1' >> /etc/sysctl.conf
    echo 'vm.overcommit_memory=1' >> /etc/sysctl.conf
    sysctl -p
    /etc/eks/bootstrap.sh <CLUSTER_NAME>
  tags:
    NodeType: memory-intensive
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 150Gi
        volumeType: gp3
        iops: 3000
        encrypted: true
        deleteOnTermination: true

---
# GPU EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2@latest-gpu
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    # Install NVIDIA drivers
    /etc/eks/bootstrap.sh <CLUSTER_NAME>
    
    # Configure nvidia runtime as default
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
    {
      "default-runtime": "nvidia",
      "runtimes": {
        "nvidia": {
          "path": "/usr/bin/nvidia-container-runtime",
          "runtimeArgs": []
        }
      }
    }
    EOF
    systemctl restart docker
  tags:
    NodeType: gpu
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        iops: 4000
        throughput: 250
        encrypted: true
        deleteOnTermination: true

---
# Stateful/High IOPS EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: stateful-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    # Format and mount instance store if available
    if [ -e /dev/nvme1n1 ]; then
      mkfs.xfs /dev/nvme1n1
      mkdir -p /mnt/nvme
      mount /dev/nvme1n1 /mnt/nvme
      echo '/dev/nvme1n1 /mnt/nvme xfs defaults,noatime 0 0' >> /etc/fstab
    fi
    /etc/eks/bootstrap.sh <CLUSTER_NAME>
  tags:
    NodeType: stateful
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: io2
        iops: 10000
        encrypted: true
        deleteOnTermination: true

---
# Windows EC2NodeClass
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: windows-nodeclass
spec:
  amiSelectorTerms:
    - alias: windows2022@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    <powershell>
    [string]$EKSBootstrapScriptFile = "$env:ProgramFiles\Amazon\EKS\Start-EKSBootstrap.ps1"
    & $EKSBootstrapScriptFile -EKSClusterName "<CLUSTER_NAME>" -APIServerEndpoint "<CLUSTER_ENDPOINT>" -Base64ClusterCA "<CLUSTER_CA>" -DNSClusterIP "10.100.0.10"
    </powershell>
  tags:
    OS: windows
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/sda1
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true

---
# CI/CD EC2NodeClass with Docker optimization
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: cicd-nodeclass
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  role: <KARPENTER_NODE_ROLE_NAME>
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <CLUSTER_NAME>
  userData: |
    #!/bin/bash
    # CI/CD optimizations
    /etc/eks/bootstrap.sh <CLUSTER_NAME>
    
    # Increase Docker daemon limits
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
    {
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "10m",
        "max-file": "3"
      },
      "max-concurrent-downloads": 10,
      "max-concurrent-uploads": 10
    }
    EOF
    systemctl restart docker
    
    # Install common CI/CD tools
    yum install -y git jq unzip
  tags:
    NodeType: cicd
    karpenter.sh/discovery: <CLUSTER_NAME>
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 150Gi
        volumeType: gp3
        iops: 3000
        encrypted: true
        deleteOnTermination: true

### Step 6: Test with Sample Workload

```bash
# Create test deployment
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7
kubectl set resources deployment inflate --requests=cpu=1,memory=1.5Gi

# Scale up
kubectl scale deployment inflate --replicas=5

# Watch Karpenter provision nodes
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# In another terminal, watch nodes
kubectl get nodes -w

# Scale down (should trigger consolidation)
kubectl scale deployment inflate --replicas=0

# Cleanup
kubectl delete deployment inflate
```

## ⚙️ Configuration

### Module Inputs

| Variable | Description | Type | Default | Required |
|----------|-------------|------|---------|----------|
| `cluster_name` | Name of the EKS cluster | `string` | - | yes |
| `region` | AWS region | `string` | `us-east-1` | yes |
| `karpenter_version` | Karpenter Helm chart version | `string` | `1.0.1` | no |
| `replicas` | Number of controller replicas | `number` | `2` | no |
| `controller_resources` | Resource limits for controller | `object` | See variables.tf | no |
| `enable_eks_access_entry` | Use EKS access entries | `bool` | `true` | no |
| `enable_aws_auth_configmap` | Use aws-auth ConfigMap | `bool` | `false` | no |

### Module Outputs

| Output | Description |
|--------|-------------|
| `node_iam_role_arn` | ARN of IAM role for nodes |
| `controller_iam_role_arn` | ARN of IAM role for controller |
| `interruption_queue_name` | Name of SQS queue |
| `interruption_queue_url` | URL of SQS queue |

## 📁 Module Structure

```
.
├── README.md
├── main.tf                      # Root module
├── variables.tf                 # Root variables
├── outputs.tf                   # Root outputs
├── terraform.tfvars.example     # Example variables
├── Makefile                     # Helper commands
├── prepare-karpenter.sh         # Preparation script
├── nodepool-examples.yaml       # NodePool configurations
└── modules/
    └── karpenter/
        ├── main.tf              # Module main
        ├── variables.tf         # Module variables
        └── outputs.tf           # Module outputs
```

## 💡 Examples

### Basic Usage

```hcl
module "karpenter" {
  source = "./modules/karpenter"

  cluster_name = "my-cluster"
  region       = "us-east-1"
  
  tags = {
    Environment = "production"
    Team        = "platform"
  }
}
```

### Advanced Configuration

```hcl
module "karpenter" {
  source = "./modules/karpenter"

  cluster_name      = "production-cluster"
  region            = "us-east-1"
  karpenter_version = "1.0.1"
  replicas          = 3

  controller_resources = {
    requests = {
      cpu    = "2"
      memory = "2Gi"
    }
    limits = {
      cpu    = "2"
      memory = "2Gi"
    }
  }

  tags = {
    Environment = "production"
    CostCenter  = "engineering"
    ManagedBy   = "terraform"
  }
}
```

### Multiple NodePools

See `nodepool-examples.yaml` for comprehensive examples including:
- Spot-optimized pools
- On-demand fallback pools
- ARM64/Graviton pools
- GPU pools
- Compute/memory-intensive pools
- Burstable workloads
- CI/CD build agents

## 📊 Monitoring

### CloudWatch Metrics

Karpenter exports metrics to CloudWatch under the `Karpenter` namespace:

- `karpenter_nodes_created`
- `karpenter_nodes_terminated`
- `karpenter_pods_startup_time_seconds`
- `karpenter_nodeclaims_disrupted`

### Prometheus Integration

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: karpenter
  namespace: karpenter
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: karpenter
  endpoints:
    - port: http-metrics
      interval: 30s
```

### Useful Commands

```bash
# View controller logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Get node pool status
kubectl get nodepools -o wide

# Get nodes managed by Karpenter
kubectl get nodes -l karpenter.sh/nodepool

# Describe a node
kubectl describe node <node-name>

# View events
kubectl get events -A --sort-by='.lastTimestamp' | grep -i karpenter
```

## 🔧 Troubleshooting

### Issue: Karpenter not provisioning nodes

**Symptoms**: Pods stuck in Pending state

**Solutions**:
1. Check Karpenter logs: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`
2. Verify subnet tags: `aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=<cluster-name>"`
3. Check IAM permissions on controller role
4. Verify NodePool requirements match pod requirements

### Issue: Nodes created but pods not scheduling

**Symptoms**: New nodes appear but pods remain pending

**Solutions**:
1. Check aws-auth ConfigMap or access entries
2. Verify security group allows cluster communication
3. Check node taints and pod tolerations
4. Review pod events: `kubectl describe pod <pod-name>`

### Issue: Spot interruptions not handled

**Solutions**:
1. Verify SQS queue: `aws sqs get-queue-attributes --queue-url <url>`
2. Check EventBridge rules are active
3. Review Karpenter logs for interruption messages
4. Ensure controller IAM role has SQS permissions

### Common Errors

**Error**: `failed to create node claim: AccessDenied`
- **Solution**: Check controller IAM role has ec2:RunInstances permission

**Error**: `no instance types satisfy requirements`
- **Solution**: Relax NodePool requirements or add more instance families

**Error**: `failed to resolve subnet selector`
- **Solution**: Ensure subnets are tagged with `karpenter.sh/discovery`

## 🎯 Best Practices

### 1. High Availability
- Run at least 2 controller replicas
- Use PodDisruptionBudgets
- Deploy controllers on different AZs

### 2. Cost Optimization
- Use Spot instances for fault-tolerant workloads
- Enable consolidation with appropriate delays
- Set resource limits on NodePools
- Use diverse instance types for better spot availability

### 3. Security
- Enable IMDSv2 on all nodes
- Encrypt EBS volumes
- Use least-privilege IAM policies
- Implement network policies
- Regular security updates

### 4. Operational Excellence
- Monitor Karpenter metrics and logs
- Set up alerts for provisioning failures
- Test failover scenarios
- Document custom NodePool configurations
- Version control all configurations

### 5. Performance
- Set appropriate consolidateAfter values
- Use topology spread constraints
- Configure resource requests accurately
- Implement proper pod priorities

## 🔗 Resources

- [Karpenter Documentation](https://karpenter.sh/)
- [AWS EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)

## 📞 Support

For issues and questions:
- Open an issue on GitHub
- Check existing issues and documentation
- Join [Karpenter Slack](https://kubernetes.slack.com/archives/C02SFFZSA2K)

---

**Made with ❤️ for the Kubernetes community**
