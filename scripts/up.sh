#!/usr/bin/env bash
# =============================================================================
# Provisiona a infraestrutura Kubernetes na AWS: rede, cluster EKS e a ponte
# privada (NLB + VPC Link) que o API Gateway usa para chegar à aplicação.
#
#   ./scripts/up.sh
#
# Único pré-requisito na máquina: Docker, e credencial da AWS configurada.
# Terraform, AWS CLI e kubectl vêm do container toolbox se não existirem
# localmente. No GitHub Actions, usa os binários do runner.
#
# O script é IDEMPOTENTE: rodar de novo reconcilia o que já existe em vez de
# duplicar. Interrompido no meio, basta rodar outra vez.
#
# O que ele faz, e por que nesta ordem:
#
#   1. bucket de state → criado pelo AWS CLI, não pelo Terraform (ver
#                        terraform/bootstrap/main.tf), e o backend.hcl gerado.
#   2. bootstrap       → ECR da imagem da aplicação.
#   3. network         → VPC, subnets, NAT, security groups.
#   4. cluster         → EKS, nós, autoscaler, NLB interno, VPC Link.
#
# backend.hcl e terraform.tfvars são GERADOS e não versionados: carregam o nome
# de um bucket da conta de quem rodou — exatamente a parte que não pode vir no
# repositório.
#
# Tempo: ~15 minutos do zero, quase tudo no cluster (o control plane do EKS
# leva ~11 min e o node group ~2).
#
# Custo e como derrubar: seção "Custo" do README e scripts/down.sh.
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APROVAR_AUTO="${APROVAR_AUTO:-nao}"
APLICAR=(apply)
if [ "$APROVAR_AUTO" = "sim" ]; then
  APLICAR+=(-auto-approve)
fi

# ─────────────────────────────────────────────────────────────────────────────
# 0. Pré-requisitos
# ─────────────────────────────────────────────────────────────────────────────
titulo "Pré-requisitos"

if _no_container terraform || _no_container aws; then
  exigir_docker
  garantir_toolbox
  ok "Ferramentas vindas do container $TOOLBOX_IMAGE"
else
  ok "Terraform e AWS CLI encontrados localmente"
fi

exigir_aws_configurada

REGIAO="$(regiao)"
ok "Região: ${REGIAO}"

# ─────────────────────────────────────────────────────────────────────────────
# Cota de vCPU — o bloqueio mais provável numa conta AWS nova.
#
# Conta recém-criada costuma vir com 5 vCPUs de instâncias On-Demand Standard.
# Dois nós t3.medium são 4 vCPUs e cabem; o Cluster Autoscaler subindo para 3
# nós pede 6 e é RECUSADO. O sintoma é um scale-up que nunca acontece, com a
# mensagem de cota enterrada no evento do Auto Scaling Group — longe de onde se
# procura.
#
# Só avisa, nunca bloqueia: a cota pode já ter sido aumentada, e a leitura
# depende de uma permissão (service-quotas) que o Learner Lab, por exemplo, nega.
# No Lab, o scale-up de 2 para 3 nós foi testado e funciona.
# ─────────────────────────────────────────────────────────────────────────────
conferir_cota_vcpu() {
  local tipo="${NODE_INSTANCE_TYPE:-t3.medium}"
  local max_nos="${NODE_MAX_SIZE:-4}"

  local cota vcpus_por_no necessario
  # L-1216C47A = "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z)
  # instances", medida em vCPUs.
  cota="$(awscli service-quotas get-service-quota \
            --service-code ec2 --quota-code L-1216C47A \
            --region "$REGIAO" \
            --query 'Quota.Value' --output text 2>/dev/null || true)"

  if [ -z "$cota" ] || [ "$cota" = "None" ]; then
    aviso "Não foi possível ler a cota de vCPU (o Learner Lab nega essa consulta)."
    aviso "Se o scale-up falhar com erro de cota, peça aumento do limite"
    aviso "'Running On-Demand Standard instances' para pelo menos 8 vCPUs."
    return 0
  fi

  vcpus_por_no="$(awscli ec2 describe-instance-types \
                    --instance-types "$tipo" --region "$REGIAO" \
                    --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' \
                    --output text 2>/dev/null || echo 2)"

  necessario=$(( vcpus_por_no * max_nos ))
  # A cota vem como float ("5.0"); corta a parte decimal para comparar.
  local cota_int="${cota%%.*}"

  if [ "$cota_int" -ge "$necessario" ]; then
    ok "Cota de vCPU: ${cota_int} (precisa de ${necessario} para ${max_nos}× ${tipo})"
  else
    aviso "Cota de vCPU é ${cota_int}, mas o autoscaling pode pedir ${necessario}"
    aviso "(${max_nos} nós × ${vcpus_por_no} vCPU do ${tipo})."
    echo "    O ambiente SOBE — 2 nós usam $(( vcpus_por_no * 2 )) vCPUs —, mas o scale-up"
    echo "    além disso será recusado, e é justamente o que demonstra o autoscaling."
    echo
    echo "    Para pedir aumento (gratuito, costuma sair em minutos):"
    echo "      https://${REGIAO}.console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-1216C47A"
    echo
  fi
}

