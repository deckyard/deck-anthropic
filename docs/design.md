<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

`@deckyard/anthropic` is a client for Anthropic™'s Claude™ Messages API,
written in Jennifer over plain HTTPS: there is no Anthropic SDK for
Jennifer. It covers messages with text, image and PDF content, tool use
with a tool loop, adaptive thinking and effort, prompt caching, structured
outputs, server-side refusal fallbacks, token counting, the Models API and
the Message Batches API. `call` reaches any other endpoint with the same
headers, deadline, cap, retries and errors.

It is one of three vendor decks (`openai`, `anthropic`, `gemini`), one per
API rather than one generic LLM deck. The wire formats differ in every part
a client touches: Anthropic takes `system` as a top-level field, requires
`max_tokens`, and returns typed content blocks (`text`, `tool_use`,
`thinking`, ...) with tool input as an object. A common facade would hide
what each API does well; a provider-neutral `llm` facade is planned as its
own deck over the three, after they are released.

Not in this version:

- **Streaming.** All replies are read whole. Server-sent events need an
  incremental body reader in the bundled `http` module (planned in core);
  until then a long generation needs a long deadline or a batch.
- **The Files API upload.** It needs a multipart upload; reading and
  deleting files works through `call`.
- **Managed Agents.** A separate surface with its own beta and event
  stream; it would be a deck of its own on top of this client.

## Decisions

- **Requests and replies are `json.Value` documents in the API's shape,**
  not structs. The API gains fields monthly; a struct would need a release
  for each. Builders (`newRequest`, `withSystem`, `withThinking`,
  `withEffort`, `withFormat`, ...) return a new value, and readers (`text`,
  `toolCalls`, `stopReason`, `usage`, ...) cover the common fields.
  Structs are kept for `Client`, `AnthropicError`, `Usage`, `ToolCall` and
  `ToolRun`.
- **Headers.** Every request sends `x-api-key`, `anthropic-version`
  (`API_VERSION`, `2026-10-21`; `withApiVersion` picks another, such as
  `2023-06-01` for code that still sends sampling parameters) and, when
  set, `anthropic-beta` joined from the client's betas. The client is a
  value, so betas for one call are `withBetas($c, [...])` passed to that
  call.
- **Current API rules are written down from the vendor's reference, not
  from memory:** adaptive thinking instead of thinking budgets, no
  assistant prefill, no forced tool choice on the newest models, effort
  and structured output under `output_config`, sampling parameters refused
  on `2026-10-21`, the `refusal` stop reason with `stop_details`. The deck
  does not check model-specific rules locally: the server's 400 says it
  better, and the rules move.
- **`DEFAULT_MAX_TOKENS` is 16000,** suited to a reply that is not
  streamed; `withMaxTokens` changes it.
