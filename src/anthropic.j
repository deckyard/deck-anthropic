# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * A client for Anthropic's Claude Messages API over HTTPS: messages with
 * text, image and PDF content, tool use with a tool loop, adaptive
 * thinking and effort, prompt caching, structured outputs, token counting,
 * the Models API and the Message Batches API. `call` reaches any other
 * endpoint. Requests and replies are `json.Value` documents in the API's
 * own shape, so every field the API has, or gains, is reachable; the
 * builders and readers cover the common ones.
 *
 * Every request carries `x-api-key` and `anthropic-version` (`API_VERSION`,
 * `2026-10-21`), has a deadline (10 minutes by default: a reply is not
 * streamed) and a reply cap, and is retried on 408, 409, 429 and 5xx (529
 * is "overloaded") and on a network failure before the request was
 * sent, honouring `retry-after-ms` and `retry-after`; a request that was
 * sent is never sent twice. A refused request throws `AnthropicError` (kind
 * `anthropic`) with the HTTP `status`, Anthropic's error `type`, the
 * `requestId`, the wait asked for and the rate-limit headers; a reply over
 * the cap is kind `"limit"`,
 * a deadline that passed `"timeout"`, a connection the server closed
 * after part of its answer `"closed"`, and a network failure is the
 * bundled `http`'s `net.NetError` (kind `"net"`), passed on unchanged.
 * The API key never appears in a message or a URL.
 *
 * | topic | covers |
 * | --- | --- |
 * | `core` | `Client`, settings, errors, the exchange and retries, `call`, `models`, `model` |
 * | `messages` | request and content-block builders, `chat`, `countTokens`, reply readers, `Usage` |
 * | `tools` | tool definitions, tool results, `runTools` |
 * | `batches` | the Message Batches API and its JSONL results |
 *
 * @module anthropic
 * @see https://platform.claude.com/docs/en/api/messages/create
 * @example
 *   def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
 *   def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
 *   $req = anthropic.addUserText($req, "Name three moons of Jupiter.");
 *   io.printf("%s\n", anthropic.text(anthropic.chat($c, $req)));
 */
use convert;
use encoding;
use io;
use json;
use lists;
use maps;
use math;
use net;
use regex;
use strings;
use task;
use time;

import "http.j" as http;

include "topics/core.j";
include "topics/messages.j";
include "topics/tools.j";
include "topics/batches.j";
