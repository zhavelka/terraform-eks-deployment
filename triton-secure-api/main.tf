# terraform {
#   required_version = ">= 1.0"
  
#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.0"
#     }
#   }
# }

# # Variables
# variable "region" {
#   description = "AWS region"
#   type        = string
#   default     = "us-east-1"
# }

# variable "cluster_name" {
#   description = "EKS cluster name where Triton is deployed"
#   type        = string
#   default     = "triton-gpu-cluster"
# }

# variable "api_name" {
#   description = "Name for the API Gateway"
#   type        = string
#   default     = "triton-inference-api"
# }

# variable "stage_name" {
#   description = "API Gateway stage name"
#   type        = string
#   default     = "prod"
# }

# variable "vpc_id" {
#   description = "VPC ID where your EKS cluster is running"
#   type        = string
# }

# variable "private_subnet_ids" {
#   description = "Private subnet IDs where your EKS nodes are running"
#   type        = list(string)
# }

# variable "node_security_group_id" {
#   description = "Security group ID of your EKS nodes"
#   type        = string
#   default     = "sg-0d12f623ca8e340e3"
# }

# # Provider
# provider "aws" {
#   region = var.region
# }

# # Data source for VPC (using the provided VPC ID)
# data "aws_vpc" "eks_vpc" {
#   id = var.vpc_id
# }

# # Cognito User Pool
# resource "aws_cognito_user_pool" "triton" {
#   name = "${var.api_name}-users"

#   password_policy {
#     minimum_length    = 8
#     require_lowercase = true
#     require_numbers   = true
#     require_symbols   = true
#     require_uppercase = true
#   }

#   schema {
#     name                     = "email"
#     attribute_data_type      = "String"
#     required                 = true
#     mutable                  = true
#     developer_only_attribute = false

#     string_attribute_constraints {
#       min_length = 0
#       max_length = 2048
#     }
#   }

#   auto_verified_attributes = ["email"]
#   email_configuration {
#     email_sending_account = "COGNITO_DEFAULT"
#   }
#   mfa_configuration = "OFF"
# }

# # Cognito User Pool Client
# resource "aws_cognito_user_pool_client" "api_client" {
#   name         = "${var.api_name}-api-client"
#   user_pool_id = aws_cognito_user_pool.triton.id

#   generate_secret = false
  
#   explicit_auth_flows = [
#     "ALLOW_USER_PASSWORD_AUTH",
#     "ALLOW_REFRESH_TOKEN_AUTH",
#     "ALLOW_ADMIN_USER_PASSWORD_AUTH"
#   ]
# }

# # Security group rule to allow NLB to access NodePort
# resource "aws_security_group_rule" "allow_nlb_nodeport" {
#   type              = "ingress"
#   from_port         = 31080
#   to_port           = 31080
#   protocol          = "tcp"
#   cidr_blocks       = [data.aws_vpc.eks_vpc.cidr_block]
#   security_group_id = var.node_security_group_id
#   description       = "Allow NLB to reach NodePort for Triton API"
# }

# # Network Load Balancer
# resource "aws_lb" "triton_nlb" {
#   name               = "triton-api-nlb"
#   internal           = true
#   load_balancer_type = "network"
#   subnets            = var.private_subnet_ids
  
#   enable_deletion_protection = false
# }

# # Target Group
# resource "aws_lb_target_group" "triton" {
#   name     = "triton-api-tg"
#   port     = 31080
#   protocol = "TCP"
#   vpc_id   = var.vpc_id
  
#   health_check {
#     enabled             = true
#     healthy_threshold   = 2
#     unhealthy_threshold = 2
#     timeout             = 5
#     interval            = 30
#     protocol            = "TCP"
#   }
# }

# # You'll need to manually attach your EKS nodes to this target group
# # Or use auto-scaling group attachment if you know the ASG name

# # NLB Listener
# resource "aws_lb_listener" "triton" {
#   load_balancer_arn = aws_lb.triton_nlb.arn
#   port              = "80"
#   protocol          = "TCP"
  
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.triton.arn
#   }
# }

# # VPC Link for API Gateway
# resource "aws_api_gateway_vpc_link" "triton" {
#   name        = "${var.cluster_name}-triton-vpc-link"
#   target_arns = [aws_lb.triton_nlb.arn]
# }

# # API Gateway
# resource "aws_api_gateway_rest_api" "triton" {
#   name        = var.api_name
#   description = "Cognito authenticated API for Triton Inference Server"
  
