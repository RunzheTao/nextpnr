#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NEXTPNR_MVP_ARCH="himbaechel-ng-ultra"
exec "${SCRIPT_DIR}/../common/bootstrap_arch.sh" "$@"
