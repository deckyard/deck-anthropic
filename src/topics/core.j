# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

# anthropic - core: the client and its settings, errors, the HTTP exchange
# with its deadline, cap and retries, JSON replies, `call` and the Models
# API. Spliced into anthropic.j via include.

/** Where the Claude API is served. */
export def const DEFAULT_BASE_URL as string init "https://api.anthropic.com";

/**
 * The `anthropic-version` a fresh client sends. On `2026-10-21` a Messages
 * request with `temperature`, `top_p` or `top_k` is a 400 on every model;
 * `withApiVersion` picks another version.
 */
export def const API_VERSION as string init "2026-10-21";

/** The model the docs and examples use. */
export def const DEFAULT_MODEL as string init "claude-opus-5-5";

/**
 * How long one attempt may take, in milliseconds: 10 minutes. A reply is
 * not streamed, so a long generation arrives only when it is complete.
 */
export def const DEFAULT_TIMEOUT_MS as int init 600000;

/** How often a fresh client retries a 408, 409, 429 or 5xx reply, or a request the network failed to send. */
export def const DEFAULT_RETRIES as int init 2;

/**
 * The longest wait a reply may ask for (`retry-after-ms` or `retry-after`),
 * in milliseconds; a longer one is not taken: the error is thrown at once,
 * with the wait in `retryAfterMs`.
 */
export def const MAX_RETRY_WAIT_MS as int init 60000;

/** The largest reply read, in bytes: 64 MiB. */
export def const DEFAULT_MAX_BYTES as int init 67108864;

/**
 * The largest tool input the tool loop hands to a handler, in bytes of its
 * JSON: 1 MiB. A larger one is answered with a `toolError`.
 */
export def const DEFAULT_MAX_TOOL_INPUT as int init 1048576;

# the first wait before a retry without `retry-after`, doubled each time
def const BACKOFF_MS as int init 500;

# the largest wait `retryAfterMs` reports
def const MAX_NAMED_WAIT_MS as int init 1000000000000;

# the most rate-limit headers an error keeps
def const MAX_LIMITS as int init 32;

# the longest wait between retries without `retry-after`
def const MAX_BACKOFF_MS as int init 8000;

# the most pages `models` reads
def const MAX_PAGES as int init 100;

# what an error message never shows: control characters and the bidi controls
# that reorder a terminal line
def const UNSHOWN as string init '[\x00-\x1f\x7f-\x9f\x{061c}\x{200b}-\x{200f}\x{2028}-\x{202e}\x{2060}-\x{2069}\x{feff}]';

# an API key: printable ASCII without spaces
def const KEY_FORM as string init '^[\x21-\x7e]{1,512}$';

# a beta name, such as server-side-fallback-2026-07-01
def const BETA_FORM as string init '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$';

# a model, batch or other object id in a path
def const ID_FORM as string init '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}$';

# the hosts plain http is allowed to without `withPlainHttp`
def const LOOPBACK as list of string init ["127.0.0.1", "localhost", "[::1]"];

/**
 * How to reach the API and as whom. Build it with `client`, change it with
 * the `with*` functions. It holds the API key: do not print it.
 *
 * @field apiKey {string} the API key, sent as `x-api-key`
 * @field baseUrl {string} the API's URL without a trailing slash, `DEFAULT_BASE_URL` unless changed
 * @field version {string} the `anthropic-version` sent
 * @field betas {list of string} the `anthropic-beta` names sent with every request
 * @field tls {http.TlsOptions} certificate checks for an `https` URL
 * @field allowPlainHttp {bool} whether plain `http` to another machine is allowed (the key then crosses the network in clear)
 * @field timeoutMs {int} how long one attempt may take
 * @field retries {int} how often a retryable failure is retried
 * @field backoffMs {int} the first wait before a retry without `retry-after`, doubled for each further one
 * @field maxBytes {int} the largest reply read
 * @field maxToolInput {int} the largest tool input, in bytes of its JSON, the tool loop hands to a handler
 */
