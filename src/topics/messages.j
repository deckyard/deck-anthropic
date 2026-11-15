# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# anthropic - messages: building a Messages request and its content blocks,
# `chat`, `countTokens`, and reading a reply. Spliced into anthropic.j via
# include.

/** A `max_tokens` that suits a reply that is not streamed. */
export def const DEFAULT_MAX_TOKENS as int init 16000;

/**
 * The beta that turns on server-side refusal fallbacks (`withFallbacks`);
 * send it with `withBetas`.
 */
export def const BETA_FALLBACKS as string init "server-side-fallback-2026-07-01";

# a model id: lower-case words and digits joined by - . : @ (gateways add prefixes)
def const MODEL_FORM as string init '^[a-z0-9][a-z0-9.:@/-]{0,127}$';

# the Messages fields `count_tokens` does not take (its reference, read
# 2026-11-15, lists model, messages, system, tools, tool_choice, thinking,
# output_config, cache_control, speed, and in beta compaction,
# context_management, mcp_servers, output_format); the sampling parameters
# are still sent by code on `2023-06-01`
def const NOT_COUNTED as list of string init [
    "max_tokens",
    "stop_sequences",
    "metadata",
    "stream",
    "service_tier",
    "inference_geo",
    "fallbacks",
    "fallback_credit_token",
    "diagnostics",
    "container",
    "thread",
    "temperature",
    "top_p",
    "top_k"
];

/**
 * Token counts of a reply, from its `usage`. The first five fields are the
 * ones every AI deck's `Usage` has. Anthropic reports no total and counts
 * thinking inside `output_tokens`, so `totalTokens` is `inputTokens +
 * outputTokens`.
 *
 * @field inputTokens {int} every input token: `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
 * @field outputTokens {int} output tokens, thinking included (`output_tokens`)
 * @field totalTokens {int} `inputTokens + outputTokens`
 * @field cachedTokens {int} the part of `inputTokens` read from the prompt cache (`cache_read_input_tokens`)
 * @field reasoningTokens {int} the part of `outputTokens` spent thinking (`output_tokens_details.thinking_tokens`)
 * @field cacheCreationInputTokens {int} the part of `inputTokens` written to the prompt cache (`cache_creation_input_tokens`)
 */
export def struct Usage {
    inputTokens as int,
    outputTokens as int,
    totalTokens as int,
    cachedTokens as int,
    reasoningTokens as int,
    cacheCreationInputTokens as int
};

/**
 * A tool call of a reply: one `tool_use` block.
 *
 * @field id {string} the block's `id`, which its `tool_result` answers
 * @field name {string} the tool's name
 * @field input {json.Value} the input the model chose, an object (`{}` when the block has none)
 */
export def struct ToolCall {
    id as string,
    name as string,
    input as json.Value
};

/**
 * Refuse a document that is not a JSON map.
 *
 * @param v {json.Value} the document
 * @param what {string} what it is, for the message
 */
func checkMap(v as json.Value, what as string) {
    if (json.typeOf($v) != "map") {
        fail($what + " is a JSON object, got a " + json.typeOf($v));
    }
}

/**
 * Refuse a request `chat` would not send: no model, `max_tokens` or
 * `messages`, or `stream` set.
 *
 * @param req {json.Value} the request
 * @param what {string} the call, for messages
 */
func checkRequest(req as json.Value, what as string) {
    checkMap($req, $what + ": the request");
    if (json.typeOf($req, "/model") != "string") {
        fail($what + ": the request has no model");
    }
    if (json.typeOf($req, "/messages") != "list") {
        fail($what + ": the request has no messages list");
    }
    if (json.typeOf($req, "/stream") == "bool" and json.asBool($req, "/stream")) {
        fail($what + ": streaming is not supported; leave stream unset");
    }
}

/**
 * The document with a map at `ptr`, created when it is missing.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer to the map, one level below the root
 * @return {json.Value} the document
 */
func withMapAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t != "map") {
        if ($t != "missing" and $t != "null") {
            fail(shown($ptr) + " is a " + $t + ", not an object");
        }
        return json.set($v, $ptr, json.map());
    }
    return $v;
}

/**
 * A new Messages request: `{"model", "max_tokens", "messages": []}`, with
 * `max_tokens` at `DEFAULT_MAX_TOKENS` (16000, suited to a reply that is
 * not streamed; change it with `withMaxTokens`). Add turns with
 * `addUserText`, `addUser`, `addAssistant` and `addReply`, and settings
 * with the `with*` builders or `json.set`.
 *
 * @param model {string} the model id, such as `DEFAULT_MODEL`
 * @return {json.Value} the request
 * @throws {AnthropicError} kind "anthropic" when the model id is malformed
 * @example
 *   def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
 */
