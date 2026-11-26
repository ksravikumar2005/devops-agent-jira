#!/usr/bin/env bash
# Entrypoint for AWS CloudShell
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${DIR}/setup-jira-integration.sh" "$@"
