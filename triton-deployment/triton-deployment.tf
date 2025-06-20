# triton-complete.tf - Complete Triton deployment configuration

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
  }
}

# Variables
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster"
  type        = string
  default     = "triton-gpu-cluster"  # Must match your existing cluster name
}

variable "model_repository_bucket_suffix" {
  description = "Suffix for the S3 bucket name (will be prepended with cluster name)"
  type        = string
  default     = "triton-models"
}

variable "use_custom_image" {
  description = "Whether to use custom Triton image with ML frameworks"
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  description = "Name for the ECR repository"
  type        = string
  default     = "triton-ml-all"
}

variable "triton_image_tag" {
  description = "Tag for the Triton image"
  type        = string
  default     = "23.10-py3-all-frameworks"
}

variable "triton_replicas" {
  description = "Number of Triton server replicas"
  type        = number
  default     = 1
}

variable "triton_gpu_count" {
  description = "Number of GPUs per Triton pod"
  type        = string
  default     = "1"
}

variable "triton_memory_limit" {
  description = "Memory limit for Triton pods"
  type        = string
  default     = "8Gi"
}

variable "triton_cpu_limit" {
  description = "CPU limit for Triton pods"
  type        = string
  default     = "4"
}

variable "model_poll_seconds" {
  description = "How often Triton polls S3 for model updates (in seconds)"
  type        = number
  default     = 60
}

variable "enable_autoscaling" {
  description = "Enable horizontal pod autoscaling for Triton"
  type        = bool
  default     = true
}

variable "min_replicas" {
  description = "Minimum number of Triton replicas (if autoscaling enabled)"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of Triton replicas (if autoscaling enabled)"
  type        = number
  default     = 3
}

# Data sources - reference existing EKS cluster
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

