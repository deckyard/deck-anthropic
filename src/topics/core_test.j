# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0

# anthropic - white-box tests for the core topic, and the fake server the
# other overlays use. Spliced into anthropic_test.j via include.

# a key for the fake; never a real one
def const KEY as string init "sk-ant-api03-test-key-0123456789";

# the reply of the API reference's Messages example (200)
def const HELLO as string init '{"id":"msg_013Zva2CMHLNnXjNJJKqJ2EF","content":[{"citations":null,"text":"Hi! My name is Claude.","type":"text"}],"diagnostics":null,"model":"claude-opus-5-5","role":"assistant","stop_details":null,"stop_reason":"end_turn","stop_sequence":null,"type":"message","usage":{"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"cache_creation_input_tokens":2051,"cache_read_input_tokens":2051,"inference_geo":"global","input_tokens":2095,"output_tokens":503,"output_tokens_details":{"thinking_tokens":0},"server_tool_use":{"web_fetch_requests":2,"web_search_requests":0},"service_tier":"standard","speed":"standard"}}';

# error bodies in the shape of the errors page
def const ERR_INVALID as string init '{"type":"error","error":{"type":"invalid_request_error","message":"messages: roles must alternate between \"user\" and \"assistant\""},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fy"}';
def const ERR_AUTH as string init '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fa"}';
def const ERR_RATE as string init '{"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fb"}';
def const ERR_OVERLOADED as string init '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fc"}';
def const ERR_API as string init '{"type":"error","error":{"type":"api_error","message":"Internal server error"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fd"}';
def const ERR_NOT_FOUND as string init '{"type":"error","error":{"type":"not_found_error","message":"model: claude-opus-9"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Fe"}';

# the models list of the API reference, cut to two models over two pages
def const MODELS_PAGE1 as string init '{"data":[{"id":"claude-opus-5-5","capabilities":{"batch":{"supported":true},"effort":{"high":{"supported":true},"low":{"supported":true},"max":{"supported":true},"medium":{"supported":true},"supported":true,"xhigh":{"supported":true}},"thinking":{"supported":true,"types":{"adaptive":{"supported":true},"disabled":{"supported":false},"enabled":{"supported":false}}}},"created_at":"2026-09-21T00:00:00Z","deprecated_at":null,"display_name":"Claude Opus 5.5","lifecycle":"active","line":"opus","max_input_tokens":1000000,"max_tokens":128000,"retires_at":null,"type":"model"}],"first_id":"claude-opus-5-5","has_more":true,"last_id":"claude-opus-5-5"}';
def const MODELS_PAGE2 as string init '{"data":[{"id":"claude-haiku-5-5","capabilities":null,"created_at":"2026-09-01T00:00:00Z","deprecated_at":null,"display_name":"Claude Haiku 5.5","lifecycle":"active","line":"haiku","max_input_tokens":1000000,"max_tokens":128000,"retires_at":null,"type":"model"}],"first_id":"claude-haiku-5-5","has_more":false,"last_id":"claude-haiku-5-5"}';

/**
 * A running fake Claude API.
 *
 * @field srv {httpd.Server} the server
 * @field base {string} its base URL
 * @field t {task of list of string} the task serving it; its result is every request seen
 */
def struct Fake {
    srv as httpd.Server,
    base as string,
    t as task of list of string
};

/**
 * Mark a call that should have thrown.
 *
 * @param what {string} what got through
 * @throws {Error} always, kind "missed"
 */
func missed(what as string) {
    throw Error{kind: "missed", message: $what};
}

/**
 * Start a fake API that answers requests in order, whatever they ask. An
 * answer is the status, a newline, header lines `Name: value`, an empty
 * line and the body; status `SLEEP <ms>` waits that long and answers 200. Once
 * the answers run out it answers 500.
 *
 * @param answers {list of string} the answers, in order
 * @return {Fake} the server
 */
func startFake(answers as list of string) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    def t as task of list of string init spawn {
        return serveFake($srv, $answers);
    };
    return Fake{srv: $srv, base: $base, t: $t};
}

