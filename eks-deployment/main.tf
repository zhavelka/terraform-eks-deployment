# # versions.tf
# terraform {
#   required_version = ">= 1.0"
  
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#     kubernetes = {
#       source  = "hashicorp/kubernetes"
#       version = "~> 2.23"
#     }
#     helm = {
#       source  = "hashicorp/helm"
#       version = "~> 2.11"
#     }
#   }
# }

# # variables.tf
# variable "region" {
#   description = "AWS region"
#   type        = string
#   default     = "us-east-1"
# }

# variable "cluster_name" {
#   description = "Name of the EKS cluster"
#   type        = string
#   default     = "triton-gpu-cluster"
# }

# variable "cluster_version" {
#   description = "Kubernetes version for the EKS cluster"
#   type        = string
#   default     = "1.28"
# }

# variable "node_instance_types" {
#   description = "Instance types for GPU nodes"
#   type        = list(string)
#   default     = ["g4dn.xlarge"] # 1 NVIDIA T4 GPU, 4 vCPU, 16 GB RAM
# }

# variable "desired_capacity" {
#   description = "Desired number of worker nodes"
#   type        = number
#   default     = 2
# }

# variable "min_capacity" {
#   description = "Minimum number of worker nodes"
#   type        = number
#   default     = 1
# }

# variable "max_capacity" {
#   description = "Maximum number of worker nodes"
#   type        = number
#   default     = 3
# }

# variable "disk_size" {
#   description = "Size of the EBS volume for nodes in GB"
#   type        = number
#   default     = 100
# }

# # providers.tf
# provider "aws" {
#   region = var.region
# }

# provider "kubernetes" {
#   host                   = module.eks.cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
#   }
# }

# provider "helm" {
#   kubernetes {
#     host                   = module.eks.cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
#     }
#   }
# }

# # main.tf
# data "aws_availability_zones" "available" {
#   filter {
#     name   = "opt-in-status"
#     values = ["opt-in-not-required"]
#   }
# }

# locals {
#   vpc_cidr = "10.0.0.0/16"
#   azs      = slice(data.aws_availability_zones.available.names, 0, 3)
# }

# # VPC Configuration - Simple and reliable
# module "vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "~> 5.0"

#   name = "${var.cluster_name}-vpc"
#   cidr = local.vpc_cidr

#   azs             = local.azs
#   private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
#   public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

#   enable_nat_gateway   = true
#   single_nat_gateway   = true
#   enable_dns_hostnames = true
#   enable_dns_support   = true

#   # Enable VPC flow logs for troubleshooting
#   enable_flow_log                      = true
#   create_flow_log_cloudwatch_iam_role  = true
#   create_flow_log_cloudwatch_log_group = true

#   public_subnet_tags = {
#     "kubernetes.io/role/elb" = 1
#   }

#   private_subnet_tags = {
#     "kubernetes.io/role/internal-elb" = 1
#   }

#   tags = {
#     Terraform = "true"
#     Environment = "production"
#   }
# }

# # EKS Cluster - Core configuration only
# module "eks" {
#   source  = "terraform-aws-modules/eks/aws"
#   version = "~> 19.0"

#   cluster_name    = var.cluster_name
#   cluster_version = var.cluster_version

#   vpc_id                         = module.vpc.vpc_id
#   subnet_ids                     = module.vpc.private_subnets
#   cluster_endpoint_public_access = true

#   # Enable cluster logging
#   cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

#   # Addons
#   cluster_addons = {
#     coredns = {
#       most_recent = true
#     }
#     kube-proxy = {
#       most_recent = true
#     }
#     vpc-cni = {
#       most_recent = true
#     }
#   }

#   eks_managed_node_group_defaults = {
#     # Use Bottlerocket NVIDIA AMI
#     ami_type = "BOTTLEROCKET_x86_64_NVIDIA"
    
#     # Instance Metadata Service v2 for security
#     metadata_options = {
#       http_endpoint               = "enabled"
#       http_tokens                 = "required"
#       http_put_response_hop_limit = 2
#     }
#   }

#   eks_managed_node_groups = {
#     gpu_nodes = {
#       name = "gpu-node-group"
      