# Get OIDC provider info
data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# Providers
provider "aws" {
  region = var.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# ECR Repository for custom Triton image
resource "aws_ecr_repository" "triton" {
  count = var.use_custom_image ? 1 : 0
  
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"
  
  image_scanning_configuration {
    scan_on_push = true
  }
  
  tags = {
    Name        = "Triton ML Server Repository"
    Environment = "production"
    Terraform   = "true"
  }
}

# ECR Lifecycle Policy
resource "aws_ecr_lifecycle_policy" "triton" {
  count = var.use_custom_image ? 1 : 0
  
  repository = aws_ecr_repository.triton[0].name
  
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Local file for Dockerfile
resource "local_file" "dockerfile" {
  count = var.use_custom_image ? 1 : 0
  
  filename = "${path.module}/Dockerfile.triton-ml-all"
  content  = <<-EOF
# Custom Triton image with PyTorch, TensorFlow, ONNX, and other ML framework support
FROM nvcr.io/nvidia/tritonserver:23.10-py3

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip3 install --upgrade pip setuptools wheel

# Install PyTorch with CUDA 11.8 support (using available version)
RUN pip3 install torch==2.0.1 torchvision==0.15.2 torchaudio==2.0.2 --index-url https://download.pytorch.org/whl/cu118

# Install TensorFlow with GPU support
RUN pip3 install tensorflow[and-cuda]==2.14.0

# Install ONNX Runtime with GPU support
RUN pip3 install onnxruntime-gpu==1.16.3 \
                 onnx==1.15.0 \
                 onnxconverter-common==1.14.0

# Install Transformers and LLM-related packages
RUN pip3 install transformers==4.35.2 \
                 accelerate==0.25.0 \
                 sentencepiece==0.1.99 \
                 tokenizers==0.15.0 \
                 safetensors==0.4.1 \
                 datasets==2.15.0 \
                 evaluate==0.4.1

# Install additional ML frameworks and utilities
RUN pip3 install scikit-learn==1.3.2 \
                 pandas==2.1.4 \
                 numpy==1.24.4 \
                 scipy==1.11.4 \
                 opencv-python-headless==4.8.1.78 \
                 pillow==10.1.0 \
                 matplotlib==3.8.2 \
                 seaborn==0.13.0

# Install model optimization tools
RUN pip3 install onnx-simplifier==0.4.35 \
                 tf2onnx==1.15.1

# Install additional utilities
RUN pip3 install protobuf==3.20.3 \
                 grpcio==1.60.0 \
                 boto3==1.33.13 \
                 requests==2.31.0 \
                 pyyaml==6.0.1 \
                 tqdm==4.66.1

# Set environment variables for better GPU memory management
ENV PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512
ENV TF_FORCE_GPU_ALLOW_GROWTH=true
ENV TF_CPP_MIN_LOG_LEVEL=2
ENV TOKENIZERS_PARALLELISM=false
ENV OMP_NUM_THREADS=1

# Create model cache directory
RUN mkdir -p /models/.cache && chmod 777 /models/.cache
ENV TRANSFORMERS_CACHE=/models/.cache
ENV HF_HOME=/models/.cache

WORKDIR /opt/tritonserver
EOF
}

# Build script
resource "local_file" "build_script" {
  count = var.use_custom_image ? 1 : 0
  
  filename = "${path.module}/build_and_push_triton.sh"
  file_permission = "0755"
  content  = <<-EOF
#!/bin/bash
set -e

echo "Building custom Triton image..."

# Get ECR login
aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com

# Build image
docker build -f ${local_file.dockerfile[0].filename} -t ${aws_ecr_repository.triton[0].repository_url}:${var.triton_image_tag} .

# Push image
docker push ${aws_ecr_repository.triton[0].repository_url}:${var.triton_image_tag}

# Also tag and push as latest
docker tag ${aws_ecr_repository.triton[0].repository_url}:${var.triton_image_tag} ${aws_ecr_repository.triton[0].repository_url}:latest
docker push ${aws_ecr_repository.triton[0].repository_url}:latest

echo "Image pushed successfully!"
EOF
}

# Define the Triton image URL
locals {
  triton_image = var.use_custom_image ? "${aws_ecr_repository.triton[0].repository_url}:${var.triton_image_tag}" : "nvcr.io/nvidia/tritonserver:23.10-py3"
}

# S3 Bucket for Model Repository
resource "aws_s3_bucket" "model_repository" {
  bucket = "${var.cluster_name}-${var.model_repository_bucket_suffix}-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Name        = "Triton Model Repository"
    Environment = "production"
    Terraform   = "true"
  }
}

resource "aws_s3_bucket_versioning" "model_repository" {
  bucket = aws_s3_bucket.model_repository.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "model_repository" {
  bucket = aws_s3_bucket.model_repository.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Create initial models directory in S3
resource "aws_s3_object" "models_directory" {
  bucket = aws_s3_bucket.model_repository.id
  key    = "models/.keep"
  content = ""
  
  depends_on = [aws_s3_bucket.model_repository]
}

# Create namespace for Triton
resource "kubernetes_namespace" "triton" {
  metadata {
    name = "triton-inference"
  }
}

# IAM Policy for S3 Access
resource "aws_iam_policy" "triton_s3_access" {
  name        = "${var.cluster_name}-triton-s3-access"
  description = "IAM policy for Triton to access S3 model repository"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetObjectVersion",
          "s3:ListBucketVersions"
        ]
        Resource = [
          aws_s3_bucket.model_repository.arn,
          "${aws_s3_bucket.model_repository.arn}/*"
        ]
      }
    ]
  })
}

# IAM Role for Service Account (IRSA)
data "aws_iam_policy_document" "triton_assume_role_policy" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:triton-inference:triton-inference-server"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "triton_s3_role" {
  name               = "${var.cluster_name}-triton-s3-role"
  assume_role_policy = data.aws_iam_policy_document.triton_assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "triton_s3_policy" {
  policy_arn = aws_iam_policy.triton_s3_access.arn
  role       = aws_iam_role.triton_s3_role.name
}

