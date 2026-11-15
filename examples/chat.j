#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Ask Claude one question: jennifer run examples/chat.j "Why is the sky blue?"
 *
 * Reads the API key from ANTHROPIC_API_KEY (and a gateway from
 * ANTHROPIC_BASE_URL, when set). Prints the answer and the token
 * counts; a refusal prints its category. Exits 2 when the request fails.
 */
use io;
use json;
use os;

import "../src/anthropic.j" as anthropic;

if (not os.hasEnv("ANTHROPIC_API_KEY")) {
    io.eprintf("set ANTHROPIC_API_KEY first\n");
    exit 0;
}
def question as string init "Name the four largest moons of Jupiter in one line.";
if (len(os.ARGS) > 1) {
    $question = os.ARGS[1];
}
def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
if (os.hasEnv("ANTHROPIC_BASE_URL")) {
    $c = anthropic.withBaseUrl($c, os.getEnv("ANTHROPIC_BASE_URL"));
}
def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
$req = anthropic.withSystem($req, "Answer briefly.");
$req = anthropic.withEffort($req, "low");
$req = anthropic.addUserText($req, $question);
try {
    def reply as json.Value init anthropic.chat($c, $req);
    if (anthropic.stopReason($reply) == "refusal") {
        io.printf("refused (%s)\n", anthropic.refusalCategory($reply));
    } else {
        io.printf("%s\n", anthropic.text($reply));
    }
    def u as anthropic.Usage init anthropic.usage($reply);
    io.printf("[%d in, %d cached, %d out]\n", $u.inputTokens, $u.cachedTokens, $u.outputTokens);
} catch (e) {
    io.eprintf("%s\n", $e.message);
    exit 2;
}
