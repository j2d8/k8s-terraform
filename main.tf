################################################################################
# Common data/locals
################################################################################

provider "aws" {
  alias  = "us-west-1"
  region = "us-west-1"
}

# data "aws_ecrpublic_authorization_token" "token" {
#   provider = aws.us-west-1
# }

data "aws_availability_zones" "available" {
  provider = aws.us-west-1
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Get the default VPC data
data "aws_vpc" "default" {
  provider = aws.us-west-1
  default  = true
}

# Get the default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  name   = "k8s-terraform"
  region = "us-west-1"

  vpc_cidr = "172.31.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}
