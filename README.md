# EKS Cluster with Karpenter Autoscaler

This Terraform configuration deploys a production-ready Amazon EKS cluster with Karpenter as the autoscaler using custom modules.

## Architecture

The setup includes:
- **VPC Module**: Creates VPC with public and private subnets across multiple AZs
- **EKS Module**: Deploys EKS cluster with managed node groups and OIDC provider
- **Karpenter Module**: Installs Karpenter with IRSA, SQS interruption handling, and EventBridge rules
- **Karpenter Provisioners Module**: Configures NodePools and EC2NodeClasses for workload-specific scaling

## Directory Structure

```
.
├── main.tf                          # Root module
├── variables.tf                     # Root variables
├── outputs.tf                       # Root outputs
├── terraform.tfvars                 # Your configuration values
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── eks/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── karpenter/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── karpenter-provisioners/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
```

## Prerequisites

1. **AWS CLI** configured with appropriate credentials
2. **Terraform** >= 1.3
3. **kubectl** for Kubernetes management
4. **Helm** CLI (optional, for manual operations)

## Required AWS Permissions

Your AWS credentials need permissions for:
- VPC, Subnet, Internet Gateway, NAT Gateway, Route Tables
- EKS Cluster and Node Groups
- IAM Roles, Policies, Instance Profiles, OIDC Provider
- EC2 (for Karpenter)
- SQS Queues
- EventBridge Rules
- CloudWatch

## Installation Steps

### 1. Clone and Configure

```bash
# Copy the example configuration
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
vim terraform.tfvars
```

### 2. Update Security Group Tags

After creating the EKS cluster, you need to tag the security groups for Karpenter discovery:

```bash
# Get cluster security group ID
CLUSTER_SG=$(terraform output -raw cluster_security_group_id)

# Tag the security group
aws ec2 create-tags \
    --resources $CLUSTER_SG \
    --tags "Key=karpenter.sh/discovery,Value=<your-cluster-name>"
```

### 3. Initialize and Deploy

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

### 4. Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig --region <your-region> --name <your-cluster-name>

# Verify connection
kubectl get nodes
kubectl get pods -n karpenter
```

## Karpenter Configuration

### Default NodePool

If you don't specify custom provisioners, a default NodePool is created with:
- **Architecture**: amd64
- **OS**: Linux
- **Capacity Types**: Spot and On-Demand
- **Instance Categories**: c, m, r (compute, memory, general purpose)
- **Instance Generation**: > 2
- **Limits**: 1000 CPUs, 1000Gi memory

### Custom Provisioners

Define custom provisioners in `terraform.tfvars`:

```hcl
karpenter_provisioners = {
  gpu-workloads = {
    labels = {
      workload-type = "gpu"
      gpu-type      = "nvidia"
    }
    requirements = [
      {
        key      = "karpenter.k8s.aws/instance-family"
        operator = "In"
        values   = ["p3", "p4", "g4dn"]
      },
      {
        key      = "karpenter.sh/capacity-type"
        operator = "In"
        values   = ["on-demand"]
      }
    ]
    taints = [
      {
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      }
    ]
    limits = {
      cpu = "100"
      memory = "500Gi"
    }
  }
}
```

## Testing Karpenter

### Deploy a Test Workload

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
        resources:
          requests:
            cpu: 1
            memory: 1.5Gi
EOF
```

### Scale Up

```bash
# Scale to trigger Karpenter
kubectl scale deployment inflate --replicas=10

# Watch Karpenter logs
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter

# Watch nodes
kubectl get nodes -w
```

### Scale Down

```bash
# Scale down
kubectl scale deployment inflate --replicas=0

# Karpenter will automatically remove unused nodes after consolidation period
```

## Karpenter Features

### 1. Spot Instance Interruption Handling
Karpenter automatically handles:
- EC2 Spot interruption warnings (2-minute notice)
- Instance rebalance recommendations
- Scheduled maintenance events

