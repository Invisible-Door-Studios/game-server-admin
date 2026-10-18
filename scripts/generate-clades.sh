#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# Retired: the former generator emitted A2ML panel-clade descriptors. Current
# standards prohibit creating, restoring, regenerating, or extending A2ML.
# Existing generated clades remain in the repository for compatibility.

set -euo pipefail

printf '%s\n' \
  'Disabled: panel-clade A2ML generation is retired. No files were created.' \
  'Existing clades remain for compatibility; a replacement authoring format needs maintainer approval.' >&2
exit 1
