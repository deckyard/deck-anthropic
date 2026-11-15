<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Messages

`chat(c, req)` sends one Messages request (`POST /v1/messages`) and returns
the reply. A request is a `json.Value`: build it with `request` and the
`add*` and `with*` functions, or set any field with `json.set`.

```jennifer
def req as json.Value init anthropic.newRequest("claude-opus-5-5");
$req = anthropic.withMaxTokens($req, 4000);
$req = anthropic.withSystem($req, "You are a terse assistant.");
$req = anthropic.addUserText($req, "Explain a B-tree in two sentences.");
$req = json.set($req, "/stop_sequences", json.list(["END"]));
def reply as json.Value init anthropic.chat($c, $req);
```

`newRequest(model)` starts `{"model", "max_tokens", "messages": []}` with
`max_tokens` at `DEFAULT_MAX_TOKENS` (16000), which suits a reply that is
not streamed; `withMaxTokens(req, n)` changes the cap on the reply.
`chat` refuses a request without `model`, `max_tokens` or a `messages`
list, and one with `stream` set.

## The conversation

Turns alternate, starting with the user:

| Function | Appends |
|---|---|
| `addUserText(req, text)` | a user turn of text |
| `addUser(req, blocks)` | a user turn of content blocks |
| `addReply(req, reply)` | the reply's whole `content` as the assistant turn |
| `addAssistant(req, content)` | an assistant turn kept from elsewhere |

Every function returns a new request: a `json.Value` is never changed in
place, so `$req = anthropic.addUserText($req, ...)`.

