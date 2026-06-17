###############################################################################
# Production terraform.tfvars
# DO NOT store sensitive values here.
# Pass secrets via environment variables:
#   export TF_VAR_db_master_password="..."
#   export TF_VAR_redis_auth_token="..."
#   export TF_VAR_pagerduty_endpoint="..."
#   export TF_VAR_slack_webhook_url="..."
###############################################################################

aws_region         = "us-east-1"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

# Restrict EKS API server to your VPN/office CIDR in production
api_server_allowed_cidrs = ["0.0.0.0/0"] # CHANGE THIS before go-live

# Replace with actual ACM certificate ARNs after cert provisioning
acm_certificate_arn           = "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID"
acm_certificate_arn_us_east_1 = "arn:aws:acm:us-east-1:ACCOUNT_ID:certificate/CERT_ID"

domain_aliases       = ["api.gmsol.io"]
cors_allowed_origins = ["https://app.gmsol.io", "https://gmsol.io"]
