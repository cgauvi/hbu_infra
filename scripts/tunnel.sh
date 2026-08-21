#!/usr/bin/env bash
# Port-forward the database to localhost through the SSM bastion.
#
# For the private posture: db_publicly_accessible = false, enable_bastion = true.
# Session Manager carries the TCP stream over the bastion's outbound agent
# connection, so this needs no open port, no SSH key, and no VPN — only IAM
# permission to start a session.
#
#   ./scripts/tunnel.sh [env] [local-port] [region]
#
# Then, in another shell:
#   psql "postgresql://USER:PASS@localhost:5433/urban_rag?sslmode=require"
#   DATABASE_URL="postgresql://USER:PASS@localhost:5433/urban_rag" ./scripts/db.py check
#
# The tunnel runs in the foreground; Ctrl-C closes it.

set -euo pipefail

ENV_NAME="${1:-dev}"
LOCAL_PORT="${2:-5433}"
REGION="${3:-${AWS_REGION:-us-east-1}}"
PROJECT="${HBU_PROJECT:-hbu}"
PREFIX="/${PROJECT}-${ENV_NAME}"

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }

# The Session Manager plugin is a separate install from the CLI, and its
# absence surfaces as an unhelpful "SessionManagerPlugin is not found".
if ! session-manager-plugin --version >/dev/null 2>&1; then
  cat >&2 <<'MSG'
error: the AWS Session Manager plugin is not installed.
  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
MSG
  exit 1
fi

param() {
  aws ssm get-parameter --name "${PREFIX}/$1" --region "$REGION" \
    --query Parameter.Value --output text 2>/dev/null
}

DB_HOST="$(param db/host)" || true
DB_PORT="$(param db/port)" || true
if [[ -z "${DB_HOST:-}" || "$DB_HOST" == "None" ]]; then
  echo "error: no database parameters under ${PREFIX} in ${REGION} — has 'make apply ENV=${ENV_NAME}' run?" >&2
  exit 1
fi

# Tagged by Terraform as <project>-<env>-bastion.
BASTION_ID="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-${ENV_NAME}-bastion" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"

if [[ -z "$BASTION_ID" || "$BASTION_ID" == "None" ]]; then
  echo "error: no running bastion named ${PROJECT}-${ENV_NAME}-bastion." >&2
  echo "       Set enable_bastion = true in ${ENV_NAME}.tfvars and re-apply." >&2
  exit 1
fi

echo "tunnelling ${DB_HOST}:${DB_PORT} -> localhost:${LOCAL_PORT} via ${BASTION_ID}"
echo "leave this running; Ctrl-C to close"

exec aws ssm start-session \
  --region "$REGION" \
  --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${DB_HOST}\"],\"portNumber\":[\"${DB_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