/**
 * Serve requests until the server shuts down.
 *
 * @param srv {httpd.Server} the server
 * @param answers {list of string} the answers
 * @return {list of string} each request as `METHOD target`, then `name: value` lines for x-api-key, anthropic-version, anthropic-beta and content-type when sent, an empty line and the body
 */
func serveFake(srv as httpd.Server, answers as list of string) {
    def seen as list of string init [];
    def next as int init 0;
    while (true) {
        def req as httpd.Request;
        try {
            $req = httpd.accept($srv);
        } catch (e) {
            return $seen;
        }
        def target as string init httpd.path($req);
        if (httpd.rawQuery($req) != "") {
            $target = $target + "?" + httpd.rawQuery($req);
        }
        def lines as list of string init [httpd.method($req) + " " + $target];
        for (def h in ["x-api-key", "anthropic-version", "anthropic-beta", "content-type"]) {
            if (httpd.header($req, $h) != "") {
                $lines[] = $h + ": " + httpd.header($req, $h);
            }
        }
        $seen[] = strings.join($lines, "\n") + "\n\n" +
            encoding.decode("utf-8", httpd.body($req));
        def spec as string init "500\ncontent-type: application/json\n\n" + ERR_API;
        if ($next < len($answers)) {
            $spec = $answers[$next];
            $next = $next + 1;
        }
        def split as int init strings.indexOf($spec, "\n\n");
        def head as list of string init strings.split($spec[..$split], "\n");
        for (def h in $head[1..]) {
            def at as int init strings.indexOf($h, ": ");
            httpd.setHeader($req, $h[..$at], $h[$at + 2..]);
        }
        if (strings.startsWith($head[0], "SLEEP ")) {
            time.sleep(time.fromMilliseconds(convert.toInt($head[0][len("SLEEP ")..])));
            httpd.respond($req, 200, '{}');
        } else {
            httpd.respond($req, convert.toInt($head[0]), $spec[$split + 2..]);
        }
    }
}

/**
 * Stop a fake and return what it saw.
 *
 * @param f {Fake} the fake
 * @return {list of string} the requests
 */
func stopFake(f as Fake) {
    httpd.shutdown($f.srv);
    return task.wait($f.t);
}

/**
 * A client of a fake, with short waits between retries.
 *
 * @param f {Fake} the fake
 * @return {Client} the client
 */
func fakeClient(f as Fake) {
    def c as Client init withBaseUrl(client(KEY), $f.base);
    $c.backoffMs = 10;
    return $c;
}

/**
 * A JSON answer with a request id.
 *
 * @param status {int} the status
 * @param body {string} the JSON
 * @return {string} the answer for `startFake`
 */
func answer(status as int, body as string) {
    return convert.toString($status) +
        "\ncontent-type: application/json\nrequest-id: req_fake" + convert.toString($status) +
        "\n\n" + $body;
}

/**
 * The first line of a request the fake saw: `METHOD target`.
 *
 * @param seen {string} the request
 * @return {string} the line
 */
func seenLine(seen as string) {
    return strings.split($seen, "\n")[0];
}

/**
 * A header of a request the fake saw.
 *
 * @param seen {string} the request
 * @param name {string} the lower-case name
 * @return {string} its value, `""` when not sent
 */
func seenHeader(seen as string, name as string) {
    def head as string init $seen[..strings.indexOf($seen, "\n\n")];
    for (def line in strings.split($head, "\n")) {
        if (strings.startsWith($line, $name + ": ")) {
            return $line[len($name) + 2..];
        }
    }
    return "";
}

/**
 * The body of a request the fake saw, as JSON.
 *
 * @param seen {string} the request
 * @return {json.Value} the body
 */
func seenBody(seen as string) {
    return json.decode($seen[strings.indexOf($seen, "\n\n") + 2..]);
}

