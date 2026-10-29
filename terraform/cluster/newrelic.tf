# =============================================================================
# Integração do New Relic com o Kubernetes — o "consumo de recursos do
# Kubernetes (CPU, memória)" do monitoramento.
#
# O que cada parte do chart nri-bundle entrega:
#
#   newrelic-infrastructure  DaemonSet: CPU, memória, disco e rede por nó, pod e
#                            container (K8sNodeSample, K8sPodSample,
#                            K8sContainerSample).
#   kube-state-metrics       Estado dos objetos: réplicas desejadas x prontas de
#                            Deployments, alvo e réplicas atuais do HPA,
#                            reinícios de container. É o que mostra o HPA
#                            escalando.
#   nri-kube-events          Eventos do cluster (scale up do HPA, OOMKilled,
#                            pod Pending, nó adicionado pelo autoscaler).
#   nri-metadata-injection   Webhook que injeta nome do cluster/pod nas
#                            variáveis do container: liga o APM da aplicação ao
#                            pod onde ela roda.
#
# Desligado de propósito:
#
#   newrelic-logging         Os logs da aplicação já chegam pelo agente Java,
#                            ligados ao trace. Um Fluent Bit por nó duplicaria
#                            a ingestão (e o consumo da cota gratuita).
#   prometheus, pixie, eBPF  Nada no cluster expõe métricas Prometheus próprias,
#                            e o APM já cobre o que o eBPF traria.
#
# A license key NÃO passa por aqui: entraria no state do Terraform. O chart só
# recebe o NOME do Secret (customSecretName), que o scripts/up.sh cria depois do
# apply, por entrada padrão do kubectl. Até lá os pods do New Relic esperam o
# Secret (CreateContainerConfigError) e o kubelet os sobe sozinho quando ele
# aparece — por isso `wait = false`.
# =============================================================================

locals {
  newrelic_namespace       = "newrelic"
  newrelic_secret_name     = "newrelic-license"
  newrelic_secret_key_name = "license"
}

resource "helm_release" "newrelic" {
  count = var.newrelic_habilitado ? 1 : 0

  name             = "newrelic-bundle"
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  version          = var.newrelic_chart_version
  namespace        = local.newrelic_namespace
  create_namespace = true

  atomic          = false
  wait            = false
  timeout         = 600
  cleanup_on_fail = true

  values = [yamlencode({
    global = {
      cluster                = aws_eks_cluster.main.name
      customSecretName       = local.newrelic_secret_name
      customSecretLicenseKey = local.newrelic_secret_key_name
      # Coleta a cada 30s em vez de 15s: metade da ingestão, e a resolução
      # ainda basta para ver o HPA reagir numa demonstração.
      lowDataMode = true
    }

    "newrelic-infrastructure" = { enabled = true }
    "kube-state-metrics"      = { enabled = true }
    "nri-kube-events"         = { enabled = true }
    "nri-metadata-injection"  = { enabled = true }

    "newrelic-logging"          = { enabled = false }
    "nri-prometheus"            = { enabled = false }
    "newrelic-prometheus-agent" = { enabled = false }
    "newrelic-pixie"            = { enabled = false }
    "pixie-chart"               = { enabled = false }
    "nr-ebpf-agent"             = { enabled = false }
    "k8s-agents-operator"       = { enabled = false }
  })]

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_addon.coredns,
  ]
}
