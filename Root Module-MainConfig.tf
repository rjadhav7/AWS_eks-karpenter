###############################################
# main.tf (Root Module)
###############################################

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.9"
    }
  }

  # Uncomment and configure your backend
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "karpenter/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "Terraform"
      Project     = "Karpenter"
    }
  }
}

###############################################
# Data Sources for Existing EKS Cluster
###############################################

data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

###############################################
# Kubernetes and Helm Providers
###############################################

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

###############################################
# Update EKS Cluster Security Group
###############################################

data "aws_vpc" "cluster_vpc" {
  id = data.aws_eks_cluster.cluster.vpc_config[0].vpc_id
}

# Allow Karpenter nodes to communicate with the cluster
resource "aws_vpc_security_group_ingress_rule" "karpenter_cluster_sg" {
  security_group_id = data.aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  
  description = "Allow nodes to communicate with the cluster API Server"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
  cidr_ipv4   = data.aws_vpc.cluster_vpc.cidr_block

  tags = {
    Name = "${var.cluster_name}-karpenter-cluster-sg-rule"
  }
}

###############################################
# Deploy Karpenter Module
###############################################

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name       = var.cluster_name
  region             = var.region
  karpenter_version  = var.karpenter_version
  replicas           = var.karpenter_replicas
  controller_resources = var.karpenter_controller_resources

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

###############################################
# Grant Karpenter IAM Role to EKS aws-auth
###############################################

# Note: This requires that your EKS cluster has the aws-auth ConfigMap
# If using EKS access entries (recommended for new clusters), skip this
resource "kubectl_manifest" "karpenter_node_role_mapping" {
  count = var.enable_aws_auth_configmap ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: aws-auth
      namespace: kube-system
    data:
      mapRoles: |
        - rolearn: ${module.karpenter.node_iam_role_arn}
          username: system:node:{{EC2PrivateDNSName}}
          groups:
            - system:bootstrappers
            - system:nodes
  YAML

  depends_on = [module.karpenter]
}

# For newer EKS clusters using Access Entries
resource "aws_eks_access_entry" "karpenter_node" {
  count = var.enable_eks_access_entry ? 1 : 0

  cluster_name      = var.cluster_name
  principal_arn     = module.karpenter.node_iam_role_arn
  type              = "EC2_LINUX"
  
  depends_on = [module.karpenter]
}

###############################################
# Deploy NodePool and EC2NodeClass
###############################################

resource "kubectl_manifest" "karpenter_nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r"]
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"]
      limits:
        cpu: 1000
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [module.karpenter]
}

resource "kubectl_manifest" "karpenter_ec2nodeclass" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
        - alias: al2023@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}
      userData: |
        #!/bin/bash
        /etc/eks/bootstrap.sh ${var.cluster_name}
      tags:
        karpenter.sh/discovery: ${var.cluster_name}
        Name: karpenter-${var.cluster_name}
        Environment: ${var.environment}
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true
      metadataOptions:
        httpEndpoint: enabled
        httpProtocolIPv6: disabled
        httpPutResponseHopLimit: 2
        httpTokens: required
  YAML

  depends_on = [module.karpenter]
}
