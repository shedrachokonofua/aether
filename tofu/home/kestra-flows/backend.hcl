# Override only the state object key; bucket/region/kms/dynamodb come from
# config/tofu-state.config (shared with the root tofu module).
key = "kestra-flows.tfstate"