titulo "Conferindo cota de vCPU"
conferir_cota_vcpu

# ─────────────────────────────────────────────────────────────────────────────
# AWS Academy Learner Lab
#
# No Lab não se cria papel IAM: o único disponível é o `LabRole`, e o cluster
# precisa usá-lo no lugar dos papéis que criaria. A detecção é pela própria
# existência do papel — numa conta comum ele não existe e nada muda.
#
# EXISTING_ROLE_ARN força um papel específico, para outros ambientes com a mesma
# restrição.
# ─────────────────────────────────────────────────────────────────────────────
PAPEL_EXISTENTE="${EXISTING_ROLE_ARN:-}"
if [ -z "$PAPEL_EXISTENTE" ]; then
  PAPEL_EXISTENTE="$(awscli iam get-role --role-name LabRole \
                       --query 'Role.Arn' --output text 2>/dev/null | tr -d '\r' || true)"
fi
if [ -n "$PAPEL_EXISTENTE" ]; then
  aviso "Usando o papel existente ${PAPEL_EXISTENTE##*/} (Learner Lab): nenhum papel IAM será criado"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Bucket de state, pelo AWS CLI
#
# Compartilhado pelos repositórios do projeto na mesma conta, cada um com o seu
# prefixo de chave (k8s/, db/, lambda/). O nome leva o ID da conta — único por
# natureza, sem precisar de sufixo aleatório.
#
# As proteções são as que uma stack Terraform aplicaria: versionamento (um apply
# interrompido pode gravar state parcial; a versão anterior continua lá),
# criptografia, bloqueio de acesso público (o state guarda tudo em texto claro)
# e expiração de versões antigas (sem ela o bucket cresce para sempre).
# ─────────────────────────────────────────────────────────────────────────────
titulo "1/4  Bucket de state"

CONTA="$(awscli sts get-caller-identity --query Account --output text | tr -d '\r')"
STATE_BUCKET="${STATE_BUCKET:-autopecas-tfstate-${CONTA}}"

if awscli s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  ok "Bucket de state já existe: ${STATE_BUCKET}"
else
  # us-east-1 não aceita LocationConstraint; as outras regiões exigem.
  if [ "$REGIAO" = "us-east-1" ]; then
    awscli s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGIAO" >/dev/null
  else
    awscli s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGIAO" \
      --create-bucket-configuration "LocationConstraint=${REGIAO}" >/dev/null
  fi
  awscli s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  awscli s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  awscli s3api put-public-access-block --bucket "$STATE_BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awscli s3api put-bucket-lifecycle-configuration --bucket "$STATE_BUCKET" \
    --lifecycle-configuration \
    '{"Rules":[{"ID":"expirar-versoes-antigas","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":90}}]}'
  ok "Bucket de state criado: ${STATE_BUCKET}"
fi

# Reescrito a cada execução de propósito: é um arquivo DERIVADO, e um
# backend.hcl apontando para um bucket de outra conta é a causa mais provável
# de um "NoSuchBucket" no init.
cat > "${REPO_ROOT}/${TF_SUBDIR}/backend.hcl" <<EOF
# GERADO por scripts/up.sh — não versionado, não edite à mão.
bucket = "${STATE_BUCKET}"
region = "${REGIAO}"
EOF
ok "backend.hcl escrito"

