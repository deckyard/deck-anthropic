#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * A Message Batch: jennifer run examples/batch.j
 *
 * Sends three questions as one batch, at half the price, waits for it to
 * end (polling every 30 seconds, for up to a day) and prints each answer
 * by its custom_id. Reads the API key from ANTHROPIC_API_KEY (and a
 * gateway from ANTHROPIC_BASE_URL, when set); exits 2 when
 * a request fails.
 */
use io;
use json;
use os;

import "../src/anthropic.j" as anthropic;

if (not os.hasEnv("ANTHROPIC_API_KEY")) {
    io.eprintf("set ANTHROPIC_API_KEY first\n");
    exit 0;
}
def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
if (os.hasEnv("ANTHROPIC_BASE_URL")) {
    $c = anthropic.withBaseUrl($c, os.getEnv("ANTHROPIC_BASE_URL"));
}
def questions as map of string to string init {
    "capital-fr": "What is the capital of France? One word.",
    "capital-no": "What is the capital of Norway? One word.",
    "capital-jp": "What is the capital of Japan? One word."
};
def reqs as list of json.Value init [];
for (def id in $questions) {
    def params as json.Value init anthropic.withMaxTokens(
        anthropic.newRequest(anthropic.DEFAULT_MODEL),
        1024);
    $reqs[] = anthropic.batchRequest($id, anthropic.addUserText($params, $questions[$id]));
}
try {
    def b as json.Value init anthropic.createBatch($c, $reqs);
    def id as string init json.asString($b, "/id");
    io.printf("batch %s created\n", $id);
    $b = anthropic.waitBatch($c, $id, 30000, 86400000);
    for (def r in anthropic.batchResults($c, $id)) {
        def name as string init json.asString($r, "/custom_id");
        def type as string init json.asString($r, "/result/type");
        if ($type == "succeeded") {
            io.printf("%s: %s\n", $name, anthropic.text(json.get($r, "/result/message")));
        } else {
            io.printf("%s: %s\n", $name, $type);
        }
    }
} catch (e) {
    io.eprintf("%s\n", $e.message);
    exit 2;
}
