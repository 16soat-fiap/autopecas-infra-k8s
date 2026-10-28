#!/usr/bin/env bash
# =============================================================================
# Destrói a infraestrutura, na ordem inversa.
#
#   ./scripts/down.sh            # derruba o cluster (EKS, nós, NLB, VPC Link)
#   ./scripts/down.sh --tudo     # derruba também a rede (VPC, NAT)
#
# Por que o padrão NÃO destrói a rede: o RDS (repositório autopecas-infra-db) e
# a Lambda (autopecas-lambda-auth) moram nas subnets desta rede. Com eles de pé,
# a AWS recusa apagar as subnets — as interfaces de rede deles ainda estão lá —,
# e o destroy fica preso até estourar o tempo. Derrubar só o cluster tira a
# maior parte do custo e não esbarra em ninguém.
#
# Ordem para derrubar TUDO: os repositórios da Lambda e do banco primeiro, e só
# então `down.sh --tudo` aqui.
#
# O `bootstrap` (ECR e, fora do Lab, o papel OIDC) e o bucket de state nunca são
# destruídos: custam centavos e guardam as imagens publicadas e o state dos três
# repositórios.
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TUDO="nao"
if [ "${1:-}" = "--tudo" ]; then
  TUDO="sim"
fi

exigir_aws_configurada

TFVARS="$(caminho_tfvars)"
if [ ! -f "${REPO_ROOT}/${TF_SUBDIR}/terraform.tfvars" ]; then
  morrer "terraform.tfvars não encontrado. Rode o scripts/up.sh primeiro — ele gera este arquivo."
fi

A_DESTRUIR=(cluster)
if [ "$TUDO" = "sim" ]; then
  A_DESTRUIR+=(network)
fi

titulo "Stacks que serão destruídas"
for stack in "${A_DESTRUIR[@]}"; do
  echo "    ${stack}"
done

if [ "$TUDO" = "sim" ]; then
  echo
  aviso "A rede só pode ser destruída depois do banco e da Lambda (outros repositórios)."
  aviso "Se eles ainda existirem, o destroy da rede vai falhar ao apagar as subnets."
fi

echo
printf 'Confirma? Digite "destruir" para prosseguir: '
read -r RESPOSTA
if [ "$RESPOSTA" != "destruir" ]; then
  echo "Cancelado."
  exit 0
fi

for stack in "${A_DESTRUIR[@]}"; do
  titulo "Destruindo ${stack}"

  # O init é necessário porque o diretório pode estar limpo (clone novo, ou
  # .terraform apagado) e sem ele o Terraform não sabe onde está o state.
  tf_stack "$stack" init -input=false -reconfigure \
    -backend-config="$(caminho_backend_hcl)"

  tf_stack "$stack" destroy -input=false -auto-approve \
    -var-file="$TFVARS"

  ok "${stack} destruída"
done

titulo "Pronto"
if [ "$TUDO" = "sim" ]; then
  cat <<'EOF'

  Cluster e rede destruídos. Ficam o ECR e o bucket de state (centavos).

  Para voltar:  ./scripts/up.sh

EOF
else
  cat <<'EOF'

  Cluster destruído. A rede continua (o NAT Gateway cobra ~US$ 1 por dia).

  Para voltar:            ./scripts/up.sh
  Para destruir a rede:   derrube o banco e a Lambda, depois ./scripts/down.sh --tudo

EOF
fi