# Service Account for Triton
resource "kubernetes_service_account" "triton" {
  metadata {
    name      = "triton-inference-server"
    namespace = kubernetes_namespace.triton.metadata[0].name
    
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.triton_s3_role.arn
    }
  }
}

# ConfigMap for Triton configuration
resource "kubernetes_config_map" "triton_config" {
  metadata {
    name      = "triton-config"
    namespace = kubernetes_namespace.triton.metadata[0].name
  }

  data = {
    "config.pbtxt" = <<-EOT
    # Example model configuration
    # Place model-specific configs in S3 under each model directory
    EOT
  }
}

# Triton Deployment
resource "kubernetes_deployment" "triton" {
  metadata {
    name      = "triton-inference-server"
    namespace = kubernetes_namespace.triton.metadata[0].name
    
    labels = {
      app = "triton-inference-server"
    }
  }

  spec {
    replicas = var.triton_replicas

    selector {
      match_labels = {
        app = "triton-inference-server"
      }
    }

    template {
      metadata {
        labels = {
          app = "triton-inference-server"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.triton.metadata[0].name
        
        container {
          name  = "triton"
          image = local.triton_image
          
          args = [
            "tritonserver",
            "--model-repository=s3://${aws_s3_bucket.model_repository.id}/models",
            "--model-control-mode=poll",
            "--repository-poll-secs=${var.model_poll_seconds}",
            "--strict-model-config=false",
            "--log-verbose=1",
            "--metrics-port=8002",
            "--backend-config=python,shm-default-byte-size=10485760",
            "--backend-config=python,shm-growth-byte-size=10485760",
            "--backend-config=python,stub-timeout-seconds=3600",  # 60 minutes
            "--backend-config=python,startup-timeout-seconds=3600",  # 60 minutes
            "--backend-config=python,grpc-timeout-milliseconds=3600000"  # 60 minutes
          ]
          
          port {
            name           = "http"
            container_port = 8000
          }
          
          port {
            name           = "grpc"
            container_port = 8001
          }
          
          port {
            name           = "metrics"
            container_port = 8002
          }
          
          env {
            name  = "AWS_REGION"
            value = var.region
          }
          
          # Set AWS web identity token file for IRSA
          env {
            name  = "AWS_WEB_IDENTITY_TOKEN_FILE"
            value = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
          }
          
          env {
            name  = "AWS_ROLE_ARN"
            value = aws_iam_role.triton_s3_role.arn
          }
          
          resources {
            limits = {
              "nvidia.com/gpu" = var.triton_gpu_count
              memory           = var.triton_memory_limit
              cpu              = var.triton_cpu_limit
            }
            requests = {
              cpu              = "2"
              memory           = "4Gi"
              "nvidia.com/gpu" = var.triton_gpu_count
            }
          }
          
          liveness_probe {
            http_get {
              path = "/v2/health/live"
              port = "http"
            }
            initial_delay_seconds = 120   # 2 minutes (server starts fast, packages install later)
            period_seconds        = 30    # Check every 30 seconds
            timeout_seconds       = 5     # 5 second timeout
            failure_threshold     = 3     # Restart after 3 failures
          }
          
          readiness_probe {
            http_get {
              path = "/v2/health/ready"
              port = "http"
            }
            initial_delay_seconds = 240  # 15 minutes initial wait
            period_seconds        = 30    # Check every 30 seconds
            timeout_seconds       = 10    # 10 second timeout per check
            failure_threshold     = 20    # Allow 20 failures (10 more minutes)
            success_threshold     = 1     # Only need 1 success
          }
          
          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }
        }
        
        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = "2Gi"
          }
        }
        
        # Schedule on GPU nodes
        node_selector = {
          role = "gpu"
        }
        
        # Tolerate any GPU node taints if they exist
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      }
    }
  }
  
  timeouts {
    create = "10m"
    update = "10m"
  }
}

