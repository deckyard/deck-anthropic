<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Message batches

The Message Batches API runs many Messages requests asynchronously at half
the price. Most batches end within an hour, all within 24 hours; results are
kept for 29 days. A batch holds up to 100000 requests (`MAX_BATCH_REQUESTS`)
or 256 MB.

## Creating a batch

Each request is a Messages request with a `custom_id` of its own:

```jennifer
def reqs as list of json.Value init [];
for (def id in $questions) {
    def params as json.Value init anthropic.withMaxTokens(anthropic.newRequest(anthropic.DEFAULT_MODEL), 1024);
    $reqs[] = anthropic.batchRequest($id, anthropic.addUserText($params, $questions[$id]));
}
def b as json.Value init anthropic.createBatch($c, $reqs);
def batchId as string init json.asString($b, "/id");
```

A `custom_id` is 1 to 64 letters, digits, `_` and `-`, unique in the batch.
The API checks each request's parameters only when the batch has ended, so
try one with `chat` first. Server-side `fallbacks` are refused in a batch.

## Waiting

A batch's `processing_status` is `in_progress`, then `ended`
(`canceling` in between after a cancel); `request_counts` counts the
requests processing, succeeded, errored, canceled and expired.

```jennifer
$b = anthropic.waitBatch($c, $batchId, 60000, 86400000);
io.printf("%d succeeded\n", json.asInt($b, "/request_counts/succeeded"));
```

`waitBatch(c, id, pollMs, timeoutMs)` polls every `pollMs` until the batch
has ended, and is kind `"timeout"` after `timeoutMs`; a slow poll is cut to
the time left, so the wait ends close to `timeoutMs`. A program that should
not wait keeps the id and calls `batch(c, id)` later.

## Results

`batchResults(c, id)` reads the JSONL results of an ended batch, one per
request, **in any order**: match them by `custom_id`.

```jennifer
for (def r in anthropic.batchResults($c, $batchId)) {
    def id as string init json.asString($r, "/custom_id");
    match (json.asString($r, "/result/type")) {
        when "succeeded" {
            io.printf("%s: %s\n", $id, anthropic.text(json.get($r, "/result/message")));
        }
        when "errored" {
            io.printf("%s: %s\n", $id, json.asString($r, "/result/error/error/type"));
        }
        else {
            io.printf("%s: canceled or expired\n", $id);
        }
    }
}
```

| `result.type` | Carries |
|---|---|
| `succeeded` | `message`: a reply, as `chat` returns it |
| `errored` | `error`: `{"type": "error", "error": {"type", "message"}}`; an `invalid_request_error` will fail again as it is |
| `canceled` | nothing: the batch was cancelled first |
| `expired` | nothing: not processed within 24 hours |

The results are read whole, under the client's cap (64 MiB by default); a
big batch needs `withMaxBytes`, up to 1 GiB, or several smaller batches.
Reading whole takes several times the body in memory (the text, its lines,
the decoded results), so prefer smaller batches to a cap near 1 GiB.

## Listing, cancelling, deleting

```jennifer
def page as json.Value init anthropic.batches($c, 20, "");
if (json.asBool($page, "/has_more")) {
    $page = anthropic.batches($c, 20, json.asString($page, "/last_id"));
}
anthropic.cancelBatch($c, $batchId);
anthropic.deleteBatch($c, $batchId);
```

A cancelled batch goes `canceling`, then `ended`, with the results of the
requests that finished. Only an ended batch can be deleted.