export def struct Client {
    apiKey as string,
    baseUrl as string,
    version as string,
    betas as list of string,
    tls as http.TlsOptions,
    allowPlainHttp as bool,
    timeoutMs as int,
    retries as int,
    backoffMs as int,
    maxBytes as int,
    maxToolInput as int
};

/**
 * Every failure of kind `anthropic`: a reply that is not 2xx, a reply that
 * is not what the API sends, a request this deck refuses to send, a server
 * it cannot reach.
 *
 * @field kind {string} always "anthropic"
 * @field message {string} `anthropic: <request>: <why>`, with the status, type and request id when the server answered
 * @field status {int} the HTTP status, such as 400, 429 or 529; 0 when no reply was read
 * @field type {string} Anthropic's `error.type`, such as `invalid_request_error`, `rate_limit_error` or `overloaded_error`; `""` without one
 * @field requestId {string} the `request-id` header (or the body's `request_id`), `""` without one
 * @field retryAfterMs {int} how long the server asked to wait (`retry-after-ms`, else `retry-after` in seconds or as an HTTP date), in milliseconds, at most 1e12; 0 when it named no wait
 * @field limits {map of string to string} the reply's rate-limit headers (at most 32), names lower-cased, values cleaned: `anthropic-ratelimit-*`, `x-ratelimit-*`, `retry-after`, `retry-after-ms`; empty without a reply
 */
export def struct AnthropicError {
    kind as string,
    message as string,
    status as int,
    type as string,
    requestId as string,
    retryAfterMs as int,
    limits as map of string to string
};

/**
 * The result of one attempt: a reply, or a transport failure that left the
 * request unsent and may be retried. Every other failure is thrown.
 *
 * @field response {http.BytesResponse} the reply when not `failed`
 * @field failed {bool} whether the attempt failed before the request was sent
 * @field netError {net.NetError} that failure, with `sent` false
 */
def struct Attempt {
    response as http.BytesResponse,
    failed as bool,
    netError as net.NetError
};

/**
 * Throw a failure that has no reply behind it.
 *
 * @param message {string} what went wrong, without the `anthropic: ` prefix
 * @throws {AnthropicError} kind "anthropic", status 0, always
 */
func fail(message as string) {
    throw AnthropicError{
        kind: "anthropic",
        message: "anthropic: " + $message,
        status: 0,
        type: "",
        requestId: "",
        retryAfterMs: 0,
        limits: {}
    };
}

/**
 * Throw a reached cap: kind "limit".
 *
 * @param message {string} what was over the cap, without the `anthropic: ` prefix
 * @throws {Error} kind "limit", always
 */
func failLimit(message as string) {
    throw Error{kind: "limit", message: "anthropic: " + $message};
}

/**
 * Throw a deadline that passed: kind "timeout".
 *
 * @param message {string} what took too long, without the `anthropic: ` prefix
 * @throws {Error} kind "timeout", always
 */
func failTimeout(message as string) {
    throw Error{kind: "timeout", message: "anthropic: " + $message};
}

/**
 * Server-controlled text made safe for a message: control and bidi
 * characters as `?`, at most a number of characters.
 *
 * @param s {string} the text
 * @param most {int} the most characters kept
 * @return {string} the text
 */
func cleaned(s as string, most as int) {
    def text as string init $s;
    if (len($text) > $most) {
        $text = $text[..$most] + "...";
    }
    return regex.replace(UNSHOWN, $text, "?");
}

/**
 * Text quoted for an error message.
 *
 * @param s {string} the text
 * @return {string} the text in double quotes, cleaned and cut at 200 characters
 */
func shown(s as string) {
    return "\"" + cleaned($s, 200) + "\"";
}

/**
 * Text with the client's API key replaced, so that no message shows it even
 * when a server or proxy echoes it.
 *
 * @param c {Client} the client
 * @param s {string} the text
 * @return {string} the text, the key as `<api key>`
 */
func scrub(c as Client, s as string) {
    if (len($c.apiKey) >= 8 and strings.contains($s, $c.apiKey)) {
        return strings.replace($s, $c.apiKey, "<api key>");
    }
    return $s;
}

