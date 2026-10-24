
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
  # TLS certificate (ACM অবশ্যই us-east-1 এ থাকতে হবে
  # এবং সব site এর domain কভার করতে হবে)
  # --------------------------------------------------
   viewer_certificate = {
    acm_certificate_arn      = module.acm.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }


   # Geo restriction: allow all countries
  # Both buckets must allow this distribution through OAC.
  # --------------------------------------------------
  restrictions = {
    geo_restriction = {
      restriction_type = "none"
    }
  }


  # --------------------------------------------------
  # React SPA fallback
  # S3 (OAC) এ object না থাকলে 403/404 আসে, তাই index.html দিতে হবে।
  # সতর্কতা: এটা /api/* এর 403/404 response ও বদলে দেয়।
  # --------------------------------------------------
  custom_error_response = [
    {
      error_code            = 403
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    },
    {
      error_code            = 404
      response_code         = 200
      response_page_path    = "/index.html"
      error_caching_min_ttl = 10
    }
  ]
     

     # --------------------------------------------------
  # S3 Origin Access Control
  # শুধু CloudFront private frontend bucket পড়তে পারবে।
  # দুই bucket এর policy তে প্রতিটি distribution এর ARN অনুমোদন করতে হবে।
  # --------------------------------------------------

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
  # HTTP is retained from your original configuration.
  # Change to https-only after configuring ALB HTTPS
  # listener and a matching certificate.
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
      origin_id                 = "s3"
      domain_name = module.frontend_bucket.s3_bucket_bucket_regional_domain_name
      origin_access_control_key = "s3"
    }

     # Backup React frontend
  s3_backup = {
    origin_id = "s3-backup"
    domain_name = module.frontend_backup_bucket.s3_bucket_bucket_regional_domain_name
    origin_access_control_key = "s3"
  }

    # EKS APIs: internal ALB through CloudFront VPC Origin
    app = {
      origin_id   = "app"
      domain_name = module.alb.dns_name
      vpc_origin_config = {
        vpc_origin_key = "alb"
      }
    }
  }


  # S3 Origin Failover
  # Primary: s3
  # Secondary: s3-backup
  # --------------------------------------------------
  origin_group = {
    frontend_failover = {
      origin_id = "frontend-origin-group"

      failover_criteria = {
        status_codes = [
          403,
          404,
          500,
          502,
          503,
          504
        ]
      }

      member = [
        {
          origin_id = "s3"
        },
        {
          origin_id = "s3-backup"
        }
      ]
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
    target_origin_id       = "frontend-origin-group"
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

    compress           = true

     # Cache static frontend content
    cache_policy_name = "Managed-CachingOptimized"    
  

   # Security response headers
   response_headers_policy_id = "67f7725c-6f97-4210-82d7-5512b31e9d03"

   # Lambda@Edge associations
     # Lambda@Edge (us-east-1, published version ARN হতে হবে,
    # environment variable ব্যবহার করা যাবে না)
   lambda_function_association = {
    viewer-request = {
      lambda_arn   = module.lambda_function.lambda_function_qualified_arn
    }

    origin-request = {
      lambda_arn = module.lambda_function.lambda_function_qualified_arn
    }
  }

    
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

      compress = true

      # Do not cache API responses by default.
      cache_policy_name = "Managed-CachingDisabled"

      # Forward authorization headers, cookies and query strings.
      origin_request_policy_name = "Managed-AllViewerExceptHostHeader"
    }
  ]

  # CloudFront Functions - module managed
  cloudfront_functions = {
    viewer-request-security = {
      runtime = "cloudfront-js-2.0"
      comment = "Security headers and cache key normalization"
      code    = file("./functions/viewer-request-security.js")
      publish = true
    }
    viewer-response-headers = {
      runtime = "cloudfront-js-2.0"
      comment = "Add security response headers"
      code    = file("./functions/viewer-response-headers.js")
      publish = true
    }
    ab-testing = {
      runtime = "cloudfront-js-2.0"
      comment = "A/B testing function"
      code    = file("./functions/ab-testing.js")
      publish = true
    }
    # Example with KeyValueStore association (uncomment and provide actual KV store ARN)
    # kvstore-redirect = {
    #   runtime = "cloudfront-js-2.0"
    #   comment = "Function using CloudFront KeyValueStore for dynamic redirects"
    #   code    = file("./functions/kvstore-redirect.js")
    #   publish = true
    #   key_value_store_associations = [
    #     "arn:aws:cloudfront::123456789012:key-value-store/example-redirects"
    #   ]
    # }
  }
}
 

 