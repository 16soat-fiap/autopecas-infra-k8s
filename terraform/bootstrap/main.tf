# =============================================================================
# Bootstrap — o que precisa existir antes do ambiente e sobreviver a ele.
#
# O bucket de state NÃO está aqui: quem o cria é o scripts/up.sh, pelo AWS CLI,
# antes de qualquer Terraform. Dois motivos:
#
#   • Ovo e galinha: uma stack que cria o próprio bucket de state teria de
#     guardar o state LOCALMENTE — e num runner do GitHub Actions o disco é
#     descartado a cada execução. A segunda execução do pipeline tentaria criar
#     tudo de novo e falharia com "já existe".
#   • Learner Lab: uma SCP da organização do Lab nega
#     `s3:GetBucketObjectLockConfiguration`, que o provider da AWS chama ao LER
#     qualquer `aws_s3_bucket`. O bucket nasceria e o apply falharia logo depois,
#     com AccessDenied. O AWS CLI não faz essa leitura.
#
# Com o bucket pronto antes, esta stack guarda o state nele como as outras
# (chave k8s/bootstrap/) e fica só com o que é dela: o ECR e, opcionalmente, o
# papel OIDC do GitHub (github-oidc.tf).
# =============================================================================

# =============================================================================
# ECR — registry da imagem da aplicação.
#
# Mora aqui, e não na stack do cluster, porque o pipeline da aplicação precisa
# publicar a imagem mesmo quando o cluster não existe (destruído para
# economizar), e porque destruir o cluster não deve apagar as imagens já
# publicadas. O `down.sh` nunca destrói esta stack.
# =============================================================================
resource "aws_ecr_repository" "app" {
  name = var.project_name

  # Scan de vulnerabilidades a cada push. É gratuito no modo básico.
  image_scanning_configuration {
    scan_on_push = true
  }

  # A tag `latest` precisa ser sobrescrita a cada deploy; MUTABLE é obrigatório
  # para isso. As tags de versão (SHA do commit) nunca são reescritas, então na
  # prática a imutabilidade que importa é preservada pelo esquema de tags.
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Permite `terraform destroy` mesmo com imagens dentro. Em produção isto seria
  # `false` — aqui o repositório é reconstruível com um push.
  force_delete = true
}

# Sem isto cada deploy deixa uma imagem órfã acumulando custo de armazenamento.
# 10 versões cobrem rollback para qualquer deploy recente.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantém apenas as 10 imagens mais recentes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}
