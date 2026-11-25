# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0

# anthropic - tools: tool definitions, tool results and the tool loop.
# Spliced into anthropic.j via include.

# a tool name
def const TOOL_NAME as string init '^[a-zA-Z0-9_-]{1,64}$';

# the key of the map `toolError` returns
def const TOOL_ERROR_KEY as string init "anthropic.toolError";

/**
 * The end of a tool loop.
 *
 * @field reply {json.Value} the last reply: one whose `stop_reason` is not `tool_use` or `pause_turn`, or, when `stopped` is `maxTurns`, the last one the loop got
 * @field request {json.Value} the conversation: the request with every turn the loop added, the last reply (and its tool results) included; send it again to go on
 * @field turns {int} how many requests were sent
 * @field calls {int} how many tool calls the handler ran
 * @field usage {Usage} the token counts of every reply, summed
 * @field stopped {string} `""` when the model finished, `maxTurns` when the loop stopped at `maxTurns` requests while the model still wanted tools, or a paused or compacted turn to go on
 */
export def struct ToolRun {
    reply as json.Value,
    request as json.Value,
    turns as int,
    calls as int,
    usage as Usage,
    stopped as string
};

/**
 * A tool definition: a function the model may ask to call.
 *
 * @param name {string} 1 to 64 letters, digits, `_` and `-`
 * @param description {string} what it does and when to use it; the model reads this
 * @param schema {json.Value} a JSON Schema object for the input
 * @return {json.Value} `{"name", "description", "input_schema"}`
 * @throws {AnthropicError} kind "anthropic" for a malformed name or a schema that is not an object
 * @example
 *   def weather as json.Value init anthropic.tool("get_weather", "The current weather in a city.",
 *       json.decode('{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}'));
 */
export func tool(name as string, description as string, schema as json.Value) {
    if (not regex.matches(TOOL_NAME, $name)) {
        fail("a tool name is 1 to 64 letters, digits, _ and -, got " + shown($name));
    }
    checkMap($schema, "an input schema");
    def t as json.Value init json.set(json.map(), "/name", $name);
    $t = json.set($t, "/description", $description);
    return json.set($t, "/input_schema", $schema);
}

/**
 * A tool definition with `strict: true`: the model's input is guaranteed
 * to match the schema, which then needs `"additionalProperties": false`
 * and `required` on every object. With `tool_choice` `auto` it is how
 * current models keep tool input exact, since they refuse a forced tool.
 *
 * @param tool {json.Value} the tool, from `tool`
 * @return {json.Value} the tool
 */
export func withStrict(tool as json.Value) {
    checkMap($tool, "a tool");
    return json.set($tool, "/strict", true);
}

/**
 * The request with a tool appended to `tools`: a definition from `tool`,
 * or a server tool such as `{"type": "web_search_20260209", "name": "web_search"}`.
 *
 * @param req {json.Value} the request
 * @param tool {json.Value} the tool
 * @return {json.Value} the request
 */
export func addTool(req as json.Value, tool as json.Value) {
    checkMap($req, "the request");
    checkMap($tool, "a tool");
    def t as string init json.typeOf($req, "/tools");
    if ($t == "missing" or $t == "null") {
        $req = json.set($req, "/tools", json.list());
    } elseif ($t != "list") {
        fail("the request's tools is a " + $t + ", not a list");
    }
    return json.append($req, "/tools", $tool);
}

/**
 * The request with several tools appended to `tools`, in order.
 *
 * @param req {json.Value} the request
 * @param tools {list of json.Value} the tools
 * @return {json.Value} the request
 * @example
 *   $req = anthropic.addTools($req, [$weather, $clock]);
 */
export func addTools(req as json.Value, tools as list of json.Value) {
    for (def t in $tools) {
        $req = addTool($req, $t);
    }
    return $req;
}

/**
 * A tool result block for a user turn, answering one `tool_use` block.
 *
 * @param toolUseId {string} the `id` of the `tool_use` block
 * @param content {string} the result, as text
 * @param isError {bool} whether the tool failed; the model sees `content` as the error
 * @return {json.Value} `{"type": "tool_result", "tool_use_id", "content"[, "is_error": true]}`
 */
export func toolResult(toolUseId as string, content as string, isError as bool) {
    if (not regex.matches('^[a-zA-Z0-9_-]{1,256}$', $toolUseId)) {
        fail("a tool_use id is letters, digits, _ and -, got " + shown($toolUseId));
    }
    def b as json.Value init json.set(json.map(), "/type", "tool_result");
    $b = json.set($b, "/tool_use_id", $toolUseId);
    $b = json.set($b, "/content", $content);
    if ($isError) {
        $b = json.set($b, "/is_error", true);
    }
    return $b;
}