#   endpoint_configuration {
#     types = ["REGIONAL"]
#   }
# }

# # Cognito Authorizer
# resource "aws_api_gateway_authorizer" "cognito" {
#   name          = "cognito-authorizer"
#   type          = "COGNITO_USER_POOLS"
#   rest_api_id   = aws_api_gateway_rest_api.triton.id
#   provider_arns = [aws_cognito_user_pool.triton.arn]
# }

# # API Gateway Resources
# resource "aws_api_gateway_resource" "proxy" {
#   rest_api_id = aws_api_gateway_rest_api.triton.id
#   parent_id   = aws_api_gateway_rest_api.triton.root_resource_id
#   path_part   = "{proxy+}"
# }

# # Method for proxy
# resource "aws_api_gateway_method" "proxy" {
#   rest_api_id   = aws_api_gateway_rest_api.triton.id
#   resource_id   = aws_api_gateway_resource.proxy.id
#   http_method   = "ANY"
#   authorization = "COGNITO_USER_POOLS"
#   authorizer_id = aws_api_gateway_authorizer.cognito.id
  
#   request_parameters = {
#     "method.request.path.proxy" = true
#   }
# }

# # Integration
# resource "aws_api_gateway_integration" "proxy" {
#   rest_api_id = aws_api_gateway_rest_api.triton.id
#   resource_id = aws_api_gateway_resource.proxy.id
#   http_method = aws_api_gateway_method.proxy.http_method
  
#   type                    = "HTTP_PROXY"
#   integration_http_method = "ANY"
#   uri                     = "http://${aws_lb.triton_nlb.dns_name}/{proxy}"
#   connection_type         = "VPC_LINK"
#   connection_id           = aws_api_gateway_vpc_link.triton.id
  
#   request_parameters = {
#     "integration.request.path.proxy" = "method.request.path.proxy"
#   }
# }

# # Deploy API
# resource "aws_api_gateway_deployment" "triton" {
#   depends_on = [
#     aws_api_gateway_integration.proxy
#   ]
  
#   rest_api_id = aws_api_gateway_rest_api.triton.id
#   stage_name  = var.stage_name
# }

# # Outputs
# output "api_endpoint" {
#   value = "https://${aws_api_gateway_rest_api.triton.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}"
# }

# output "user_pool_id" {
#   value = aws_cognito_user_pool.triton.id
# }

# output "user_pool_client_id" {
#   value = aws_cognito_user_pool_client.api_client.id
# }

# output "target_group_arn" {
#   value = aws_lb_target_group.triton.arn
# }

# output "next_steps" {
#   value = <<-EOT
  
#   IMPORTANT: After applying, you need to:
  
#   1. Attach your EKS nodes to the target group:
#      aws elbv2 register-targets \
#        --target-group-arn ${aws_lb_target_group.triton.arn} \
#        --targets Id=i-0807337427684f093 Id=i-06d59e5f91492c2f2 \
#        --region ${var.region}
  
#   2. Create a user:
#      aws cognito-idp admin-create-user \
#        --user-pool-id <POOL_ID> \
#        --username test@example.com \
#        --user-attributes Name=email,Value=test@example.com \
#        --temporary-password 'TempPass123!' \
#        --region ${var.region}
  
#   3. Test the API with the instructions from the output
#   EOT
# }

terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
  description = "EKS cluster name where Triton is deployed"
  type        = string
  default     = "triton-gpu-cluster"
}

variable "api_name" {
  description = "Name for the API Gateway"
  type        = string
  default     = "triton-inference-api"
}

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "VPC ID where your EKS cluster is running"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where your EKS nodes are running"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group ID of your EKS nodes"
  type        = string
  default     = "sg-0d12f623ca8e340e3"
}

# Provider
provider "aws" {
  region = var.region
}

# Data source for VPC (using the provided VPC ID)
data "aws_vpc" "eks_vpc" {
  id = var.vpc_id
}

