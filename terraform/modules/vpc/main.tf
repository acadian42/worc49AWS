locals {
  az_count = length(var.availability_zones)
}

# ── VPC ───────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# ── Private Subnets (one per AZ, /26 each) ────────────────────────────────────
# No public tier: egress routes back through on-prem via Direct Connect / TGW.
# RDS Multi-AZ, Aurora, ElastiCache replication, and ALB fault-tolerance all
# depend on the 3-AZ spread confirmed in the spec emails.
resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  })
}

# ── Route Tables ──────────────────────────────────────────────────────────────
# One route table per subnet. No default 0.0.0.0/0 route is added here;
# on-prem egress (Direct Connect / Transit Gateway) is managed by the
# network team outside this Terraform scope. If a Transit Gateway attachment
# ID is provided, a route to 0.0.0.0/0 via that TGW is added.
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rt-private-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Optional: on-prem egress route via Transit Gateway.
# Set var.transit_gateway_id to the TGW ID supplied by the network/ECM team.
resource "aws_route" "tgw_default" {
  count = var.transit_gateway_id != "" ? local.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id
}

# ── VPC Endpoints Security Group ──────────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-vpce-"
  vpc_id      = aws_vpc.this.id
  description = "Security group for Interface VPC endpoints"

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "vpce_ingress_443" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from VPC CIDR to VPC endpoints"
}

resource "aws_security_group_rule" "vpce_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.vpc_endpoints.id
}

# ── VPC Endpoints — Interface type ────────────────────────────────────────────
locals {
  interface_endpoints = {
    "ecr-api"        = "com.amazonaws.${var.region}.ecr.api"
    "ecr-dkr"        = "com.amazonaws.${var.region}.ecr.dkr"
    "logs"           = "com.amazonaws.${var.region}.logs"
    "secretsmanager" = "com.amazonaws.${var.region}.secretsmanager"
    "sts"            = "com.amazonaws.${var.region}.sts"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.this.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"
  subnet_ids        = aws_subnet.private[*].id
  security_group_ids = concat(
    [aws_security_group.vpc_endpoints.id],
    var.vpc_endpoint_security_group_ids
  )
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}

# ── VPC Endpoint — S3 Gateway ─────────────────────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}
