resource "aws_lambda_layer_version" "as_layer" {
  filename    = "${path.root}/${var.layer_function_dir}/${var.layer_function_build_dir}/layer.zip"
  layer_name  = "${var.name}-as-layer"
  description = "Auto scale lambda layer"

  source_code_hash    = filebase64sha256("${path.root}/${var.layer_function_dir}/${var.layer_function_build_dir}/layer.zip")
  compatible_runtimes = ["python3.6", "python3.7"]
}

# Generate zip files for lambda functions if development variable is true
data "archive_file" "stepfunction" {
  for_each = var.development == true ? toset([for file in fileset("${path.root}/${var.lambda_function_dir}/src", "*.py") : trimsuffix(file, ".py")]) : toset([])

  type        = "zip"
  source_file = "${path.root}/${var.lambda_function_dir}/src/${each.key}.py"
  output_path = "${path.root}/${var.lambda_function_dir}/package/${each.key}.zip"

}

data "archive_file" "nodejslambda" {
  for_each = var.development == true ? toset([for file in fileset("${path.root}/${var.lambda_function_dir}/src", "*.js") : trimsuffix(file, ".js")]) : toset([])

  type        = "zip"
  source_file = "${path.root}/${var.lambda_function_dir}/src/${each.key}.js"
  output_path = "${path.root}/${var.lambda_function_dir}/package/${each.key}.zip"

}

# Create step function s3 bucket
resource "aws_s3_bucket" "stepfunction" {
  bucket_prefix = "${lower(var.name)}-stepfunction"
  acl           = "private"
}

# Upload step function zip to an s3 bucket
resource "aws_s3_bucket_object" "this" {
  for_each = local.lambda_functions
  bucket   = aws_s3_bucket.stepfunction.id
  key      = "${each.key}.zip"
  source   = "${path.root}/${var.lambda_function_dir}/package/${each.key}.zip"
  etag     = filemd5("${path.root}/${var.lambda_function_dir}/package/${each.key}.zip")

  depends_on = [data.archive_file.stepfunction, data.archive_file.nodejslambda]
}

# Upload sfn init function
resource "aws_s3_bucket_object" "sfn_init_s3" {
  for_each = local.sfn_init_lambda
  bucket   = aws_s3_bucket.stepfunction.id
  key      = "${each.key}.zip"
  source   = "${path.root}/${var.lambda_function_dir}/package/${each.key}.zip"
  etag     = filemd5("${path.root}/${var.lambda_function_dir}/package/${each.key}.zip")

  depends_on = [data.archive_file.stepfunction, data.archive_file.nodejslambda]
}

