terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "The GitHub repository to deploy"
  type        = string
  validation {
    condition     = can(regex("^[^/ ]+/challenge-FSL$", var.github_repository))
    error_message = "Use DarkEdson/challenge-FSL"
  }
}

variable "existing_oidc_provider_arn" {
  default     = ""
  type        = string
  description = "reuse an existing token.actions.githubusercontext"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Environment = "FSL-Challenge"
      Project     = "challenge-fsl"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name     = "challenge-fsl"
  oidc_arn = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_vpc" "demo" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${local.name}"
  }
}

resource "aws_internet_gateway" "demo" {
  vpc_id = aws_vpc.demo.id
  tags = {
    Name = "${local.name}"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.demo.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.demo.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web" {
  name        = local.name
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.demo.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecr_repository" "app" {
  name         = local.name
  force_delete = true
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ecs/${local.name}"
  retention_in_days = 1
}

resource "aws_ecs_cluster" "demo" {
  name = local.name
}

resource "aws_iam_role" "execution" {
  name = "${local.name}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "execution" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "web"
      image     = "${aws_ecr_repository.app.repository_url}:bootstrap"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q -O - http://127.0.0.1/ || exit 1"]
        interval    = 10
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "web"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.demo.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 0
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.web.id]
    assign_public_ip = true
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
  depends_on = [aws_route_table_association.public, aws_iam_role_policy.execution]
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "github" {
  name = "${local.name}-github"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "github" {
  role = aws_iam_role.github.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "ec2:DescribeNetworkInterfaces",
          "iam:PassRole"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_variables" {
  value = {
    AWS_REGION         = var.aws_region
    AWS_ROLE_ARN       = aws_iam_role.github.arn
    AWS_ECR_REPOSITORY = aws_ecr_repository.app.repository_url
    AWS_ECS_CLUSTER    = aws_ecs_cluster.demo.name
    AWS_ECS_SERVICE    = aws_ecs_service.app.name
  }
}

output "ecr_url" {
  value = aws_ecr_repository.app.repository_url
}
