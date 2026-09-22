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

  depends_on = [
    aws_internet_gateway.main,
    aws_route_table_association.public_1,
  ]
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

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
