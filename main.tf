locals {
  bastion_fqdn        = "bastion.${replace(data.aws_route53_zone.selected.name, "/[.]$/", "")}"
  authorized_keys_url = "https://raw.githubusercontent.com/ministryofjustice/cloud-platform-terraform-bastion/main/files/authorized_keys.txt"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnet_ids" "public" {
  vpc_id = data.aws_vpc.selected.id

  tags = {
    SubnetType = "Utility"
  }
}

# It's possible to get Route53 zone_id using cluster_base_domain_name
data "aws_route53_zone" "selected" {
  name = var.route53_zone
}

data "aws_ami" "debian_stretch_latest" {
  most_recent      = true
  executable_users = ["all"]
  owners           = ["379101102735"] // official Debian account (https://wiki.debian.org/Cloud/AmazonEC2Image/)

  filter {
    name   = "name"
    values = ["debian-stretch-hvm-x86_64-gp2-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The EIP cannot be associated with the instance since it's in an autoscaling
# group. The host itself has a role which allows it and will do it on startup.
# See the userdata below for more detail.
resource "aws_eip" "bastion" {
  vpc = true

  tags = {
    "Name" = local.bastion_fqdn
  }
}

data "template_file" "authorized_keys_manager" {
  template = file(
    "${path.module}/resources/bastion/authorized_keys_manager.service",
  )

  vars = {
    authorized_keys_url = local.authorized_keys_url
    username            = "admin"
  }
}

data "template_file" "authorized_keys_for_kops" {
  template = file(
    "${path.module}/resources/bastion/authorized_keys_manager.service",
  )

  vars = {
    authorized_keys_url = local.authorized_keys_url
    username            = "ubuntu"
  }
}

data "template_file" "configure_bastion" {
  template = file("${path.module}/resources/bastion/configure_bastion.sh")

  vars = {
    eip_id     = aws_eip.bastion.id
    aws_region = data.aws_region.current.name
  }
}

data "template_cloudinit_config" "bastion" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"

    content = <<EOF
packages:
- awscli
write_files:
- content: |
    ${indent(4, data.template_file.authorized_keys_manager.rendered)}
  owner: root:root
  path: /etc/systemd/system/authorized-keys-manager.service
- content: |
    ${indent(4, file("${path.module}/resources/bastion/sshd_config"))}
  owner: root:root
  path: /etc/ssh/sshd_config
EOF

  }

  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.configure_bastion.rendered
  }
}

resource "aws_security_group" "bastion" {
  name        = local.bastion_fqdn
  description = "Security group for bastion"
  vpc_id      = data.aws_vpc.selected.id

  // non-standard port to reduce probes
  ingress {
    from_port   = 50422
    to_port     = 50422
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "Name" = local.bastion_fqdn
  }
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role" "bastion" {
  name               = local.bastion_fqdn
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

data "aws_iam_policy_document" "bastion" {
  statement {
    actions = [
      "ec2:AssociateAddress",
    ]

    // ec2:AssociateAddress cannot be constrained to a single eipalloc
    resources = [
      "*",
    ]
  }
}

resource "aws_iam_role_policy" "bastion" {
  name   = "associate-eip"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion.json
}

resource "aws_iam_instance_profile" "bastion" {
  name = aws_route53_record.bastion.name
  role = aws_iam_role.bastion.name
}

resource "aws_launch_configuration" "bastion" {
  iam_instance_profile = aws_iam_instance_profile.bastion.name
  image_id             = data.aws_ami.debian_stretch_latest.image_id
  instance_type        = "t2.nano"
  key_name             = aws_key_pair.vpc.key_name
  security_groups      = [aws_security_group.bastion.id]
  user_data            = data.template_cloudinit_config.bastion.rendered

  lifecycle {
    create_before_destroy = true
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp2"
  }
}

resource "aws_autoscaling_group" "bastion" {
  name                      = local.bastion_fqdn
  desired_capacity          = "1"
  max_size                  = "1"
  min_size                  = "1"
  health_check_grace_period = 60
  health_check_type         = "EC2"
  force_delete              = true
  launch_configuration      = aws_launch_configuration.bastion.name
  vpc_zone_identifier       = data.aws_subnet_ids.public.ids
  default_cooldown          = 60

  tags = [
    {
      key                 = "Name"
      value               = local.bastion_fqdn
      propagate_at_launch = true
    },
  ]
}

resource "aws_route53_record" "bastion" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.bastion_fqdn
  type    = "A"
  ttl     = "30"
  records = [aws_eip.bastion.public_ip]
}

############
# Key Pair #
############

resource "tls_private_key" "vpc" {
  algorithm = "RSA"
  rsa_bits  = "2048"
}

resource "aws_key_pair" "vpc" {
  key_name   = var.cluster_domain_name
  public_key = tls_private_key.vpc.public_key_openssh
}
