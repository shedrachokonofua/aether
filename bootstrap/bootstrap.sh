#!/bin/bash
set -e

# Bootstrap Aether AWS infrastructure
# Prerequisite: provide pre-existing human AWS credentials through the standard
# AWS environment or profile chain. Unified `task login` depends on resources
# and outputs created after this backend bootstrap.

echo "Checking AWS authentication..."
aws sts get-caller-identity --no-cli-pager || {
    echo "No AWS bootstrap credentials found. Configure a human AWS profile or environment credentials first."
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
sh ./scripts/create-tofu-state-config.sh

echo "Initializing Tofu..."
task tofu:init

echo "Bootstrap complete!"
