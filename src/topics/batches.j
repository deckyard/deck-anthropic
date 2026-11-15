# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# anthropic - batches: the Message Batches API, from creating a batch to
# reading its JSONL results. Spliced into anthropic.j via include.

/** The most requests in one batch. */
export def const MAX_BATCH_REQUESTS as int init 100000;

# a batch request's custom_id
def const CUSTOM_ID as string init '^[a-zA-Z0-9_-]{1,64}$';

/**
 * One request of a batch: `{"custom_id", "params"}`. Results come back in
 * any order; match them by `custom_id`.
 *
 * @param customId {string} 1 to 64 letters, digits, `_` and `-`, unique in the batch
 * @param params {json.Value} a Messages request, as for `chat`; server-side `fallbacks` are refused in a batch
 * @return {json.Value} the batch request
 * @throws {AnthropicError} kind "anthropic" for a malformed id or request
 * @example
 *   $reqs[] = anthropic.batchRequest("q-1", anthropic.addUserText(anthropic.newRequest(anthropic.DEFAULT_MODEL), "Hi"));
 */
export func batchRequest(customId as string, params as json.Value) {
    if (not regex.matches(CUSTOM_ID, $customId)) {
        fail("a custom_id is 1 to 64 letters, digits, _ and -, got " + shown($customId));
    }
    checkRequest($params, "batch request " + $customId);
    if (json.typeOf($params, "/max_tokens") != "int") {
        fail("batch request " + $customId + ": the request has no max_tokens");
    }
    if (json.has($params, "/fallbacks")) {
        fail("batch request " + $customId + ": batches do not take fallbacks");
    }
    return json.set(json.set(json.map(), "/custom_id", $customId), "/params", $params);
}

/**
 * Refuse a batch reply that is not a `message_batch` object.
 *
 * @param v {json.Value} the reply
 * @param what {string} the request, for messages
 * @return {json.Value} the batch
 */
func batchReply(v as json.Value, what as string) {
    if (json.typeOf($v, "/id") != "string" or json.typeOf($v, "/processing_status") != "string") {
        fail($what + ": the reply is not a message batch");
    }
    return $v;
}

/**
 * Create a Message Batch: `POST /v1/messages/batches`. The requests run
 * asynchronously at half the price, most within an hour, all within 24
 * hours.
 *
 * @param c {Client} the client
 * @param requests {list of json.Value} 1 to 100000 requests from `batchRequest`, with unique ids
 * @return {json.Value} the batch: `id`, `processing_status` (`in_progress`), `request_counts`, `created_at`, `expires_at`, ...
 * @throws {AnthropicError} kind "anthropic" for no requests, a repeated custom_id, a status that is not 2xx, or a failed request
 * @throws {Error} kind "limit" for more than `MAX_BATCH_REQUESTS` requests
 * @example
 *   def b as json.Value init anthropic.createBatch($c, $reqs);
 *   io.printf("%s\n", json.asString($b, "/id"));
 */
export func createBatch(c as Client, requests as list of json.Value) {
    if (len($requests) == 0) {
        fail("create batch: no requests");
    }
    if (len($requests) > MAX_BATCH_REQUESTS) {
        failLimit(io.sprintf(
            "create batch: %d requests, over %d",
            len($requests),
            MAX_BATCH_REQUESTS));
    }
    def seen as map of string to bool init {};
    for (def r in $requests) {
        if (json.typeOf($r, "/custom_id") != "string" or json.typeOf($r, "/params") != "map") {
            fail("create batch: a request is not a custom_id with params: use batchRequest");
        }
        def id as string init json.asString($r, "/custom_id");
        if (maps.has($seen, $id)) {
            fail("create batch: custom_id " + shown($id) + " is used twice");
        }
        $seen[$id] = true;
    }
    def body as json.Value init json.set(json.map(), "/requests", json.list($requests));
    return batchReply(
        api($c, "POST", "/v1/messages/batches", json.encode($body), "create batch"),
        "create batch");
}

/**
 * A batch: its `processing_status` (`in_progress`, `canceling`, `ended`)
 * and `request_counts`.
 *
 * @param c {Client} the client
 * @param id {string} the batch id, such as `msgbatch_01HkcTjaV5uDC8jWR4ZsDV8d`
 * @return {json.Value} the batch
 * @throws {AnthropicError} kind "anthropic" with status 404 for an unknown batch, or when the request fails
 */
export func batch(c as Client, id as string) {
    checkId($id, "a batch id");
    return batchReply(
        api($c, "GET", "/v1/messages/batches/" + $id, "", "batch " + $id),
        "batch " + $id);
}

/**
 * One page of batches, newest first.
 *
 * @param c {Client} the client
 * @param limit {int} 1 to 1000 batches
 * @param afterId {string} `""` for the first page, else the `last_id` of the page before
 * @return {json.Value} the page: `data` (batches), `has_more`, `first_id`, `last_id`
 * @throws {AnthropicError} kind "anthropic" when the status is not 2xx or the request fails
 * @example
 *   def page as json.Value init anthropic.batches($c, 20, "");
 */
export func batches(c as Client, limit as int, afterId as string) {
    checkRange($limit, 1, 1000, "the page size");
    def path as string init "/v1/messages/batches?limit=" + convert.toString($limit);
    if ($afterId != "") {
        checkId($afterId, "afterId");
        $path = $path + "&after_id=" + $afterId;
    }
    def v as json.Value init api($c, "GET", $path, "", "batches");
    if (json.typeOf($v, "/data") != "list") {
        fail("batches: the reply has no data list");
    }
    return $v;
}