resource "aws_lambda_function" "this" {
  for_each      = local.lambda_functions
  function_name = "${var.name}-${each.key}"
  s3_bucket     = aws_s3_bucket.stepfunction.id
  s3_key        = aws_s3_bucket_object.this[each.key].id
  handler       = each.value.handler
  role          = aws_iam_role.lambda_execution_role.arn
  timeout       = each.value.timeout
  runtime       = lookup(each.value, "runtime", var.runtime)
  layers        = lookup(each.value, "layers", [aws_lambda_layer_version.as_layer.arn])

  environment {
    variables = lookup(each.value, "environment_variables", { Region = var.region })
  }

  dynamic "vpc_config" {
    for_each = lookup(each.value, "vpc_config", null) != null ? [each.value.vpc_config] : []

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  source_code_hash = filebase64sha256("${path.root}/${var.lambda_function_dir}/package/${each.key}.zip")
}

locals {
  lambda_functions = {

    custom_gp_metrics = {
      handler = "custom_gp_metrics.lambda_handler"
      timeout = 60
      runtime = "nodejs12.x"
      layers  = []
      environment_variables = {
        Region = var.region
      }
    }

    config_fw = {
      handler = "config_fw.lambda_handler"
      timeout = 20
      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
        vmseries_api_key          = var.vmseries_api_key
        panorama_ip_1             = var.panorama_ip_1
        panorama_ip_2             = var.panorama_ip_2
      }
      vpc_config = {
        subnet_ids         = var.lambda_subnet_ids
        security_group_ids = var.security_group_ids
      }
    }

    get_serial = {
      handler = "get_serial.lambda_handler"
      timeout = 900
      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
        vmseries_api_key          = var.vmseries_api_key
        panorama_ip_1             = "172.30.0.10"
        panorama_ip_2             = "172.30.1.10"
      }
      vpc_config = {
        subnet_ids         = var.lambda_subnet_ids
        security_group_ids = var.security_group_ids
      }
    }

    config_panorama = {
      handler = "config_panorama.lambda_handler"
      timeout = 600
      environment_variables = {
        panorama_api_key = var.panorama_api_key
        panorama_ip_1    = "172.30.0.10"
        panorama_ip_2    = "172.30.1.10"
        tpl_stk          = "MOJ AWS GP Gateway Stack"
        device_group     = "MOJ AWS GP Gateway Firewalls"
      }
      vpc_config = {
        subnet_ids         = var.lambda_subnet_ids
        security_group_ids = var.security_group_ids
      }
    }

    deactivate_license = {
      handler = "deactivate_license.lambda_handler"
      timeout = 300
      environment_variables = {
        panorama_api_key = var.panorama_api_key
        panorama_ip_1    = "172.30.0.10"
        panorama_ip_2    = "172.30.1.10"
      }
      vpc_config = {
        subnet_ids         = var.lambda_subnet_ids
        security_group_ids = var.security_group_ids
      }
    }

    cleanup_panorama = {
      handler = "cleanup_panorama.lambda_handler"
      timeout = 600
      environment_variables = {
        panorama_api_key = var.panorama_api_key
        panorama_ip_1    = "172.30.0.10"
        panorama_ip_2    = "172.30.1.10"
        tpl_stk          = "MOJ AWS GP Gateway Stack"
        device_group     = "MOJ AWS GP Gateway Firewalls"
      }
      vpc_config = {
        subnet_ids         = var.lambda_subnet_ids
        security_group_ids = var.security_group_ids
      }
    }


    scale_in_or_out = {
      handler = "scale_in_or_out.lambda_handler"
      timeout = 600
    }

    create_eni = {
      handler = "create_eni.lambda_handler"
      timeout = 60

      environment_variables = {
        Region         = var.region
        PublicIpv4Pool = var.public_ipv4_pool
      }
    }

    delete_eni = {
      handler = "delete_eni.lambda_handler"
      timeout = 300

      environment_variables = {
        Region         = var.region
        PublicIpv4Pool = var.public_ipv4_pool
      }
    }

    reserve_record = {
      handler = "reserve_record.lambda_handler"
      timeout = 10

      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
      }
    }

    release_db = {
      handler = "release_db.lambda_handler"
      timeout = 10

      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
      }
    }

    create_dns = {
      handler = "create_dns.lambda_handler"
      timeout = 30

      environment_variables = {
        Region       = var.region
        host_zone_id = var.host_zone_id
        host_zone    = var.aws_route53_zone
      }
    }

    delete_dns = {
      handler = "delete_dns.lambda_handler"
      timeout = 30

      environment_variables = {
        Region       = var.region
        host_zone_id = var.host_zone_id
        host_zone    = var.aws_route53_zone
      }
    }

    update_db = {
      handler = "update_db.lambda_handler"
      timeout = 10

      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
      }
    }

    query_db = {
      handler = "query_db.lambda_handler"
      timeout = 10

      environment_variables = {
        Region                    = var.region
        gp_client_ip_pool_db_name = var.gp_client_ip_pool_db_name
      }
    }

    update_ec2_name = {
      handler = "update_ec2_name.lambda_handler"
      timeout = 10
    }

    cfn_success = {
      handler = "cfn_success.lambda_handler"
      timeout = 600
    }

    cfn_fail = {
      handler = "cfn_fail.lambda_handler"
      timeout = 10
    }
  }

  sfn_init_lambda = {
    start_sfn = {
      handler = "start_sfn.lambda_handler"
      timeout = 30

      environment_variables = {
        InitFWStateMachine = aws_sfn_state_machine.sfn.id
      }
    }
  }
}