#       instance_types = var.node_instance_types
      
#       min_size     = var.min_capacity
#       max_size     = var.max_capacity
#       desired_size = var.desired_capacity
      
#       # Use Bottlerocket NVIDIA AMI - it includes NVIDIA drivers and runtime
#       ami_type = "BOTTLEROCKET_x86_64_NVIDIA"
#       platform = "bottlerocket"
      
#       # Disk configuration
#       disk_size = var.disk_size
      
#       block_device_mappings = {
#         # Root device
#         xvda = {
#           device_name = "/dev/xvda"
#           ebs = {
#             volume_size           = var.disk_size
#             volume_type           = "gp3"
#             iops                  = 3000
#             throughput            = 125
#             encrypted             = true
#             delete_on_termination = true
#           }
#         }
#         # Data volume for container images
#         xvdb = {
#           device_name = "/dev/xvdb"
#           ebs = {
#             volume_size           = 200
#             volume_type           = "gp3"
#             iops                  = 3000
#             throughput            = 125
#             encrypted             = true
#             delete_on_termination = true
#           }
#         }
#       }
      
#       labels = {
#         role = "gpu"
#         workload = "ml-inference"
#         "nvidia.com/gpu" = "true"
#       }
      
#       taints = []
      
#       tags = {
#         "k8s.io/cluster-autoscaler/enabled" = "true"
#         "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
#       }
#     }
#   }

#   # aws-auth configmap managed by EKS
#   manage_aws_auth_configmap = true

#   tags = {
#     Environment = "production"
#     Terraform   = "true"
#   }
# }

# # Metrics Server - For HPA and resource monitoring
# resource "helm_release" "metrics_server" {
#   name       = "metrics-server"
#   repository = "https://kubernetes-sigs.github.io/metrics-server/"
#   chart      = "metrics-server"
#   namespace  = "kube-system"
#   version    = "3.11.0"

#   set {
#     name  = "args[0]"
#     value = "--kubelet-insecure-tls"
#   }

#   depends_on = [module.eks]
# }

# # Cluster Autoscaler - For automatic node scaling
# resource "helm_release" "cluster_autoscaler" {
#   name       = "cluster-autoscaler"
#   repository = "https://kubernetes.github.io/autoscaler"
#   chart      = "cluster-autoscaler"
#   namespace  = "kube-system"
#   version    = "9.29.3"

#   set {
#     name  = "autoDiscovery.clusterName"
#     value = module.eks.cluster_name
#   }

#   set {
#     name  = "awsRegion"
#     value = var.region
#   }

#   set {
#     name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = module.eks.cluster_iam_role_arn
#   }

#   depends_on = [module.eks]
# }

# # outputs.tf
# output "cluster_endpoint" {
#   description = "Endpoint for EKS control plane"
#   value       = module.eks.cluster_endpoint
# }

# output "cluster_name" {
#   description = "The name of the EKS cluster"
#   value       = module.eks.cluster_name
# }

# output "cluster_security_group_id" {
#   description = "Security group ID attached to the EKS cluster"
#   value       = module.eks.cluster_security_group_id
# }

# output "node_security_group_id" {
#   description = "Security group ID attached to the EKS nodes"
#   value       = module.eks.node_security_group_id
# }

# output "configure_kubectl" {
#   description = "Configure kubectl command"
#   value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
# }

# output "test_gpu_command" {
#   description = "Command to test GPU availability"
#   value       = "kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:11.8.0-base-ubuntu22.04 -- nvidia-smi"
# }

# output "next_steps" {
#   description = "Next steps after cluster creation"
#   value = <<-EOT
#     Cluster "${module.eks.cluster_name}" is ready!
    
#     1. Configure kubectl:
#        aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}
    
#     2. Verify cluster and nodes:
#        kubectl get nodes
#        kubectl get pods -A
    
#     3. Test GPU availability (Bottlerocket NVIDIA AMI includes drivers):
#        kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:11.8.0-base-ubuntu22.04 -- nvidia-smi
    
