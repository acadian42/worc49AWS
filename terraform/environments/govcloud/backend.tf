terraform {
  backend "s3" {
    bucket         = "<STUB: your-tfstate-bucket-name>"
    key            = "tines/govcloud/terraform.tfstate"
    region         = "us-gov-east-1"
    encrypt        = true
    kms_key_id     = "<STUB: arn:aws-us-gov:kms:us-gov-east-1:ACCOUNT_ID:key/KEY_ID>"
    dynamodb_table = "<STUB: your-tfstate-lock-table>"
    use_fips_endpoint = true
  }
}
