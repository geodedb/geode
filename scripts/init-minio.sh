#!/bin/bash
# Initialize MinIO buckets
set -e

echo "Waiting for MinIO to be ready..."
until curl -sf http://minio:9000/minio/health/live > /dev/null 2>&1; do
    sleep 2
done

echo "Creating Geode backup bucket..."
mc alias set geode http://minio:9000 ${S3_ACCESS_KEY} ${S3_SECRET_KEY}
mc mb geode/geode-backups --ignore-existing
mc mb geode/geode-backups-gpu --ignore-existing

# GAP-0497: Do NOT set anonymous access on backup buckets.
# Use IAM policies or pre-signed URLs for controlled read access.
echo "Bucket access: private (authenticated IAM access only)"

echo "MinIO initialization complete"
