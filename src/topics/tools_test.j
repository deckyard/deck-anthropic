# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0

# anthropic - white-box tests for the tools topic. Spliced into
# anthropic_test.j via include.

# turn 1: thinking, text and two parallel tool calls
def const TURN1 as string init '{"id":"msg_01T1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"","signature":"sig-turn-1"},{"type":"text","text":"Let me check both cities."},{"type":"tool_use","id":"toolu_01Paris","name":"get_weather","input":{"city":"Paris"},"caller":{"type":"direct"}},{"type":"tool_use","id":"toolu_01Oslo","name":"get_weather","input":{"city":"Oslo"},"caller":{"type":"direct"}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":400,"output_tokens":80,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens_details":{"thinking_tokens":40}}}';

# turn 2: a redacted thinking block and a call to a tool that fails
def const TURN2 as string init '{"id":"msg_01T2","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix/LafPsn4aDFIT"},{"type":"tool_use","id":"toolu_01Conv","name":"convert","input":{"celsius":18.5}}],"stop_reason":"tool_use","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":520,"output_tokens":30,"cache_read_input_tokens":400,"cache_creation_input_tokens":0}}';

# turn 3: a long server-tool turn paused
def const TURN3 as string init '{"id":"msg_01T3","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"server_tool_use","id":"srvtoolu_01Search","name":"web_search","input":{"query":"Oslo weather"}}],"stop_reason":"pause_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":10,"output_tokens":5}}';

# turn 4: the answer
def const TURN4 as string init '{"id":"msg_01T4","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"Both known.","signature":"sig-turn-4"},{"type":"text","text":"Paris 18, Oslo 4."}],"stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":600,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}';

# what the test handler knows: context a handler reads instead of a closure
def const WEATHER as map of string to string init {"Paris": "18 C, sunny", "Oslo": "4 C, rain"};

/**
 * The test handler: `get_weather` answers from WEATHER as text,
 * `convert` answers with a `toolError`, `crash` throws, anything else
 * answers with JSON.
 *
 * @param name {string} the tool
 * @param input {json.Value} its input
 * @return {json.Value} the result
 */
func fakeTool(name as string, input as json.Value) {
    if ($name == "get_weather") {
        return toolText(WEATHER[json.asString($input, "/city")]);
    }
    if ($name == "convert") {
        return toolError("convert is offline");
    }
    if ($name == "crash") {
        throw Error{kind: "tool", message: "the tool crashed"};
    }
    return json.decode('{"unknown":true}');
}

/**
 * The weather tool for the tests.
 *
 * @return {json.Value} the tool
 */
func weatherTool() {
    return withStrict(tool(
        "get_weather",
        "The current weather in a city.",
        json.decode('{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}')));
}

func testToolBuilders() {
    testing.assertEqual(
        json.encode(weatherTool()),
        '{"name":"get_weather","description":"The current weather in a city.","input_schema":{"type":"object",' +
            '"properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false},"strict":true}');
    def req as json.Value init addTool(
        withMaxTokens(newRequest(DEFAULT_MODEL), 100),
        weatherTool());
    $req = addTools(
        $req,
        [
            json.decode('{"type":"web_search_20260209","name":"web_search"}'),
            tool("clock", "The time.", json.decode('{"type":"object"}'))
        ]);
    testing.assertEqual(json.length($req, "/tools"), 3);
    testing.assertEqual(json.asString($req, "/tools/2/name"), "clock");
    testing.assertEqual(json.length(addTools($req, []), "/tools"), 3);
    testing.assertEqual(json.encode(toolError("down")), '{"anthropic.toolError":"down"}');
    testing.assertEqual(
        json.encode(resultOf("toolu_01A", toolError("down"))),
        '{"type":"tool_result","tool_use_id":"toolu_01A","content":"down","is_error":true}');
    testing.assertEqual(
        json.encode(resultOf("toolu_01A", toolError(""))),
        '{"type":"tool_result","tool_use_id":"toolu_01A","content":"the tool failed","is_error":true}');
    testing.assertEqual(
        json.encode(resultOf("toolu_01A", json.decode('{"n":1}'))),
        '{"type":"tool_result","tool_use_id":"toolu_01A","content":"{\"n\":1}"}');
    testing.assertEqual(
        json.encode(toolResult("toolu_01A", "18 C", false)),
        '{"type":"tool_result","tool_use_id":"toolu_01A","content":"18 C"}');
    testing.assertEqual(
        json.encode(toolResult("toolu_01A", "down", true)),
        '{"type":"tool_result","tool_use_id":"toolu_01A","content":"down","is_error":true}');
    testing.assertEqual(json.typeOf(toolText("x")), "string");
    try {
        tool("get weather", "x", json.map());
        missed("a name");
    } catch (e) {
        testing.assertContains($e.message, "a tool name is");
    }
    try {
        toolResult("a b", "x", false);
        missed("an id");
    } catch (e) {
        testing.assertContains($e.message, "a tool_use id is");
    }
}

