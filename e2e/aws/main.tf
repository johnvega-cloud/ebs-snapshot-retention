# End-to-end harness: the smallest real fleet that exercises every rule of the
# script, plus an IAM role with exactly the policy in iam/, so the run proves
# the least-privilege policy and not just the script's logic.
#
#   backed     running, selector=true, root + 1 GiB tagged data volume  -> snapshotted
#   unselected running, selector=false                                 -> ignored
#   stopped    stopped, selector=true                                  -> ignored
#   manual     a snapshot made by hand of the data volume              -> never deleted
#
# The selector tag key and the backup policy name carry a random suffix, so
# the run cannot select or prune anything else in a shared account.
#
# Cost: three t4g.nano for the duration of the test plus a few GiB of
# snapshots for minutes: a few cents. Destroy it when the checks pass.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ebs-snapshot-retention"
      Purpose   = "e2e"
      ManagedBy = "terraform"
    }
  }
}

variable "region" {
  description = "Region for the e2e resources."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every name. Accounts that only allow IAM names matching a pattern set it accordingly."
  type        = string
  default     = "ebs-e2e"
}

variable "instance_type" {
  description = "Instance type for the three test instances (arm64, matches the AMI)."
  type        = string
  default     = "t4g.nano"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "first" {
  id = sort(data.aws_subnets.default.ids)[0]
}

resource "random_id" "run" {
  byte_length = 3
}

locals {
  suffix       = random_id.run.hex
  selector_key = "E2EBackup-${local.suffix}"
  policy       = "e2e-${local.suffix}"
}

# ---------------------------------------------------------------- fleet ------

resource "aws_instance" "backed" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.first.id
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
    tags = {
      Name = "${var.name_prefix}-backed-root"
    }
  }

  tags = {
    Name                 = "${var.name_prefix}-backed"
    (local.selector_key) = "true"
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.first.availability_zone
  size              = 1
  type              = "gp3"
  encrypted         = true

  tags = {
    Name       = "${var.name_prefix}-data"
    owner      = "team-e2e"
    CostCenter = "lab-05"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.backed.id
}

resource "aws_instance" "unselected" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.first.id
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name                 = "${var.name_prefix}-unselected"
    (local.selector_key) = "false"
  }
}

resource "aws_instance" "stopped" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.first.id
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name                 = "${var.name_prefix}-stopped"
    (local.selector_key) = "true"
  }
}

resource "aws_ec2_instance_state" "stopped" {
  instance_id = aws_instance.stopped.id
  state       = "stopped"
}

# A snapshot the tool did not create: must survive every retention run.
resource "aws_ebs_snapshot" "manual" {
  volume_id   = aws_ebs_volume.data.id
  description = "manual snapshot, not managed by ebs-snapshot-backup"

  tags = {
    Name = "${var.name_prefix}-manual"
  }
}

# ------------------------------------------------------------------ IAM ------

resource "aws_iam_role" "backup" {
  name                 = "${var.name_prefix}-ebs-snapshot-backup-${local.suffix}"
  description          = "e2e: runs ebs-snapshot-backup with the repository's least-privilege policy"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_caller_identity.current.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "backup" {
  name   = "ebs-snapshot-backup"
  role   = aws_iam_role.backup.id
  policy = file("${path.module}/../../iam/ebs-snapshot-backup-policy.json")
}
