output "authorized_keys_for_kops" {
  description = "authorized_keys rendered template used by kops"
  value       = data.template_file.authorized_keys_for_kops.rendered
}
