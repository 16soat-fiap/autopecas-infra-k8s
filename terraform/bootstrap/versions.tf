terraform {
  # 1.10 é o piso para `use_lockfile` no backend S3 — o lock nativo que dispensa
  # a tabela DynamoDB que as versões anteriores exigiam.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    # Usado apenas para ler o certificado do emissor OIDC do GitHub e extrair o
    # thumbprint — ver github-oidc.tf.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Configuração parcial: `bucket` e `region` vêm do backend.hcl que o up.sh
  # gera depois de criar o bucket. Ver o comentário em main.tf.
  backend "s3" {
    key          = "k8s/bootstrap/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
      Stack     = "k8s-bootstrap"
    }
  }
}