func testToolCalls() {
    def calls as list of ToolCall init toolCalls(json.decode(TURN1));
    testing.assertEqual(len($calls), 2);
    testing.assertEqual($calls[0].id, "toolu_01Paris");
    testing.assertEqual($calls[1].id, "toolu_01Oslo");
    testing.assertEqual($calls[1].name, "get_weather");
    testing.assertEqual(json.asString($calls[1].input, "/city"), "Oslo");
    # server tool calls are the API's; a block without input gets {}
    testing.assertEqual(len(toolCalls(json.decode(TURN3))), 0);
    def bare as list of ToolCall init toolCalls(json.decode(
        '{"content":[{"type":"tool_use","id":"toolu_1","name":"clock"}]}'));
    testing.assertEqual(json.encode($bare[0].input), '{}');
    for (def bad in [
        '{"content":[{"type":"tool_use","name":"clock","input":{}}]}',
        '{"content":[{"type":"tool_use","id":"toolu_1","name":"clock","input":[1]}]}'
    ]) {
        try {
            toolCalls(json.decode($bad));
            missed($bad);
        } catch (e) {
            testing.assertEqual($e.kind, "anthropic");
            testing.assertContains($e.message, "a tool_use block");
        }
    }
}

func testRunToolsOverSeveralTurns() {
    def f as Fake init startFake([
        answer(200, TURN1),
        answer(200, TURN2),
        answer(200, TURN3),
        answer(200, TURN4)
    ]);
    def req as json.Value init addTool(
        withMaxTokens(newRequest(DEFAULT_MODEL), 4000),
        weatherTool());
    $req = withThinking(addUserText($req, "Weather in Paris and Oslo?"), "");
    def run as ToolRun init runTools(fakeClient($f), $req, fakeTool, 10);
    def seen as list of string init stopFake($f);
    testing.assertEqual($run.turns, 4);
    testing.assertEqual($run.calls, 3);
    testing.assertEqual(len($seen), 4);
    testing.assertEqual(text($run.reply), "Paris 18, Oslo 4.");
    testing.assertEqual($run.usage.inputTokens, 1530 + 900);
    testing.assertEqual($run.usage.outputTokens, 135);
    testing.assertEqual($run.usage.cachedTokens, 900);
    testing.assertEqual($run.usage.reasoningTokens, 40);
    testing.assertEqual($run.usage.cacheCreationInputTokens, 0);
    testing.assertEqual($run.usage.totalTokens, 1530 + 900 + 135);
    testing.assertEqual($run.stopped, "");
    # request 2: the first reply unchanged, then both results in one user turn
    def second as json.Value init seenBody($seen[1]);
    testing.assertEqual(json.length($second, "/messages"), 3);
    testing.assertEqual(
        json.get($second, "/messages/1/content"),
        json.get(json.decode(TURN1), "/content"));
    testing.assertEqual(json.asString($second, "/messages/1/content/0/signature"), "sig-turn-1");
    testing.assertEqual(
        json.encode(json.get($second, "/messages/2")),
        '{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01Paris","content":"18 C, sunny"},' +
            '{"type":"tool_result","tool_use_id":"toolu_01Oslo","content":"4 C, rain"}]}');
    testing.assertEqual(json.get($second, "/tools"), json.get($req, "/tools"));
    testing.assertEqual(json.get($second, "/thinking"), json.get($req, "/thinking"));
    # request 3: the redacted thinking passed back; the failed tool as an error result
    def third as json.Value init seenBody($seen[2]);
    testing.assertEqual(
        json.get($third, "/messages/3/content"),
        json.get(json.decode(TURN2), "/content"));
    testing.assertEqual(
        json.encode(json.get($third, "/messages/4/content/0")),
        '{"type":"tool_result","tool_use_id":"toolu_01Conv","content":"convert is offline","is_error":true}');
    # request 4: the paused turn sent back as it was, no user turn after it
    def fourth as json.Value init seenBody($seen[3]);
    testing.assertEqual(json.length($fourth, "/messages"), 6);
    testing.assertEqual(json.asString($fourth, "/messages/5/role"), "assistant");
    testing.assertEqual(
        json.get($fourth, "/messages/5/content"),
        json.get(json.decode(TURN3), "/content"));
    # the conversation ends with the last reply, ready for another turn
    testing.assertEqual(json.length($run.request, "/messages"), 7);
    testing.assertEqual(
        json.get($run.request, "/messages/6/content"),
        json.get(json.decode(TURN4), "/content"));
}