func testClientAndSettings() {
    def c as Client init client(KEY);
    testing.assertEqual($c.baseUrl, DEFAULT_BASE_URL);
    testing.assertEqual($c.version, "2026-10-21");
    testing.assertEqual($c.timeoutMs, 600000);
    testing.assertEqual($c.retries, 2);
    testing.assertEqual($c.maxBytes, 67108864);
    testing.assertEqual(
        withBaseUrl($c, "https://gw.example.org/anthropic/").baseUrl,
        "https://gw.example.org/anthropic");
    testing.assertEqual(withApiVersion($c, "2023-06-01").version, "2023-06-01");
    testing.assertEqual(withBetas($c, [BETA_FALLBACKS]).betas, ["server-side-fallback-2026-07-01"]);
    testing.assertEqual(withTimeout($c, 5000).timeoutMs, 5000);
    testing.assertEqual(withRetries($c, 0).retries, 0);
    testing.assertEqual(withMaxBytes($c, 65536).maxBytes, 65536);
    testing.assertTrue(withPlainHttp($c).allowPlainHttp);
    testing.assertTrue(withTls($c, http.TlsOptions{skipVerify: true}).tls.skipVerify);
}

func testBadSettingsAreRefusedWithoutTheKey() {
    for (def bad in ["", "has space", "line\nbreak"]) {
        try {
            client($bad);
            missed("a bad key");
        } catch (e) {
            testing.assertEqual($e.kind, "anthropic");
            testing.assertEqual($e.status, 0);
            testing.assertContains($e.message, "an API key is");
        }
    }
    def c as Client init client(KEY);
    for (def bad in [
        "ftp://x",
        "https://x/?a=1",
        "api.anthropic.com",
        "https://x:0",
        "https://x/a/../b"
    ]) {
        try {
            withBaseUrl($c, $bad);
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a base URL is");
        }
    }
    try {
        withApiVersion($c, "latest");
        missed("a version");
    } catch (e) {
        testing.assertContains($e.message, "an API version is a date");
    }
    try {
        withBetas($c, ["a b"]);
        missed("a beta");
    } catch (e) {
        testing.assertContains($e.message, "a beta name is");
    }
    try {
        withTimeout($c, 999);
        missed("a timeout");
    } catch (e) {
        testing.assertContains($e.message, "the timeout must be 1000 to 86400000");
    }
    try {
        withRetries($c, 11);
        missed("retries");
    } catch (e) {
        testing.assertContains($e.message, "the retry count must be 0 to 10");
    }
    try {
        withMaxBytes($c, 1024);
        missed("a cap");
    } catch (e) {
        testing.assertContains($e.message, "the largest reply must be");
    }
    # plain http to another machine is refused when a request is sent
    try {
        models(withBaseUrl($c, "http://gw.lan:8080"));
        missed("plain http");
    } catch (e) {
        testing.assertEqual($e.kind, "anthropic");
        testing.assertContains($e.message, "would send the API key in clear");
        testing.assertFalse(strings.contains($e.message, KEY));
    }
    checkUrl(withPlainHttp(withBaseUrl($c, "http://gw.lan:8080")));
    checkUrl(withBaseUrl($c, "http://localhost:8080"));
}

func testRequestsCarryTheHeaders() {
    def f as Fake init startFake([answer(200, MODELS_PAGE2)]);
    def c as Client init withBetas(fakeClient($f), ["a-beta-2026-01-01", "b-beta"]);
    def all as list of json.Value init models($c);
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($all), 1);
    testing.assertEqual(seenLine($seen[0]), "GET /v1/models?limit=1000");
    testing.assertEqual(seenHeader($seen[0], "x-api-key"), KEY);
    testing.assertEqual(seenHeader($seen[0], "anthropic-version"), "2026-10-21");
    testing.assertEqual(seenHeader($seen[0], "anthropic-beta"), "a-beta-2026-01-01,b-beta");
    testing.assertEqual(seenHeader($seen[0], "content-type"), "");
}

func testModelsReadsEveryPage() {
    def f as Fake init startFake([answer(200, MODELS_PAGE1), answer(200, MODELS_PAGE2)]);
    def all as list of json.Value init models(fakeClient($f));
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($all), 2);
    testing.assertEqual(json.asString($all[0], "/id"), "claude-opus-5-5");
    testing.assertEqual(json.asInt($all[0], "/max_input_tokens"), 1000000);
    testing.assertTrue(json.asBool($all[0], "/capabilities/thinking/types/adaptive/supported"));
    testing.assertEqual(json.asString($all[1], "/id"), "claude-haiku-5-5");
    testing.assertEqual(seenLine($seen[1]), "GET /v1/models?limit=1000&after_id=claude-opus-5-5");
}