export func newRequest(model as string) {
    if (not regex.matches(MODEL_FORM, $model)) {
        fail("a model id is lower-case letters, digits and -.:@/, got " + shown($model));
    }
    def v as json.Value init json.set(json.map(), "/model", $model);
    $v = json.set($v, "/max_tokens", DEFAULT_MAX_TOKENS);
    return json.set($v, "/messages", json.list());
}

/**
 * The request with another `max_tokens`: the most tokens the reply may
 * have. 0 only fills the prompt cache.
 *
 * @param req {json.Value} the request
 * @param n {int} 0 to 300000 (above 128000 only for batches with the `output-300k-2026-03-24` beta)
 * @return {json.Value} the request
 * @throws {AnthropicError} kind "anthropic" when `n` is out of range
 * @example
 *   $req = anthropic.withMaxTokens($req, 1024);
 */
export func withMaxTokens(req as json.Value, n as int) {
    checkMap($req, "the request");
    checkRange($n, 0, 300000, "max_tokens");
    return json.set($req, "/max_tokens", $n);
}

/**
 * The request with a system prompt as plain text.
 *
 * @param req {json.Value} the request
 * @param text {string} the system prompt
 * @return {json.Value} the request
 */
export func withSystem(req as json.Value, text as string) {
    checkMap($req, "the request");
    return json.set($req, "/system", $text);
}

/**
 * The request with a system prompt as text blocks, so that the last one
 * can carry `cache_control` (`withCacheControl`).
 *
 * @param req {json.Value} the request
 * @param blocks {list of json.Value} text blocks, such as `textBlock(...)`
 * @return {json.Value} the request
 * @example
 *   $req = anthropic.withSystemBlocks($req, [anthropic.withCacheControl(anthropic.textBlock($manual), "")]);
 */
export func withSystemBlocks(req as json.Value, blocks as list of json.Value) {
    checkMap($req, "the request");
    return json.set($req, "/system", json.list($blocks));
}

/**
 * Append a turn.
 *
 * @param req {json.Value} the request
 * @param turn {json.Value} the turn: `role` and `content`, a string or a list of blocks
 * @return {json.Value} the request
 */
func addTurn(req as json.Value, turn as json.Value) {
    checkMap($req, "the request");
    if (json.typeOf($req, "/messages") != "list") {
        fail("the request has no messages list");
    }
    def t as string init json.typeOf($turn, "/content");
    if ($t != "string" and $t != "list") {
        fail("a turn's content is a string or a list of blocks, got a " + $t);
    }
    return json.append($req, "/messages", $turn);
}

/**
 * A turn: `{"role", "content"}`.
 *
 * @param role {string} `user` or `assistant`
 * @param content {json.Value} a list of blocks
 * @return {json.Value} the turn
 */
func turnOf(role as string, content as json.Value) {
    return json.set(json.set(json.map(), "/role", $role), "/content", $content);
}

/**
 * The request with a user turn of plain text appended.
 *
 * @param req {json.Value} the request
 * @param text {string} what the user says
 * @return {json.Value} the request
 * @example
 *   $req = anthropic.addUserText($req, "Summarise this in one line.");
 */
export func addUserText(req as json.Value, text as string) {
    return addTurn($req, json.set(json.set(json.map(), "/role", "user"), "/content", $text));
}

/**
 * The request with a user turn of content blocks appended: text, images,
 * PDFs, tool results.
 *
 * @param req {json.Value} the request
 * @param blocks {list of json.Value} the blocks, such as `imageBlock(...)` and `textBlock(...)`
 * @return {json.Value} the request
 * @example
 *   $req = anthropic.addUser($req, [anthropic.pdfBlock($pdf), anthropic.textBlock("Summarise it.")]);
 */
export func addUser(req as json.Value, blocks as list of json.Value) {
    return addTurn($req, turnOf("user", json.list($blocks)));
}

/**
 * The request with an assistant turn appended, such as one kept from an
 * earlier conversation. Current models refuse a request that ends with
 * one (no prefill): add a user turn after it.
 *
 * @param req {json.Value} the request
 * @param content {json.Value} a string or a list of blocks, exactly as the API returned them
 * @return {json.Value} the request
 */
export func addAssistant(req as json.Value, content as json.Value) {
    return addTurn($req, turnOf("assistant", $content));
}

