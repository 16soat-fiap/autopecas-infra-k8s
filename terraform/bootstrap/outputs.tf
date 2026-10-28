output "ecr_repository_url" {
  description = "URL do ECR para `docker push`. É o destino da imagem no pipeline do repositório da aplicação."
  value       = aws_ecr_repository.app.repository_url
}

output "github_deploy_role_arn" {
  description = <<-EOT
    Papel que o GitHub Actions assume via OIDC, ou null se
    `enable_github_oidc = false` — sempre o caso no Learner Lab, que não
    permite criar papel IAM nem provedor OIDC.

    Quando existe, vai em DOIS lugares, e os dois são necessários:
      • secret AWS_DEPLOY_ROLE_ARN do repositório (para o workflow assumi-lo);
      • `cluster_admin_role_arns` do terraform.tfvars (para o EKS autorizá-lo).
  EOT
  value       = one(aws_iam_role.github_deploy[*].arn)
}