func testModel() {
    def page as json.Value init json.decode(MODELS_PAGE1);
    def f as Fake init startFake([
        answer(200, json.encode(json.get($page, "/data/0"))),
        answer(404, ERR_NOT_FOUND)
    ]);
    def c as Client init fakeClient($f);
    def m as json.Value init model($c, "claude-opus-5-5");
    testing.assertEqual(json.asString($m, "/display_name"), "Claude Opus 5.5");
    try {
        model($c, "claude-opus-9");
        missed("a 404");
    } catch (e) {
        testing.assertEqual($e.kind, "anthropic");
        testing.assertEqual($e.status, 404);
        testing.assertEqual($e.type, "not_found_error");
        testing.assertEqual($e.requestId, "req_fake404");
        testing.assertContains(
            $e.message,
            "model claude-opus-9: model: claude-opus-9 (HTTP 404 not_found_error, request req_fake404)");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "GET /v1/models/claude-opus-5-5");
    try {
        model($c, "../x");
        missed("a bad id");
    } catch (e) {
        testing.assertContains($e.message, "a model id is 1 to 128");
    }
}

func testEveryErrorTypeAndStatus() {
    def cases as list of string init [
        "400 invalid_request_error",
        "401 authentication_error",
        "402 billing_error",
        "403 permission_error",
        "404 not_found_error",
        "413 request_too_large",
        "429 rate_limit_error",
        "500 api_error",
        "504 timeout_error",
        "529 overloaded_error"
    ];
    def answers as list of string init [];
    for (def k in $cases) {
        def parts as list of string init strings.split($k, " ");
        $answers[] = answer(
            convert.toInt($parts[0]),
            '{"type":"error","error":{"type":"' + $parts[1] + '","message":"m ' + $parts[1] +
                '"},"request_id":"req_body"}');
    }
    def f as Fake init startFake($answers);
    def c as Client init withRetries(fakeClient($f), 0);
    for (def k in $cases) {
        def parts as list of string init strings.split($k, " ");
        try {
            call($c, "GET", "/v1/models", json.decode("null"));
            missed($k);
        } catch (e) {
            testing.assertEqual($e.kind, "anthropic");
            testing.assertEqual($e.status, convert.toInt($parts[0]));
            testing.assertEqual($e.type, $parts[1]);
            testing.assertEqual($e.requestId, "req_fake" + $parts[0]);
            testing.assertContains($e.message, "m " + $parts[1]);
        }
    }
    stopFake($f);
}

func testErrorBodiesThatAreNotTheApis() {
    # Cloudflare answers an oversized request with HTML; a body may carry
    # only request_id; neither may show the key
    def f as Fake init startFake([
        "413\ncontent-type: text/html\n\n<html><body>413 Request Entity Too Large</body></html>",
        "400\ncontent-type: application/json\n\n" +
            '{"type":"error","error":{"type":"invalid_request_error","message":"bad key ' + KEY +
            '"},"request_id":"req_only_body"}'
    ]);
    def c as Client init withRetries(fakeClient($f), 0);
    try {
        call($c, "POST", "/v1/messages", json.decode('{}'));
        missed("413");
    } catch (e) {
        testing.assertEqual($e.status, 413);
        testing.assertEqual($e.type, "");
        testing.assertContains(
            $e.message,
            "POST /v1/messages: Request Entity Too Large (HTTP 413)");
    }
    try {
        call($c, "POST", "/v1/messages", json.decode('{}'));
        missed("400");
    } catch (e) {
        testing.assertEqual($e.requestId, "req_only_body");
        testing.assertFalse(strings.contains($e.message, KEY));
        testing.assertContains($e.message, "bad key <api key>");
    }
    stopFake($f);
}

