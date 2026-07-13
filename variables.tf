
variable "retry_error_message_regex" {
  description = <<DESC
Regular expressions the provider retries on when a Graph call fails, applied to the detection rule
resource and the validation actions. Transient service noise is retried by default; the provider
retries matching errors with backoff until the operation timeout bounds it (the provider exposes no
retry count knob, so the timeout is the ceiling). Set null to disable retries.
DESC
  type        = list(string)
  default     = ["(?i)too many requests", "(?i)service unavailable", "(?i)internal server error", "(?i)timeout", "(?i)temporarily unavailable"]
}

variable "timeouts" {
  description = <<DESC
Operation timeouts for the detection rule resource. The delete default is 10 minutes because rule
deletion was observed hanging server side (live, via both the API and the portal): a wedged delete
now fails loudly at the timeout instead of spinning into the provider default, and transient errors
retry per retry_error_message_regex.
DESC
  type = object({
    create = optional(string, "10m")
    delete = optional(string, "10m")
    read   = optional(string, "5m")
    update = optional(string, "10m")
  })
  default = {}
}
