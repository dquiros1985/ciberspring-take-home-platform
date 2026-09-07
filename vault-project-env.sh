#!/usr/bin/env zsh
# Sandbox/prototyping env-loader for the ci-devops-platform take-home.
# Uses YOUR OWN vault login session (not an AppRole — that path is still
# blocked by the open "failed to determine alias name" bug). Fine for
# personal prototyping; NOT the pattern for anything going into the
# homelab Semaphore pipeline.

EXPECTED=David-MacBook
[ "$(scutil --get LocalHostName)" = "$EXPECTED" ] || { echo "ABORT: expected $EXPECTED, got $(scutil --get LocalHostName)"; return 1 2>/dev/null || exit 1; }

export VAULT_ADDR="https://10.0.100.60:8200"
export VAULT_CACERT="$HOME/.config/homelab-api/homelab-ca.crt"

vault token lookup >/dev/null 2>&1 || { echo "ABORT: vault token missing/expired — run: vault login -method=userpass username=david"; return 1 2>/dev/null || exit 1; }

export ARM_SUBSCRIPTION_ID=$(vault kv get -mount=homelab -field=subscription_id infra/azure-terraform)
export ARM_CLIENT_ID=$(vault kv get -mount=homelab -field=client_id infra/azure-terraform)
export ARM_TENANT_ID=$(vault kv get -mount=homelab -field=tenant_id infra/azure-terraform)
export ARM_CLIENT_SECRET=$(vault kv get -mount=homelab -field=client_secret infra/azure-terraform)
export VERCEL_API_TOKEN=$(vault kv get -mount=homelab -field=api_token infra/vercel-terraform)

echo "######## ARM_* and VERCEL_API_TOKEN exported — ready for terraform ########"
