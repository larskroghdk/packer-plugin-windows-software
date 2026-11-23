packer {
  required_plugins {
    windows-software = {
      source  = "github.com/larskroghdk/windows-software"
      version = ">= 0.1.0"
    }
  }
}

variable "winrm_host" { type = string }
variable "winrm_username" { type = string }
variable "winrm_password" {
  type      = string
  sensitive = true
}
variable "catalog_path" {
  type        = string
  default     = ""
  description = "Empty uses the catalog embedded in the plugin; a path loads that catalog file instead."
}
source "null" "windows" {
  communicator   = "winrm"
  winrm_host     = var.winrm_host
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_use_ssl  = true
  winrm_insecure = false
}
build {
  sources = ["source.null.windows"]
  provisioner "windows-software" {
    packages       = ["vcredist", "powershell7", "adobereader", "chrome", "edge"]
    catalog_path   = var.catalog_path
    skip_installed = true
    fail_on_error  = true
    report_path    = "reports/windows-software.json"
  }
}