# -reconfigure, e não -migrate-state: o backend.hcl pode ter mudado entre
# execuções (outra conta, outra região), e aí o Terraform perguntaria se deve
# migrar o state — uma pergunta interativa num script.
iniciar_stack() {
  tf_stack "$1" init -input=false -reconfigure -backend-config="$(caminho_backend_hcl)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Bootstrap — ECR e (opcionalmente) o papel OIDC do GitHub
# ─────────────────────────────────────────────────────────────────────────────
titulo "2/4  bootstrap — ECR"

VARS_BOOTSTRAP=(-var "aws_region=${REGIAO}")

# O papel OIDC do GitHub só existe fora do Learner Lab (o Lab não permite criar
# papel nem provedor OIDC) e só se o repositório for informado — ver
# terraform/bootstrap/github-oidc.tf.
if [ -n "${GITHUB_OIDC_REPOSITORY:-}" ] && [ -z "$PAPEL_EXISTENTE" ]; then
  VARS_BOOTSTRAP+=(-var "enable_github_oidc=true" -var "github_repository=${GITHUB_OIDC_REPOSITORY}")
  aviso "OIDC do GitHub habilitado para ${GITHUB_OIDC_REPOSITORY}"
fi

iniciar_stack bootstrap
tf_stack bootstrap "${APLICAR[@]}" -input=false "${VARS_BOOTSTRAP[@]}"

ECR_URL="$(tf_output bootstrap ecr_repository_url)"
GH_ROLE="$(tf_output bootstrap github_deploy_role_arn)"
ok "ECR: ${ECR_URL}"

# ─────────────────────────────────────────────────────────────────────────────
# Variáveis compartilhadas por network e cluster
# ─────────────────────────────────────────────────────────────────────────────
ADMINS_TF='cluster_admin_role_arns = []'
if [ -n "$GH_ROLE" ]; then
  ADMINS_TF="cluster_admin_role_arns = [\"${GH_ROLE}\"]"
fi

PAPEL_TF='# existing_role_arn: vazio, o cluster cria os próprios papéis'
if [ -n "$PAPEL_EXISTENTE" ]; then
  PAPEL_TF="existing_role_arn = \"${PAPEL_EXISTENTE}\""
fi

cat > "${REPO_ROOT}/${TF_SUBDIR}/terraform.tfvars" <<EOF
# GERADO por scripts/up.sh — não versionado, não edite à mão.
#
# Para mudar dimensionamento ou região, exporte a variável antes de rodar o
# script, ou edite e rode as stacks manualmente (ver o README).
state_bucket = "${STATE_BUCKET}"
aws_region   = "${REGIAO}"

# Papéis IAM com acesso de admin ao cluster, além de quem rodou o apply.
${ADMINS_TF}

# Papel IAM pronto (Learner Lab), usado no lugar dos que o cluster criaria.
${PAPEL_TF}
EOF
ok "terraform.tfvars escrito"

# ─────────────────────────────────────────────────────────────────────────────
# 3 e 4. Rede e cluster, em ordem — o cluster lê o state da rede.
# ─────────────────────────────────────────────────────────────────────────────
PASSO=3
for stack in "${STACKS[@]}"; do
  titulo "${PASSO}/4  ${stack}"
  PASSO=$((PASSO + 1))

  iniciar_stack "$stack"
  tf_stack "$stack" "${APLICAR[@]}" -input=false -var-file="$(caminho_tfvars)"
done

# ─────────────────────────────────────────────────────────────────────────────
# Kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
CLUSTER="$(tf_output cluster cluster_name)"
if [ -n "$CLUSTER" ]; then
  titulo "Configurando o kubeconfig"
  awscli eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" >/dev/null
  ok "kubectl apontado para ${CLUSTER}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Resumo — o que os outros repositórios do projeto precisam receber daqui.
# ─────────────────────────────────────────────────────────────────────────────
VPC_ID="$(tf_output network vpc_id)"
SUBNETS="$(tf_stack network output -json private_subnet_ids 2>/dev/null | tr -d '\r\n ' || true)"
SG_APP="$(tf_output network application_security_group_id)"
VPC_LINK="$(tf_output cluster vpc_link_id)"
LISTENER="$(tf_output cluster api_listener_arn)"

titulo "Infraestrutura pronta"
cat <<EOF

  Cluster              ${CLUSTER:-<não aplicado>}
  ECR                  ${ECR_URL}
  Bucket de state      ${STATE_BUCKET}

  Para o repositório autopecas-infra-db:
    vpc_id                          = "${VPC_ID}"
    subnet_ids                      = ${SUBNETS}
    application_security_group_ids  = ["${SG_APP}"]

  Para o repositório autopecas-lambda-auth (integração privada):
    vpc_link_id                     = "${VPC_LINK}"
    api_listener_arn                = "${LISTENER}"
    lambda_subnet_ids               = ${SUBNETS}

  Para derrubar e parar de pagar:

      ./scripts/down.sh

EOF
