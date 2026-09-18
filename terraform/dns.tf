# DNS and TLS.
#
# Everything here exists to make one `terraform apply` sufficient. Without a
# domain the app's own address is whatever hostname AWS gives the load balancer
# Kubernetes creates - a value that does not exist at plan time, that changes on
# every rebuild, and that the app itself needs to know (the frontend accepts
# sign-ins only from its exact origin). That is what forced a wrapper script to
# discover the address after the fact and inject it back in.
#
# With a hosted zone, the addresses are decided here, before anything is built:
# app.<domain>, argocd.<domain>, jenkins.<domain>. The load balancer's generated
# hostname is then only ever a CNAME target - still resolved during apply, but
# inside Terraform's own dependency graph, never something a human has to read
# off a terminal and paste somewhere.

# Looked up, not created: an aws_route53_zone made in this same apply would not
# be delegated at the registrar yet, so the ACM validation below would sit
# waiting for DNS that nobody can answer until someone updates NS records by
# hand - which is exactly the manual step this design removes.
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

locals {
  app_fqdn     = "${var.app_subdomain}.${local.domain_name}"
  argocd_fqdn  = "${var.argocd_subdomain}.${local.domain_name}"
  jenkins_fqdn = "${var.jenkins_subdomain}.${local.domain_name}"

  # The origin the app is served from. https, because TLS terminates on the
  # load balancer below - this is the value the frontend compares every
  # sign-in and form submission against.
  app_url = "https://${local.app_fqdn}"
}

# One certificate covering both public names. DNS validation rather than email:
# it needs no mailbox and no human, and renewal stays automatic for as long as
# the validation records below exist.
resource "aws_acm_certificate" "main" {
  domain_name               = local.app_fqdn
  subject_alternative_names = [local.argocd_fqdn]
  validation_method         = "DNS"

  # The certificate is referenced by the ingress-nginx Service annotation, so a
  # replacement has to exist before the old one goes away.
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

  # ACM re-issues with the same validation record, but a stale record from a
  # previous certificate in the same zone would otherwise block the apply.
  allow_overwrite = true
}

# Not a resource in the usual sense - it blocks until ACM reports the
# certificate issued, so nothing downstream can attach a certificate that is
# still PENDING_VALIDATION. Takes a minute or two on a delegated zone.
resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# The load balancer is created by Kubernetes when the ingress-nginx Service is
# applied, so Terraform cannot know its hostname in advance - but it can read it
# straight afterwards. helm_release waits for a Service of type LoadBalancer to
# be given its ingress hostname before reporting success, so by the time this
# data source is read the value is there.
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

# CNAME rather than an ALIAS record: an ALIAS needs the load balancer's own
# hosted zone id, which would mean looking the ELB up a second time by parsing
# its name out of the hostname. These are subdomains, never the zone apex, so a
# CNAME is allowed and costs one extra resolution.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.app_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [local.ingress_lb_hostname]
}

resource "aws_route53_record" "argocd" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.argocd_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [local.ingress_lb_hostname]
}

# Jenkins is a plain EC2 instance, not behind the load balancer. The record
# means the GitHub webhook target stays valid when the instance is replaced and
# comes back with a different public IP.
resource "aws_route53_record" "jenkins" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.jenkins_fqdn
  type    = "A"
  ttl     = 60
  records = [aws_instance.jenkins.public_ip]
}
