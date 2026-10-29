# =============================================================================
# VPC Link — como o API Gateway, que é um serviço gerenciado fora da nossa VPC,
# alcança um balanceador que não tem endereço público.
#
# O gateway em si mora no repositório autopecas-lambda-auth, junto da Lambda
# que emite os tokens. Este repositório entrega a ele a outra ponta: o VPC Link
# e o ARN do listener de cada ambiente no NLB (outputs `vpc_link_id` e
# `listener_arns`). Com isso, a integração das rotas da aplicação, no stage de
# um ambiente, é
#
#     integration_type = "HTTP_PROXY"
#     connection_type  = "VPC_LINK"
#     connection_id    = <vpc_link_id>
#     integration_uri  = <listener_arns[ambiente]>
#
# e o cluster continua sem NENHUMA entrada pública — sem ela, o gateway teria de
# apontar para uma URL pública da aplicação, e passaria a ser contornável.
#
# Fica nesta stack, e não na de rede, porque só faz sentido com o NLB de pé: um
# VPC Link sem destino é um recurso pago esperando por nada.
#
# A AWS cria ENIs nas subnets informadas; elas usam o security group `vpclink`
# da stack network, cuja única regra é "sair para o NLB".
# =============================================================================
resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.project_name}-vpclink"
  subnet_ids         = local.network.private_subnet_ids
  security_group_ids = [local.network.security_group_ids.vpclink]

  tags = {
    Name = "${var.project_name}-vpclink"
  }
}
