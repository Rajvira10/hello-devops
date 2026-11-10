environment        = "production"
image_tag          = "0.1.0"
instance_type      = "t3.small"
log_level          = "info"
log_retention_days = 30
# Tighten to your load balancer / office CIDRs in a real deployment.
http_ingress_cidrs  = ["0.0.0.0/0"]
container_memory_mb = 512