/**
 * The request with a reply's whole `content` appended as the assistant
 * turn, unchanged: thinking, tool use and fallback blocks are passed back
 * as the API requires.
 *
 * @param req {json.Value} the request
 * @param reply {json.Value} the reply `chat` returned
 * @return {json.Value} the request
 * @throws {AnthropicError} kind "anthropic" when the reply has no content list
 * @example
 *   def reply as json.Value init anthropic.chat($c, $req);
 *   $req = anthropic.addUserText(anthropic.addReply($req, $reply), "And the next one?");
 */
export func addReply(req as json.Value, reply as json.Value) {
    if (json.typeOf($reply, "/content") != "list") {
        fail("the reply has no content list");
    }
    return addTurn($req, turnOf("assistant", json.get($reply, "/content")));
}

/**
 * A text content block.
 *
 * @param text {string} the text
 * @return {json.Value} `{"type": "text", "text": ...}`
 */
export func textBlock(text as string) {
    def m as map of string to string init {"type": "text", "text": $text};
    return json.map($m);
}

/**
 * A base64 block of some type.
 *
 * @param type {string} `image` or `document`
 * @param mediaType {string} the media type
 * @param data {bytes} the bytes
 * @return {json.Value} the block
 */
func base64Block(type as string, mediaType as string, data as bytes) {
    if (len($data) == 0) {
        fail("a " + $type + " block needs data");
    }
    def source as map of string to string init {
        "type": "base64",
        "media_type": $mediaType,
        "data": encoding.toText("base64", $data)
    };
    return json.set(json.set(json.map(), "/type", $type), "/source", json.map($source));
}

/**
 * An image content block, base64 inline.
 *
 * @param mediaType {string} `image/jpeg`, `image/png`, `image/gif` or `image/webp`
 * @param data {bytes} the image
 * @return {json.Value} `{"type": "image", "source": {"type": "base64", "media_type", "data"}}`
 * @throws {AnthropicError} kind "anthropic" for another media type or no data
 * @example
 *   def img as json.Value init anthropic.imageBlock("image/png", fs.readBytes("chart.png"));
 */
export func imageBlock(mediaType as string, data as bytes) {
    if (not lists.contains(["image/jpeg", "image/png", "image/gif", "image/webp"], $mediaType)) {
        fail("an image is image/jpeg, image/png, image/gif or image/webp, got " + shown($mediaType));
    }
    return base64Block("image", $mediaType, $data);
}

/**
 * A PDF document content block, base64 inline. Put it before the text
 * that asks about it, in a user turn.
 *
 * @param data {bytes} the PDF
 * @return {json.Value} `{"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data"}}`
 * @throws {AnthropicError} kind "anthropic" when the data does not start with `%PDF-`
 */
export func pdfBlock(data as bytes) {
    if (len($data) < 5 or convert.stringFromBytes("utf-8", $data[..5]) != "%PDF-") {
        fail("a PDF starts with %PDF-");
    }
    return base64Block("document", "application/pdf", $data);
}

/**
 * A block, tool or request with `cache_control` set: a prompt-cache
 * breakpoint after this block (or tool), or, on the request itself,
 * automatic caching of the last cacheable block. Up to 4 per request.
 *
 * @param v {json.Value} a content block, a tool definition or the request
 * @param ttl {string} `""` for the default 5 minutes, `5m` or `1h`
 * @return {json.Value} the same with `"cache_control": {"type": "ephemeral"[, "ttl"]}`
 * @throws {AnthropicError} kind "anthropic" for another TTL or a value that is not an object
 */
export func withCacheControl(v as json.Value, ttl as string) {
    checkMap($v, "what carries cache_control");
    def cc as map of string to string init {"type": "ephemeral"};
    if ($ttl != "") {
        if ($ttl != "5m" and $ttl != "1h") {
            fail("a cache TTL is 5m or 1h, got " + shown($ttl));
        }
        $cc["ttl"] = $ttl;
    }
    return json.set($v, "/cache_control", json.map($cc));
}

/**
 * The request with adaptive thinking: the model decides when and how much
 * to think. Current models think when `thinking` is left out too; set it
 * to choose the display. Depth is `withEffort`.
 *
 * @param req {json.Value} the request
 * @param display {string} `""` to leave it to the model (`omitted` on current models: the thinking text is empty), `summarized`, `omitted`, or `updates` (progress notes between tool calls; beta `thinking-display-updates-2026-08-18`)
 * @return {json.Value} the request with `"thinking": {"type": "adaptive"[, "display"]}`
 * @throws {AnthropicError} kind "anthropic" for another display
 */
