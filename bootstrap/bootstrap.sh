#!/bin/bash
set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <AWS_ACCESS_KEY_ID> <AWS_SECRET_ACCESS_KEY>"
    echo "Example: $0 AKIA... secret..."
    exit 1
fi

clean_output() {
    echo "$1" | tr -d '\r'
}

AWS_ACCESS_KEY_ID=$1
AWS_SECRET_ACCESS_KEY=$2
AWS_REGION=us-east-1

aws() {
    task aws -- "$@"
}

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION

echo "Deploying bootstrap IAM stack..."

aws cloudformation deploy \
    --template-file ./bootstrap/cf/iam.yaml \
    --stack-name aether-bootstrap-iam \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset

echo "Bootstrap IAM stack deployed successfully."

echo "Getting IAM stack outputs..."
DEV_ACCESS_KEY_ID=$(clean_output "$(aws cloudformation describe-stacks --stack-name aether-bootstrap-iam --query "Stacks[0].Outputs[?OutputKey=='DevUserAccessKey'].OutputValue" --output text)")
DEV_SECRET_ACCESS_KEY=$(clean_output "$(aws cloudformation describe-stacks --stack-name aether-bootstrap-iam --query "Stacks[0].Outputs[?OutputKey=='DevUserSecretKey'].OutputValue" --output text)")
IAC_ROLE_ARN=$(clean_output "$(aws cloudformation describe-stacks --stack-name aether-bootstrap-iam --query "Stacks[0].Outputs[?OutputKey=='IACRoleArn'].OutputValue" --output text)")

echo "Setting up AWS CLI with new credentials..."
# Set up the AWS CLI with the new credentials
export AWS_ACCESS_KEY_ID=$DEV_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$DEV_SECRET_ACCESS_KEY

echo "IAC Role ARN: ${IAC_ROLE_ARN}"
echo "Assuming the IAC role..."
CREDS=$(aws sts assume-role \
    --role-arn "${IAC_ROLE_ARN}" \
    --role-session-name aether-bootstrap-iam)

export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

echo "Bootstraped IAM stack successfully."

echo "Bootstap Tofu stack..."
aws cloudformation deploy \
    --template-file ./bootstrap/cf/tofu.yaml \
    --stack-name aether-bootstrap-tofu \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset

echo "Bootstraped Tofu stack successfully."

echo "Writing secrets to ./secrets/aws-dev-user.env..."
cat <<EOF > ./secrets/aws-dev-user.env
AWS_ACCESS_KEY_ID=$DEV_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$DEV_SECRET_ACCESS_KEY
AWS_REGION=$AWS_REGION
TF_VAR_AWS_REGION=$AWS_REGION
TF_VAR_AWS_IAC_ROLE_ARN=$IAC_ROLE_ARN
EOF

task tofu:create-state-config

echo "Complete"