func testRetriesHonourRetryAfter() {
    def f as Fake init startFake([
        "429\ncontent-type: application/json\nretry-after: 1\n\n" + ERR_RATE,
        answer(529, ERR_OVERLOADED),
        answer(200, MODELS_PAGE2)
    ]);
    def started as int init time.unixMilliseconds(time.now());
    def all as list of json.Value init models(fakeClient($f));
    def took as int init time.unixMilliseconds(time.now()) - $started;
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 3);
    testing.assertEqual(len($all), 1);
    testing.assertTrue($took >= 1000);
}

func testRetriesRunOut() {
    def f as Fake init startFake([
        answer(529, ERR_OVERLOADED),
        answer(500, ERR_API),
        answer(529, ERR_OVERLOADED),
        answer(200, HELLO)
    ]);
    try {
        models(fakeClient($f));
        missed("three failures");
    } catch (e) {
        testing.assertEqual($e.status, 529);
        testing.assertEqual($e.type, "overloaded_error");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 3);
}

func testNoRetryForAClientErrorOrALongRetryAfter() {
    def f as Fake init startFake([
        answer(400, ERR_INVALID),
        "429\ncontent-type: application/json\nretry-after: 3600\n\n" + ERR_RATE,
        answer(401, ERR_AUTH)
    ]);
    def c as Client init fakeClient($f);
    for (def want in [400, 429, 401]) {
        try {
            models($c);
            missed(convert.toString($want));
        } catch (e) {
            testing.assertEqual($e.status, $want);
        }
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 3);
}

func testRetryWait() {
    def c as Client init client(KEY);
    def r as http.BytesResponse init http.BytesResponse{status: 529, headers: {}};
    testing.assertEqual(retryWait($c, $r, 1), 500);
    testing.assertEqual(retryWait($c, $r, 2), 1000);
    testing.assertEqual(retryWait($c, $r, 3), 2000);
    testing.assertEqual(retryWait($c, $r, 9), 8000);
    $r.headers = {"retry-after": "2.5"};
    testing.assertEqual(retryWait($c, $r, 1), 2500);
    $r.headers = {"retry-after": "61"};
    testing.assertEqual(retryWait($c, $r, 1), -1);
    # an HTTP date: the time left until it, 0 once past
    $r.headers = {"retry-after": "Wed, 21 Oct 2015 07:28:00 GMT"};
    testing.assertEqual(retryWait($c, $r, 1), 0);
    def soon as string init time.format(
        time.add(time.utc(), time.fromSeconds(30)),
        "%a, %d %b %Y %H:%M:%S GMT");
    $r.headers = {"retry-after": $soon};
    def w as int init retryWait($c, $r, 1);
    testing.assertTrue($w > 28000 and $w <= 30000);
    def later as string init time.format(
        time.add(time.utc(), time.fromSeconds(600)),
        "%a, %d %b %Y %H:%M:%S GMT");
    $r.headers = {"retry-after": $later};
    testing.assertEqual(retryWait($c, $r, 1), -1);
    # retry-after-ms comes first
    $r.headers = {"retry-after-ms": "250", "retry-after": "30"};
    testing.assertEqual(retryWait($c, $r, 1), 250);
    $r.headers = {"retry-after-ms": "61000.5"};
    testing.assertEqual(retryWait($c, $r, 1), -1);
    # malformed: the backoff applies
    $r.headers = {"retry-after": "soon", "retry-after-ms": "-5"};
    testing.assertEqual(retryWait($c, $r, 1), 500);
}

func testTheDeadlineIsKindTimeout() {
    def f as Fake init startFake(["SLEEP 600\n\n"]);
    def c as Client init fakeClient($f);
    $c.timeoutMs = 300;
    try {
        models($c);
        missed("a deadline");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
        testing.assertContains($e.message, "models: no reply within 300 ms");
    }
    stopFake($f);
}

func testTheCapIsKindLimit() {
    def f as Fake init startFake([
        answer(200, '{"data":[],"pad":"' + strings.replicate("x", 70000) + '"}')
    ]);
    def c as Client init withMaxBytes(fakeClient($f), 65536);
    try {
        models($c);
        missed("a cap");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "models: the reply is over 65536 bytes");
    }
    stopFake($f);
}

