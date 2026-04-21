output "certificate_arn" {
  description = "ARN of the validated ACM certificate"
  value       = aws_acm_certificate_validation.main.certificate_arn
}

output "test_certificate_arn" {
  description = "ARN of the validated ACM certificate for the test/canary endpoint"
  value       = aws_acm_certificate_validation.test.certificate_arn
}
