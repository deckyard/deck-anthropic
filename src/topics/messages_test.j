# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# anthropic - white-box tests for the messages topic. Spliced into
# anthropic_test.j via include.

# a reply with summarized thinking, in the shape of the API reference
def const THOUGHTFUL as string init '{"id":"msg_01ThinkA","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"The user wants three moons.","signature":"EqQBCkYIBxgCKkBsig-AAA"},{"type":"text","text":"Io, Europa","citations":null},{"type":"text","text":" and Ganymede.","citations":null}],"stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":30,"output_tokens":120,"cache_creation_input_tokens":0,"cache_read_input_tokens":1800,"output_tokens_details":{"thinking_tokens":90}}}';

# a refusal: HTTP 200, stop_reason refusal with stop_details
def const REFUSED as string init '{"id":"msg_01Refused","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"The request could enable cyber harm."},"usage":{"input_tokens":25,"output_tokens":3}}';

# a structured-output reply: the JSON is the text
def const STRUCTURED as string init '{"id":"msg_01Struct","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"{\"name\":\"John Smith\",\"email\":\"john@example.com\",\"plan_interest\":\"Enterprise\",\"demo_requested\":true}"}],"stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":120,"output_tokens":40}}';

func testRequestBuilders() {
    testing.assertEqual(
        json.encode(newRequest("claude-opus-5-5")),
        '{"model":"claude-opus-5-5","max_tokens":16000,"messages":[]}');
    testing.assertEqual(json.asInt(withMaxTokens(newRequest(DEFAULT_MODEL), 0), "/max_tokens"), 0);
    def req as json.Value init withMaxTokens(newRequest("claude-opus-5-5"), 1024);
    $req = withSystem($req, "Be brief.");
    $req = addUserText($req, 'Say {hi}');
    $req = withThinking($req, "summarized");
    $req = withEffort($req, "high");
    $req = withFormat(
        $req,
        json.decode('{"type":"object","properties":{},"additionalProperties":false}'));
    $req = withFallbacks($req);
    testing.assertEqual(
        json.encode($req),
        '{"model":"claude-opus-5-5","max_tokens":1024,"messages":[{"role":"user","content":"Say {hi}"}],"system":"Be brief.",' +
            '"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"high","format":{"type":"json_schema",' +
            '"schema":{"type":"object","properties":{},"additionalProperties":false}}},"fallbacks":"default"}');
    testing.assertEqual(
        json.encode(withThinking(withMaxTokens(newRequest("claude-opus-5-5"), 0), "")),
        '{"model":"claude-opus-5-5","max_tokens":0,"messages":[],"thinking":{"type":"adaptive"}}');
}

func testContentBlocks() {
    def png as bytes init convert.bytesFromString("utf-8", "PNGDATA");
    testing.assertEqual(
        json.encode(imageBlock("image/png", $png)),
        '{"type":"image","source":{"type":"base64","media_type":"image/png","data":"UE5HREFUQQ=="}}');
    def pdf as bytes init convert.bytesFromString("utf-8", "%PDF-1.7");
    testing.assertEqual(
        json.encode(pdfBlock($pdf)),
        '{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"JVBERi0xLjc="}}');
    testing.assertEqual(
        json.encode(withCacheControl(textBlock("manual"), "")),
        '{"type":"text","text":"manual","cache_control":{"type":"ephemeral"}}');
    testing.assertEqual(
        json.encode(withCacheControl(textBlock("manual"), "1h")),
        '{"type":"text","text":"manual","cache_control":{"type":"ephemeral","ttl":"1h"}}');
    def req as json.Value init withMaxTokens(newRequest(DEFAULT_MODEL), 100);
    $req = withSystemBlocks($req, [withCacheControl(textBlock("a long manual"), "5m")]);
    $req = addUser($req, [imageBlock("image/jpeg", $png), textBlock("What is it?")]);
    $req = withCacheControl($req, "");
    testing.assertEqual(json.asString($req, "/system/0/cache_control/ttl"), "5m");
    testing.assertEqual(
        json.asString($req, "/messages/0/content/0/source/media_type"),
        "image/jpeg");
    testing.assertEqual(json.asString($req, "/cache_control/type"), "ephemeral");
    try {
        imageBlock("image/tiff", $png);
        missed("tiff");
    } catch (e) {
        testing.assertContains($e.message, "an image is image/jpeg");
    }
    try {
        pdfBlock($png);
        missed("not a PDF");
    } catch (e) {
        testing.assertContains($e.message, "a PDF starts with %PDF-");
    }
    try {
        withCacheControl(textBlock("x"), "2h");
        missed("2h");
    } catch (e) {
        testing.assertContains($e.message, "a cache TTL is 5m or 1h");
    }
}

