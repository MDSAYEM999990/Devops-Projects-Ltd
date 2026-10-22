
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "6.7.1"

  for_each = local.sites

  # --------------------------------------------------
  # Distribution settings
  # --------------------------------------------------
  aliases = [each.value.domain_name]

  comment         = "CloudFront for ${each.value.domain_name}"
  enabled         = true
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = "PriceClass_All"

  default_root_object = "index.html"

  create_monitoring_subscription = true

  # --------------------------------------------------
  # S3 Origin Access Control
  # --------------------------------------------------
  # Only CloudFront should read the private frontend bucket.
  origin_access_control = {
    s3 = {
      description      = "CloudFront access to React frontend"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }

  # --------------------------------------------------
  # VPC Origin for internal EKS ALB
  # --------------------------------------------------
  vpc_origin = {
    alb = {
      name = "${each.key}-internal-alb-origin"

      arn       = module.alb.arn
      http_port = 80
      https_port = 443

      # Use HTTP initially unless the ALB origin hostname
      # has a certificate that CloudFront can validate.
      origin_protocol_policy = "http-only"

      origin_ssl_protocols = {
        items    = ["TLSv1.2"]
        quantity = 1
      }

      timeouts = {
        create = "20m"
        update = "20m"
        delete = "20m"
      }
    }
  }

  # --------------------------------------------------
  # Origins
  # --------------------------------------------------
  origin = {
    # React frontend: private S3 bucket
    s3 = {
      domain_name = module.frontend_bucket.s3_bucket_bucket_regional_domain_name

      origin_access_control_key = "s3"
    }

    # EKS APIs: internal ALB through CloudFront VPC Origin
    app = {
      domain_name = module.alb.dns_name

      vpc_origin_config = {
        vpc_origin_key = "alb"
      }
    }
  }

  # --------------------------------------------------
  # CloudFront standard logging v2
  # --------------------------------------------------
  enable_v2_logging = true

  v2_logging = {
    name = "${each.key}-cloudfront-logs"

    delivery_destination_configuration = {
      destination_resource_arn = "${module.log_bucket.s3_bucket_arn}/cloudfront"
    }

    delivery_destination_type = "S3"
    output_format             = "parquet"

    s3_delivery_configuration = {
      enable_hive_compatible_path = true
      suffix_path = "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
    }
  }

  # --------------------------------------------------
  # Default behavior: React frontend from S3
  # --------------------------------------------------
  default_cache_behavior = {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = [
      "GET",
      "HEAD",
      "OPTIONS"
    ]

    cached_methods = [
      "GET",
      "HEAD"
    ]

    cache_policy_name = "Managed-CachingOptimized"
  }

  # --------------------------------------------------
  # API behavior: /api/* -> Internal ALB -> EKS
  # --------------------------------------------------
  ordered_cache_behavior = [
    {
      path_pattern           = "/api/*"
      target_origin_id       = "app"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = [
        "GET",
        "HEAD",
        "OPTIONS",
        "PUT",
        "POST",
        "PATCH",
        "DELETE"
      ]

      cached_methods = [
        "GET",
        "HEAD"
      ]

      # Do not cache API responses by default.
      cache_policy_name = "Managed-CachingDisabled"

      # Forward authorization headers, cookies and query strings.
      origin_request_policy_name = "Managed-AllViewerExceptHostHeader"
    }
  ]
}
 