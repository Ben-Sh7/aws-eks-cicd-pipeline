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

# ECR serves image layers out of S3, so without this every layer of every ECR
# pull - the app images and the EKS add-ons alike - is billed as NAT data
# processing (~$0.045/GB). A gateway endpoint is only a route: no hourly or
# per-GB charge, and the S3 prefix list is more specific than 0.0.0.0/0, so
# in-region S3 traffic takes it and everything else still goes to the NAT.
#
# The ECR API calls (auth, manifests) stay on the NAT. Moving those takes
# interface endpoints at ~$7/month each per AZ - more than the NAT they relieve.
#
# No restrictive endpoint policy: pinning it to the ECR layer bucket would stop
# nothing while the NAT reaches the whole internet, and would turn any later
# in-region S3 use by a pod into a bare AccessDenied.
#
# Private route table only. The public subnets leave through the IGW, which has
# no processing fee, and Jenkins pushes layers through the ECR API, not S3.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-s3-endpoint" }
  )
}