/**
 * Refuse an int outside a range.
 *
 * @param value {int} the value
 * @param low {int} the smallest allowed
 * @param high {int} the largest allowed
 * @param what {string} what the value is
 */
func checkRange(value as int, low as int, high as int, what as string) {
    if ($value < $low or $value > $high) {
        fail(io.sprintf("%s must be %d to %d, got %d", $what, $low, $high, $value));
    }
}

/**
 * Refuse an id that would not be one path segment.
 *
 * @param id {string} the id
 * @param what {string} what it is
 */
func checkId(id as string, what as string) {
    if (not regex.matches(ID_FORM, $id)) {
        fail($what + " is 1 to 128 letters, digits and ._:@-, got " + shown($id));
    }
}

/**
 * A client for the Claude API with an API key from the Console. The key is
 * sent as `x-api-key` and never shown in a message.
 *
 * @param apiKey {string} the API key, such as `os.getEnv("ANTHROPIC_API_KEY")`
 * @return {Client} the client
 * @throws {AnthropicError} kind "anthropic" when the key is empty or not printable ASCII without spaces
 * @example
 *   def c as anthropic.Client init anthropic.client(os.getEnv("ANTHROPIC_API_KEY"));
 */
export func client(apiKey as string) {
    if (not regex.matches(KEY_FORM, $apiKey)) {
        fail("an API key is 1 to 512 printable ASCII characters without spaces (is ANTHROPIC_API_KEY set?)");
    }
    return Client{
        apiKey: $apiKey,
        baseUrl: DEFAULT_BASE_URL,
        version: API_VERSION,
        betas: [],
        tls: http.TlsOptions{},
        allowPlainHttp: false,
        timeoutMs: DEFAULT_TIMEOUT_MS,
        retries: DEFAULT_RETRIES,
        backoffMs: BACKOFF_MS,
        maxBytes: DEFAULT_MAX_BYTES,
        maxToolInput: DEFAULT_MAX_TOOL_INPUT
    };
}

/**
 * Refuse a base URL that is not absolute http(s) without query or fragment.
 *
 * @param baseUrl {string} the URL, without a trailing slash
 * @return {regex.Match} the URL's parts: scheme, host, port
 */
func checkUrlForm(baseUrl as string) {
    def m as regex.Match init regex.find(
        '^(https?)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*)(:([0-9]{1,5}))?(/[A-Za-z0-9._~-]+)*$',
        $baseUrl);
    if ($m.start < 0 or regex.matches('/\.+(/|$)', $baseUrl) or
        ($m.groups[6] != "" and
        (convert.toInt($m.groups[6]) < 1 or convert.toInt($m.groups[6]) > 65535))) {
        fail("a base URL is http(s)://host[:port][/path], port 1 to 65535, the path plain segments, got " +
            shown($baseUrl));
    }
    return $m;
}

/**
 * Refuse a base URL `checkUrlForm` refuses, or plain http to another
 * machine without `allowPlainHttp`.
 *
 * @param c {Client} the client
 */
func checkUrl(c as Client) {
    def m as regex.Match init checkUrlForm($c.baseUrl);
    if ($m.groups[0] == "http" and not $c.allowPlainHttp and
        not lists.contains(LOOPBACK, strings.lower($m.groups[1]))) {
        fail("plain http to " + shown($m.groups[1]) +
            " would send the API key in clear: use https, or withPlainHttp");
    }
}

/**
 * The client with another API root: a gateway or proxy that serves the
 * Claude API, or a fake for tests. Plain `http` to another machine is
 * refused when a request is sent, unless `withPlainHttp`.
 *
 * @param c {Client} the client
 * @param baseUrl {string} the root, such as `https://llm-gateway.example.org/anthropic`; the deck appends `/v1/...`
 * @return {Client} the client
 * @throws {AnthropicError} kind "anthropic" when the URL is not an absolute http(s) URL without query or fragment
 */
