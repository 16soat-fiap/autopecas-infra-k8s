# =============================================================================
# Estes outputs são a interface pública desta stack. Quem os lê:
#
#   • a stack `cluster`, deste repositório, por `terraform_remote_state`;
#   • o repositório autopecas-infra-db, que NÃO cria rede e recebe daqui a VPC,
#     as subnets privadas e o security group da aplicação.
#
# Remover ou renomear um output quebra os consumidores no próximo plan — e, no
# caso do outro repositório, sem nenhum aviso deste lado. Trate como API.
# =============================================================================

output "vpc_id" {
  description = "ID da VPC. Entrada `vpc_id` do repositório do banco."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR da VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets públicas (apenas o NAT Gateway mora nelas)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = <<-EOT
    Subnets privadas, em duas AZs: nós do EKS, NLB interno, VPC Link — e também
    o RDS e a Lambda dos outros repositórios. Entrada `subnet_ids` do
    repositório do banco e `lambda_subnet_ids` do repositório da Lambda.
  EOT
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "AZs em uso."
  value       = local.azs
}

output "cluster_name" {
  description = <<-EOT
    Nome do cluster EKS, derivado de project_name.

    Fica nesta stack para que as demais usem a MESMA derivação sem repetir a
    expressão — se cada stack montasse o nome por conta própria, uma divergência
    só apareceria como "cluster não encontrado" na hora do apply.
  EOT
  value       = local.cluster_name
}

output "security_group_ids" {
  description = "Security groups da cadeia de tráfego."
  value = {
    nodes   = aws_security_group.nodes.id
    nlb     = aws_security_group.nlb.id
    vpclink = aws_security_group.vpclink.id
  }
}

output "application_security_group_id" {
  description = <<-EOT
    Security group dos nós do cluster — de onde a aplicação origina conexões.
    Entrada `application_security_group_ids` do repositório do banco, que
    libera a porta 5432 apenas a partir dele.
  EOT
  value       = aws_security_group.nodes.id
}

output "node_ports" {
  description = <<-EOT
    Mapa dos serviços expostos pelo cluster: porta do listener no NLB, NodePort
    e caminho de health check.

    A stack `cluster` itera sobre este mapa para criar um target group e um
    listener por serviço.
  EOT
  value       = local.node_ports
}