Current models refuse a request that ends with an assistant turn (no
prefill). To shape the answer, use the system prompt or
[structured outputs](#structured-outputs).

## Content blocks

| Function | Block |
|---|---|
| `textBlock(text)` | `{"type": "text", "text"}` |
| `imageBlock(mediaType, data)` | a base64 image: `image/jpeg`, `image/png`, `image/gif`, `image/webp` |
| `pdfBlock(data)` | a base64 PDF document |
| `toolResult(toolUseId, content, isError)` | the answer to a tool call (see [Tool use](tools.md)) |

Put a document or image before the question about it:

```jennifer
use fs;

$req = anthropic.addUser($req, [
    anthropic.pdfBlock(fs.readBytes("report.pdf")),
    anthropic.textBlock("List the three main findings.")
]);
```

A request may be up to 128 MB; a PDF up to 600 pages.

## Reading a reply

| Function | Returns |
|---|---|
| `text(reply)` | the `text` blocks joined |
| `toolCalls(reply)` | the `tool_use` blocks as `ToolCall{id, name, input}` |
| `stopReason(reply)` | why the model stopped |
| `refusalCategory(reply)` | the category of a refusal |
| `usage(reply)` | a `Usage` with the token counts |

Everything else is in the reply itself: `json.asString($reply, "/model")`,
`json.get($reply, "/content")`, `json.typeOf($reply, "/stop_details")`.

The stop reasons are `end_turn`, `max_tokens` (the reply was cut at
`max_tokens`), `stop_sequence`, `tool_use`, `pause_turn` (a long server-tool
turn paused: send the reply back as it is to go on),
`refusal`, `model_context_window_exceeded`, and with beta compaction
`compaction` (the context was summarised: send the reply back as it is).
Check it before using the text.

## Thinking and effort

Current models think adaptively: they decide when and how much. Thinking is
on even without a `thinking` field; `withThinking` chooses whether its text
comes back. Effort sets how thoroughly the model thinks and works.

```jennifer
$req = anthropic.withThinking($req, "summarized");
$req = anthropic.withEffort($req, "high");
```

| Display | Thinking blocks hold |
|---|---|
| `""` (the model's default: `omitted` on current models) | an empty `thinking` text and a `signature` |
| `summarized` | a readable summary of the reasoning |
| `omitted` | an empty text, explicitly |
| `updates` | short progress notes between tool calls (beta `thinking-display-updates-2026-08-18`) |

Effort is `low`, `medium`, `high`, `xhigh` or `max`, sent as
`output_config.effort`. Claude Opus 5.5 defaults to `medium`, most other
current models to `high`; `xhigh` suits most coding and agent work. Thinking
is billed as output whatever the display; `usage(reply).reasoningTokens`
shows how much.

A thinking budget (`"type": "enabled"` with `budget_tokens`) is refused with
a 400 by Opus 4.7 and later, Sonnet 5 and later, and Fable; Claude Opus 5.5
also refuses `{"type": "disabled"}`. Lower the effort instead.

Thinking blocks (`thinking`, `redacted_thinking`) carry a signature tied to
the conversation. Pass them back exactly as they came, with `addReply`, in
every later request, also after switching models (the API drops, unbilled,
the blocks the new model cannot read); never edit an earlier turn, the
system prompt or the tools in a conversation that has them, or the next
request may be a 400.

## Prompt caching

A cache breakpoint marks the end of a prefix the API keeps for 5 minutes (or
an hour), so a repeated prefix is read at a fraction of the input price.
The prefix runs `tools`, then `system`, then `messages`; put what never
changes first.

```jennifer
$req = anthropic.withSystemBlocks($req, [
    anthropic.withCacheControl(anthropic.textBlock($manual), "1h")
]);
```

`withCacheControl(v, ttl)` works on a content block, a tool definition or
the request itself; on the request it asks the API to place the breakpoint
on the last cacheable block. Up to 4 breakpoints per request; a prefix
shorter than the model's minimum (512 to 4096 tokens) is not cached, without
an error. Check with `usage`:

```jennifer
def u as anthropic.Usage init anthropic.usage($reply);
io.printf("cache: %d read, %d written\n", $u.cachedTokens, $u.cacheCreationInputTokens);
```

`inputTokens` counts every input token, cached or not: Anthropic's
`input_tokens` plus `cachedTokens` (read from the cache) plus
`cacheCreationInputTokens` (written to it). `totalTokens` is `inputTokens +
outputTokens`; thinking is part of `outputTokens` (`reasoningTokens` says
how much). A timestamp or anything else that changes in the
prefix makes every request miss.

## Structured outputs

`withFormat(req, schema)` sets `output_config.format` to a JSON Schema; the
reply's text is then JSON that matches it. Every object in the schema needs
`"additionalProperties": false`.

```jennifer
def schema as json.Value init json.decode('{"type": "object",
    "properties": {"name": {"type": "string"}, "email": {"type": "string"}},
    "required": ["name", "email"], "additionalProperties": false}');
$req = anthropic.withFormat($req, $schema);
def contact as json.Value init json.decode(anthropic.text(anthropic.chat($c, $req)));
```

Check `stopReason` first: a reply cut at `max_tokens`, or a refusal, is not
complete JSON. Structured outputs cannot be combined with citations.

## Token counting

`countTokens(c, req)` asks `POST /v1/messages/count_tokens` how many input
tokens a request would take, without running it. Fields the endpoint does
not take (`max_tokens`, `stop_sequences`, `metadata`, `fallbacks`, ...) are
left out, so the same request can be counted and then sent. Counts are per
model: count with the model you will use.

```jennifer
if (anthropic.countTokens($c, $req) > 900000) {
    io.eprintf("too long for one request\n");
}
```

## Refusals

A safety classifier may decline a request. That is not an error: the reply
is HTTP 200 with `stop_reason` `refusal` and `stop_details` naming a
category (`cyber`, `bio`, `frontier_llm`, `reasoning_extraction`,
`general_harms`, or none).

```jennifer
if (anthropic.stopReason($reply) == "refusal") {
    io.eprintf("declined: %s\n", anthropic.refusalCategory($reply));
}
```

On Claude Opus 5.5 and Fable, server-side fallbacks rerun a declined
request on a fallback model within the same call. They need a beta:

```jennifer
$req = anthropic.withFallbacks($req);
$reply = anthropic.chat(anthropic.withBetas($c, [anthropic.BETA_FALLBACKS]), $req);
```

The reply's `model` names the model that answered; a `fallback` block in its
content marks the switch. Send it back with `addReply` like any other.
Batches do not take fallbacks.