export func withBaseUrl(c as Client, baseUrl as string) {
    def base as string init $baseUrl;
    while (strings.endsWith($base, "/")) {
        $base = $base[..len($base) - 1];
    }
    checkUrlForm($base);
    $c.baseUrl = $base;
    return $c;
}

/**
 * The client allowed to use plain `http` to another machine. The API key
 * crosses the network in clear.
 *
 * @param c {Client} the client
 * @return {Client} the client
 */
export func withPlainHttp(c as Client) {
    $c.allowPlainHttp = true;
    return $c;
}

/**
 * The client with certificate options for `https`: `caCert` for a gateway
 * with a certificate from a private CA.
 *
 * @param c {Client} the client
 * @param tls {http.TlsOptions} the options (`caCert`, `skipVerify`)
 * @return {Client} the client
 */
export func withTls(c as Client, tls as http.TlsOptions) {
    $c.tls = $tls;
    return $c;
}

/**
 * The client with another `anthropic-version`, such as `2023-06-01` for
 * code that still sends sampling parameters.
 *
 * @param c {Client} the client
 * @param version {string} a date `YYYY-MM-DD`
 * @return {Client} the client
 * @throws {AnthropicError} kind "anthropic" when it is not a date
 */
export func withApiVersion(c as Client, version as string) {
    if (not regex.matches('^[0-9]{4}-[0-9]{2}-[0-9]{2}$', $version)) {
        fail("an API version is a date YYYY-MM-DD, got " + shown($version));
    }
    $c.version = $version;
    return $c;
}

/**
 * The client sending these beta names as `anthropic-beta` with every
 * request, replacing the ones it had. For one request only, pass
 * `withBetas($c, [...])` to that call: the client is a value.
 *
 * @param c {Client} the client
 * @param betas {list of string} the names, such as `BETA_FALLBACKS`; `[]` for none
 * @return {Client} the client
 * @throws {AnthropicError} kind "anthropic" when a name is not letters, digits and ._-
 * @example
 *   def reply as json.Value init anthropic.chat(anthropic.withBetas($c, [anthropic.BETA_FALLBACKS]), $req);
 */
export func withBetas(c as Client, betas as list of string) {
    for (def b in $betas) {
        if (not regex.matches(BETA_FORM, $b)) {
            fail("a beta name is 1 to 128 letters, digits and ._-, got " + shown($b));
        }
    }
    $c.betas = $betas;
    return $c;
}

/**
 * The client with another deadline for each attempt.
 *
 * @param c {Client} the client
 * @param ms {int} 1000 to 86400000 milliseconds
 * @return {Client} the client
 */
