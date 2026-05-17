variable "db_password" {
  description = "Master password for the RDS PostgreSQL database"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret for the application"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub username or organization that owns zen-pharma-frontend and zen-pharma-backend (e.g. john-smith)"
  type        = string
  default     = "deprajwal"
}
