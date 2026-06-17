###############################################################################
# Module: ALB (Application Load Balancer)
#
# Creates:
#   • HTTPS ALB for public traffic (WebSocket gateway + API proxy)
#   • HTTP → HTTPS redirect
#   • Security group (80/443 from CloudFront only)
###############################################################################

###############################################################################
# Security Group — ALB
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "ALB - allow HTTP/HTTPS from anywhere (CloudFront sits in front)"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

###############################################################################
# ALB
###############################################################################

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection       = var.enable_deletion_protection
  enable_cross_zone_load_balancing = true
  idle_timeout                     = 120 # Longer for WebSocket connections

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

###############################################################################
# HTTP → HTTPS redirect
###############################################################################

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

###############################################################################
# HTTPS Listener
###############################################################################

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ws_gateway.arn
  }
}

###############################################################################
# Target Group — WebSocket Gateway (EKS pods)
###############################################################################

resource "aws_lb_target_group" "ws_gateway" {
  name        = "${var.name_prefix}-ws-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }

  deregistration_delay = 30

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = {
    Name = "${var.name_prefix}-ws-tg"
  }
}

###############################################################################
# Listener Rule — WebSocket upgrade path
###############################################################################

resource "aws_lb_listener_rule" "ws" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ws_gateway.arn
  }

  condition {
    path_pattern {
      values = ["/ws", "/ws/*"]
    }
  }
}
