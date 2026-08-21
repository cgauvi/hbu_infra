data "aws_caller_identity" "current" {}

locals {
  prefix = "${var.project_name}-${var.environment}"
}

# Read the VPC, subnets, and DB subnet groups from the shared stack, so this
# per-env stack can place a database into networking it does not own.
#
# The shared stack lives in shared/ and uses the state key
# hbu/shared/terraform.tfstate within the same backend bucket.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-tf-state-${data.aws_caller_identity.current.account_id}"
    key    = "${var.project_name}/shared/terraform.tfstate"
    region = var.aws_region
  }
}
