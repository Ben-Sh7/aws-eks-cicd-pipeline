data "aws_route53_zone" "main" {
  name         = local.domain_name
  private_zone = false

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", local.domain_name))
      error_message = "DOMAIN_NAME in the configuration secret must be a bare domain such as example.com - no scheme, no trailing dot, no path."
    }
  }
}

data "aws_elb_hosted_zone_id" "main" {}

locals {
  app_fqdn     = var.app_subdomain == "" ? local.domain_name : "${var.app_subdomain}.${local.domain_name}"
  argocd_fqdn  = "${var.argocd_subdomain}.${local.domain_name}"
  jenkins_fqdn = "${var.jenkins_subdomain}.${local.domain_name}"

  app_url = "https://${local.app_fqdn}"
}

resource "aws_acm_certificate" "main" {
  domain_name               = local.app_fqdn
  subject_alternative_names = [local.argocd_fqdn]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-cert" }
  )
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

data "kubernetes_service" "ingress_nginx" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.ingress_nginx]
}

locals {
  ingress_lb_hostname = data.kubernetes_service.ingress_nginx.status[0].load_balancer[0].ingress[0].hostname
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = local.ingress_lb_hostname
    zone_id                = data.aws_elb_hosted_zone_id.main.id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.argocd_fqdn
  type    = "A"

  alias {
    name                   = local.ingress_lb_hostname
    zone_id                = data.aws_elb_hosted_zone_id.main.id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "jenkins" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.jenkins_fqdn
  type    = "A"
  ttl     = 60
  records = [aws_instance.jenkins.public_ip]
}
