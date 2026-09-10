# The private subnets carried no internet route because RDS needs none. The EKS
# worker nodes, now living there (aws_eks_node_group.main.subnet_ids), do need
# egress: kubelet pulls the add-on images - ingress-nginx, kube-prometheus-stack,
# argo-cd, external-secrets - from registry.k8s.io, quay.io and docker.io, none
# of which an ECR VPC endpoint covers.
#
# One NAT gateway, not one per AZ: ~$32/month instead of ~$64. The trade-off is
# a shared failure domain - if us-east-1a degrades, the us-east-1b nodes lose
# egress with it. Acceptable here; a production setup would run one per AZ.
#
# destroy.sh accounts for both resources below - terraform destroy removes them,
# and verify_cleanup re-checks for a live NAT gateway and an orphaned EIP, both
# of which bill by the hour.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-nat-eip" }
  )

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-nat" }
  )

  depends_on = [aws_internet_gateway.main]
}

# aws_route_table.private is defined in rds.tf; both private subnets are already
# associated with it there.
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