func testAnUnreachableServerIsRetriedThenNet() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    httpd.shutdown($srv);
    def c as Client init withBaseUrl(client(KEY), $base);
    $c.backoffMs = 10;
    try {
        models($c);
        missed("no server");
    } catch (e) {
        # the NetError of the last attempt, passed on unchanged
        testing.assertEqual($e.kind, "net");
        def ne as net.NetError init $e;
        testing.assertEqual($ne.reason, "refused");
        testing.assertFalse($ne.sent);
        testing.assertFalse(strings.contains($e.message, KEY));
    }
}

func testAConnectionClosedMidAnswerIsKindClosedAndNotRetried() {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def addr as string init net.address($l);
    def t as task of int init spawn {
        for (def i in 0..1) {
            def conn as net.Conn init net.accept($l);
            net.readBytes($conn, 65536);
            net.writeBytes(
                $conn,
                encoding.encode(
                    "utf-8",
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n" +
                        '{"data"'));
            net.close($conn);
        }
        return 1;
    };
    def c as Client init withTimeout(withBaseUrl(client(KEY), "http://" + $addr), 2000);
    $c.backoffMs = 10;
    try {
        models($c);
        missed("a short body");
    } catch (e) {
        testing.assertEqual($e.kind, "closed");
        testing.assertContains($e.message, "anthropic: models: the server closed the connection");
    }
    testing.assertEqual(task.wait($t), 1);
    net.close($l);
}

func testCall() {
    def f as Fake init startFake([answer(200, '{"ok":true}'), answer(200, "")]);
    def c as Client init fakeClient($f);
    def v as json.Value init call($c, "POST", "/v1/files/x?beta=true", json.decode('{"a":1}'));
    testing.assertTrue(json.asBool($v, "/ok"));
    testing.assertTrue(json.isNull(call($c, "DELETE", "/v1/files/x", json.decode("null"))));
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "POST /v1/files/x?beta=true");
    testing.assertEqual(seenHeader($seen[0], "content-type"), "application/json");
    testing.assertEqual(json.asInt(seenBody($seen[0]), "/a"), 1);
    testing.assertEqual(seenLine($seen[1]), "DELETE /v1/files/x");
    for (def bad in ["/v1/../x", "v1/x", "/v1/x y", "/v1/x#f"]) {
        try {
            call($c, "GET", $bad, json.decode("null"));
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a path is");
        }
    }
    try {
        call($c, "HEAD", "/v1/x", json.decode("null"));
        missed("HEAD");
    } catch (e) {
        testing.assertContains($e.message, "a method is");
    }
}

func testAReplyThatIsNotJson() {
    def f as Fake init startFake([answer(200, "not json"), answer(200, "[1]")]);
    def c as Client init fakeClient($f);
    try {
        models($c);
        missed("not JSON");
    } catch (e) {
        testing.assertEqual($e.kind, "anthropic");
        testing.assertContains($e.message, "models: the reply is not JSON");
    }
    try {
        models($c);
        missed("a list");
    } catch (e) {
        testing.assertContains($e.message, "models: the reply is a list, not an object");
    }
    stopFake($f);
}

func testAnEchoedKeyNeverReachesTheError() {
    def f as Fake init startFake([
        "401\ncontent-type: application/json\nrequest-id: req_" + KEY + "\n\n" +
            '{"type":"error","error":{"type":"' + KEY + '","message":"bad key ' + KEY + '"}}'
    ]);
    try {
        models(fakeClient($f));
        missed("a 401");
    } catch (e) {
        testing.assertEqual($e.status, 401);
        testing.assertFalse(strings.contains($e.message, KEY));
        testing.assertFalse(strings.contains($e.requestId, KEY));
        testing.assertFalse(strings.contains($e.type, KEY));
        testing.assertEqual($e.requestId, "req_<api key>");
    }
    stopFake($f);
}