export func withTimeout(c as Client, ms as int) {
    checkRange($ms, 1000, 86400000, "the timeout");
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * The client retrying a 408, 409, 429 or 5xx reply, or a `net.NetError`
 * whose `sent` is false (refused, DNS, TLS, a reset before the whole
 * request was written), this often. A deadline that passed is not retried,
 * nor a request that was sent and then reset or closed, whatever the
 * method: it may have run (no duplicate batches or charges).
 *
 * @param c {Client} the client
 * @param retries {int} 0 to 10
 * @return {Client} the client
 */
export func withRetries(c as Client, retries as int) {
    checkRange($retries, 0, 10, "the retry count");
    $c.retries = $retries;
    return $c;
}

/**
 * The client with another cap on replies (a big batch's JSONL results may
 * need more than the default).
 *
 * @param c {Client} the client
 * @param most {int} 65536 to 1073741824 bytes
 * @return {Client} the client
 */
export func withMaxBytes(c as Client, most as int) {
    checkRange($most, 65536, 1073741824, "the largest reply");
    $c.maxBytes = $most;
    return $c;
}

/**
 * The client with another cap on the tool input the tool loop hands to a
 * handler, measured as the input's JSON. A larger input is answered with a
 * `toolError` and the handler is not called.
 *
 * @param c {Client} the client
 * @param most {int} 1024 to 1073741824 bytes
 * @return {Client} the client
 */
export func withMaxToolInput(c as Client, most as int) {
    checkRange($most, 1024, 1073741824, "the largest tool input");
    $c.maxToolInput = $most;
    return $c;
}

/**
 * Send one attempt within the deadline.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param url {string} the URL
 * @param headers {map of string to string} the headers
 * @param body {string} the body, `""` for none
 * @param what {string} the request, for messages
 * @return {Attempt} the reply, or why there was none
 */
func attempt(
    c as Client,
    method as string,
    url as string,
    headers as map of string to string,
    body as string,
    what as string) {
    def timeoutMs as int init $c.timeoutMs;
    def maxBytes as int init $c.maxBytes;
    def tls as http.TlsOptions init $c.tls;
    def t as task of http.BytesResponse init spawn {
        return http.requestWithBytes($method, $url, $headers, $body, $timeoutMs, $maxBytes, $tls);
    };
    def none as net.NetError;
    try {
        return Attempt{response: task.waitTimeout($t, $timeoutMs), failed: false, netError: $none};
    } catch (e) {
        if ($e.kind == "cancelled") {
            task.cancel($t);
            task.discard($t);
            throw $e;
        }
        if ($e.kind == "timeout") {
            task.cancel($t);
            task.discard($t);
            failTimeout(io.sprintf("%s: no reply within %d ms", $what, $timeoutMs));
        }
        if ($e.kind == "limit") {
            failLimit(io.sprintf("%s: the reply is over %d bytes", $what, $maxBytes));
        }
        if ($e.kind == "net") {
            # refused, unreachable, DNS, TLS, or reset or closed before the
            # whole request was written: it never reached the server, so it
            # may be sent again. Once sent, a reset or a close may come
            # after the server acted on it: passed on, never resent
            def ne as net.NetError init $e;
            if ($ne.sent or $ne.replied) {
                throw $e;
            }
            return Attempt{response: http.BytesResponse{}, failed: true, netError: $ne};
        }
        def why as string init cleaned(scrub($c, $e.message), 300);
        if ($e.kind == "closed") {
            # the server closed the connection after part of its answer
            throw Error{
                kind: "closed",
                message: "anthropic: " + $what + ": the server closed the connection: " + $why
            };
        }
        if ($e.kind == "http") {
            fail($what + ": the reply is malformed: " + $why);
        }
        fail($what + ": cannot reach " + shown($c.baseUrl) + ": " + $why);
    }
}

/**
 * Whether a status is worth another attempt: 408, 409, 429 and 5xx (529
 * is "overloaded").
 *
 * @param status {int} the status
 * @return {bool} true to retry
 */
func retryable(status as int) {
    return $status == 408 or $status == 409 or $status == 429 or $status >= 500;
}

/**
 * How long the reply asks to wait: `retry-after-ms`, else `retry-after` in
 * seconds or as an HTTP date (a date past is 0).
 *
 * @param r {http.BytesResponse} the reply, status 0 for none
 * @return {int} milliseconds; -1 when it names no wait (or a malformed one)
 */
func namedWait(r as http.BytesResponse) {
    if (maps.has($r.headers, "retry-after-ms")) {
        def v as string init strings.trim($r.headers["retry-after-ms"]);
        if (regex.matches('^[0-9]{1,12}(\.[0-9]{1,6})?$', $v)) {
            return convert.toInt(math.ceil(convert.toFloat($v)));
        }
    }
    if (not maps.has($r.headers, "retry-after")) {
        return -1;
    }
    def v as string init strings.trim($r.headers["retry-after"]);
    if (regex.matches('^[0-9]{1,9}(\.[0-9]{1,6})?$', $v)) {
        return convert.toInt(math.ceil(convert.toFloat($v) * 1000.0));
    }
    if (regex.matches(
        '^[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$',
        $v)) {
        try {
            def at as int init time.unixMillis(time.parse($v, "%a, %d %b %Y %H:%M:%S GMT"));
            return math.min(MAX_NAMED_WAIT_MS, math.max(0, $at - time.unixMillis(time.now())));
        } catch (e) {
            # past what time represents (about 2262): as far as it goes
            if (convert.toInt($v[12..16]) >= 2262) {
                return MAX_NAMED_WAIT_MS;
            }
            return -1;
        }
    }
    return -1;
}

/**
 * How long to wait before the next attempt: what the reply asks for
 * (`namedWait`), else the client's backoff doubled per attempt.
 *
 * @param c {Client} the client
 * @param r {http.BytesResponse} the reply, status 0 for none
 * @param n {int} the attempts made so far, from 1
 * @return {int} milliseconds; -1 when the reply asks for longer than `MAX_RETRY_WAIT_MS`
 */
func retryWait(c as Client, r as http.BytesResponse, n as int) {
    def named as int init namedWait($r);
    if ($named > MAX_RETRY_WAIT_MS) {
        return -1;
    }
    if ($named >= 0) {
        return $named;
    }
    def wait as int init $c.backoffMs;
    for (def i in 1..$n) {
        $wait = $wait * 2;
        if ($wait >= MAX_BACKOFF_MS) {
            return MAX_BACKOFF_MS;
        }
    }
    return $wait;
}

/**
 * Send a request, retrying as the client says, and return its 2xx reply.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param path {string} the path and query below the base URL, starting with `/`
 * @param body {string} a JSON body, `""` for none
 * @param what {string} the request, for messages
 * @return {http.BytesResponse} the reply
 */
func exchange(c as Client, method as string, path as string, body as string, what as string) {
    checkUrl($c);
    if (not regex.matches(KEY_FORM, $c.apiKey)) {
        fail("the client's API key was changed to something that is not printable ASCII");
    }
    def headers as map of string to string init {
        "x-api-key": $c.apiKey,
        "anthropic-version": $c.version,
        "Accept": "application/json"
    };
    if (len($c.betas) > 0) {
        $headers["anthropic-beta"] = strings.join($c.betas, ",");
    }
    if ($body != "") {
        $headers["Content-Type"] = "application/json";
    }
    def url as string init $c.baseUrl + $path;
    def n as int init 0;
    while (true) {
        $n = $n + 1;
        def a as Attempt init attempt($c, $method, $url, $headers, $body, $what);
        def last as bool init $n > $c.retries;
        def wait as int init 0;
        if (not $a.failed) {
            if ($a.response.status >= 200 and $a.response.status <= 299) {
                return $a.response;
            }
            if ($last or not retryable($a.response.status)) {
                failStatus($c, $a.response, $what);
            }
            $wait = retryWait($c, $a.response, $n);
            if ($wait < 0) {
                failStatus($c, $a.response, $what);
            }
        } else {
            # a request that was not sent: retried, else its NetError as it is
            if ($last) {
                def ne as net.NetError init $a.netError;
                throw $ne;
            }
            $wait = retryWait($c, $a.response, $n);
        }
        time.sleep(time.fromMilliseconds($wait));
    }
}

/**
 * Whether a header is one `AnthropicError.limits` keeps.
 *
 * @param low {string} the lower-cased name
 * @return {bool} true for `anthropic-ratelimit-*`, `x-ratelimit-*`, `retry-after` and `retry-after-ms`
 */
func isLimitHeader(low as string) {
    return strings.startsWith($low, "anthropic-ratelimit-") or
        strings.startsWith($low, "x-ratelimit-") or
        $low == "retry-after" or $low == "retry-after-ms";
}

/**
 * Throw the AnthropicError of a reply that is not 2xx, with what the
 * server said: `{"type": "error", "error": {"type", "message"}, "request_id"}`.
 *
 * @param c {Client} the client, whose key is scrubbed from the message
 * @param r {http.BytesResponse} the reply
 * @param what {string} the request, for messages
 * @throws {AnthropicError} kind "anthropic", always
 */
func failStatus(c as Client, r as http.BytesResponse, what as string) {
    def type as string init "";
    def why as string init $r.statusText;
    def requestId as string init "";
    if (maps.has($r.headers, "request-id")) {
        $requestId = $r.headers["request-id"];
    }
    try {
        def text as string init strings.trim(convert.stringFromBytes("utf-8", $r.body));
        if ($text != "" and not strings.startsWith($text, "<")) {
            $why = $text;
            def v as json.Value init json.decode($text);
            if (json.typeOf($v, "/error/type") == "string") {
                $type = json.asString($v, "/error/type");
            }
            if (json.typeOf($v, "/error/message") == "string") {
                $why = json.asString($v, "/error/message");
            }
            if ($requestId == "" and json.typeOf($v, "/request_id") == "string") {
                $requestId = json.asString($v, "/request_id");
            }
        }
    } catch (e) {
        $why = $why;
    }
    $type = cleaned(scrub($c, $type), 64);
    $requestId = cleaned(scrub($c, $requestId), 128);
    def limits as map of string to string init {};
    for (def name in $r.headers) {
        def low as string init strings.lower($name);
        if (len($limits) < MAX_LIMITS and isLimitHeader($low)) {
            $limits[$low] = cleaned(scrub($c, $r.headers[$name]), 200);
        }
    }
    def tail as string init io.sprintf("HTTP %d", $r.status);
    if ($type != "") {
        $tail = $tail + " " + $type;
    }
    if ($requestId != "") {
        $tail = $tail + ", request " + $requestId;
    }
    throw AnthropicError{
        kind: "anthropic",
        message: "anthropic: " + $what + ": " + cleaned(scrub($c, $why), 500) + " (" + $tail + ")",
        status: $r.status,
        type: $type,
        requestId: $requestId,
        retryAfterMs: math.max(0, namedWait($r)),
        limits: $limits
    };
}

/**
 * A reply body as JSON.
 *
 * @param r {http.BytesResponse} the reply
 * @param what {string} the request, for messages
 * @return {json.Value} the body, JSON `null` when empty
 */
func jsonBody(r as http.BytesResponse, what as string) {
    def text as string init "";
    try {
        $text = convert.stringFromBytes("utf-8", $r.body);
    } catch (e) {
        fail($what + ": the reply is not UTF-8");
    }
    if (strings.trim($text) == "") {
        return json.decode("null");
    }
    try {
        return json.decode($text);
    } catch (e) {
        if ($e.kind == "limit") {
            failLimit($what + ": the reply is too deeply nested or has too many values");
        }
        fail($what + ": the reply is not JSON: " + shown($text));
    }
}

/**
 * Send an API request and read its JSON reply.
 *
 * @param c {Client} the client
 * @param method {string} the HTTP method
 * @param path {string} the path and query, starting with `/v1/`
 * @param body {string} a JSON body, `""` for none
 * @param what {string} the request, for messages
 * @return {json.Value} the reply, JSON `null` when it has no body
 */
func api(c as Client, method as string, path as string, body as string, what as string) {
    return jsonBody(exchange($c, $method, $path, $body, $what), $what);
}

/**
 * A string at a JSON pointer, `""` when absent or null.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {string} the string
 */
func textAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t == "missing" or $t == "null") {
        return "";
    }
    if ($t != "string") {
        fail(shown($ptr) + " is a " + $t + ", not a string");
    }
    return json.asString($v, $ptr);
}

