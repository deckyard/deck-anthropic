<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/anthropic

A client for Anthropic™'s Claude™ Messages API, written in Jennifer over
plain HTTPS: there is no Anthropic SDK for Jennifer. It sends messages with
text, image and PDF content, runs tool loops, sets adaptive thinking and
effort, places prompt-cache breakpoints, asks for structured output, counts
tokens, lists models, and runs Message Batches. `call` reaches any other
endpoint.

Requests and replies are `json.Value` documents in the API's own shape, as
the [API reference](https://platform.claude.com/docs/en/api/messages/create)
describes them. The builders (`newRequest`, `addUserText`, `withThinking`, ...)
and readers (`text`, `toolCalls`, `usage`, ...) cover the common fields;
anything else is one `json.set` or `json.get` away, so a field the API adds
later needs no new release.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/anthropic/" as anthropic;
```

The trailing slash resolves to the entry module.

## A first request

```jennifer
use io;
use json;
use os;

import "@deckyard/anthropic/" as anthropic;

def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
$req = anthropic.addUserText($req, "Name the four largest moons of Jupiter.");
def reply as json.Value init anthropic.chat($c, $req);
io.printf("%s\n", anthropic.text($reply));
```

To go on with the conversation, append the reply and the next question:

```jennifer
$req = anthropic.addReply($req, $reply);
$req = anthropic.addUserText($req, "Which one is the largest?");
$reply = anthropic.chat($c, $req);
```

`addReply` appends the reply's whole `content` unchanged. Thinking blocks
must go back exactly as they came, so never rebuild a reply from its text.

## The client

`client(apiKey)` takes a key from the
[Console](https://platform.claude.com); read it from the environment, never
from source. Every request carries it as `x-api-key`, with
`anthropic-version: 2026-10-21` (`API_VERSION`). The key never appears in an
error message or a URL, but `Client` holds it: do not print a client.

| Setting | Default | Change with |
|---|---|---|
| API root | `https://api.anthropic.com` | `withBaseUrl` (a gateway or proxy), `withTls` for its CA |
| API version | `2026-10-21` | `withApiVersion` |
| beta features | none | `withBetas` |
| deadline of one attempt | 10 minutes | `withTimeout` |
| retries | 2 | `withRetries` |
| largest reply | 64 MiB | `withMaxBytes` |
| largest tool input the loop hands to a handler | 1 MiB | `withMaxToolInput` |

The client is a value: `withBetas($c, [...])` passed to one call changes
that call only.

**Deadlines.** A reply is not streamed: it arrives when the model has
finished. A long generation (a high `max_tokens`, high effort) can take
minutes, so one attempt may take 10 minutes by default, the limit the
official SDKs use. Raise it with `withTimeout`, lower `max_tokens`, or send
long work as a [batch](batches.md).

**Retries.** A 408, 409, 429 or 5xx reply (529 is "overloaded") is retried
twice, and so is a transport failure that left the request unsent: a
`net.NetError` (kind `"net"`) whose `sent` is false, such as a refused
connection, a failed lookup or TLS handshake, or a reset before the whole
request was written. Once the request was sent, a reset or a close (with
or without part of the answer, `replied`) is never retried, whatever the
method, since the request may have run (no duplicate batches or charges):
the `NetError` is passed on unchanged, and a body cut short is kind
`"closed"`. A malformed answer is kind `"anthropic"`. A `retry-after-ms`
header sets the wait, else `retry-after` in seconds or as an HTTP date, up
to a minute (`MAX_RETRY_WAIT_MS`); a longer one is not waited for and the
error is thrown at once, with the wait in `retryAfterMs`. Without one the
wait starts at half a second and doubles. A
deadline that passed is not retried, so a request takes at most
`(retries + 1) x timeout` plus the waits.

**Plain http** goes only to this machine (a local gateway, a test fake)
unless `withPlainHttp` allows it: the key would cross the network in clear.

**API versions.** On `2026-10-21` a Messages request with `temperature`,
`top_p` or `top_k` is a 400 on every model, as is a `document` block in an
assistant turn or a user `text` block with `citations`. Code that still
needs sampling parameters can stay on `withApiVersion($c, "2023-06-01")`.

## Models

`DEFAULT_MODEL` is `claude-opus-5-5`, the model Anthropic's docs default to.
Use model ids exactly as listed, never with a date suffix. `models(c)` lists
the models the key may use, `model(c, id)` reads one: its context window
(`max_input_tokens`), output cap (`max_tokens`) and `capabilities`, which say
whether it takes adaptive thinking, which effort levels, structured outputs,
images and PDFs.

```jennifer
for (def m in anthropic.models($c)) {
    io.printf("%s  %s\n", json.asString($m, "/id"), json.asString($m, "/display_name"));
}
def opus as json.Value init anthropic.model($c, "claude-opus-5-5");
if (json.asBool($opus, "/capabilities/effort/xhigh/supported")) {
    $req = anthropic.withEffort($req, "xhigh");
}
```

Current models differ from what older code assumes:

- thinking is adaptive (`withThinking`); a thinking budget (`budget_tokens`)
  is a 400, and Claude Opus 5.5 cannot turn thinking off: lower the effort
  instead;
- a request that ends with an assistant turn (prefill) is a 400;
- a forced tool (`tool_choice` `any` or `tool`) is a 400 on Claude Opus 5.5,
  Sonnet 5.5 and Fable 5.1 and 5.2: use `auto` with a strict tool
  (`withStrict`), or structured output (`withFormat`).

## Errors

| Kind | Struct | When |
|---|---|---|
| `"anthropic"` | `AnthropicError` | the API refused the request (`status`, `type`, `requestId`, `retryAfterMs`, `limits`); the deck refused to send it (`status` 0); the reply was not what the API sends |
| `"net"` | `net.NetError` | the network failed: `reason` (`refused`, `reset`, `dns`, `tls`, `closed`, ...), `sent`, `replied`; passed on unchanged from `http` |
| `"limit"` | `Error` | a reply over the cap; `models` past 100 pages or its pages together over the cap; a batch over 100000 requests |
| `"timeout"` | `Error` | no reply within the deadline; `waitBatch` past its timeout |
| `"closed"` | `Error` | the server closed the connection after part of its answer |
| `"cancelled"` | `Error` | the task running the request was cancelled |

`AnthropicError.type` is Anthropic's `error.type`: `invalid_request_error`
(400), `authentication_error` (401), `billing_error` (402),
`permission_error` (403), `not_found_error` (404), `request_too_large`
(413), `rate_limit_error` (429), `api_error` (500), `timeout_error` (504),
`overloaded_error` (529). `retryAfterMs` is the wait the server asked for
(0 when none) and `limits` its rate-limit headers (`anthropic-ratelimit-*`,
`retry-after`, ...), lower-cased. Match the kind, then read the fields;
never the message:

```jennifer
try {
    $reply = anthropic.chat($c, $req);
} catch (e) {
    if ($e.kind == "anthropic" and $e.status == 429) {
        io.eprintf("rate limited (request %s), retry in %d ms\n", $e.requestId, $e.retryAfterMs);
    } else {
        io.eprintf("%s\n", $e.message);
    }
}
```

A function that takes a caught error declares it `anthropic.AnthropicError`,
not `Error`. A refusal is not an error: it is a reply with `stop_reason`
`refusal` (see [Messages](messages.md#refusals)).

## Not in this version

- **Streaming** (server-sent events) would need an incremental HTTP body
  reader in the bundled `http` module, which reads a whole body; with it the
  deck would assemble `content_block_delta` events into the same reply
  `chat` returns, and lift the 10-minute default. Until then a long reply
  needs a long deadline or a batch.
- **The Files API** (`/v1/files`) needs a multipart upload, which `http`
  sends only as one body built by hand; a later version adds
  `uploadFile` and a `fileBlock` for `{"type": "file", "file_id"}` sources.
  Reading and deleting files works through `call` today.
- **Managed Agents** (`/v1/agents`, sessions and environments) is a separate
  surface with its own beta and an event stream; it would be a deck of its
  own on top of this client. Its plain REST calls work through `call` with
  `withBetas`.

Server tools (web search, code execution) need nothing new: add them with
`addTool` and read their blocks from the reply.

## Guides

- [Messages](messages.md): requests, content, thinking and effort, prompt
  caching, structured outputs, token counting, refusals.
- [Tool use](tools.md): tool definitions and the tool loop.
- [Message batches](batches.md): asynchronous batches at half the price.
- [Cheatsheet](cheatsheet.md): every export.

## Trademarks

Anthropic™ and Claude™ are trademarks of Anthropic, PBC. Other product and
company names may be trademarks of their respective owners. They are used
only to identify the products this deck works with. This deck is an
independent project, not affiliated with, sponsored or endorsed by
Anthropic, PBC.