func testBadBuilderInput() {
    for (def bad in ["", "Claude Opus", "claude_opus"]) {
        try {
            withMaxTokens(newRequest($bad), 100);
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a model id is");
        }
    }
    try {
        withMaxTokens(newRequest(DEFAULT_MODEL), -1);
        missed("negative");
    } catch (e) {
        testing.assertContains($e.message, "max_tokens must be 0 to 300000");
    }
    def req as json.Value init withMaxTokens(newRequest(DEFAULT_MODEL), 100);
    try {
        withEffort($req, "extreme");
        missed("effort");
    } catch (e) {
        testing.assertContains($e.message, "an effort is low, medium, high, xhigh or max");
    }
    try {
        withThinking($req, "full");
        missed("display");
    } catch (e) {
        testing.assertContains($e.message, "a thinking display is");
    }
    try {
        addReply($req, json.decode('{"type":"message"}'));
        missed("no content");
    } catch (e) {
        testing.assertContains($e.message, "the reply has no content list");
    }
    try {
        withFormat($req, json.decode('"x"'));
        missed("a schema");
    } catch (e) {
        testing.assertContains($e.message, "a schema is a JSON object");
    }
}

func testChatSendsTheRequest() {
    def f as Fake init startFake([answer(200, HELLO)]);
    def req as json.Value init addUserText(
        withMaxTokens(newRequest(DEFAULT_MODEL), 1024),
        "Hello, world");
    def reply as json.Value init chat(fakeClient($f), $req);
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "POST /v1/messages");
    testing.assertEqual(seenHeader($seen[0], "x-api-key"), KEY);
    testing.assertEqual(seenHeader($seen[0], "anthropic-version"), "2026-10-21");
    testing.assertEqual(seenHeader($seen[0], "content-type"), "application/json");
    testing.assertEqual(seenBody($seen[0]), $req);
    testing.assertEqual(text($reply), "Hi! My name is Claude.");
    testing.assertEqual(stopReason($reply), "end_turn");
    testing.assertEqual(len(toolCalls($reply)), 0);
    def u as Usage init usage($reply);
    # input counts the cache reads and writes too
    testing.assertEqual($u.inputTokens, 2095 + 2051 + 2051);
    testing.assertEqual($u.outputTokens, 503);
    testing.assertEqual($u.cacheCreationInputTokens, 2051);
    testing.assertEqual($u.cachedTokens, 2051);
    testing.assertEqual($u.reasoningTokens, 0);
    testing.assertEqual($u.totalTokens, $u.inputTokens + $u.outputTokens);
    # a reply without usage counts 0 everywhere
    def none as Usage init usage(json.decode('{"type":"message","content":[]}'));
    testing.assertEqual($none.totalTokens, 0);
    testing.assertEqual($none.cachedTokens, 0);
}

func testChatRefusesWhatItWouldNotSend() {
    def c as Client init client(KEY);
    def req as json.Value init addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "x");
    try {
        chat($c, json.set($req, "/stream", true));
        missed("stream");
    } catch (e) {
        testing.assertContains($e.message, "messages: streaming is not supported");
    }
    try {
        chat($c, json.remove($req, "/max_tokens"));
        missed("max_tokens");
    } catch (e) {
        testing.assertContains($e.message, "messages: the request has no max_tokens");
    }
    try {
        chat($c, json.remove($req, "/model"));
        missed("model");
    } catch (e) {
        testing.assertContains($e.message, "messages: the request has no model");
    }
    try {
        chat($c, json.decode("[]"));
        missed("a list");
    } catch (e) {
        testing.assertContains($e.message, "messages: the request is a JSON object");
    }
}

func testChatRefusesAReplyThatIsNotAMessage() {
    def f as Fake init startFake([answer(200, '{"type":"error_page"}')]);
    try {
        chat(fakeClient($f), addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 10), "x"));
        missed("not a message");
    } catch (e) {
        testing.assertContains($e.message, "messages: the reply is not a message");
    }
    stopFake($f);
}

