resource "aws_db_subnet_group" "postgres" {
  name_prefix = "${local.project_name}-db-"
  subnet_ids  = [aws_subnet.db_1.id, aws_subnet.db_2.id]

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
    description     = "Postgres from the EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
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

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  skip_final_snapshot = true
  deletion_protection = false

  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-postgres" }
  )
}