export func withThinking(req as json.Value, display as string) {
    checkMap($req, "the request");
    def t as map of string to string init {"type": "adaptive"};
    if ($display != "") {
        if (not lists.contains(["summarized", "omitted", "updates"], $display)) {
            fail("a thinking display is summarized, omitted or updates, got " + shown($display));
        }
        $t["display"] = $display;
    }
    return json.set($req, "/thinking", json.map($t));
}

/**
 * The request with an effort level, `output_config.effort`: how
 * thoroughly the model thinks and works. Claude Opus 5.5 defaults to
 * `medium`, most other current models to `high`.
 *
 * @param req {json.Value} the request
 * @param effort {string} `low`, `medium`, `high`, `xhigh` or `max`
 * @return {json.Value} the request
 * @throws {AnthropicError} kind "anthropic" for another level
 */
export func withEffort(req as json.Value, effort as string) {
    checkMap($req, "the request");
    if (not lists.contains(["low", "medium", "high", "xhigh", "max"], $effort)) {
        fail("an effort is low, medium, high, xhigh or max, got " + shown($effort));
    }
    return json.set(withMapAt($req, "/output_config"), "/output_config/effort", $effort);
}

/**
 * The request asking for a reply that is JSON matching a schema
 * (structured outputs, `output_config.format`). The JSON arrives as the
 * reply's text: `json.decode(text(reply))`.
 *
 * @param req {json.Value} the request
 * @param schema {json.Value} a JSON Schema object; every object in it needs `"additionalProperties": false`
 * @return {json.Value} the request with `"output_config": {"format": {"type": "json_schema", "schema"}}`
 * @throws {AnthropicError} kind "anthropic" when the schema is not an object
 */
export func withFormat(req as json.Value, schema as json.Value) {
    checkMap($req, "the request");
    checkMap($schema, "a schema");
    def f as json.Value init json.set(
        json.set(json.map(), "/type", "json_schema"),
        "/schema",
        $schema);
    return json.set(withMapAt($req, "/output_config"), "/output_config/format", $f);
}

/**
 * The request with server-side refusal fallbacks (`"fallbacks": "default"`):
 * when a model declines, the API reruns the request on a fallback model
 * chosen by the refusal's category, in the same call. Needs the
 * `BETA_FALLBACKS` beta (`withBetas`); not for batches.
 *
 * @param req {json.Value} the request
 * @return {json.Value} the request
 */
export func withFallbacks(req as json.Value) {
    checkMap($req, "the request");
    return json.set($req, "/fallbacks", "default");
}

/**
 * Send a Messages request and return the reply: `POST /v1/messages`. The
 * reply is not streamed; for a long generation raise the timeout
 * (`withTimeout`) or use a batch.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, from `newRequest` or written by hand
 * @return {json.Value} the reply: `id`, `model`, `content` (blocks), `stop_reason`, `stop_details`, `usage`, ...
 * @throws {AnthropicError} kind "anthropic" when the request is malformed, the status is not 2xx (after the retries), or the reply is not a message
 * @throws {Error} kind "limit" for a reply over the cap, "timeout" for a deadline that passed, "closed" for a connection the server closed
 * @example
 *   def reply as json.Value init anthropic.chat($c, $req);
 *   io.printf("%s\n", anthropic.text($reply));
 */
export func chat(c as Client, req as json.Value) {
    checkRequest($req, "messages");
    if (json.typeOf($req, "/max_tokens") != "int") {
        fail("messages: the request has no max_tokens");
    }
    def v as json.Value init api($c, "POST", "/v1/messages", json.encode($req), "messages");
    if (json.typeOf($v, "/type") != "string" or json.asString($v, "/type") != "message" or
        json.typeOf($v, "/content") != "list") {
        fail("messages: the reply is not a message");
    }
    return $v;
}

/**
 * How many input tokens a request would take, without running it:
 * `POST /v1/messages/count_tokens`. Fields the endpoint does not take
 * (`max_tokens`, `stop_sequences`, `metadata`, `fallbacks`, `thread`, the
 * sampling parameters, ...) are left out, so the same request can be
 * counted and sent.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request
 * @return {int} the input tokens: messages, system prompt and tools
 * @throws {AnthropicError} kind "anthropic" when the request is malformed, the status is not 2xx, or the reply has no count
 * @example
 *   io.printf("%d tokens\n", anthropic.countTokens($c, $req));
 */
export func countTokens(c as Client, req as json.Value) {
    checkRequest($req, "count_tokens");
    def body as json.Value init $req;
    for (def k in NOT_COUNTED) {
        if (json.has($body, "/" + $k)) {
            $body = json.remove($body, "/" + $k);
        }
    }
    def v as json.Value init api(
        $c,
        "POST",
        "/v1/messages/count_tokens",
        json.encode($body),
        "count_tokens");
    if (json.typeOf($v, "/input_tokens") != "int") {
        fail("count_tokens: the reply has no input_tokens");
    }
    return json.asInt($v, "/input_tokens");
}

