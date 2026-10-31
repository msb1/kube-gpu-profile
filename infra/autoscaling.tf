# Controllers must never depend on the GPU nodes they provision.
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["m6i.xlarge"]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  disk_size       = 100
  scaling_config {
    min_size     = 2
    desired_size = 2
    max_size     = 3
  }
  labels = { workload = "system" }
  update_config { max_unavailable = 1 }
  depends_on = [aws_iam_role_policy_attachment.node, aws_iam_role_policy_attachment.node_ssm]
  tags       = var.tags
}

# Upstream module supplies scoped controller permissions, IRSA, encrypted SQS,
# EventBridge interruption events, a node role and its EKS access entry.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.37.2"

  iam_role_name                   = "${var.name}-karpenter-controller"
  node_iam_role_name              = "${var.name}-karpenter-node"
  cluster_name                    = aws_eks_cluster.main.name
  enable_v1_permissions           = true
  enable_irsa                     = true
  enable_pod_identity             = false
  irsa_oidc_provider_arn          = aws_iam_openid_connect_provider.eks.arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]
  node_iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  tags = var.tags
}

output "karpenter_role_arn" { value = module.karpenter.iam_role_arn }
output "karpenter_node_role_name" { value = module.karpenter.node_iam_role_name }
output "karpenter_queue_name" { value = module.karpenter.queue_name }
output "node_security_group_id" { value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id }
