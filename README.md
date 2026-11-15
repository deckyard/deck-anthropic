# @deckyard/anthropic

[![test](https://github.com/deckyard/deck-anthropic/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-anthropic/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-anthropic/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-anthropic)](https://github.com/deckyard/deck-anthropic/releases/latest)

A client for Anthropic's Claude Messages API for
[Jennifer](https://jennifer-lang.dev/) programs, over plain HTTPS: messages
with text, image and PDF content, tool use with a tool loop, adaptive
thinking and effort, prompt caching, structured outputs, token counting,
the Models API and the Message Batches API. Requests and replies are
`json.Value` documents in the API's own shape.

**[Documentation](https://deckyard.github.io/deck-anthropic/)**

## Install

```sh
jvc add @deckyard/anthropic
```

This vendors the deck to `vendor/<scope>/anthropic/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-anthropic-<version>.tar.gz`) there.

## Usage

```jennifer
use io;
use json;
use os;

import "@deckyard/anthropic/" as anthropic;

def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
def req as json.Value init anthropic.newRequest(anthropic.DEFAULT_MODEL);
$req = anthropic.withEffort(anthropic.addUserText($req, "Explain TCP slow start briefly."), "low");
def reply as json.Value init anthropic.chat($c, $req);
io.printf("%s\n", anthropic.text($reply));
```

A tool loop, with a handler the program defines and a context passed to
it (Jennifer has no closures):

```jennifer
def run as anthropic.ToolRun init anthropic.runToolsWith($c, $req, runTool, $context, 10);
io.printf("%s (%d tool calls)\n", anthropic.text($run.reply), $run.calls);
```

The examples in `examples/` (`chat.j`, `tools.j`, `batch.j`) read the key
from `ANTHROPIC_API_KEY`.

## Requirements

Jennifer 0.26.0 or newer, the default `jennifer` binary (the deck needs the
`net` capability, so not `jennifer-tiny`), network access to
`api.anthropic.com` and an API key from the
[Claude Console](https://platform.claude.com). Replies are not streamed (see
the documentation for what is not covered yet).

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/anthropic_test.j   # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

The tests need no key: a loopback fake answers with replies in the shape of
Anthropic's API reference.

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.