- **Deadline per attempt: 10 minutes** (`DEFAULT_TIMEOUT_MS`, the official
  SDKs' non-streaming default), enforced around the whole exchange; the
  `http` timeout is only an idle one. A deadline that passed is not
  retried.
- **The tool loop** (`runTools`, `runToolsWith`) appends each reply's whole
  `content` unchanged with `addReply` (thinking, redacted thinking and
  fallback blocks keep their signatures and positions), answers every
  `tool_use` block of a reply in one user turn, in order, and resends a
  `pause_turn` or a `compaction` stop as it is. It ends at any other stop
  reason with `ToolRun.stopped` `""`, or after `maxTurns` requests with
  `stopped` `maxTurns`; then the last reply's tool calls are answered too,
  so `request` can go straight into another `runTools`. A handler that
  throws ends the loop with its error unchanged; a handler returns
  `toolError(message)` for an error the model can recover from. Jennifer
  has no closures, so `runToolsWith` passes a context value to every call.
- **The three AI decks share one surface,** aligned on purpose so the
  planned facade is mostly routing: the request builders, `tool` /
  `addTool` / `addTools`, `toolError`, `ToolCall`, `ToolRun`, the common
  core of `Usage` (`inputTokens` with the cache included, `outputTokens`,
  `totalTokens`, `cachedTokens`, `reasoningTokens`), one retry rule,
  `withMaxToolInput`, and errors with `status`, `retryAfterMs` and
  `limits`. Anthropic's own extras stay: `cacheCreationInputTokens`,
  `withCacheControl`, `withFallbacks`, the batch functions.
- **`Usage`.** Anthropic reports input without the cache, cache reads and
  cache writes separately, and counts thinking inside `output_tokens`, with
  no total. So `inputTokens` sums all three, `cachedTokens` and
  `cacheCreationInputTokens` are its parts, and `totalTokens` is
  `inputTokens + outputTokens`.
- **`countTokens` drops the Messages fields the endpoint does not take**
  (`max_tokens`, `stop_sequences`, `metadata`, `fallbacks`, `thread`, the
  sampling parameters, ...) rather than keeping a list of the ones it
  takes, so beta fields still pass and the same request can be counted and
  sent.
- **Batches.** `batchResults` reads the JSONL results whole under the
  client's reply cap; `waitBatch` cuts each poll's deadline to the time
  left, so the wait ends near its timeout. Server-side fallbacks are
  refused in a batch request, as the API does.

## Errors

Every failure of the deck's own is `AnthropicError{kind, message, status,
type, requestId, retryAfterMs, limits}` with kind `"anthropic"`: a reply
that is not 2xx, a reply that is not what the API sends, and a request the
deck refuses to send (`status` 0). `type` is Anthropic's `error.type`,
`requestId` the `request-id` header (or the body's `request_id`),
`retryAfterMs` the wait the server named (0 when none), and `limits` its
rate-limit headers (`anthropic-ratelimit-*`, `x-ratelimit-*`,
`retry-after`, `retry-after-ms`), lower-cased.

The generic kinds pass through: `"limit"` for a cap (a reply, the models
pages together, a decoded document too deep or too large), `"timeout"` for
a deadline, `"closed"` for a server that closed after part of its answer,
`"net"` for a network failure (the bundled `http`'s `net.NetError`,
unchanged), `"cancelled"` for a cancelled task. Callers match the kind and
read fields, never the message. A refusal is not an error: it is a reply
with `stop_reason` `refusal`.

## Security and limits

- **The API key** must be printable ASCII without spaces, is sent only as a
  header, never in a URL, and is replaced by `<api key>` in any server text
  that reaches an error: the message, `type`, `requestId` and `limits`.
  Server text in messages is cut and stripped of control and bidi
  characters.
- **Plain http** goes only to loopback unless `withPlainHttp` allows it,
  since the key would cross the network in clear. `withTls` takes a CA for
  a gateway. Redirects are not followed.
- **Input validation.** Base URLs, model ids, object ids, beta names,
  custom ids, tool names and `call` paths are checked against strict forms,
  so caller input cannot add a path segment, a query or a header line.
- **Caps.** A reply is read up to `DEFAULT_MAX_BYTES` (64 MiB,
  `withMaxBytes` up to 1 GiB); `models` reads at most 100 pages and at
  most the reply cap over all of them; a batch holds at most `MAX_BATCH_REQUESTS`;
  the tool loop runs at most 1000 requests; a tool input whose JSON is over
  `DEFAULT_MAX_TOOL_INPUT` (1 MiB, `withMaxToolInput`) is answered with an
  error result without calling the handler.
- **Retries** cover 408, 409, 429 and 5xx (529 is overloaded), twice by
  default, and a `net.NetError` whose `sent` is false (refused, DNS, TLS, a
  reset before the whole request was written). A request that was sent is
  never sent again after a reset or a close, whatever the method: it may
  have run, and a resend could duplicate a batch or a charge. The wait is
  `retry-after-ms`, else `retry-after` in seconds or as an HTTP date; a
  wait over `MAX_RETRY_WAIT_MS` (60 s) is not taken and the error is thrown
  at once. Without one the backoff doubles from half a second up to 8 s.
- **Hostile replies** were tried: negative and huge `Content-Length`, an
  endless chunked body, deep nesting and millions of JSON values, a slow
  drip, a gzip body, a redirect, a `retry-after` of 1e9 seconds. Each ends
  in `"limit"`, `"timeout"` or `"anthropic"`.

## Testing and validation

The suite runs offline against a loopback fake written in Jennifer that
answers requests in order from scripted replies and records each request.
Fixtures follow the current API reference: the Messages example reply, the
models list, the batch object and JSONL results, the error shape; thinking,
tool use, refusal, pause and compaction replies are built to the documented
schema. Raw sockets test bodies cut short and real TCP resets before the
request, after it and mid-answer. The examples take `ANTHROPIC_BASE_URL`,
so they run against a local fake; CI only parses them, since a real call
needs a key and costs money.

The deck has not been run against the live API: no key was available. The
request and reply shapes were checked against the API reference and guides
read on 2026-11-14 and 15.

## Known limitations and open questions

- One live call per endpoint remains to be made when a key is available.
- Replies are not streamed (see Scope).
- Batch results are read whole: a cap near 1 GiB takes several times that
  in memory (the body, its text, its lines, the decoded results).
- The tool loop does not remove blocks before a `fallback` block. The API
  asks for that only after a mid-output fallback while streaming; a reply
  that is not streamed leaves the declined part out.
- A `json.Value` round-trips a block exactly except integers beyond int64
  in a tool input, which come back as floats; such a block would fail the
  API's check of replayed thinking. Not seen in practice.
- The `anthropic-ratelimit-*` headers of a successful reply are not
  exposed; only an error carries them.

## Dependencies on the interpreter

Floor `>=0.28.0` (the calls 0.29.0 removes are replaced by their 0.28.0 forms), the default binary (the deck needs `net`). 0.27.0 brought
the UTF-8 codecs of `encoding.encode` / `decode` and `strings.replicate`.
It relies on these `jennifer` milestones:

- M28.56, a thrown module struct keeps its identity, so a caller can
  declare a caught error as `anthropic.AnthropicError`.
- M28.65, transport errors have their own kind: the retry rule reads
  `sent` and `replied` from `net.NetError`.
- M28.68, decoder caps throw `"limit"`.
- M28.71, `net.abort`, which the tests use for real resets.
- M30.9, streaming HTTP responses and server-sent events (planned), is
  what streaming waits for.
