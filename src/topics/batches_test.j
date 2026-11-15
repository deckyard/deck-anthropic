# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# anthropic - white-box tests for the batches topic. Spliced into
# anthropic_test.j via include.

# the batch of the batch-processing guide, just created
def const BATCH_NEW as string init '{"id":"msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d","type":"message_batch","processing_status":"in_progress","request_counts":{"processing":2,"succeeded":0,"errored":0,"canceled":0,"expired":0},"ended_at":null,"created_at":"2024-09-24T18:37:24.100435Z","expires_at":"2024-09-25T18:37:24.100435Z","cancel_initiated_at":null,"results_url":null}';

# the same batch, ended
def const BATCH_ENDED as string init '{"id":"msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d","type":"message_batch","processing_status":"ended","request_counts":{"processing":0,"succeeded":2,"errored":1,"canceled":1,"expired":1},"ended_at":"2024-09-24T19:01:02.100435Z","created_at":"2024-09-24T18:37:24.100435Z","expires_at":"2024-09-25T18:37:24.100435Z","cancel_initiated_at":null,"results_url":"https://api.anthropic.com/v1/messages/batches/msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d/results"}';

# the guide's two result lines, then an errored, a canceled and an expired one
def const RESULTS as string init '{"custom_id":"my-second-request","result":{"type":"succeeded","message":{"id":"msg_014VwiXbi91y3JMjcpyGBHX5","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Hello again! It' +
    "'" + 's nice to see you. How can I assist you today? Is there anything specific you' + "'" +
    'd like to chat about or any questions you have?"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":11,"output_tokens":36}}}}
{"custom_id":"my-first-request","result":{"type":"succeeded","message":{"id":"msg_01FqfsLoHwgeFbguDgpz48m7","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Hello! How can I assist you today? Feel free to ask me any questions or let me know if there' +
    "'" + 's anything you' + "'" +
    'd like to chat about."}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":34}}}}
{"custom_id":"bad-request","result":{"type":"errored","error":{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: Field required"},"request_id":"req_011CSHoEeqs5C35K2UUqR7Ff"}}}

{"custom_id":"late-request","result":{"type":"canceled"}}
{"custom_id":"old-request","result":{"type":"expired"}}
';

/**
 * A batch request for the tests.
 *
 * @param id {string} the custom_id
 * @param say {string} the user's text
 * @return {json.Value} the request
 */
func greeting(id as string, say as string) {
    return batchRequest($id, addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 1024), $say));
}

func testBatchRequest() {
    testing.assertEqual(
        json.encode(greeting("my-first-request", "Hello, world")),
        '{"custom_id":"my-first-request","params":{"model":"claude-opus-5-5","max_tokens":1024,' +
            '"messages":[{"role":"user","content":"Hello, world"}]}}');
    for (def bad in ["", "has space", strings.repeat("x", 65)]) {
        try {
            greeting($bad, "x");
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a custom_id is 1 to 64");
        }
    }
    try {
        batchRequest(
            "a",
            withFallbacks(addUserText(withMaxTokens(newRequest(DEFAULT_MODEL), 10), "x")));
        missed("fallbacks");
    } catch (e) {
        testing.assertContains($e.message, "batches do not take fallbacks");
    }
}

func testCreateBatch() {
    def f as Fake init startFake([answer(200, BATCH_NEW)]);
    def c as Client init fakeClient($f);
    def b as json.Value init createBatch(
        $c,
        [
            greeting("my-first-request", "Hello, world"),
            greeting("my-second-request", "Hi again, friend")
        ]);
    testing.assertEqual(json.asString($b, "/id"), "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d");
    testing.assertEqual(json.asInt($b, "/request_counts/processing"), 2);
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "POST /v1/messages/batches");
    testing.assertEqual(seenHeader($seen[0], "content-type"), "application/json");
    def body as json.Value init seenBody($seen[0]);
    testing.assertEqual(json.length($body, "/requests"), 2);
    testing.assertEqual(json.asString($body, "/requests/1/custom_id"), "my-second-request");
    testing.assertEqual(
        json.asString($body, "/requests/1/params/messages/0/content"),
        "Hi again, friend");
    try {
        createBatch($c, []);
        missed("no requests");
    } catch (e) {
        testing.assertContains($e.message, "create batch: no requests");
    }
    try {
        createBatch($c, [greeting("a", "x"), greeting("a", "y")]);
        missed("twice");
    } catch (e) {
        testing.assertContains($e.message, "custom_id \"a\" is used twice");
    }
    try {
        createBatch($c, [json.decode('{"x":1}')]);
        missed("not a batch request");
    } catch (e) {
        testing.assertContains($e.message, "use batchRequest");
    }
}

func testBatchCalls() {
    def id as string init "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d";
    def page as string init '{"data":[' + BATCH_NEW + '],"has_more":false,"first_id":"' + $id +
        '","last_id":"' + $id + '"}';
    def f as Fake init startFake([
        answer(200, BATCH_NEW),
        answer(200, $page),
        answer(200, $page),
        answer(
            200,
            json.encode(json.set(json.decode(BATCH_NEW), "/processing_status", "canceling"))),
        answer(200, '{"id":"' + $id + '","type":"message_batch_deleted"}'),
        answer(404, ERR_NOT_FOUND)
    ]);
    def c as Client init fakeClient($f);
    testing.assertEqual(json.asString(batch($c, $id), "/processing_status"), "in_progress");
    testing.assertEqual(json.length(batches($c, 20, ""), "/data"), 1);
    batches($c, 1000, "msgbatch_01Prev");
    testing.assertEqual(json.asString(cancelBatch($c, $id), "/processing_status"), "canceling");
    testing.assertEqual(json.asString(deleteBatch($c, $id), "/type"), "message_batch_deleted");
    try {
        batch($c, "msgbatch_01Gone");
        missed("a 404");
    } catch (e) {
        testing.assertEqual($e.status, 404);
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "GET /v1/messages/batches/" + $id);
    testing.assertEqual(seenLine($seen[1]), "GET /v1/messages/batches?limit=20");
    testing.assertEqual(
        seenLine($seen[2]),
        "GET /v1/messages/batches?limit=1000&after_id=msgbatch_01Prev");
    testing.assertEqual(seenLine($seen[3]), "POST /v1/messages/batches/" + $id + "/cancel");
    testing.assertEqual(seenLine($seen[4]), "DELETE /v1/messages/batches/" + $id);
    for (def bad in ["", "../x", "a/b"]) {
        try {
            batch($c, $bad);
            missed($bad);
        } catch (e) {
            testing.assertContains($e.message, "a batch id is");
        }
    }
    try {
        batches($c, 0, "");
        missed("limit 0");
    } catch (e) {
        testing.assertContains($e.message, "the page size must be 1 to 1000");
    }
}

func testWaitBatch() {
    def f as Fake init startFake([answer(200, BATCH_NEW), answer(200, BATCH_ENDED)]);
    def b as json.Value init waitBatch(
        fakeClient($f),
        "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d",
        1000,
        60000);
    testing.assertEqual(json.asString($b, "/processing_status"), "ended");
    testing.assertEqual(len(stopFake($f)), 2);
    def g as Fake init startFake([
        answer(200, BATCH_NEW),
        answer(200, BATCH_NEW),
        answer(200, BATCH_NEW)
    ]);
    try {
        waitBatch(fakeClient($g), "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d", 1000, 1000);
        missed("not ended");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
        testing.assertContains($e.message, "not ended within 1000 ms");
    }
    stopFake($g);
}

func testBatchResults() {
    def f as Fake init startFake([
        "200\ncontent-type: application/binary\n\n" + RESULTS,
        "200\ncontent-type: application/binary\n\n" +
            '{"custom_id":"a","result":{"type":"succeeded"}}' + "\nnot json\n",
        "200\ncontent-type: application/binary\n\n" + '{"custom_id":"a"}'
    ]);
    def c as Client init fakeClient($f);
    def id as string init "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d";
    def results as list of json.Value init batchResults($c, $id);
    testing.assertEqual(len($results), 5);
    def byId as map of string to json.Value init {};
    for (def r in $results) {
        $byId[json.asString($r, "/custom_id")] = $r;
    }
    testing.assertEqual(json.asString($byId["my-first-request"], "/result/type"), "succeeded");
    testing.assertContains(
        text(json.get($byId["my-first-request"], "/result/message")),
        "Hello! How can I assist");
    testing.assertEqual(
        usage(json.get($byId["my-second-request"], "/result/message")).outputTokens,
        36);
    testing.assertEqual(
        json.asString($byId["bad-request"], "/result/error/error/type"),
        "invalid_request_error");
    testing.assertEqual(json.asString($byId["late-request"], "/result/type"), "canceled");
    testing.assertEqual(json.asString($byId["old-request"], "/result/type"), "expired");
    try {
        batchResults($c, $id);
        missed("a bad line");
    } catch (e) {
        testing.assertContains($e.message, "batch " + $id + " results: line 2 is not JSON");
    }
    try {
        batchResults($c, $id);
        missed("not a result");
    } catch (e) {
        testing.assertContains($e.message, "line 1 is not a batch result");
    }
    def seen as list of string init stopFake($f);
    testing.assertEqual(seenLine($seen[0]), "GET /v1/messages/batches/" + $id + "/results");
}

func testWaitBatchCutsASlowPollToTheTimeLeft() {
    def f as Fake init startFake(["SLEEP\n\n"]);
    def started as int init time.unixMillis(time.now());
    try {
        waitBatch(fakeClient($f), "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d", 1000, 1000);
        missed("a slow poll");
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
    }
    testing.assertTrue(time.unixMillis(time.now()) - $started < 2500);
    stopFake($f);
}

func testADecodeBombInTheResultsIsKindLimit() {
    def deep as string init strings.repeat("[", 2000) + strings.repeat("]", 2000);
    def f as Fake init startFake([answer(200, RESULTS + $deep + "\n"), answer(200, $deep)]);
    def c as Client init fakeClient($f);
    try {
        batchResults($c, "msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d");
        missed("a bomb line");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "line 7 is too deeply nested");
    }
    # a reply that is one: the same kind
    try {
        models($c);
        missed("a bomb reply");
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
        testing.assertContains($e.message, "models: the reply is too deeply nested");
    }
    stopFake($f);
}