resource "aws_lambda_function" "sfn_init" {
  for_each      = local.sfn_init_lambda
  function_name = "${var.name}-${each.key}"
  s3_bucket     = aws_s3_bucket.stepfunction.id
  s3_key        = aws_s3_bucket_object.sfn_init_s3[each.key].id
  handler       = each.value.handler
  role          = aws_iam_role.lambda_execution_role.arn
  timeout       = each.value.timeout
  runtime       = lookup(each.value, "runtime", var.runtime)
  layers        = lookup(each.value, "layers", [aws_lambda_layer_version.as_layer.arn])

  environment {
    variables = lookup(each.value, "environment_variables", { Region = var.region })
  }

  dynamic "vpc_config" {
    for_each = lookup(each.value, "vpc_config", null) != null ? [each.value.vpc_config] : []

    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  source_code_hash = filebase64sha256("${path.root}/${var.lambda_function_dir}/package/${each.key}.zip")
  depends_on       = [aws_sfn_state_machine.sfn]
}

resource "aws_sfn_state_machine" "sfn" {
  name     = "${var.name}-Autoscale"
  role_arn = aws_iam_role.sfn_execution_role.arn

  definition = <<EOF
{
  "Comment": "GlobalProtect Autoscaling step function",
  "StartAt": "scale_in_out",
  "States": {
    "scale_in_out": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.LifecycleTransition",
          "StringEquals": "autoscaling:EC2_INSTANCE_LAUNCHING",
          "Next": "create_eni"
        },
        {
          "Variable": "$.LifecycleTransition",
          "StringEquals": "autoscaling:EC2_INSTANCE_TERMINATING",
          "Next": "delete_eni"
        }
      ],
      "Default": "cfn_success"
    },
    "create_eni": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["create_eni"].arn}",
      "Next": "reserve_record",
      "TimeoutSeconds": 300,
      "Catch": [
        {
          "ErrorEquals": [
            "States.Timeout"
          ],
          "Next": "cfn_fail"
        }
      ]
    },
    "reserve_record": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["reserve_record"].arn}",
      "Next": "config_fw",
      "TimeoutSeconds": 10
    },
    "config_fw": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["config_fw"].arn}",
      "Next": "get_serial",
      "Retry": [ 
        {
          "ErrorEquals": [ "FWNotUpException" ],
          "IntervalSeconds": 120,
          "MaxAttempts": 15,
          "BackoffRate": 1
        }
      ],
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "cfn_fail"
        }
      ]
    },
    "get_serial": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["get_serial"].arn}",
      "TimeoutSeconds": 10,
      "Next": "update_db",
      "Retry": [ 
        {
          "ErrorEquals": [ "NotLicensed" ],
          "IntervalSeconds": 10,
          "MaxAttempts": 10,
          "BackoffRate": 1.5
        } 
      ],
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "cfn_fail"
        }
      ]
    },
    "update_db": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["update_db"].arn}",
      "Next": "update_ec2_name",
      "TimeoutSeconds": 10
    },
    "update_ec2_name": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["update_ec2_name"].arn}",
      "Next": "config_panorama",
      "TimeoutSeconds": 10
    },
    "config_panorama": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["config_panorama"].arn}",
      "Next": "create_dns",
      "TimeoutSeconds": 300
    },
    "create_dns": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["create_dns"].arn}",
      "Next": "cfn_success",
      "TimeoutSeconds": 60
    },
    "delete_eni": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["delete_eni"].arn}",
      "Next": "query_db",
      "TimeoutSeconds": 300
    },
    "query_db": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["query_db"].arn}",
      "Next": "delete_dns",
      "TimeoutSeconds": 10
    },
    "delete_dns": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["delete_dns"].arn}",
      "Next": "deactivate_license",
      "TimeoutSeconds": 10
    },
    "deactivate_license": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["deactivate_license"].arn}",
      "Next": "cleanup_panorama",
      "TimeoutSeconds": 10
    },
    "cleanup_panorama": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["cleanup_panorama"].arn}",
      "Next": "release_db",
      "TimeoutSeconds": 20
    },
    "release_db": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["release_db"].arn}",
      "Next": "cfn_success",
      "TimeoutSeconds": 20
    },
    "cfn_success": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["cfn_success"].arn}",
      "End": true
    },
    "cfn_fail": {
      "Type": "Task",
      "Resource": "${aws_lambda_function.this["cfn_fail"].arn}",
      "Next": "FailState"
    },
    "FailState": {
      "Type": "Fail",
      "Cause": "Failed",
      "Error": "Creation Error"
    }
  }
}
EOF

  depends_on = [aws_lambda_function.this]
}