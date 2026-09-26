resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "recordings" {
  bucket = "voicebridge-recordings-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "${var.project_name}-recordings"
  }
}

resource "aws_s3_bucket_public_access_block" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  versioning_configuration {
    status = "Disabled"
  }
}
