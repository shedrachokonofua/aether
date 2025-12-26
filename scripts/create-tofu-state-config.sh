TOFU_BUCKET=$(aws cloudformation describe-stacks --stack-name aether-bootstrap-tofu --query "Stacks[0].Outputs[?OutputKey=='OpenTofuBackendBucketName'].OutputValue" --output text)
TOFU_DDB_TABLE=$(aws cloudformation describe-stacks --stack-name aether-bootstrap-tofu --query "Stacks[0].Outputs[?OutputKey=='OpenTofuBackendDynamoDBTableName'].OutputValue" --output text)
TOFU_KMS_ARN=$(aws cloudformation describe-stacks --stack-name aether-bootstrap-tofu --query "Stacks[0].Outputs[?OutputKey=='OpenTofuBackendKMSKeyArn'].OutputValue" --output text)

echo "Writing Tofu state config..."
cat <<EOF > ./config/tofu-state.config
bucket         = "${TOFU_BUCKET}"
key            = "terraform.tfstate"
region         = "${AWS_REGION}"
kms_key_id     = "${TOFU_KMS_ARN}"
dynamodb_table = "${TOFU_DDB_TABLE}"
EOF

echo "Tofu state config written successfully."
