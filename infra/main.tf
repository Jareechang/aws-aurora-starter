provider "aws" {
  version = "~> 2.0"
  region  = var.aws_region
}

provider "random" {
  version = "~> 2.2.0"
}

locals {
  # Target port to expose
  target_port = 3000

  # VPV
  vpc_az = ["us-east-1a", "us-east-1b", "us-east-1d"]

  # ECS Service config
  ecs_launch_type = "FARGATE"
  ecs_desired_count = 2
  ecs_network_mode = "awsvpc"
  ecs_cpu = 512
  ecs_memory = 1024
  ecs_container_name = "nextjs-image"
  ecs_log_group = "/aws/ecs/${var.project_id}-${var.env}"
  # Retention in days
  ecs_log_retention = 1

  # Deployment Configuration
  ecs_deployment_type = "TimeBasedCanary"
  ## In minutes
  ecs_deployment_config_interval = 1
  ## In percentage
  ecs_deployment_config_pct = 99
}

module "networking" {
  source = "github.com/Jareechang/tf-modules//networking?ref=v1.0.20"
  env = var.env
  project_id = var.project_id
  subnet_public_cidrblock = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24"
  ]
  subnet_private_cidrblock = [
    "10.0.10.0/24",
    "10.0.21.0/24",
    "10.0.31.0/24"
  ]
  azs = local.vpc_azs
}

## Load Balancer and Target groups
module "ecs_tg_blue" {
  source              = "github.com/Jareechang/tf-modules//alb?ref=v1.0.2"
  create_target_group = true
  port                = local.target_port
  protocol            = "HTTP"
  target_type         = "ip"
  vpc_id              = module.networking.vpc_id
}

# Target group for new infrastructure
module "ecs_tg_green" {
  project_id          = "${var.project_id}-green"
  source              = "github.com/Jareechang/tf-modules//alb?ref=v1.0.2"
  create_target_group = true
  port                = local.target_port
  protocol            = "HTTP"
  target_type         = "ip"
  vpc_id              = module.networking.vpc_id
}

module "alb" {
  source             = "github.com/Jareechang/tf-modules//alb?ref=v1.0.2"
  create_alb         = true
  enable_https       = false
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_ecs_sg.id]
  subnets            = module.networking.public_subnets[*].id
  target_group       = module.ecs_tg_blue.tg.arn
}