/**
 * An integer at a JSON pointer, 0 when absent or null.
 *
 * @param v {json.Value} the document
 * @param ptr {string} the pointer
 * @return {int} the number
 */
func intAt(v as json.Value, ptr as string) {
    def t as string init json.typeOf($v, $ptr);
    if ($t == "missing" or $t == "null") {
        return 0;
    }
    if ($t != "int") {
        fail(shown($ptr) + " is a " + $t + ", not an integer");
    }
    return json.asInt($v, $ptr);
}

/**
 * Refuse a reply that is not a JSON map.
 *
 * @param v {json.Value} the reply
 * @param what {string} the request, for messages
 * @return {json.Value} the reply
 */
func mapReply(v as json.Value, what as string) {
    if (json.typeOf($v) != "map") {
        fail($what + ": the reply is a " + json.typeOf($v) + ", not an object");
    }
    return $v;
}

/**
 * Any other API request, such as one to an endpoint this deck has no
 * function for. The body is sent as JSON; the reply is read as JSON.
 *
 * @param c {Client} the client
 * @param method {string} `GET`, `POST`, `PUT`, `PATCH` or `DELETE`
 * @param path {string} the path below the base URL, with an optional query, such as `/v1/models?limit=5`
 * @param body {json.Value} the body, JSON `null` for none
 * @return {json.Value} the reply, JSON `null` when it has no body
 * @throws {AnthropicError} kind "anthropic" when the method or path is malformed, the status is not 2xx, or the request fails
 * @example
 *   def page as json.Value init anthropic.call($c, "GET", "/v1/models?limit=5", json.decode("null"));
 */
