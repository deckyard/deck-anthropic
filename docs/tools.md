<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Tool use

A tool is a function the model may ask to call. The request declares it with
a name, a description and a JSON Schema for its input; when the model wants
it, the reply stops with `stop_reason` `tool_use` and holds `tool_use`
blocks; the program runs them and answers with `tool_result` blocks in the
next user turn.

## Declaring tools

```jennifer
def schema as json.Value init json.decode('{"type": "object",
    "properties": {"city": {"type": "string", "description": "City name"}},
    "required": ["city"], "additionalProperties": false}');
def weather as json.Value init anthropic.tool("get_weather", "The current weather in a city.", $schema);
$req = anthropic.addTool($req, anthropic.withStrict($weather));
```

`addTools(req, tools)` appends several at once, in order.

`withStrict` sets `strict: true`: the model's input then always matches the
schema, which needs `"additionalProperties": false` and `required` on every
object. The description is what the model reads to decide; say what the tool
does and when to use it.

`tool_choice` is `auto` unless set (`json.set($req, "/tool_choice", ...)`).
Claude Opus 5.5, Sonnet 5.5 and Fable 5.1 and 5.2 refuse a forced tool
(`any` or `tool`) with a 400: keep `auto`, name the tool in the prompt, and
use a strict tool, or [structured outputs](messages.md#structured-outputs)
when the call only existed to get JSON back.

Server tools run on Anthropic's side and are declared the same way, without
a schema:

```jennifer
$req = anthropic.addTool($req, json.decode('{"type": "web_search_20260209", "name": "web_search"}'));
```

Their results come back as blocks in the same reply; nothing for the
program to run.

## The tool loop

`runTools(c, req, handler, maxTurns)` and
`runToolsWith(c, req, handler, context, maxTurns)` do the whole exchange:

1. send the request;
2. append the reply unchanged (`addReply`): text, thinking and tool blocks;
3. if it stopped for `tool_use`, run every `tool_use` block through the
   handler and append one user turn with all the results; if it stopped for
   `pause_turn`, or for `compaction` (beta compaction with
   `pause_after_compaction`), append nothing; each such turn counts against
   `maxTurns`;
4. repeat, until the model stops for anything else (`end_turn`,
   `max_tokens`, `refusal`, ...) or `maxTurns` requests were sent.

A tool input whose JSON is over the client's `maxToolInput` (1 MiB;
`withMaxToolInput`) is answered with an error result,
`{"error": "the input is over N bytes; call the tool again with a smaller
input"}`, and the handler is not called (nor counted in `calls`).

It returns a `ToolRun`: the last `reply`, the whole conversation as
`request` (ready for another `addUserText`), the number of `turns`
(requests sent), the number of tool `calls` the handler ran, and the
`usage` of every reply summed, and why it `stopped`: `""` when the model
finished, `maxTurns` when the loop stopped after `maxTurns` requests while
the model still wanted tools (their calls are run and answered) or a paused
turn to go on. Nothing is lost then: `runTools($c, $run.request, ...)`
carries on. Check `stopReason($run.reply)` before
going on: after `max_tokens` the last reply may hold a `tool_use` cut short
and no result for it, after `refusal` its content may be empty; the API
may refuse another user turn after either as it is.

```jennifer
def run as anthropic.ToolRun init anthropic.runTools($c, $req, runTool, 10);
io.printf("%s\n", anthropic.text($run.reply));
if ($run.stopped == "maxTurns") {
    $run = anthropic.runTools($c, $run.request, runTool, 10);
}
$req = anthropic.addUserText($run.request, "And tomorrow?");
```

### The handler

The handler is a top-level function with this signature, passed by name:

```jennifer
func runTool(name as string, input as json.Value) {
    if ($name == "get_weather") {
        return anthropic.toolText(lookUp(json.asString($input, "/city")));
    }
    return anthropic.toolError("no tool " + $name);
}
```

`input` is the tool's input object. The handler returns a `json.Value`:

| Returned | Sent as |
|---|---|
| a JSON string (`toolText`) | the result text |
| `toolError(message)` | an error result (`is_error`): the model sees the message and can try something else |
| anything else (an object, a list, a number) | its JSON |

A handler that throws ends the loop: the error reaches the caller of
`runTools` unchanged, and nothing more is sent. Return `toolError` for a
failure the model should hear about; throw for one the program must
handle. Every tool call of one reply is answered in one user turn, in
order.

### Context without closures

Jennifer has no closures, so a handler cannot capture local state. Two ways
to give it some:

`runToolsWith` passes one `json.Value` to every call, as the handler's
third argument:

```jennifer
func runTool(name as string, input as json.Value, context as json.Value) {
    def city as string init json.asString($input, "/city");
    if (not json.has($context, "/" + $city)) {
        return anthropic.toolError("no city " + $city);
    }
    return json.get($context, "/" + $city);
}

def known as json.Value init json.decode('{"Paris": "18 C", "Oslo": "4 C"}');
def run as anthropic.ToolRun init anthropic.runToolsWith($c, $req, runTool, $known, 10);
```

The context is read-only: the handler gets the same value every time. For
state the handler changes, a handler in the program reads and updates the
script's top-level variables:

```jennifer
def stock as map of string to int init {"bolts": 1200, "nuts": 80};
def calls as int init 0;

func runTool(name as string, input as json.Value) {
    $calls = $calls + 1;
    def item as string init json.asString($input, "/item");
    return json.decode('{"count": ' + convert.toString($stock[$item]) + '}');
}
```

A handler defined in a module cannot do that (a module has no mutable
top-level variables): give it constants, or keep the handler in the program
and pass it what it needs through the variables the program owns. For state
that must cross tasks, use a `kv` store.

### Thinking in the loop

With thinking on, a reply that calls tools starts with `thinking` (or
`redacted_thinking`) blocks. The API needs them back unchanged in every
later request, in the same position, or it answers with a 400. `runTools`
appends each reply's whole `content` as it came, so the signatures stay
valid; a loop written by hand must do the same with `addReply`. Do not edit
earlier turns, the system prompt or the tools during the loop.

### A loop by hand

`runTools` covers the common case. For approval of each call, or to run
calls in parallel tasks, write the loop yourself:

```jennifer
def reply as json.Value init anthropic.chat($c, $req);
while (anthropic.stopReason($reply) == "tool_use") {
    $req = anthropic.addReply($req, $reply);
    def results as list of json.Value init [];
    for (def call in anthropic.toolCalls($reply)) {
        $results[] = anthropic.toolResult($call.id, approveAndRun($call.name, $call.input), false);
    }
    $req = anthropic.addUser($req, $results);
    $reply = anthropic.chat($c, $req);
}
```

Answer every `tool_use` block, failed ones with `isError` true; leaving one
out is a 400.