# Service for Triton
resource "kubernetes_service" "triton" {
  metadata {
    name      = "triton-inference-server"
    namespace = kubernetes_namespace.triton.metadata[0].name
    
    labels = {
      app = "triton-inference-server"
    }
  }

  spec {
    selector = {
      app = "triton-inference-server"
    }
    
    type = "ClusterIP"  # Internal service
    
    port {
      name        = "http"
      port        = 8000
      target_port = 8000
      protocol    = "TCP"
    }
    
    port {
      name        = "grpc"
      port        = 8001
      target_port = 8001
      protocol    = "TCP"
    }
    
    port {
      name        = "metrics"
      port        = 8002
      target_port = 8002
      protocol    = "TCP"
    }
  }
}

# HorizontalPodAutoscaler for Triton (conditional)
resource "kubernetes_horizontal_pod_autoscaler_v2" "triton" {
  count = var.enable_autoscaling ? 1 : 0
  
  metadata {
    name      = "triton-inference-server"
    namespace = kubernetes_namespace.triton.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.triton.metadata[0].name
    }

    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    metric {
      type = "Resource"
      
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
    
    metric {
      type = "Resource"
      
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

# Outputs
output "ecr_repository_url" {
  description = "ECR repository URL for custom Triton image"
  value       = var.use_custom_image ? aws_ecr_repository.triton[0].repository_url : "Using default Triton image"
}

output "ecr_build_commands" {
  description = "Commands to build and push custom Triton image"
  value = var.use_custom_image ? "cd ${path.module} && ./build_and_push_triton.sh" : "Not using custom image"
}

output "model_repository_bucket" {
  description = "S3 bucket for Triton model repository"
  value       = aws_s3_bucket.model_repository.id
}

output "model_repository_bucket_arn" {
  description = "ARN of the S3 bucket for Triton model repository"
  value       = aws_s3_bucket.model_repository.arn
}

output "triton_service_name" {
  description = "Kubernetes service name for Triton"
  value       = kubernetes_service.triton.metadata[0].name
}

output "triton_namespace" {
  description = "Kubernetes namespace for Triton"
  value       = kubernetes_namespace.triton.metadata[0].name
}

output "triton_iam_role_arn" {
  description = "IAM role ARN for Triton S3 access"
  value       = aws_iam_role.triton_s3_role.arn
}

output "triton_image_used" {
  description = "Triton image being used"
  value       = local.triton_image
}

output "upload_model_command" {
  description = "Example command to upload a model to S3"
  value = "aws s3 cp ./my_model_dir s3://${aws_s3_bucket.model_repository.id}/models/my_model/1/ --recursive"
}

output "test_triton_commands" {
  description = "Commands to test Triton deployment"
  value = <<-EOT
# Check if Triton is running
kubectl get pods -n triton-inference

# Check Triton logs
kubectl logs -n triton-inference -l app=triton-inference-server

# Port-forward to test locally
kubectl port-forward -n triton-inference svc/triton-inference-server 8000:8000

# Test endpoints (in another terminal)
curl http://localhost:8000/v2/health/ready
curl http://localhost:8000/v2/models
EOT
}

output "next_steps" {
  description = "Next steps for deployment"
  value = <<-EOT
${var.use_custom_image ? "1. Build and push the custom Triton image:\n   cd ${path.module}\n   ./build_and_push_triton.sh\n\n2. After image is pushed, update the deployment:\n   terraform apply -replace=\"kubernetes_deployment.triton\"\n\n3. Upload your models to S3:\n   aws s3 cp ./your_model s3://${aws_s3_bucket.model_repository.id}/models/your_model/ --recursive\n\n4. Test the deployment:\n   kubectl port-forward -n triton-inference svc/triton-inference-server 8000:8000\n   curl http://localhost:8000/v2/models" : "1. Upload your models to S3:\n   aws s3 cp ./your_model s3://${aws_s3_bucket.model_repository.id}/models/your_model/ --recursive\n\n2. Test the deployment:\n   kubectl port-forward -n triton-inference svc/triton-inference-server 8000:8000\n   curl http://localhost:8000/v2/models"}
EOT
}