### 2. Consolidation
Karpenter automatically:
- Consolidates underutilized nodes
- Replaces nodes with cheaper alternatives
- Removes empty nodes

### 3. Node Expiry
Nodes automatically expire after the configured period (default: 720h/30 days) to ensure:
- Security patches are applied
- AMIs are updated
- Nodes are refreshed

## Monitoring

### Check Karpenter Status

```bash
# Check Karpenter deployment
kubectl get deploy -n karpenter

# Check Karpenter pods
kubectl get pods -n karpenter

# Check NodePools
kubectl get nodepools

# Check EC2NodeClasses
kubectl get ec2nodeclasses

# Describe a NodePool
kubectl describe nodepool default
```

### View Karpenter Logs

```bash
# Follow Karpenter controller logs
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter

# Get recent events
kubectl get events -n karpenter --sort-by='.lastTimestamp'
```

## Cost Optimization

1. **Use Spot Instances**: Configure provisioners with spot capacity type
2. **Consolidation**: Enable `WhenUnderutilized` consolidation policy
3. **Single NAT Gateway**: Set `single_nat_gateway = true` for dev environments
4. **Right-sizing**: Use appropriate instance categories and generations
5. **Node Expiry**: Balance between security and churn with `expireAfter`

## Troubleshooting

### Karpenter Not Scheduling Nodes

```bash
# Check provisioner configuration
kubectl get nodepools -o yaml

# Check EC2NodeClass configuration
kubectl get ec2nodeclasses -o yaml

# Check pending pods
kubectl get pods --all-namespaces --field-selector=status.phase=Pending

# Check Karpenter logs for errors
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i error
```

### IAM Permission Issues

```bash
# Verify IRSA annotation
kubectl get sa karpenter -n karpenter -o yaml

# Check IAM role
aws iam get-role --role-name <cluster-name>-karpenter-controller

# Check IAM policy
aws iam list-attached-role-policies --role-name <cluster-name>-karpenter-controller
```

### Subnet/Security Group Discovery Issues

```bash
# Verify subnet tags
aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=<cluster-name>"

# Verify security group tags
aws ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=<cluster-name>"
```
# Karpenter Testing Guide

This guide provides step-by-step instructions to test various Karpenter features and scenarios.

## Prerequisites

```bash
# Ensure kubectl is configured
kubectl get nodes

# Ensure Karpenter is running
kubectl get pods -n karpenter

# Check NodePools
kubectl get nodepools

# Check EC2NodeClasses
kubectl get ec2nodeclasses
```

## Test 1: Basic Autoscaling

Test Karpenter's ability to provision nodes based on pending pods.

```bash
# Apply the example workloads
kubectl apply -f examples/workloads.yaml

# Scale up the inflate deployment
kubectl scale deployment inflate-general --replicas=5

# Watch Karpenter logs
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter

# In another terminal, watch nodes
kubectl get nodes -w

# Check pod status
kubectl get pods -l app=inflate-general

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep -i karpenter
```

**Expected Result**: Karpenter should provision new nodes within 1-2 minutes to accommodate the pending pods.

## Test 2: Scale Down and Consolidation

Test Karpenter's consolidation feature.

```bash
# Scale down the deployment
kubectl scale deployment inflate-general --replicas=0

# Watch Karpenter logs for consolidation decisions
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter | grep -i consolidat

# Watch nodes (nodes should be removed after ~30 seconds of being empty)
kubectl get nodes -w
```

**Expected Result**: Empty nodes should be cordoned, drained, and terminated automatically.

## Test 3: Different Instance Types

Test Karpenter's ability to select appropriate instance types.

```bash
# Deploy memory-intensive workload
kubectl scale deployment memory-workload --replicas=3

# Watch for node creation
kubectl get nodes -L karpenter.sh/nodepool -L node.kubernetes.io/instance-type -w

# Check which instance types were selected
kubectl get nodes -o custom-columns=NAME:.metadata.name,INSTANCE:.metadata.labels.'node\.kubernetes\.io/instance-type',CAPACITY:.metadata.labels.'karpenter\.sh/capacity-type'
```