export func call(c as Client, method as string, path as string, body as json.Value) {
    if (not lists.contains(["GET", "POST", "PUT", "PATCH", "DELETE"], $method)) {
        fail("a method is GET, POST, PUT, PATCH or DELETE, got " + shown($method));
    }
    if (not regex.matches('^(/[A-Za-z0-9._~:@-]+)+/?(\?[A-Za-z0-9._~=&%:,+-]*)?$', $path) or
        regex.matches('/\.+(/|\?|$)', $path)) {
        fail("a path is /segments of letters, digits and ._~:@- with an optional ?query, got " +
            shown($path));
    }
    def payload as string init "";
    if (json.typeOf($body) != "null") {
        $payload = json.encode($body);
    }
    def at as int init strings.indexOf($path, "?");
    def what as string init $method + " " + $path;
    if ($at >= 0) {
        $what = $method + " " + $path[..$at];
    }
    return api($c, $method, $path, $payload, $what);
}

/**
 * Every model the key may use, newest first, read page by page.
 *
 * @param c {Client} the client
 * @return {list of json.Value} the model objects: `id`, `display_name`, `max_input_tokens`, `max_tokens`, `capabilities`, `lifecycle`, ...
 * @throws {AnthropicError} kind "anthropic" when the status is not 2xx or the request fails
 * @throws {Error} kind "limit" after 100 pages of 1000, or when the pages together are over the client's `maxBytes`
 * @example
 *   for (def m in anthropic.models($c)) {
 *       io.printf("%s\n", json.asString($m, "/id"));
 *   }
 */
