################################################################################
# Cluster
################################################################################

// EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.11"

  cluster_name = local.name
  // 1.30 is not compatible with Karpenter
  // "message":"karpenter version is not compatible with K8s version 1.30","commit":"e719109","ec2nodeclass":"default"}
  cluster_version = "1.28"

  # Give the Terraform identity admin access to the cluster
  # which will allow it to deploy resources into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  cluster_addons = {
    coredns = {
      configuration_values = jsonencode({
        tolerations = [
          # Allow CoreDNS to run on the same nodes as the Karpenter controller
          # for use during cluster creation when Karpenter nodes do not yet exist
          {
            key    = "karpenter.sh/controller"
            value  = "true"
            effect = "NoSchedule"
          }
        ]
      })
    }
    eks-pod-identity-agent = {}
    kube-proxy             = {}
    vpc-cni                = {}
  }

  # Use default VPC
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  eks_managed_node_groups = {
    karpenter = {
      // https://aws.amazon.com/ec2/instance-types/
      instance_types = ["m7g.large"] # Graviton3
      // https://docs.aws.amazon.com/eks/latest/APIReference/API_Nodegroup.html#AmazonEKS-Type-Nodegroup-amiType
      ami_type = "AL2_ARM_64"

      min_size     = 1
      max_size     = 3
      desired_size = 2

      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }

      taints = {
        # The pods that do not tolerate this taint should run on nodes
        # created by Karpenter
        karpenter = {
          key    = "karpenter.sh/controller"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # cluster_tags = merge(local.tags, {
  #   NOTE - only use this option if you are using "attach_cluster_primary_security_group"
  #   and you know what you're doing. In this case, you can remove the "node_security_group_tags" below.
  #  "karpenter.sh/discovery" = local.name
  # })

  node_security_group_tags = merge(local.tags, {
    # NOTE - if creating multiple security groups with this module, only tag the
    # security group that Karpenter should utilize with the following tag
    # (i.e. - at most, only one security group should have this tag in your account)
    "karpenter.sh/discovery" = "${local.name}"
  })

  tags = local.tags
}

################################################################################
# Controller & Node IAM roles, SQS Queue, Eventbridge Rules
################################################################################

// Karpenter
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.11"

  cluster_name = module.eks.cluster_name

  # Name needs to match role name passed to the EC2NodeClass
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true

  tags = local.tags
}

################################################################################
# Helm charts
################################################################################

// Karpenter Helm Chart
resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  # repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  # repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart   = "karpenter"
  version = "1.0.1"
  wait    = false

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: karpenter.sh/controller
        operator: Exists
        effect: NoSchedule
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
}

# Karpenter EC2NodeClass and NodePool
resource "kubectl_manifest" "karpenter_ec2nodeclass" {
  yaml_body = <<-YAML
  apiVersion: karpenter.k8s.aws/v1beta1
  kind: EC2NodeClass
  metadata:
    name: default
  spec:
    amiFamily: AL2
    role: ${local.name}
    subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${local.name}
    securityGroupSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${local.name}
    tags:
      karpenter.sh/discovery: ${local.name}
    instanceTypes: ["t3.medium", "t3a.medium", "t4g.medium", "m6a.large", "m6g.large"]
  YAML

  depends_on = [helm_release.karpenter, aws_ec2_tag.subnet_tags]
}

// karpenter nodepool for x86_64 instances
resource "kubectl_manifest" "karpenter_nodepool_x86" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1
  kind: NodePool
  metadata:
    name: x86processors
  spec:
    template:
      spec:
        nodeClassRef:
          group: karpenter.k8s.aws
          kind: EC2NodeClass
          name: default
        tolerations:
          - key: "karpenter.sh/controller"
            operator: "Exists"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-cpu"
            operator: In
            values: ["2", "4"]
          - key: "karpenter.k8s.aws/instance-generation"
            operator: Gt
            values: ["6"]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
    limits:
      cpu: 1000
    disruption:
      consolidationPolicy: WhenEmpty
      consolidateAfter: 30s
  YAML

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass]
}

// karpenter nodepool for arm64 instances
resource "kubectl_manifest" "karpenter_nodepool_arm" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1
  kind: NodePool
  metadata:
    name: armprocessors
  spec:
    template:
      spec:
        nodeClassRef:
          group: karpenter.k8s.aws
          kind: EC2NodeClass
          name: default
        tolerations:
          - key: "karpenter.sh/controller"
            operator: "Exists"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-cpu"
            operator: In
            values: ["2", "4"]
          - key: "karpenter.k8s.aws/instance-generation"
            operator: In
            values: ["7"]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["arm64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
    limits:
      cpu: 1000
    disruption:
      consolidationPolicy: WhenEmpty
      consolidateAfter: 30s
  YAML

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass]
}

// karpenter nodepool for g4dn instances
resource "kubectl_manifest" "karpenter_nodepool_gpu" {
  yaml_body = <<-YAML
  apiVersion: karpenter.sh/v1
  kind: NodePool
  metadata:
    name: gpuslicing
  spec:
    template:
      spec:
        labels:
          compute: models
          gpu-type: nvidia
        nodeClassRef:
          group: karpenter.k8s.aws
          kind: EC2NodeClass
          name: default
        tolerations:
          - key: "karpenter.sh/controller"
            operator: "Exists"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-cpu"
            operator: In
            values: ["4"]
          - key: "karpenter.k8s.aws/instance-generation"
            operator: In
            values: ["4"]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g4dn"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
    limits:
      cpu: 100
    disruption:
      consolidationPolicy: WhenEmpty
      consolidateAfter: 30s
  YAML

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass]
}

resource "aws_ec2_tag" "subnet_tags" {
  for_each    = toset(data.aws_subnets.default.ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.name
}
