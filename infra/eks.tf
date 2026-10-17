resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name = "${var.name}-gpu-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Secure node administration through Systems Manager Session Manager; no inbound SSH rule or key pair.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_eks_cluster" "main" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }
  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidr_blocks
  }
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  depends_on                = [aws_iam_role_policy_attachment.cluster]
  tags                      = var.tags
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cluster_admin_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cluster_admin_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.admin]
}

resource "aws_eks_addon" "core" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy"])
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = each.value
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

resource "aws_iam_role" "efs_csi" {
  name = "${var.name}-efs-csi-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
      } }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# IRSA role used by AWS Load Balancer Controller to provision the private Grafana ALB.
resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.name}-aws-load-balancer-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = { StringEquals = {
        "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
      } }
    }]
  })
  tags = var.tags
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.name}-aws-load-balancer-controller"
  description = "Core permissions for AWS Load Balancer Controller ALB provisioning, based on upstream v2.14.1 policy."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses", "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways", "ec2:DescribeVpcs", "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces", "ec2:DescribeTags", "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools", "ec2:GetSecurityGroupsForVpc", "ec2:DescribeIpamPools", "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeRouteTables", "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes", "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates", "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes", "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes", "elasticloadbalancing:DescribeCapacityReservation",
          "acm:ListCertificates", "acm:DescribeCertificate", "iam:ListServerCertificates",
          "iam:GetServerCertificate", "cognito-idp:DescribeUserPoolClient"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" } }
      },
      {
        Effect = "Allow"
        Action = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ec2:CreateTags", "ec2:DeleteTags", "ec2:DeleteSecurityGroup"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:ModifyListener", "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities", "elasticloadbalancing:ModifyListenerAttributes"
        ]
        Resource = "*"
      }
    ]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-efs-csi-driver"
  service_account_role_arn = aws_iam_role.efs_csi.arn
  depends_on               = [aws_iam_role_policy_attachment.efs_csi]
}

resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "gpu-inference"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.gpu_instance_type]
  ami_type        = "AL2023_x86_64_NVIDIA"
  capacity_type   = "ON_DEMAND"
  scaling_config {
    min_size     = var.gpu_min_size
    desired_size = var.gpu_desired_size
    max_size     = var.gpu_max_size
  }
  update_config { max_unavailable = 1 }
  labels = { workload = "gpu-inference" }
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_iam_role_policy_attachment.node_ssm,
    aws_eks_addon.core
  ]
  tags = var.tags
}

# Optional host DCGM engine and CLI. DCGM Exporter can connect to this engine
# when the matching option is enabled in the workloads Terraform root.
resource "aws_ssm_association" "install_dcgm_cli" {
  count = var.install_dcgm_cli ? 1 : 0

  name                = "AWS-RunShellScript"
  association_name    = "${var.name}-install-dcgm-cli"
  schedule_expression = "rate(1 day)"
  targets {
    key    = "tag:aws:eks:cluster-name"
    values = [aws_eks_cluster.main.name]
  }
  parameters = {
    commands = <<-SCRIPT
      set -eu
      CUDA_VERSION=$(nvidia-smi -q | sed -nE 's/^[[:space:]]*CUDA Version[[:space:]]*:[[:space:]]*([0-9]+)\..*/\1/p' | head -n1)
      case "$CUDA_VERSION" in
        ''|*[!0-9]*)
        echo "Could not determine CUDA user-mode major version from nvidia-smi" >&2
        exit 1
        ;;
      esac
      dnf install -y dnf-plugins-core
      if ! grep -Rqs 'cuda-amzn2023.repo' /etc/yum.repos.d; then
        dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
      fi
      dnf install -y --setopt=install_weak_deps=True "datacenter-gpu-manager-4-cuda$CUDA_VERSION"
      systemctl enable --now nvidia-dcgm
      dcgmi discovery -l
    SCRIPT
  }
  depends_on = [
    aws_eks_node_group.gpu,
    aws_iam_role_policy_attachment.node_ssm
  ]
}