**Expected Result**: Karpenter should select memory-optimized instances (r-family) for memory-intensive workloads.

## Test 4: Spot vs On-Demand

Test capacity type selection.

```bash
# Deploy spot-only workload
kubectl scale deployment spot-workload --replicas=3

# Deploy on-demand workload
kubectl scale deployment critical-workload --replicas=2

# Check node capacity types
kubectl get nodes -L karpenter.sh/capacity-type

# Describe nodes to see spot vs on-demand
kubectl get nodes -o custom-columns=NAME:.metadata.name,CAPACITY:.metadata.labels.'karpenter\.sh/capacity-type',INSTANCE:.metadata.labels.'node\.kubernetes\.io/instance-type'
```

**Expected Result**: Spot workloads run on spot instances, critical workloads run on on-demand instances.

## Test 5: Batch Workload

Test parallel job scaling.

```bash
# Submit a batch job
kubectl apply -f examples/workloads.yaml

# Watch job progress
kubectl get jobs -w

# Watch pods
kubectl get pods -l app=batch-job -w

# Watch node count
kubectl get nodes --no-headers | wc -l
```

**Expected Result**: Karpenter scales up to handle parallel job pods and scales down when the job completes.

## Test 6: Node Affinity and Taints

Test scheduling with node selectors and tolerations.

```bash
# If you have a compute-optimized provisioner, scale it up
kubectl scale deployment compute-workload --replicas=3

# Check that pods are scheduled on correct nodes
kubectl get pods -l workload-type=compute -o wide

# Verify nodes have the correct labels
kubectl get nodes -L workload-type
```

**Expected Result**: Pods with specific node selectors are scheduled on nodes from matching provisioners.

## Test 7: Mixed Workload

Test Karpenter with multiple simultaneous workloads.

```bash
# Scale multiple deployments
kubectl scale deployment inflate-general --replicas=10
kubectl scale deployment memory-workload --replicas=5
kubectl scale deployment spot-workload --replicas=8

# Watch Karpenter create diverse nodes
kubectl get nodes -L node.kubernetes.io/instance-type -L karpenter.sh/capacity-type -w

# Check distribution
kubectl get pods -o wide | grep -E '(inflate-general|memory-workload|spot-workload)'
```

**Expected Result**: Karpenter provisions a mix of instance types and capacity types based on workload requirements.

## Test 8: Node Expiry

Test automatic node replacement.

```bash
# Check current node ages
kubectl get nodes -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp

# For testing, you can temporarily reduce expiry time in your NodePool
kubectl edit nodepool default

# Change expireAfter to a short duration like "5m" for testing
# Watch for node rotation
kubectl get nodes -w
```

**Expected Result**: Nodes older than the expiry time are cordoned, drained, and replaced.


## Cleanup

```bash
# Scale down all workloads first
kubectl delete deployment inflate

# Wait for Karpenter to remove nodes
kubectl get nodes -w

# Destroy infrastructure
terraform destroy
```

## Important Notes

1. **Security Groups**: After initial deployment, ensure cluster security groups are tagged with `karpenter.sh/discovery=<cluster-name>`
2. **Subnets**: Private subnets are automatically tagged for Karpenter discovery
3. **Node IAM Role**: Karpenter reuses the EKS node IAM role for launched instances
4. **Interruption Queue**: SQS queue handles spot interruptions and rebalance recommendations
5. **IRSA**: Karpenter controller uses IAM Roles for Service Accounts (IRSA) for AWS API access

## Additional Resources

- [Karpenter Documentation](https://karpenter.sh/)
- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter GitHub](https://github.com/aws/karpenter)

## License
This configuration is provided as-is for educational and production use.