func testRunToolsStopsAtMaxTurnsAndKeepsTheConversation() {
    def f as Fake init startFake([
        answer(200, TURN1),
        answer(200, TURN1),
        answer(200, TURN3),
        answer(200, TURN4)
    ]);
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(
        addTool(withMaxTokens(newRequest(DEFAULT_MODEL), 100), weatherTool()),
        "x");
    def run as ToolRun init runTools($c, $req, fakeTool, 2);
    testing.assertEqual($run.stopped, "maxTurns");
    testing.assertEqual($run.turns, 2);
    testing.assertEqual($run.calls, 4);
    testing.assertEqual(stopReason($run.reply), "tool_use");
    # the last reply and its results are in: user, (reply, results) x 2
    testing.assertEqual(json.length($run.request, "/messages"), 5);
    testing.assertEqual(json.asString($run.request, "/messages/4/role"), "user");
    # a paused turn at the last request stops too, and the run goes on from there
    def next as ToolRun init runTools($c, $run.request, fakeTool, 1);
    testing.assertEqual($next.stopped, "maxTurns");
    testing.assertEqual(stopReason($next.reply), "pause_turn");
    def done as ToolRun init runTools($c, $next.request, fakeTool, 1);
    testing.assertEqual($done.stopped, "");
    testing.assertEqual(text($done.reply), "Paris 18, Oslo 4.");
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 4);
    testing.assertEqual(json.length(seenBody($seen[3]), "/messages"), 6);
    try {
        runTools(client(KEY), $req, fakeTool, 0);
        missed("no turns");
    } catch (e) {
        testing.assertContains($e.message, "the most turns must be 1 to 1000");
    }
}

func testRunToolsEndsAtARefusalAndAnAnswer() {
    def f as Fake init startFake([answer(200, REFUSED), answer(200, HELLO)]);
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "x");
    def run as ToolRun init runTools($c, $req, fakeTool, 5);
    testing.assertEqual(stopReason($run.reply), "refusal");
    testing.assertEqual($run.turns, 1);
    testing.assertEqual(text(runTools($c, $req, fakeTool, 5).reply), "Hi! My name is Claude.");
    stopFake($f);
}

func testRunToolsRefusesToolUseWithoutACall() {
    def bad as string init '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"x"}],"stop_reason":"tool_use"}';
    def f as Fake init startFake([answer(200, $bad)]);
    try {
        runTools(
            fakeClient($f),
            addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "x"),
            fakeTool,
            5);
        missed("no tool_use");
    } catch (e) {
        testing.assertEqual($e.kind, "anthropic");
        testing.assertContains($e.message, "without a tool_use block");
    }
    stopFake($f);
}

/**
 * A handler that takes a context: the reply for a city comes from it.
 *
 * @param name {string} the tool
 * @param input {json.Value} its input
 * @param context {json.Value} a map of city to weather
 * @return {json.Value} the result
 */
func contextTool(name as string, input as json.Value, context as json.Value) {
    def city as string init json.asString($input, "/city");
    if (not json.has($context, "/" + $city)) {
        return toolError("no city " + $city);
    }
    return json.get($context, "/" + $city);
}

func testRunToolsWithPassesTheContext() {
    def f as Fake init startFake([answer(200, TURN1), answer(200, TURN4)]);
    def req as json.Value init addUserText(addTool(newRequest(DEFAULT_MODEL), weatherTool()), "x");
    def ctx as json.Value init json.decode('{"Paris":"warm","Oslo":{"temp":4}}');
    def run as ToolRun init runToolsWith(fakeClient($f), $req, contextTool, $ctx, 5);
    def seen as list of string init stopFake($f);
    testing.assertEqual($run.turns, 2);
    testing.assertEqual($run.calls, 2);
    testing.assertEqual($run.usage.inputTokens, 1500);
    testing.assertEqual($run.usage.outputTokens, 100);
    testing.assertEqual(
        json.encode(json.get(seenBody($seen[1]), "/messages/2/content")),
        '[{"type":"tool_result","tool_use_id":"toolu_01Paris","content":"warm"},' +
            '{"type":"tool_result","tool_use_id":"toolu_01Oslo","content":"{\"temp\":4}"}]');
    try {
        runToolsWith(client(KEY), $req, contextTool, $ctx, 1001);
        missed("too many turns");
    } catch (e) {
        testing.assertContains($e.message, "the most turns must be 1 to 1000");
    }
}

