# RDS Postgres - replaces the in-cluster postgres pod. Private subnets, no
# public access, reachable only from the EKS nodes' security group.

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_1_cidr
  availability_zone = "${var.aws_region}a"

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-private-1" }
  )
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_2_cidr
  availability_zone = "${var.aws_region}b"

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-private-2" }
  )
}

# No internet route - RDS needs no outbound access, so no NAT gateway
# (which would add real cost).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-private-rt" }
  )
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "postgres" {
  name_prefix = "${local.project_name}-db-"
  subnet_ids  = [aws_subnet.private_1.id, aws_subnet.private_2.id]

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-db-subnet-group" }
  )
}

resource "aws_security_group" "rds" {
  name_prefix = "${local.project_name}-rds-"
  description = "Postgres access from the EKS nodes only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks.id]
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-rds-sg" }
  )
}

resource "aws_db_instance" "postgres" {
  identifier     = "${local.project_name}-postgres"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.rds_db_name
  username = var.rds_username

  # AWS creates and rotates the master password in Secrets Manager itself -
  # it never passes through Terraform, so it never lands in the state file.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # No leftovers to pay for after destroy.sh: no final snapshot, no
  # retained automated backups, and deletion is never blocked.
  skip_final_snapshot     = true
  backup_retention_period = 0
  deletion_protection     = false

  auto_minor_version_upgrade = true

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-postgres" }
  )
}