/**
 * Text as a JSON string value, for a tool handler that answers with text.
 *
 * @param s {string} the text
 * @return {json.Value} the JSON string
 * @example
 *   return anthropic.toolText("18 degrees and sunny");
 */
export func toolText(s as string) {
    return json.get(json.set(json.map(), "/s", $s), "/s");
}

/**
 * An error result for a tool handler to return: the model sees the message
 * as a `tool_result` with `is_error` and can try something else. A handler
 * that throws instead ends the loop.
 *
 * @param message {string} what went wrong, for the model
 * @return {json.Value} a value `runTools` turns into an error result
 * @example
 *   return anthropic.toolError("no city named " + $city);
 */
export func toolError(message as string) {
    return json.set(json.map(), "/" + TOOL_ERROR_KEY, $message);
}

/**
 * The result block for a handler's answer: a `toolError` value as an error
 * result, a JSON string as text, anything else as its JSON.
 *
 * @param id {string} the `tool_use` id
 * @param out {json.Value} what the handler returned
 * @return {json.Value} the `tool_result` block
 */
func resultOf(id as string, out as json.Value) {
    def t as string init json.typeOf($out);
    if ($t == "string") {
        return toolResult($id, json.asString($out), false);
    }
    if ($t == "map" and json.length($out) == 1 and
        json.typeOf($out, "/" + TOOL_ERROR_KEY) == "string") {
        def why as string init json.asString($out, "/" + TOOL_ERROR_KEY);
        if ($why == "") {
            $why = "the tool failed";
        }
        return toolResult($id, $why, true);
    }
    return toolResult($id, json.encode($out), false);
}

/**
 * The sum of two token counts.
 *
 * @param a {Usage} the counts so far
 * @param b {Usage} one more reply's
 * @return {Usage} the sum
 */
func addUsage(a as Usage, b as Usage) {
    return Usage{
        inputTokens: $a.inputTokens + $b.inputTokens,
        outputTokens: $a.outputTokens + $b.outputTokens,
        totalTokens: $a.totalTokens + $b.totalTokens,
        cachedTokens: $a.cachedTokens + $b.cachedTokens,
        reasoningTokens: $a.reasoningTokens + $b.reasoningTokens,
        cacheCreationInputTokens: $a.cacheCreationInputTokens + $b.cacheCreationInputTokens
    };
}

/**
 * The error result for a tool input over the cap, in the words every AI
 * deck uses: `{"error": "the input is over N bytes; ..."}`.
 *
 * @param most {int} the cap
 * @return {string} the result's content
 */
func oversized(most as int) {
    def m as map of string to string init {
        "error": io.sprintf(
            "the input is over %d bytes; call the tool again with a smaller input",
            $most)
    };
    return json.encode(json.map($m));
}

/**
 * The answers to one reply's tool calls.
 *
 * @field results {list of json.Value} the `tool_result` blocks, in the calls' order
 * @field ran {int} how many calls the handler ran
 */
def struct Answers {
    results as list of json.Value,
    ran as int
};

/**
 * Answer every tool call of a reply: through the handler, or with a
 * `toolError` without calling it when the input's JSON is over the
 * client's `maxToolInput`.
 *
 * @param c {Client} the client
 * @param handler {func} the handler
 * @param wanted {list of ToolCall} the calls
 * @param context {json.Value} passed to the handler when `withContext`
 * @param withContext {bool} whether the handler takes the context
 * @return {Answers} the results and how many the handler ran
 */
func answerAll(
    c as Client,
    handler as func,
    wanted as list of ToolCall,
    context as json.Value,
    withContext as bool) {
    def out as Answers init Answers{results: [], ran: 0};
    for (def call in $wanted) {
        def size as int init len(encoding.encode("utf-8", json.encode($call.input)));
        if ($size > $c.maxToolInput) {
            $out.results[] = toolResult($call.id, oversized($c.maxToolInput), true);
        } else {
            $out.results[] = resultOf(
                $call.id,
                runCall($handler, $call.name, $call.input, $context, $withContext));
            $out.ran = $out.ran + 1;
        }
    }
    return $out;
}

/**
 * Run one tool call through the handler.
 *
 * @param handler {func} the handler
 * @param name {string} the tool
 * @param input {json.Value} its input
 * @param context {json.Value} passed to the handler when `withContext`
 * @param withContext {bool} whether the handler takes the context
 * @return {json.Value} what the handler returned
 */
func runCall(
    handler as func,
    name as string,
    input as json.Value,
    context as json.Value,
    withContext as bool) {
    if ($withContext) {
        return $handler($name, $input, $context);
    }
    return $handler($name, $input);
}

/**
 * The tool loop behind `runTools` and `runToolsWith`.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request
 * @param handler {func} the handler
 * @param context {json.Value} passed to the handler when `withContext`
 * @param withContext {bool} whether the handler takes the context
 * @param maxTurns {int} the most requests to send
 * @return {ToolRun} the end of the loop
 */
