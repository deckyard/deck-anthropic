#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.28.0
# pragma-jennifer-capability: net

/**
 * A tool loop: jennifer run examples/tools.j
 *
 * Claude answers a question about stock levels by calling a tool that
 * reads a stock table. Jennifer has no closures, so the table reaches the
 * handler as the context of `runToolsWith`. Reads the API key from
 * ANTHROPIC_API_KEY (and a gateway from ANTHROPIC_BASE_URL, when set);
 * exits 2 when a request fails.
 */
use convert;
use io;
use json;
use os;

import "../src/anthropic.j" as anthropic;

/**
 * Run one tool call.
 *
 * @param name {string} the tool Claude asked for
 * @param input {json.Value} its input
 * @param stock {json.Value} the context: item -> count
 * @return {json.Value} the result
 */
func runTool(name as string, input as json.Value, stock as json.Value) {
    if ($name != "stock_level") {
        return anthropic.toolError("no tool " + $name);
    }
    def item as string init json.asString($input, "/item");
    if (json.typeOf($stock, "/" + $item) != "int") {
        return anthropic.toolError("unknown item " + $item);
    }
    def count as int init json.asInt($stock, "/" + $item);
    return json.decode('{"item":"' + $item + '","count":' + convert.toString($count) + '}');
}

if (not os.hasEnv("ANTHROPIC_API_KEY")) {
    io.eprintf("set ANTHROPIC_API_KEY first\n");
    exit 0;
}
def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
if (os.hasEnv("ANTHROPIC_BASE_URL")) {
    $c = anthropic.withBaseUrl($c, os.getEnv("ANTHROPIC_BASE_URL"));
}
def schema as json.Value init json.decode('{"type":"object","required":["item"],' +
    '"properties":{"item":{"type":"string"}},"additionalProperties":false}');
def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
$req = anthropic.addTool(
    $req,
    anthropic.withStrict(
        anthropic.tool("stock_level", "How many of an item are in stock.", $schema)));
$req = anthropic.addUserText(
    $req,
    "Which of bolts, nuts and washers need reordering? " +
        "Below 100 means reorder.");
try {
    def stock as json.Value init json.decode('{"bolts": 1200, "nuts": 80, "washers": 0}');
    def run as anthropic.ToolRun init anthropic.runToolsWith($c, $req, runTool, $stock, 10);
    if ($run.stopped == "maxTurns") {
        io.printf("(stopped after %d requests)\n", $run.turns);
    }
    io.printf("%s\n", anthropic.text($run.reply));
    def out as int init $run.usage.outputTokens;
    io.printf("[%d tool calls in %d requests, %d tokens out]\n", $run.calls, $run.turns, $out);
} catch (e) {
    io.eprintf("%s\n", $e.message);
    exit 2;
}
