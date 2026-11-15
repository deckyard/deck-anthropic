<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# anthropic cheatsheet

Every export of `@deckyard/anthropic`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/anthropic/" as anthropic;
```

Requests, replies, blocks and tools are `json.Value` documents in the API's
own shape. A refused request throws `AnthropicError` (kind `anthropic`) with
the HTTP `status`, Anthropic's error `type`, the `requestId`, the wait the
server asked for and its rate-limit headers; so does a
request the deck refuses to send (`status` 0). A reply over the cap is kind
`"limit"`, a deadline that passed `"timeout"`, a connection the server
closed after part of its answer `"closed"`; a network failure is the
bundled `http`'s `net.NetError` (kind `"net"`), passed on unchanged; a
cancelled task stays `"cancelled"`. A `c`
argument is a `Client`, a `req` a Messages request, a `reply` what `chat`
returned.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `VERSION` | `"0.1.0"` | this deck's version |
| `DEFAULT_BASE_URL` | `"https://api.anthropic.com"` | where the API is served |
| `API_VERSION` | `"2026-10-21"` | the `anthropic-version` a fresh client sends |
| `DEFAULT_MODEL` | `"claude-opus-5-5"` | the model the docs and examples use |
| `DEFAULT_TIMEOUT_MS` | `600000` | how long one attempt may take (10 minutes) |
| `DEFAULT_RETRIES` | `2` | retries of a 408, 409, 429, 5xx or a failed connection |
| `MAX_RETRY_WAIT_MS` | `60000` | the longest `retry-after-ms` / `retry-after` waited for |
| `DEFAULT_MAX_BYTES` | `67108864` | the largest reply read (64 MiB) |
| `DEFAULT_MAX_TOOL_INPUT` | `1048576` | the largest tool input (its JSON) the tool loop hands to a handler (1 MiB) |
| `DEFAULT_MAX_TOKENS` | `16000` | a `max_tokens` that suits a reply that is not streamed |
| `BETA_FALLBACKS` | `"server-side-fallback-2026-07-01"` | the beta for `withFallbacks` |
| `MAX_BATCH_REQUESTS` | `100000` | the most requests in one batch |

## The client

| Function | Returns | Does |
|---|---|---|
| `client(apiKey)` | `Client` | a client for the Claude API with an API key |
| `withBaseUrl(c, baseUrl)` | `Client` | another API root: a gateway, a proxy, a fake |
| `withPlainHttp(c)` | `Client` | allow plain http to another machine (the key crosses in clear) |
| `withTls(c, tls)` | `Client` | certificate options (`caCert`, `skipVerify`) |
| `withApiVersion(c, version)` | `Client` | another `anthropic-version`, such as `2023-06-01` |
| `withBetas(c, betas)` | `Client` | the `anthropic-beta` names sent with every request |
| `withTimeout(c, ms)` | `Client` | the deadline of one attempt, 1000 to 86400000 ms |
| `withRetries(c, retries)` | `Client` | how often a retryable failure is retried, 0 to 10 |
| `withMaxBytes(c, most)` | `Client` | the largest reply, 65536 to 1073741824 bytes |
| `withMaxToolInput(c, most)` | `Client` | the largest tool input the loop hands to a handler, 1024 to 1073741824 bytes |
| `call(c, method, path, body)` | `json.Value` | any other endpoint; `body` JSON `null` for none |
| `models(c)` | `list of json.Value` | every model the key may use, newest first |
| `model(c, id)` | `json.Value` | one model: context window, output cap, capabilities |

### `Client`

| Field | Meaning |
|---|---|
| `apiKey as string` | the API key, sent as `x-api-key` |
| `baseUrl as string` | the API root without a trailing slash |
| `version as string` | the `anthropic-version` sent |
| `betas as list of string` | the `anthropic-beta` names sent |
| `tls as http.TlsOptions` | certificate checks for `https` |
| `allowPlainHttp as bool` | whether plain `http` to another machine is allowed |
| `timeoutMs as int` | how long one attempt may take |
| `retries as int` | how often a retryable failure is retried |
| `backoffMs as int` | the first wait before a retry without `retry-after`, doubled each time |
| `maxBytes as int` | the largest reply read |
| `maxToolInput as int` | the largest tool input, in bytes of its JSON, the tool loop hands to a handler |

### `AnthropicError`

| Field | Meaning |
|---|---|
| `kind as string` | always `"anthropic"` |
| `message as string` | `anthropic: <request>: <why> (HTTP <status> <type>, request <id>)` |
| `status as int` | the HTTP status; 0 when no reply was read |
| `type as string` | Anthropic's `error.type`, such as `rate_limit_error`; `""` without one |
| `requestId as string` | the `request-id` header or the body's `request_id` |
| `retryAfterMs as int` | the wait the server asked for (`retry-after-ms`, `retry-after` seconds or HTTP date), at most 1e12; 0 when it named none |
| `limits as map of string to string` | its rate-limit headers, lower-cased, at most 32: `anthropic-ratelimit-*`, `x-ratelimit-*`, `retry-after`, `retry-after-ms` |

## Messages

| Function | Returns | Does |
|---|---|---|
| `newRequest(model)` | `json.Value` | a new request `{"model", "max_tokens": 16000, "messages": []}` |
| `withMaxTokens(req, n)` | `json.Value` | another `max_tokens`, 0 to 300000 |
| `withSystem(req, text)` | `json.Value` | the system prompt as text |
| `withSystemBlocks(req, blocks)` | `json.Value` | the system prompt as text blocks (for `cache_control`) |
| `addUserText(req, text)` | `json.Value` | a user turn of text appended |
| `addUser(req, blocks)` | `json.Value` | a user turn of content blocks appended |
| `addAssistant(req, content)` | `json.Value` | an assistant turn appended (a string or blocks) |
| `addReply(req, reply)` | `json.Value` | a reply's whole content appended unchanged, thinking included |
| `textBlock(text)` | `json.Value` | a `text` block |
| `imageBlock(mediaType, data)` | `json.Value` | a base64 `image` block: jpeg, png, gif or webp |
| `pdfBlock(data)` | `json.Value` | a base64 PDF `document` block |
| `withCacheControl(v, ttl)` | `json.Value` | a cache breakpoint on a block or tool, or automatic caching on a request; ttl `""`, `5m` or `1h` |
| `withThinking(req, display)` | `json.Value` | adaptive thinking; display `""`, `summarized`, `omitted` or `updates` |
| `withEffort(req, effort)` | `json.Value` | `output_config.effort`: `low` to `max` |
| `withFormat(req, schema)` | `json.Value` | structured output: `output_config.format` with a JSON Schema |
| `withFallbacks(req)` | `json.Value` | server-side refusal fallbacks (needs `BETA_FALLBACKS`) |
| `chat(c, req)` | `json.Value` | send the request, return the reply |
| `countTokens(c, req)` | `int` | the input tokens the request would take |
| `text(reply)` | `string` | the reply's text blocks joined |
| `toolCalls(reply)` | `list of ToolCall` | the reply's `tool_use` blocks |
| `stopReason(reply)` | `string` | `end_turn`, `max_tokens`, `tool_use`, `pause_turn`, `refusal`, `compaction`, ... |
| `refusalCategory(reply)` | `string` | a refusal's category, such as `cyber`; `""` otherwise |
| `usage(reply)` | `Usage` | the reply's token counts |

### `Usage`

| Field | Meaning |
|---|---|
| `inputTokens as int` | every input token: `input_tokens` + cache reads + cache writes |
| `outputTokens as int` | output tokens, thinking included |
| `totalTokens as int` | `inputTokens + outputTokens` (Anthropic sends no total) |
| `cachedTokens as int` | the part of `inputTokens` read from the prompt cache |
| `reasoningTokens as int` | the part of `outputTokens` spent thinking |
| `cacheCreationInputTokens as int` | the part of `inputTokens` written to the prompt cache |

### `ToolCall`

| Field | Meaning |
|---|---|
| `id as string` | the `tool_use` block's id, which its `tool_result` answers |
| `name as string` | the tool's name |
| `input as json.Value` | the input, an object (`{}` when the block has none) |

## Tools

| Function | Returns | Does |
|---|---|---|
| `tool(name, description, schema)` | `json.Value` | a tool definition |
| `withStrict(tool)` | `json.Value` | the tool with `strict: true` |
| `addTool(req, tool)` | `json.Value` | a tool (or server tool) appended to `tools` |
| `addTools(req, tools)` | `json.Value` | several tools appended, in order |
| `toolResult(toolUseId, content, isError)` | `json.Value` | a `tool_result` block |
| `toolText(s)` | `json.Value` | text as a JSON string, for a handler's answer |
| `toolError(message)` | `json.Value` | an error result for a handler's answer; the model can recover |
| `runTools(c, req, handler, maxTurns)` | `ToolRun` | the tool loop, until the model stops for something else |
| `runToolsWith(c, req, handler, context, maxTurns)` | `ToolRun` | the tool loop with a context passed to every handler call |

A `runTools` handler is `func(name as string, input as json.Value)`, a
`runToolsWith` handler `func(name as string, input as json.Value, context
as json.Value)`; both return a `json.Value`. A handler that throws ends
the loop with its error. A tool input over `maxToolInput` is answered with
`{"error": "the input is over N bytes; call the tool again with a smaller
input"}` (`is_error`) without calling the handler.

### `ToolRun`

| Field | Meaning |
|---|---|
| `reply as json.Value` | the last reply |
| `request as json.Value` | the conversation, the last reply and its tool results included |
| `turns as int` | how many requests were sent |
| `calls as int` | how many tool calls the handler ran |
| `usage as Usage` | the token counts of every reply, summed |
| `stopped as string` | `""` when the model finished, `maxTurns` when the loop stopped there |

## Message batches

| Function | Returns | Does |
|---|---|---|
| `batchRequest(customId, params)` | `json.Value` | one request of a batch |
| `createBatch(c, requests)` | `json.Value` | create a batch |
| `batch(c, id)` | `json.Value` | a batch and its `processing_status` |
| `batches(c, limit, afterId)` | `json.Value` | one page of batches, newest first |
| `cancelBatch(c, id)` | `json.Value` | cancel a batch in progress |
| `deleteBatch(c, id)` | `json.Value` | delete an ended batch |
| `waitBatch(c, id, pollMs, timeoutMs)` | `json.Value` | poll until the batch has ended |
| `batchResults(c, id)` | `list of json.Value` | the JSONL results, one per request, in any order |