#### Security groups
resource "aws_security_group" "alb_ecs_sg" {
  vpc_id = module.networking.vpc_id

  ## Allow inbound on port 80 from internet (all traffic)
  ingress {
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ## Allow outbound to ecs instances in private subnet
  egress {
    protocol    = "tcp"
    from_port   = local.target_port
    to_port     = local.target_port
    cidr_blocks = module.networking.private_subnets[*].cidr_block
  }
}

resource "aws_security_group" "ecs_sg" {
  vpc_id = module.networking.vpc_id
  ingress {
    protocol         = "tcp"
    from_port        = local.target_port
    to_port          = local.target_port
    security_groups  = [aws_security_group.alb_ecs_sg.id]
  }

  ## Allow ECS service to reach out to internet (download packages, pull images etc)
  egress {
    protocol         = -1
    from_port        = 0
    to_port          = 0
    cidr_blocks      = ["0.0.0.0/0"]
  }
}


data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "main" {
  name                 = "web/${var.project_id}/nextjs"
  image_tag_mutability = "IMMUTABLE"
}


## CI/CD user role for managing pipeline for AWS ECR resources
module "ecr_ecs_ci_user" {
  source            = "github.com/Jareechang/tf-modules//iam/ecr?ref=v1.0.19"
  env               = var.env
  project_id        = var.project_id
  create_ci_user    = true
  # This is the ECR ARN - Feel free to add other repository as required (if you want to re-use role for CI/CD in other projects)
  ecr_resource_arns = [
    "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/web/${var.project_id}",
    "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/web/${var.project_id}/*"
  ]

  other_iam_statements = {
    codedeploy = {
      actions = [
        "codedeploy:CreateDeployment",
        "codedeploy:GetDeployment",
        "codedeploy:GetDeploymentGroup",
        "codedeploy:GetDeploymentConfig",
        "codedeploy:RegisterApplicationRevision"
      ]
      effect = "Allow"
      resources = [
        "*"
      ]
    }
  }
}

resource "aws_ecs_cluster" "web_cluster" {
  name = "web-cluster-${var.project_id}-${var.env}"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  name = local.ecs_log_group
  retention_in_days = local.ecs_log_retention
}

data "template_file" "task_def_generated" {
  template = "${file("./task-definitions/service.json.tpl")}"
  vars = {
    env                 = var.env
    port                = local.target_port
    name                = local.ecs_container_name
    cpu                 = local.ecs_cpu
    memory              = local.ecs_memory
    aws_region          = var.aws_region
    ecs_execution_role  = module.ecs_roles.ecs_execution_role_arn
    launch_type         = local.ecs_launch_type
    network_mode        = local.ecs_network_mode
    log_group           = local.ecs_log_group
  }
}

# Create a static version of task definition for CI/CD
resource "local_file" "output_task_def" {
  content         = data.template_file.task_def_generated.rendered
  file_permission = "644"
  filename        = "./task-definitions/service.latest.json"
}

resource "aws_ecs_task_definition" "nextjs" {
  family                   = "task-definition-node"
  execution_role_arn       = module.ecs_roles.ecs_execution_role_arn
  task_role_arn            = module.ecs_roles.ecs_task_role_arn

  requires_compatibilities = [local.ecs_launch_type]
  network_mode             = local.ecs_network_mode
  cpu                      = local.ecs_cpu
  memory                   = local.ecs_memory
  container_definitions    = jsonencode(
    jsondecode(data.template_file.task_def_generated.rendered).containerDefinitions
  )
}

resource "aws_ecs_service" "web_ecs_service" {
  name            = "web-service-${var.project_id}-${var.env}"
  cluster         = aws_ecs_cluster.web_cluster.id
  task_definition = aws_ecs_task_definition.nextjs.arn
  desired_count   = local.ecs_desired_count
  launch_type     = local.ecs_launch_type

  load_balancer {
    target_group_arn = module.ecs_tg_blue.tg.arn
    container_name   = local.ecs_container_name
    container_port   = local.target_port
  }

  network_configuration {
    subnets         = module.networking.private_subnets[*].id
    security_groups = [aws_security_group.ecs_sg.id]
  }

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  tags = {
    Name = "web-service-${var.project_id}-${var.env}"
  }

  depends_on = [
    module.alb.lb,
    module.ecs_tg_blue.tg
  ]
}

## Execution role and task roles
module "ecs_roles" {
  source                    = "github.com/Jareechang/tf-modules//iam/ecs?ref=v1.0.23"
  create_ecs_execution_role = true
  create_ecs_task_role      = true
}

data "aws_iam_policy_document" "codedeploy_assume_role" {
  version = "2012-10-17"
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = [
        "codedeploy.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "codedeploy_role" {
  name               = "CodeDeployRole${var.project_id}"
  description        = "CodeDeployRole for ${var.project_id} in ${var.env}"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
  role       = aws_iam_role.codedeploy_role.name
}

resource "aws_codedeploy_deployment_config" "custom_canary" {
  deployment_config_name = "EcsCanary25Percent20Minutes"
  compute_platform       = "ECS"
  traffic_routing_config {
    type = local.ecs_deployment_type
    time_based_canary {
      interval   = local.ecs_deployment_config_interval
      percentage = local.ecs_deployment_config_pct
    }
  }
}

resource "aws_codedeploy_app" "node_app" {
  compute_platform = "ECS"
  name             = "deployment-app-${var.project_id}-${var.env}"
}

resource "aws_codedeploy_deployment_group" "node_deploy_group" {
  app_name               = aws_codedeploy_app.node_app.name
  deployment_config_name = aws_codedeploy_deployment_config.custom_canary.id
  deployment_group_name  = "deployment-group-${var.project_id}-${var.env}"
  service_role_arn       = aws_iam_role.codedeploy_role.arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 0
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.web_cluster.name
    service_name = aws_ecs_service.web_ecs_service.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [module.alb.http_listener.arn]
      }

      target_group {
        name = module.ecs_tg_blue.tg.name
      }

      target_group {
        name = module.ecs_tg_green.tg.name
      }
    }
  }
}