# Get the node instances dynamically
data "aws_instances" "eks_nodes" {
  filter {
    name   = "tag:eks:cluster-name"
    values = ["triton-gpu-cluster"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

# Cognito User Pool
resource "aws_cognito_user_pool" "triton" {
  name = "${var.api_name}-users"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  auto_verified_attributes = ["email"]
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }
  mfa_configuration = "OFF"
}

# Cognito User Pool Client
resource "aws_cognito_user_pool_client" "api_client" {
  name         = "${var.api_name}-api-client"
  user_pool_id = aws_cognito_user_pool.triton.id

  generate_secret = false
  
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH"
  ]
}

# Security group rule to allow NLB to access NodePort
resource "aws_security_group_rule" "allow_nlb_nodeport" {
  type              = "ingress"
  from_port         = 31080
  to_port           = 31080
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.eks_vpc.cidr_block]
  security_group_id = var.node_security_group_id
  description       = "Allow NLB to reach NodePort for Triton API"
}

# Network Load Balancer
resource "aws_lb" "triton_nlb" {
  name               = "triton-api-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
  
  enable_deletion_protection = false
}

# Target Group
resource "aws_lb_target_group" "triton" {
  name     = "triton-api-tg"
  port     = 31080
  protocol = "TCP"
  vpc_id   = var.vpc_id
  
  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    protocol            = "TCP"
  }
}

# Register all nodes dynamically
resource "aws_lb_target_group_attachment" "nodes" {
  for_each = toset(data.aws_instances.eks_nodes.ids)
  
  target_group_arn = aws_lb_target_group.triton.arn
  target_id        = each.value
  port             = 31080
}

# NLB Listener
resource "aws_lb_listener" "triton" {
  load_balancer_arn = aws_lb.triton_nlb.arn
  port              = "80"
  protocol          = "TCP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.triton.arn
  }
}

# VPC Link for API Gateway
resource "aws_api_gateway_vpc_link" "triton" {
  name        = "${var.cluster_name}-triton-vpc-link"
  target_arns = [aws_lb.triton_nlb.arn]
}

# API Gateway
resource "aws_api_gateway_rest_api" "triton" {
  name        = var.api_name
  description = "Cognito authenticated API for Triton Inference Server"
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Cognito Authorizer
resource "aws_api_gateway_authorizer" "cognito" {
  name          = "cognito-authorizer"
  type          = "COGNITO_USER_POOLS"
  rest_api_id   = aws_api_gateway_rest_api.triton.id
  provider_arns = [aws_cognito_user_pool.triton.arn]
}

# API Gateway Resources
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.triton.id
  parent_id   = aws_api_gateway_rest_api.triton.root_resource_id
  path_part   = "{proxy+}"
}

# Method for proxy
resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.triton.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
  
  request_parameters = {
    "method.request.path.proxy" = true
  }
}

# Integration
resource "aws_api_gateway_integration" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.triton.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy.http_method
  
  type                    = "HTTP_PROXY"
  integration_http_method = "ANY"
  uri                     = "http://${aws_lb.triton_nlb.dns_name}/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.triton.id
  
  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

# Deploy API
resource "aws_api_gateway_deployment" "triton" {
  depends_on = [
    aws_api_gateway_integration.proxy
  ]
  
  rest_api_id = aws_api_gateway_rest_api.triton.id
  stage_name  = var.stage_name
}

# Outputs
output "api_endpoint" {
  value = "https://${aws_api_gateway_rest_api.triton.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}"
}

output "user_pool_id" {
  value = aws_cognito_user_pool.triton.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.api_client.id
}

output "target_group_arn" {
  value = aws_lb_target_group.triton.arn
}

output "next_steps" {
  value = <<-EOT
  
  1. Create a user:
     aws cognito-idp admin-create-user \
       --user-pool-id ${aws_cognito_user_pool.triton.id} \
       --username test@example.com \
       --user-attributes Name=email,Value=test@example.com \
       --temporary-password 'TempPass123!' \
       --region ${var.region}
  
  2. Set permanent password:
     aws cognito-idp admin-set-user-password \
       --user-pool-id ${aws_cognito_user_pool.triton.id} \
       --username test@example.com \
       --password 'YourPass123!' \
       --permanent \
       --region ${var.region}
  
  3. Get auth token:
     TOKEN=$(aws cognito-idp initiate-auth \
       --client-id ${aws_cognito_user_pool_client.api_client.id} \
       --auth-flow USER_PASSWORD_AUTH \
       --auth-parameters USERNAME=test@example.com,PASSWORD='YourPass123!' \
       --region ${var.region} \
       --query 'AuthenticationResult.IdToken' \
       --output text)
  
  4. Test the API:
     curl -H "Authorization: $$TOKEN" \
       https://${aws_api_gateway_rest_api.triton.id}.execute-api.${var.region}.amazonaws.com/${var.stage_name}/v2/health/ready
  EOT
}