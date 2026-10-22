locals {
  name_prefix = "${var.project_name}-${var.environment}"

  environment_settings = {    
    prod = {
      deletion_protection = true
      log_retention_days  = 90
    }
  }

  current_settings = local.environment_settings[var.environment]

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    CostCenter  = var.cost_center
  }


  sites = {
    sites = {
    app   = "app.sayem.xyz"
    web   = "web.sayem.xyz"
    sites = "sites.sayem.xyz"
    # add more here: blog = "blog.sayem.xyz"
  }

  }
}