func testThinkingAndUsage() {
    def reply as json.Value init json.decode(THOUGHTFUL);
    testing.assertEqual(text($reply), "Io, Europa and Ganymede.");
    def u as Usage init usage($reply);
    testing.assertEqual($u.reasoningTokens, 90);
    testing.assertEqual($u.cachedTokens, 1800);
    # the reply goes back unchanged, signature and all
    def req as json.Value init addReply(
        addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "Moons?"),
        $reply);
    testing.assertEqual(json.get($req, "/messages/1/content"), json.get($reply, "/content"));
    testing.assertEqual(json.asString($req, "/messages/1/role"), "assistant");
    testing.assertEqual(
        json.asString($req, "/messages/1/content/0/signature"),
        "EqQBCkYIBxgCKkBsig-AAA");
    # a kept assistant turn, then the next question
    def kept as json.Value init addAssistant(
        withMaxTokens(newRequest(DEFAULT_MODEL), 100),
        json.get($reply, "/content"));
    $kept = addUserText($kept, "Another?");
    testing.assertEqual(json.get($kept, "/messages/0/content"), json.get($reply, "/content"));
    testing.assertEqual(
        json.asString(addAssistant($kept, toolText("ok")), "/messages/2/content"),
        "ok");
    try {
        addAssistant($kept, json.decode("1"));
        missed("a number");
    } catch (e) {
        testing.assertContains($e.message, "a turn's content is a string or a list of blocks");
    }
}

func testARefusal() {
    def f as Fake init startFake([answer(200, REFUSED), answer(200, HELLO)]);
    def c as Client init withBetas(fakeClient($f), [BETA_FALLBACKS]);
    def reply as json.Value init chat(
        $c,
        addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "x"));
    testing.assertEqual(stopReason($reply), "refusal");
    testing.assertEqual(refusalCategory($reply), "cyber");
    testing.assertEqual(text($reply), "");
    testing.assertEqual(
        refusalCategory(chat($c, addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 100), "y"))),
        "");
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenHeader($seen[0], "anthropic-beta"), "server-side-fallback-2026-07-01");
}

func testStructuredOutput() {
    def reply as json.Value init json.decode(STRUCTURED);
    def v as json.Value init json.decode(text($reply));
    testing.assertEqual(json.asString($v, "/name"), "John Smith");
    testing.assertTrue(json.asBool($v, "/demo_requested"));
}

func testCountTokens() {
    def f as Fake init startFake([answer(200, '{"input_tokens":14}'), answer(200, '{"tokens":1}')]);
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(
        withMaxTokens(newRequest(DEFAULT_MODEL), 1024),
        "Hello, world");
    $req = withFallbacks(json.set($req, "/stop_sequences", json.list(["END"])));
    $req = withThinking($req, "");
    testing.assertEqual(countTokens($c, $req), 14);
    try {
        countTokens($c, $req);
        missed("no count");
    } catch (e) {
        testing.assertContains($e.message, "count_tokens: the reply has no input_tokens");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "POST /v1/messages/count_tokens");
    testing.assertEqual(
        json.encode(seenBody($seen[0])),
        '{"model":"claude-opus-5-5","messages":[{"role":"user","content":"Hello, world"}],"thinking":{"type":"adaptive"}}');
}

func testCountTokensDropsSamplingAndThreadFields() {
    def f as Fake init startFake([answer(200, '{"input_tokens":9}')]);
    def c as Client init fakeClient($f);
    def req as json.Value init addUserText(newRequest(DEFAULT_MODEL), "Hi");
    $req = json.set($req, "/temperature", 0.2);
    $req = json.set($req, "/top_p", 0.9);
    $req = json.set($req, "/top_k", 40);
    $req = json.set($req, "/thread", json.decode('{"id":"thr_1"}'));
    $req = json.set($req, "/fallback_credit_token", "tok");
    testing.assertEqual(countTokens(withApiVersion($c, "2023-06-01"), $req), 9);
    def seen as list of string init stopFake($f);
    testing.assertEqual(
        json.encode(seenBody($seen[0])),
        '{"model":"claude-opus-5-5","messages":[{"role":"user","content":"Hi"}]}');
}