/**
 * Cancel a batch that is still processing. It goes `canceling`, then
 * `ended`, with the results of the requests that finished.
 *
 * @param c {Client} the client
 * @param id {string} the batch id
 * @return {json.Value} the batch
 * @throws {AnthropicError} kind "anthropic" when the status is not 2xx or the request fails
 */
export func cancelBatch(c as Client, id as string) {
    checkId($id, "a batch id");
    def what as string init "cancel batch " + $id;
    return batchReply(api($c, "POST", "/v1/messages/batches/" + $id + "/cancel", "", $what), $what);
}

/**
 * Delete an ended batch and its results (cancel one in progress first).
 *
 * @param c {Client} the client
 * @param id {string} the batch id
 * @return {json.Value} `{"id", "type": "message_batch_deleted"}`
 * @throws {AnthropicError} kind "anthropic" when the status is not 2xx or the request fails
 */
export func deleteBatch(c as Client, id as string) {
    checkId($id, "a batch id");
    return api($c, "DELETE", "/v1/messages/batches/" + $id, "", "delete batch " + $id);
}

/**
 * Poll a batch until it has ended. Each poll's deadline is cut to the
 * time left, so the wait ends near `timeoutMs` (a poll still retries a
 * 5xx as the client says).
 *
 * @param c {Client} the client
 * @param id {string} the batch id
 * @param pollMs {int} the wait between polls, 1000 to 3600000 milliseconds
 * @param timeoutMs {int} how long to wait in all, 1000 to 172800000 milliseconds
 * @return {json.Value} the ended batch
 * @throws {AnthropicError} kind "anthropic" when a poll fails
 * @throws {Error} kind "timeout" when it has not ended in time
 * @example
 *   $b = anthropic.waitBatch($c, json.asString($b, "/id"), 30000, 86400000);
 */
export func waitBatch(c as Client, id as string, pollMs as int, timeoutMs as int) {
    checkRange($pollMs, 1000, 3600000, "the poll interval");
    checkRange($timeoutMs, 1000, 172800000, "the timeout");
    def deadline as int init time.unixMillis(time.now()) + $timeoutMs;
    def poller as Client init $c;
    while (true) {
        # a poll may take no longer than the time left (at least 1 s), and
        # a poll that ran out of it is not retried
        def room as int init math.max(1000, $deadline - time.unixMillis(time.now()));
        if ($room < $c.timeoutMs) {
            $poller.timeoutMs = $room;
        }
        def b as json.Value init batch($poller, $id);
        if (json.asString($b, "/processing_status") == "ended") {
            return $b;
        }
        def left as int init $deadline - time.unixMillis(time.now());
        if ($left <= 0) {
            failTimeout(io.sprintf("batch %s: not ended within %d ms", $id, $timeoutMs));
        }
        time.sleep(time.fromMilliseconds(math.min($pollMs, $left)));
    }
}

/**
 * The results of an ended batch, one per request, in any order. Each is
 * `{"custom_id", "result": {"type", ...}}`: `succeeded` carries the
 * `message` (a reply, as `chat` returns), `errored` the `error`,
 * `canceled` and `expired` nothing more.
 *
 * @param c {Client} the client
 * @param id {string} the batch id
 * @return {list of json.Value} the results
 * @throws {AnthropicError} kind "anthropic" when the status is not 2xx, the request fails, or a line is not a result
 * @throws {Error} kind "limit" when the results are over the client's cap (`withMaxBytes`)
 * @example
 *   for (def r in anthropic.batchResults($c, $id)) {
 *       if (json.asString($r, "/result/type") == "succeeded") {
 *           io.printf("%s: %s\n", json.asString($r, "/custom_id"), anthropic.text(json.get($r, "/result/message")));
 *       }
 *   }
 */
export func batchResults(c as Client, id as string) {
    checkId($id, "a batch id");
    def what as string init "batch " + $id + " results";
    def r as http.BytesResponse init exchange(
        $c,
        "GET",
        "/v1/messages/batches/" + $id + "/results",
        "",
        $what);
    def text as string init "";
    try {
        $text = convert.stringFromBytes("utf-8", $r.body);
    } catch (e) {
        fail($what + ": the reply is not UTF-8");
    }
    return parseResults($text, $what);
}

/**
 * JSONL results, one JSON object per line; blank lines are skipped.
 *
 * @param text {string} the JSONL
 * @param what {string} the request, for messages
 * @return {list of json.Value} the results
 */
func parseResults(text as string, what as string) {
    def out as list of json.Value init [];
    def n as int init 0;
    for (def line in strings.split($text, "\n")) {
        $n = $n + 1;
        if ($line == "" or $line == "\r" or strings.trim($line) == "") {
            continue;
        }
        def v as json.Value;
        try {
            $v = json.decode($line);
        } catch (e) {
            if ($e.kind == "limit") {
                failLimit(io.sprintf(
                    "%s: line %d is too deeply nested or has too many values",
                    $what,
                    $n));
            }
            fail(io.sprintf("%s: line %d is not JSON", $what, $n));
        }
        if (json.typeOf($v, "/custom_id") != "string" or json.typeOf($v, "/result/type") != "string") {
            fail(io.sprintf("%s: line %d is not a batch result", $what, $n));
        }
        $out[] = $v;
    }
    return $out;
}
