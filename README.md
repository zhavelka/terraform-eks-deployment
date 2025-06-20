# terraform-eks-deployment
## Build EKS
1. `cd ./eks-deployment`
2. `terraform init`
3. `terraform plan`
4. `terraform apply`

## Build Triton
### Create a terraform.tfvars file (If Needed)
cat > terraform.tfvars << EOF
cluster_name = "triton-gpu-cluster"  # Your existing EKS cluster name
use_custom_image = true
ecr_repository_name = "triton-ml-all"
triton_image_tag = "23.10-py3-all-frameworks"
EOF

### Initialize Terraform
terraform init

### Step 1: Create ECR and infrastructure first
terraform apply -target=aws_ecr_repository.triton \
                -target=aws_ecr_lifecycle_policy.triton \
                -target=aws_s3_bucket.model_repository \
                -target=aws_s3_bucket_versioning.model_repository \
                -target=aws_s3_bucket_public_access_block.model_repository \
                -target=aws_s3_object.models_directory \
                -target=local_file.dockerfile \
                -target=local_file.build_script

### Step 2: Build and push the Docker image
./build_and_push_triton.sh

### Step 3: Deploy everything including Triton
terraform apply

## Build API Gateway
### Get all the IDs
USER_POOL_ID=$(terraform output -raw user_pool_id)
CLIENT_ID=$(terraform output -raw user_pool_client_id)
API_URL=$(terraform output -raw api_endpoint)

### Verify they're set
echo "User Pool: $USER_POOL_ID"
echo "Client ID: $CLIENT_ID"
echo "API URL: $API_URL"

### Create user with temporary password
aws cognito-idp admin-create-user \
  --user-pool-id $USER_POOL_ID \
  --username test@example.com \
  --user-attributes Name=email,Value=test@example.com Name=email_verified,Value=true \
  --temporary-password 'TempPass123!' \
  --message-action SUPPRESS \
  --region us-east-1

### Set permanent password
aws cognito-idp admin-set-user-password \
  --user-pool-id $USER_POOL_ID \
  --username test@example.com \
  --password 'SecurePass123!' \
  --permanent \
  --region us-east-1

### Get token
TOKEN=$(aws cognito-idp initiate-auth \
  --client-id $CLIENT_ID \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=test@example.com,PASSWORD='SecurePass123!' \
  --region us-east-1 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

### Verify token was retrieved
echo "Token received: ${TOKEN:0:50}..."

### Test health endpoint
curl -v -H "Authorization: $TOKEN" $API_URL/v2/health/ready

### List models
curl -H "Authorization: $TOKEN" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"ready": true}' \
  $API_URL/v2/repository/index

### Test inference
curl -X POST \
  -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      {
        "name": "text_input",
        "shape": [1, 1],
        "datatype": "BYTES",
        "data": [["Hello, what is the capital of California?"]]
      },
      {
        "name": "max_tokens",
        "shape": [1, 1],
        "datatype": "INT32",
        "data": [[50]]
      },
      {
        "name": "temperature",
        "shape": [1, 1],
        "datatype": "FP32",
        "data": [[0.7]]
      }
    ],
    "outputs": [{"name": "text_output"}]
  }' \
  $API_URL/v2/models/tinyllama/infer