export func models(c as Client) {
    def all as list of json.Value init [];
    def after as string init "";
    def read as int init 0;
    for (def page in 0..MAX_PAGES) {
        def path as string init "/v1/models?limit=1000";
        if ($after != "") {
            $path = $path + "&after_id=" + $after;
        }
        def r as http.BytesResponse init exchange($c, "GET", $path, "", "models");
        $read = $read + len($r.body);
        if ($read > $c.maxBytes) {
            failLimit(io.sprintf("models: the pages are over %d bytes in all", $c.maxBytes));
        }
        def v as json.Value init mapReply(jsonBody($r, "models"), "models");
        if (json.typeOf($v, "/data") != "list") {
            fail("models: the reply has no data list");
        }
        for (def i in 0..json.length($v, "/data")) {
            $all[] = json.get($v, "/data/" + convert.toString($i));
        }
        if (json.typeOf($v, "/has_more") != "bool" or not json.asBool($v, "/has_more")) {
            return $all;
        }
        $after = textAt($v, "/last_id");
        checkId($after, "models: the next page's last_id");
    }
    failLimit(io.sprintf("models: more than %d pages", MAX_PAGES));
}

/**
 * One model: its context window (`max_input_tokens`), output cap
 * (`max_tokens`) and `capabilities`.
 *
 * @param c {Client} the client
 * @param id {string} the model id, such as `claude-opus-5-5`
 * @return {json.Value} the model object
 * @throws {AnthropicError} kind "anthropic" with status 404 for an unknown model, or when the request fails
 * @example
 *   def m as json.Value init anthropic.model($c, "claude-opus-5-5");
 *   io.printf("%d\n", json.asInt($m, "/max_input_tokens"));
 */
export func model(c as Client, id as string) {
    checkId($id, "a model id");
    return mapReply(api($c, "GET", "/v1/models/" + $id, "", "model " + $id), "model " + $id);
}
