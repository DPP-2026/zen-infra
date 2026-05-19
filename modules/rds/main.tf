resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-${var.env}-rds-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name    = "${var.project}-${var.env}-rds-subnet-group"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.env}-rds-sg"
  description = "Security group for RDS PostgreSQL instance"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project}-${var.env}-rds-sg"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_db_instance" "main" {
  identifier              = "${var.project}-${var.env}-postgres"
  engine                  = "postgres"
  engine_version          = "15.7"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  multi_az                = var.env == "prod" ? true : false
  skip_final_snapshot     = var.env == "prod" ? false : true
  backup_retention_period = var.env == "prod" ? 7 : 0
  storage_encrypted       = true
  deletion_protection     = var.env == "prod" ? true : false
  publicly_accessible     = false

  tags = {
    Name    = "${var.project}-${var.env}-postgres"
    Env     = var.env
    Project = var.project
  }
}
