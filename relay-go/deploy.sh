#!/bin/bash
# Deploy A2A Relay to Cloud Run
# Usage: ./deploy.sh [dev|prod]

set -e

ENV="${1:-dev}"
PROJECT_ID="alan-blount"
REGION="us-central1"
SERVICE_NAME="a2a-relay-${ENV}"

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Usage: $0 [dev|prod]"
  exit 1
fi

echo "🚀 Deploying A2A Relay to ${ENV}..."

# Check for JWT secret
if [[ -z "$RELAY_JWT_SECRET" ]]; then
  echo "❌ RELAY_JWT_SECRET env var required"
  echo "   Set it with: export RELAY_JWT_SECRET='your-secret-here'"
  exit 1
fi

# Check if we're in the right directory
if [[ ! -f "main.go" ]]; then
  echo "❌ Run from relay-go directory"
  exit 1
fi

# Build and deploy using gcloud run deploy (source-based)
echo "📦 Building and deploying..."
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --memory 256Mi \
  --cpu 1 \
  --min-instances 0 \
  --max-instances 10 \
  --set-env-vars "RELAY_JWT_SECRET=${RELAY_JWT_SECRET}"

echo "✅ Deployed to ${ENV}"

# Get the URL
URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --format 'value(status.url)')

echo "🌐 Service URL: ${URL}"
echo "🔍 Health check: curl ${URL}/health"