func testModelsCapsThePagesTogether() {
    def pad as string init strings.replicate("x", 40000);
    def page as string init '{"data":[],"pad":"' + $pad + '","has_more":true,"last_id":"claude-x"}';
    def f as Fake init startFake([answer(200, $page), answer(200, $page), answer(200, $page)]);
    def c as Client init withMaxBytes(fakeClient($f), 65536);
    try {
        models($c);
        missed("pages over the cap");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "models: the pages are over 65536 bytes in all");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(len($seen), 2);
}

/**
 * Serve raw replies on a listener, one per connection.
 *
 * @param l {net.Listener} the listener
 * @param replies {list of string} what each connection gets before it is closed
 * @return {int} how many connections were served
 */
func serveRaw(l as net.Listener, replies as list of string) {
    for (def reply in $replies) {
        def conn as net.Conn init net.accept($l);
        net.readBytes($conn, 65536);
        if ($reply != "") {
            net.writeBytes($conn, encoding.encode("utf-8", $reply));
        }
        net.close($conn);
    }
    return len($replies);
}

func testAPostWhoseAnswerBrokeOffIsNotSentTwice() {
    # a request whose answer broke off may have run: it is never sent again
    def short as string init "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n" +
        '{"id"';
    def l as net.Listener init net.listen("127.0.0.1:0");
    def addr as string init net.address($l);
    def t as task of int init spawn {
        return serveRaw($l, [$short, ""]);
    };
    def c as Client init withTimeout(withBaseUrl(client(KEY), "http://" + $addr), 2000);
    $c.backoffMs = 10;
    def req as json.Value init addUserText(newRequest(DEFAULT_MODEL), "x");
    try {
        chat($c, $req);
        missed("a short body");
    } catch (e) {
        testing.assertEqual($e.kind, "closed");
    }
    # a connection closed before any byte of the answer: not sent twice
    # either, and its NetError passed on
    try {
        chat($c, $req);
        missed("no answer");
    } catch (e) {
        testing.assertEqual($e.kind, "net");
        def ne as net.NetError init $e;
        testing.assertEqual($ne.reason, "closed");
        testing.assertTrue($ne.sent);
        testing.assertFalse($ne.replied);
    }
    # each POST was sent once
    testing.assertEqual(task.wait($t), 2);
    net.close($l);
}

func testErrorsCarryTheWaitAndTheRateLimitHeaders() {
    def f as Fake init startFake([
        "429\ncontent-type: application/json\nretry-after: 120\n" +
            "anthropic-ratelimit-requests-limit: 50\nanthropic-ratelimit-requests-remaining: 0\n" +
            "anthropic-ratelimit-requests-reset: 2026-11-15T10:00:30Z\nx-ratelimit-other: 1\n" +
            "request-id: req_r\n\n" + ERR_RATE,
        answer(400, ERR_INVALID)
    ]);
    def c as Client init fakeClient($f);
    def started as int init time.unixMilliseconds(time.now());
    try {
        models($c);
        missed("a 429");
    } catch (e) {
        testing.assertEqual($e.status, 429);
        testing.assertEqual($e.retryAfterMs, 120000);
        testing.assertEqual($e.limits["anthropic-ratelimit-requests-remaining"], "0");
        testing.assertEqual(
            $e.limits["anthropic-ratelimit-requests-reset"],
            "2026-11-15T10:00:30Z");
        testing.assertEqual($e.limits["x-ratelimit-other"], "1");
        testing.assertEqual($e.limits["retry-after"], "120");
        testing.assertFalse(maps.has($e.limits, "request-id"));
    }
    testing.assertTrue(time.unixMilliseconds(time.now()) - $started < 1000);
    try {
        models($c);
        missed("a 400");
    } catch (e) {
        testing.assertEqual($e.retryAfterMs, 0);
        testing.assertEqual(len($e.limits), 0);
    }
    try {
        client("");
        missed("no key");
    } catch (e) {
        testing.assertEqual($e.retryAfterMs, 0);
        testing.assertEqual(len($e.limits), 0);
    }
    stopFake($f);
}

