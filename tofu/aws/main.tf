terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type = string
}

variable "aws_iac_role_arn" {
  type = string
}

variable "aws_notification_email" {
  type = string
}

provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = var.aws_iac_role_arn
  }
}
