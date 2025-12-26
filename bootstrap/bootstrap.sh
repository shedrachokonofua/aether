#!/bin/bash
set -e

# Bootstrap Aether AWS infrastructure
# Prerequisites: Run 'aws login' first to authenticate

echo "Checking AWS authentication..."
aws sts get-caller-identity --no-cli-pager || {
    echo "Not authenticated. Run 'aws login' first."
    exit 1
}

echo "Deploying Tofu backend stack (S3 + DynamoDB + KMS)..."
aws cloudformation deploy \
    --template-file ./bootstrap/cf/tofu.yaml \
    --stack-name aether-bootstrap-tofu \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset

echo "Tofu backend deployed."

echo "Creating Tofu state config..."
task tofu:create-state-config

echo "Initializing Tofu..."
task tofu:init

echo "Bootstrap complete!"
