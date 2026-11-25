# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0

/**
 * White-box tests: jennifer test src/anthropic_test.j
 *
 * No test needs an API key or the network. A fake on 127.0.0.1
 * (`startFake` in the core overlay) answers requests in order from a
 * script and records each one; the replies follow the shapes in
 * Anthropic's API reference. The topic overlays are fragments spliced in
 * here, not standalone suites.
 */
use httpd;
use net;
use testing;

include "topics/core_test.j";
include "topics/messages_test.j";
include "topics/tools_test.j";
include "topics/batches_test.j";