#     4. Check GPU resources:
#        kubectl describe nodes | grep -E "Name:|gpu|nvidia|Capacity:" -A 5
    
#     5. Verify Bottlerocket:
#        kubectl get nodes -o wide
#   EOT
# }

# versions.tf
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

# variables.tf
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "triton-gpu-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.28"
}

variable "node_instance_types" {
  description = "Instance types for GPU nodes"
  type        = list(string)
  default     = ["g4dn.xlarge"] # 1 NVIDIA T4 GPU, 4 vCPU, 16 GB RAM
}

variable "desired_capacity" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "disk_size" {
  description = "Size of the EBS volume for nodes in GB"
  type        = number
  default     = 100
}

# providers.tf
provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# main.tf
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

locals {
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

# VPC Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Terraform = "true"
    Environment = "production"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # Enable OIDC Provider for IRSA
  enable_irsa = true

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type = "BOTTLEROCKET_x86_64_NVIDIA"
    
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
  }

  eks_managed_node_groups = {
    gpu_nodes = {
      name = "gpu-node-group"
      
      instance_types = var.node_instance_types
      
      min_size     = var.min_capacity
      max_size     = var.max_capacity
      desired_size = var.desired_capacity
      
      ami_type = "BOTTLEROCKET_x86_64_NVIDIA"
      platform = "bottlerocket"
      
      disk_size = var.disk_size
      
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.disk_size
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = 200
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      
      labels = {
        role = "gpu"
        workload = "ml-inference"
        "nvidia.com/gpu" = "true"
      }
      
      taints = []
      
      tags = {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  manage_aws_auth_configmap = true

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}

# IAM Policy for Cluster Autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.cluster_name}-cluster-autoscaler"
  path        = "/"
  description = "IAM policy for cluster autoscaler"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled" = "true"
            "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
          }
        }
      }
    ]
  })
}

# IAM Role for Cluster Autoscaler Service Account
module "cluster_autoscaler_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_ids   = [module.eks.cluster_name]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:cluster-autoscaler-aws-cluster-autoscaler"]
    }
  }
}

# Metrics Server
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.11.0"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.eks]
}

# Cluster Autoscaler with proper IRSA configuration
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.29.3"

  set {
    name  = "autoDiscovery.clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.region
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_autoscaler_irsa_role.iam_role_arn
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler-aws-cluster-autoscaler"
  }

  depends_on = [
    module.eks,
    module.cluster_autoscaler_irsa_role
  ]
}

# outputs.tf
output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "The name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS nodes"
  value       = module.eks.node_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_autoscaler_role_arn" {
  description = "ARN of the cluster autoscaler IAM role"
  value       = module.cluster_autoscaler_irsa_role.iam_role_arn
}

output "configure_kubectl" {
  description = "Configure kubectl command"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "test_gpu_command" {
  description = "Command to test GPU availability"
  value       = "kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:11.8.0-base-ubuntu22.04 -- nvidia-smi"
}

output "debug_autoscaler" {
  description = "Commands to debug cluster autoscaler"
  value = <<-EOT
    # Check cluster autoscaler logs:
    kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f
    
    # Check service account:
    kubectl get sa cluster-autoscaler-aws-cluster-autoscaler -n kube-system -o yaml
    
    # Check if IRSA annotation is present:
    kubectl get sa cluster-autoscaler-aws-cluster-autoscaler -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
    
    # Verify OIDC provider:
    aws iam list-open-id-connect-providers
  EOT
}

output "next_steps" {
  description = "Next steps after cluster creation"
  value = <<-EOT
    Cluster "${module.eks.cluster_name}" is ready!
    
    1. Configure kubectl:
       aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}
    
    2. Verify cluster and nodes:
       kubectl get nodes
       kubectl get pods -A
    
    3. Test GPU availability:
       kubectl run gpu-test --rm -it --restart=Never --image=nvidia/cuda:11.8.0-base-ubuntu22.04 -- nvidia-smi
    
    4. Check cluster autoscaler:
       kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f
    
    5. Verify autoscaling by creating a deployment:
       kubectl create deployment nginx --image=nginx --replicas=10
       kubectl get nodes -w
  EOT
}