func testAThrowingHandlerEndsTheLoop() {
    def crash as string init '{"id":"m","type":"message","role":"assistant","content":[' +
        '{"type":"tool_use","id":"toolu_01Crash","name":"crash","input":{}}],"stop_reason":"tool_use",' +
        '"usage":{"input_tokens":1,"output_tokens":1}}';
    def f as Fake init startFake([answer(200, $crash), answer(200, HELLO)]);
    def req as json.Value init addUserText(newRequest(DEFAULT_MODEL), "x");
    try {
        runTools(fakeClient($f), $req, fakeTool, 5);
        missed("a crash");
    } catch (e) {
        testing.assertEqual($e.kind, "tool");
        testing.assertEqual($e.message, "the tool crashed");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 1);
}

func testAToolInputOverTheCapIsAnErrorResult() {
    def big as string init strings.replicate("x", 2000);
    def huge as string init '{"id":"m","type":"message","role":"assistant","content":[' +
        '{"type":"tool_use","id":"toolu_big","name":"crash","input":{"city":"' + $big + '"}},' +
        '{"type":"tool_use","id":"toolu_ok","name":"get_weather","input":{"city":"Oslo"}}],' +
        '"stop_reason":"tool_use"}';
    def f as Fake init startFake([answer(200, $huge), answer(200, TURN4)]);
    def c as Client init withMaxToolInput(fakeClient($f), 1024);
    testing.assertEqual(client(KEY).maxToolInput, 1048576);
    def req as json.Value init addUserText(addTool(newRequest(DEFAULT_MODEL), weatherTool()), "x");
    # the handler would throw for "crash": it is not called
    def run as ToolRun init runTools($c, $req, fakeTool, 5);
    testing.assertEqual($run.calls, 1);
    def seen as list of string init stopFake($f);
    testing.assertEqual(
        json.encode(json.get(seenBody($seen[1]), "/messages/2/content")),
        '[{"type":"tool_result","tool_use_id":"toolu_big","content":"{\"error\":\"the input is over 1024 bytes; ' +
            'call the tool again with a smaller input\"}","is_error":true},' +
            '{"type":"tool_result","tool_use_id":"toolu_ok","content":"4 C, rain"}]');
    for (def bad in [1023, 1073741825]) {
        try {
            withMaxToolInput($c, $bad);
            missed(convert.toString($bad));
        } catch (e) {
            testing.assertContains($e.message, "the largest tool input must be 1024 to 1073741824");
        }
    }
}

func testACompactionStopGoesOnLikeAPausedTurn() {
    def compacted as string init '{"id":"msg_01C","type":"message","role":"assistant",' +
        '"model":"claude-opus-5-5","content":[{"type":"compaction","content":"Summary so far."}],' +
        '"stop_reason":"compaction","usage":{"input_tokens":50,"output_tokens":10}}';
    def f as Fake init startFake([
        answer(200, $compacted),
        answer(200, TURN4),
        answer(200, $compacted)
    ]);
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(newRequest(DEFAULT_MODEL), "x");
    def run as ToolRun init runTools($c, $req, fakeTool, 5);
    testing.assertEqual($run.turns, 2);
    testing.assertEqual($run.stopped, "");
    testing.assertEqual(text($run.reply), "Paris 18, Oslo 4.");
    # it counts against maxTurns
    def one as ToolRun init runTools($c, $req, fakeTool, 1);
    testing.assertEqual($one.stopped, "maxTurns");
    testing.assertEqual(stopReason($one.reply), "compaction");
    def seen as list of string init stopFake($f);
    # the compaction block went back as it came, with no user turn after it
    def second as json.Value init seenBody($seen[1]);
    testing.assertEqual(json.length($second, "/messages"), 2);
    testing.assertEqual(json.asString($second, "/messages/1/content/0/type"), "compaction");
}

