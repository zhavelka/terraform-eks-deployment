#!/bin/bash
# simple_build.sh - Build without buildx for more control

set -e

# Variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="069435869585"
ECR_REPO="triton-ml-all"
IMAGE_TAG="23.10-py3-all-frameworks"

# Login to ECR
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

echo "Building Triton image (this may take 20-30 minutes)..."

# Build with standard docker build (will build for your current platform)
DOCKER_BUILDKIT=1 docker build \
    --platform linux/amd64 \
    -f Dockerfile.triton-ml-all \
    -t ${ECR_REPO}:${IMAGE_TAG} \
    --progress=plain \
    .

# Tag for ECR
docker tag ${ECR_REPO}:${IMAGE_TAG} ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}
docker tag ${ECR_REPO}:${IMAGE_TAG} ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest

# Push to ECR
echo "Pushing to ECR..."
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}
docker push ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:latest

echo "Done!"
echo "Image: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}"
