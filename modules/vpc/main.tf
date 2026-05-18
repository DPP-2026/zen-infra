resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project}-${var.env}-vpc"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = element(["us-east-1a", "us-east-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project}-${var.env}-public-subnet-${count.index + 1}"
    Env                      = var.env
    Project                  = var.project
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private_eks" {
  count             = length(var.private_eks_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_eks_subnet_cidrs[count.index]
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)

  tags = {
    Name                                                      = "${var.project}-${var.env}-eks-private-subnet-${count.index + 1}"
    Env                                                       = var.env
    Project                                                   = var.project
    "kubernetes.io/role/internal-elb"                         = "1"
    "kubernetes.io/cluster/${var.project}-${var.env}-cluster" = "owned"
  }
}

resource "aws_subnet" "private_rds" {
  count             = length(var.private_rds_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_rds_subnet_cidrs[count.index]
  availability_zone = element(["us-east-1a", "us-east-1b"], count.index)

  tags = {
    Name    = "${var.project}-${var.env}-rds-private-subnet-${count.index + 1}"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project}-${var.env}-igw"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name    = "${var.project}-${var.env}-nat-eip"
    Env     = var.env
    Project = var.project
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name    = "${var.project}-${var.env}-nat-gw"
    Env     = var.env
    Project = var.project
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project}-${var.env}-public-rt"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name    = "${var.project}-${var.env}-private-rt"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_eks" {
  count          = length(aws_subnet.private_eks)
  subnet_id      = aws_subnet.private_eks[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_rds" {
  count          = length(aws_subnet.private_rds)
  subnet_id      = aws_subnet.private_rds[count.index].id
  route_table_id = aws_route_table.private.id
}
