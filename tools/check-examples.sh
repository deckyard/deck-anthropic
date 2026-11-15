#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# anthropic overrides the shared example runner.
#
# The examples call the Claude API, which needs an API key and costs money,
# and CI has no key. CI checks that each one still parses against the
# current language and module surface; `jennifer lint` covers them too, in
# the test workflow, and reaches undefined calls. The suite tests every call
# against a loopback fake that answers with the API reference's replies.
set -euo pipefail
cd "$(dirname "$0")/.."
exec env EXAMPLES_SKIP_RUN=1 tools/check-examples-shared.sh
