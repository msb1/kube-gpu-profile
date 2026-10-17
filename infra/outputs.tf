output "cluster_name" { value = aws_eks_cluster.main.name }
output "aws_region" { value = var.aws_region }
output "efs_file_system_id" { value = aws_efs_file_system.models.id }
output "gpu_instance_type" { value = var.gpu_instance_type }
output "vpc_id" { value = aws_vpc.main.id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "aws_load_balancer_controller_role_arn" { value = aws_iam_role.aws_load_balancer_controller.arn }