/**
 * Refuse a reply without a content list.
 *
 * @param reply {json.Value} the reply
 */
func checkReply(reply as json.Value) {
    if (json.typeOf($reply, "/content") != "list") {
        fail("the reply has no content list");
    }
}

/**
 * A content block's type.
 *
 * @param b {json.Value} the block
 * @return {string} its `type`, `""` when it has none
 */
func blockType(b as json.Value) {
    if (json.typeOf($b, "/type") != "string") {
        return "";
    }
    return json.asString($b, "/type");
}

/**
 * The reply's text: its `text` blocks joined. Thinking and tool blocks are
 * left out; a structured-output reply is this text.
 *
 * @param reply {json.Value} the reply
 * @return {string} the text, `""` when there is none
 */
export func text(reply as json.Value) {
    checkReply($reply);
    def content as json.Value init json.get($reply, "/content");
    def parts as list of string init [];
    for (def i in 0..json.length($content)) {
        def b as json.Value init json.get($content, "/" + convert.toString($i));
        if (blockType($b) == "text") {
            $parts[] = textAt($b, "/text");
        }
    }
    return strings.join($parts, "");
}

/**
 * The tool calls in a reply: its `tool_use` blocks, in order. Server tool
 * calls (`server_tool_use`) are not in it: the API runs those.
 *
 * @param reply {json.Value} the reply
 * @return {list of ToolCall} the calls; empty when there are none
 * @throws {AnthropicError} kind "anthropic" when the reply has no content list, or a `tool_use` block has no string `id` and `name` or an `input` that is not an object
 * @example
 *   for (def call in anthropic.toolCalls($reply)) {
 *       io.printf("%s %s %v\n", $call.id, $call.name, $call.input);
 *   }
 */
export func toolCalls(reply as json.Value) {
    checkReply($reply);
    def content as json.Value init json.get($reply, "/content");
    def out as list of ToolCall init [];
    for (def i in 0..json.length($content)) {
        def b as json.Value init json.get($content, "/" + convert.toString($i));
        if (blockType($b) == "tool_use") {
            if (json.typeOf($b, "/id") != "string" or json.typeOf($b, "/name") != "string") {
                fail("a tool_use block has no id or name");
            }
            def input as json.Value init json.map();
            def t as string init json.typeOf($b, "/input");
            if ($t == "map") {
                $input = json.get($b, "/input");
            } elseif ($t != "missing" and $t != "null") {
                fail("a tool_use block's input is a " + $t + ", not an object");
            }
            $out[] = ToolCall{
                id: json.asString($b, "/id"),
                name: json.asString($b, "/name"),
                input: $input
            };
        }
    }
    return $out;
}

/**
 * Why the model stopped.
 *
 * @param reply {json.Value} the reply
 * @return {string} `end_turn`, `max_tokens`, `stop_sequence`, `tool_use`, `pause_turn`, `refusal` or `model_context_window_exceeded`
 */
export func stopReason(reply as json.Value) {
    return textAt($reply, "/stop_reason");
}

/**
 * The policy category of a refusal (`stop_reason` `refusal`), from
 * `stop_details`.
 *
 * @param reply {json.Value} the reply
 * @return {string} such as `cyber`, `bio`, `frontier_llm`, `reasoning_extraction` or `general_harms`; `""` when the reply is not a refusal or names no category
 */
export func refusalCategory(reply as json.Value) {
    if (stopReason($reply) != "refusal") {
        return "";
    }
    return textAt($reply, "/stop_details/category");
}

/**
 * The token counts of a reply.
 *
 * @param reply {json.Value} the reply
 * @return {Usage} the counts, 0 where the reply has none
 * @example
 *   def u as anthropic.Usage init anthropic.usage($reply);
 *   io.printf("%d read from the cache\n", $u.cachedTokens);
 */
export func usage(reply as json.Value) {
    def cached as int init intAt($reply, "/usage/cache_read_input_tokens");
    def written as int init intAt($reply, "/usage/cache_creation_input_tokens");
    def input as int init intAt($reply, "/usage/input_tokens") + $cached + $written;
    def output as int init intAt($reply, "/usage/output_tokens");
    return Usage{
        inputTokens: $input,
        outputTokens: $output,
        totalTokens: $input + $output,
        cachedTokens: $cached,
        reasoningTokens: intAt($reply, "/usage/output_tokens_details/thinking_tokens"),
        cacheCreationInputTokens: $written
    };
}