func testRetryAfterMsIsHonoured() {
    def f as Fake init startFake([
        "529\ncontent-type: application/json\nretry-after-ms: 300\nretry-after: 30\n\n" +
            ERR_OVERLOADED,
        answer(200, MODELS_PAGE2)
    ]);
    def started as int init time.unixMilliseconds(time.now());
    testing.assertEqual(len(models(fakeClient($f))), 1);
    def took as int init time.unixMilliseconds(time.now()) - $started;
    testing.assertTrue($took >= 300 and $took < 5000);
    stopFake($f);
}

func testRetryAfterMsIsCappedAndLimitsAtMost32() {
    def r as http.BytesResponse init http.BytesResponse{
        status: 429,
        headers: {"retry-after": "Fri, 31 Dec 9999 23:59:59 GMT"}
    };
    testing.assertEqual(namedWait($r), 1000000000000);
    $r.headers = {"retry-after": "Sat, 01 Jan 2200 00:00:00 GMT"};
    testing.assertEqual(namedWait($r), 1000000000000);
    def head as string init "429\ncontent-type: application/json\n";
    for (def i in 0..40) {
        $head = $head + "x-ratelimit-n" + convert.toString($i) + ": " + convert.toString($i) + "\n";
    }
    def f as Fake init startFake([$head + "\n" + ERR_RATE]);
    def c as Client init withRetries(fakeClient($f), 0);
    try {
        models($c);
        missed("a 429");
    } catch (e) {
        testing.assertEqual(len($e.limits), 32);
    }
    stopFake($f);
}

/**
 * Reset connections: accept each, read the request first unless `early`,
 * write `reply` (when not empty), then abort with a TCP reset.
 *
 * @param l {net.Listener} the listener
 * @param n {int} how many connections to take
 * @param early {bool} reset at once, before the request is read
 * @param reply {string} what to send before the reset
 * @return {int} how many connections were taken
 */
func serveResets(l as net.Listener, n as int, early as bool, reply as string) {
    for (def i in 0..$n) {
        def conn as net.Conn init net.accept($l);
        if (not $early) {
            net.readBytes($conn, 65536);
        }
        if ($reply != "") {
            net.writeBytes($conn, encoding.encode("utf-8", $reply));
            time.sleep(time.fromMilliseconds(50));
        }
        net.abort($conn);
    }
    return $n;
}

func testAResetBeforeTheRequestWasSentIsRetried() {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def addr as string init net.address($l);
    def t as task of int init spawn {
        return serveResets($l, 3, true, "");
    };
    def c as Client init withTimeout(withBaseUrl(client(KEY), "http://" + $addr), 5000);
    $c.backoffMs = 10;
    # a body too big for the socket buffers: the write meets the reset
    def big as json.Value init json.set(json.map(), "/pad", strings.replicate("x", 16000000));
    try {
        call($c, "POST", "/v1/messages", $big);
        missed("resets");
    } catch (e) {
        testing.assertEqual($e.kind, "net");
        def ne as net.NetError init $e;
        testing.assertEqual($ne.reason, "reset");
        testing.assertFalse($ne.sent);
    }
    # three attempts: the request never reached the server
    testing.assertEqual(task.wait($t), 3);
    net.close($l);
}

func testAResetAfterTheRequestOrMidAnswerIsNotRetried() {
    for (def reply in ["", "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n" + '{"id"']) {
        def l as net.Listener init net.listen("127.0.0.1:0");
        def addr as string init net.address($l);
        def t as task of int init spawn {
            return serveResets($l, 1, false, $reply);
        };
        def c as Client init withTimeout(withBaseUrl(client(KEY), "http://" + $addr), 2000);
        $c.backoffMs = 10;
        try {
            chat($c, addUserText(newRequest(DEFAULT_MODEL), "x"));
            missed("a reset");
        } catch (e) {
            testing.assertEqual($e.kind, "net");
            def ne as net.NetError init $e;
            testing.assertEqual($ne.reason, "reset");
            testing.assertTrue($ne.sent);
            testing.assertEqual($ne.replied, $reply != "");
        }
        # one connection: a second attempt would time out on the listener
        testing.assertEqual(task.wait($t), 1);
        net.close($l);
    }
}

