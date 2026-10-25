output "region" {
  value = var.region
}

output "role_arn" {
  value = aws_iam_role.backup.arn
}

output "selector" {
  description = "Value for --tag."
  value       = "${local.selector_key}=true"
}

output "policy" {
  description = "Value for --policy."
  value       = local.policy
}

output "backed_instance_id" {
  value = aws_instance.backed.id
}

output "backed_volume_ids" {
  description = "Root and data volume of the backed instance: the two volumes that must be snapshotted."
  value       = sort([aws_instance.backed.root_block_device[0].volume_id, aws_ebs_volume.data.id])
}

output "ignored_volume_ids" {
  description = "Root volumes of the unselected and the stopped instance: never snapshotted."
  value       = sort([aws_instance.unselected.root_block_device[0].volume_id, aws_instance.stopped.root_block_device[0].volume_id])
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}

output "manual_snapshot_id" {
  value = aws_ebs_snapshot.manual.id
}
