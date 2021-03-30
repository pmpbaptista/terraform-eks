terraform {
    required_version = ">= 0.12.0"
}

provider "aws" {
    region  = var.region
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "aws_availability_zones" "available" {
}

resource "aws_security_group" "worker_group_mgmt_one" {
    name_prefix = "worker_group_mgmt_one"
    vpc_id = "module.vpc.vpc_id"

    ingress {
      cidr_blocks = [ "10.0.0.0/8" ]
      from_port = 22
      to_port =22
      protocol = "tcp"
    }
}

resource "aws_security_group" "all_worker_mgmt" {
    name_prefix = "all_worker_management"
    vpc_id = "module.vpc.vpc_id"

    ingress {
      cidr_blocks = [ 
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          ]
      from_port = 22
      to_port =22
      protocol = "tcp"
    }
}

module "vpc" {
  source    = "terraform-aws-modules/vpc/aws"

  name                  = "pedro-vpc"
  cidr                  = "10.0.0.0/16"
  azs                   = data.aws_availability_zones.available.names
  private_subnets       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets        = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
  enable_nat_gateway    = true
  single_nat_gateway    = true
  enable_dns_hostnames  = true
  public_subnet_tags = {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
      "kubernetes.io/role/elb" = 1
    }

    private_subnet_tags = {
        "kubernetes.io/cluster/${var.cluster_name}" = "shared"
        "kubernetes.io/role/internal-elb" = 1
    }
}


module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "14.0.0" 
  cluster_name    = var.cluster_name
  cluster_version = "1.19"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

  cluster_create_timeout = "1h"
  cluster_endpoint_private_access = true

  worker_groups = [
      {
          name = "worker-group-1"
          instance_type = "t2.small"
          additional_userdata = "Pedro"
          asg_desired_capacity = 1
          additional_security_group_ids = [aws_security_group.worker_group_mgmt_one.id]
      },
  ]

  worker_additional_security_group_ids = [aws_security_group.all_worker_mgmt.id]

  map_roles = var.map_roles
  map_users = var.map_users
  map_accounts = var.map_accounts

}

# Kubernetes provider
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Kubernetes example deployments
resource "kubernetes_deployment" "pedro-app" {
  metadata {
    name = "pedro-app-1"
    labels = {
      test = "pedro-app"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        test = "pedro-app"
      }
    }

    template {
      metadata {
        labels = {
          test = "pedro-app"
        }
      }

      spec {
        container {
          image = "nginx:1.7.8"
          name  = "nginx"

          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "pedro-service" {
  metadata {
    name = "pedro-service-1"
  }
  spec {
    selector = {
      test = "pedro-app"
    }
    port {
      port        = 80
      target_port = 80
    }

    type = "LoadBalancer"
  }
}