func loop(
    c as Client,
    req as json.Value,
    handler as func,
    context as json.Value,
    withContext as bool,
    maxTurns as int) {
    checkRange($maxTurns, 1, 1000, "the most turns");
    def total as Usage init Usage{
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cachedTokens: 0,
        reasoningTokens: 0,
        cacheCreationInputTokens: 0
    };
    def calls as int init 0;
    def reply as json.Value;
    for (def turn in 1..$maxTurns + 1) {
        $reply = chat($c, $req);
        $total = addUsage($total, usage($reply));
        $req = addReply($req, $reply);
        def stop as string init stopReason($reply);
        if ($stop == "tool_use") {
            def wanted as list of ToolCall init toolCalls($reply);
            if (len($wanted) == 0) {
                fail("messages: the reply stopped for tool_use without a tool_use block");
            }
            def answers as Answers init answerAll($c, $handler, $wanted, $context, $withContext);
            $calls = $calls + $answers.ran;
            $req = addUser($req, $answers.results);
        } elseif ($stop != "pause_turn" and $stop != "compaction") {
            return ToolRun{
                reply: $reply,
                request: $req,
                turns: $turn,
                calls: $calls,
                usage: $total,
                stopped: ""
            };
        }
    }
    return ToolRun{
        reply: $reply,
        request: $req,
        turns: $maxTurns,
        calls: $calls,
        usage: $total,
        stopped: "maxTurns"
    };
}

/**
 * The tool loop: send the request; while the model stops for `tool_use`,
 * run each tool call through the handler, append the reply unchanged
 * (thinking blocks included, as the API requires) and one user turn with
 * every result, and send again. A `pause_turn` (a long server-tool turn)
 * is sent back as it is, and so is a `compaction` stop (beta compaction
 * with `pause_after_compaction`); each counts against `maxTurns`. The loop
 * ends at any other stop reason
 * (`end_turn`, `max_tokens`, `refusal`, ...: `stopped` is `""`), or after
 * `maxTurns` requests (`stopped` is `maxTurns`; the last reply's tool calls
 * are answered, so `request` can be sent on with another `runTools`).
 * A tool input whose JSON is over the client's `maxToolInput`
 * (`withMaxToolInput`) is answered with an error result without calling
 * the handler: `{"error": "the input is over N bytes; call the tool again
 * with a smaller input"}`.
 *
 * The handler is `func(name as string, input as json.Value)` returning a
 * `json.Value`: a JSON string (`toolText`) is sent as text, a `toolError`
 * as an error result the model can recover from, anything else as its
 * JSON. A handler that throws ends the loop: the error reaches the caller
 * unchanged. For context, use `runToolsWith`, or the script's top-level
 * variables (Jennifer has no closures).
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, with its tools
 * @param handler {func} the function that runs a tool
 * @param maxTurns {int} the most requests to send, 1 to 1000
 * @return {ToolRun} the last reply, the conversation, the turns, the tool calls, the summed usage and why the loop stopped
 * @throws {AnthropicError} kind "anthropic" when a request fails or a reply asks for tools without a tool_use block
 * @throws {Error} whatever the handler throws; kind "limit", "timeout", "closed" or "net" from a request
 * @example
 *   def run as anthropic.ToolRun init anthropic.runTools($c, $req, runTool, 10);
 *   io.printf("%s\n", anthropic.text($run.reply));
 */
export func runTools(c as Client, req as json.Value, handler as func, maxTurns as int) {
    return loop($c, $req, $handler, json.decode("null"), false, $maxTurns);
}

/**
 * The tool loop of `runTools` with a context: the handler is
 * `func(name as string, input as json.Value, context as json.Value)` and
 * gets the same `context` with every call, in place of the closure
 * Jennifer does not have.
 *
 * @param c {Client} the client
 * @param req {json.Value} the request, with its tools
 * @param handler {func} the function that runs a tool, taking the context third
 * @param context {json.Value} what the handler needs, such as a map of settings
 * @param maxTurns {int} the most requests to send, 1 to 1000
 * @return {ToolRun} the last reply, the conversation, the turns, the tool calls, the summed usage and why the loop stopped
 * @throws {AnthropicError} kind "anthropic" when a request fails or a reply asks for tools without a tool_use block
 * @throws {Error} whatever the handler throws; kind "limit", "timeout", "closed" or "net" from a request
 * @example
 *   def ctx as json.Value init json.decode('{"unit": "celsius"}');
 *   def run as anthropic.ToolRun init anthropic.runToolsWith($c, $req, runTool, $ctx, 10);
 */
export func runToolsWith(
    c as Client,
    req as json.Value,
    handler as func,
    context as json.Value,
    maxTurns as int) {
    return loop($c, $req, $handler, $context, true, $maxTurns);
}
