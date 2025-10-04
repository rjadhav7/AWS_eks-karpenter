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
