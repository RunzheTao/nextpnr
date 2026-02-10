#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export NEXTPNR_MVP_ARCH="himbaechel-gowin"
exec "${SCRIPT_DIR}/../common/bootstrap_arch.sh" "$@"
