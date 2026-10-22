module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "6.7.1"
  for_each = local.sites

  aliases = [each.value]
  comment = "Cloudfront distribution for ${each.value.domain_name}"
  enabled = true
  price_class = "PriceClass_All"

  create_monitoring_subscription = true

  origin_access_control = {    
    "${each.key}-oac" = {
      description      = "OAC for ${each.value}"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  }


enable_v2_logging = true

v2_logging = {
  name = "example-v2-logs"

  delivery_destination_configuration = {
    destination_resource_arn = "${module.log_bucket.s3_bucket_arn}/cloudfront"
  }

  delivery_destination_type = "S3"
  output_format             = "parquet"

  s3_delivery_configuration = {
    enable_hive_compatible_path = true
    suffix_path                 = "{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
  }
}






  default_cache_behavior = {
    target_origin_id       = "my-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
  }
}