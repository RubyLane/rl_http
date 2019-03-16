RL_HTTP
=======

This package provides a REST-capable, entirely non-blocking HTTP client library.

Features
--------

* Supported HTTP verbs: GET, POST, PUT, DELETE, HEAD, PATCH, OPTIONS
* HTTPS (using the tls package)
* Never blocks, and uses async socket establishment to support reliable timeouts
* gzip, deflate, compress supported
* utf-8, iso-8859-1 and windows-1252 charset encodings
* Chunked-transfer encoding
* Automatic multi-thread keepalive support
* Inspection of the read and write events and bytes on the wire for debugging
* Works in NaviServer / AOLServer / plain Tcl

Quick Reference
---------------
rl_http instvar *varname* *METHOD* *url* ?*-option* *value* ...?

### Options
| Option | Default | Description |
|--------|---------|-------------|
| -timeout | 15.0 | Time in seconds after which to consider the request a timeout.  The timeout applies from the start of the connection attempt until the response is fully received.  Use a value of "" to disable |
| -ver | 1.1 | The HTTP version to declare in the request |
| -accept | \*/\* | The Accept header to send with the request |
| -headers | | The request headers to send, as a list similar to a dictionary but allowing duplicate keys: HTTP headers can be multivalued |
| -sizelimit | |  If set, and the returned Content-Length is larger than this value, and exception will be raised: {RL HTTP READ_BODY TOO_BIG $content_length} |
| -data | | The body of the request.  Must already be encoded to bytes |
| -data_cb | | If set, the value is used as a command prefix to invoke to write the request body to the socket.  The socket channel is appended as the first argument.  The channel is in binary mode for writing |
| -data_len | | If -data_cb is used, the -data_len option can be used to supply a Content-Length header in the request |
| -override_host | | If set, use the supplied value as the request Host header, otherwise default to the authority section of the supplied url |
| -tapchan | | If set, a stacked channel will be layered on top of the socket, with the -tapchan value used as the command prefix for the reflected channel handler.  An example handler is provided as ::rl_http::tapchan, which logs the read and write events and the base64 encoded bytes on the wire, for debugging.  Redefine ::rl_http::log to suit your environment (default writes to stderr) |
| -useragent | Ruby Lane HTTP client | The value to send as the User-Agent header in the request |

### Instance Methods
| Method | Arguments | Description |
|--------|-----------|-------------|
| code | | The HTTP status code of the response |
| headers | | The response headers, as a dictionary with the headers as keys, normalized to lower case, and the values as a list (HTTP headers are multi-valued) |
| body | | The response body, decoded and interpreted in the charset according to the response headers |

Usage
-----

rl_http uses gc_class, so instance management is best left to bound instance variables:

~~~tcl
rl_http instvar h GET https://raw.githubusercontent.com/RubyLane/rl_http/master/README.md
switch -glob -- [$h code] {
    2* {
        puts "Got result:\n[$h body]"
        puts "Headers: [$h headers]"
    }

    default {
        puts "Something went wrong: [$h code]\n[$h body]"
    }
}
~~~

When $h is unset (usually because it went out of scope), or its value is
changed, the instance of rl_http will be destroyed.

## Headers

Response headers (returned by the *headers* method) are represented as a dictionary with the header names as the keys, normalized to lowercase.  The values are a list (HTTP headers can be multi-valued)

## Upload body data and encoding

Request body data supplied in the *-data* option must be fully encoded, matching the Content-Type request header.  For text types this usually means utf-8, for images it should be the raw bytes of the image.
~~~tcl
set json_body {
    {
        "hello": "server",
        "foo": 1234
    }
}
# utf-8 is the default for application/json, could also be explicit: "application/json; charset=utf-8"
rl_http instvar h PUT $url -headers {Content-Type application/json} -data [encoding convertto utf-8 $json_body]
~~~

~~~tcl
set h	[open avatar.jpg rb]
try {set image_bytes [read $h]} finally {close $h}
rl_http instvar h PUT $url -headers {Content-Type image/jpeg} -data $image_bytes
~~~

## Exceptions
* RL URI ERROR - the supplied url cannot be parsed.
* RL HTTP CONNECT UNSUPPORTED_SCHEME $scheme - the scheme specified in the url is not supported.
* RL HTTP CONNECT timeout - attempting to connect to the server timed out.
* RL HTTP READ_HEADERS timeout - timeout while reading the response headers from the server.
* RL HTTP READ_HEADERS dropped - the TCP connection was closed while reading the response headers.
* RL HTTP PARSE_HEADERS $line - error parsing the response status line or headers.
* RL HTTP READ_BODY timeout - timeout while reading the response body.
* RL HTTP READ_BODY dropped - the TCP connection was closed while reading the body.
* RL HTTP READ_BODY truncated - the server returned fewer bytes in the body than it promised in the Content-Length response header.
* RL HTTP READ_BODY CORRUPT_CHUNKED - the server returned malformed Transfer-Encoding: Chunked data.
* RL HTTP READ_BODY TOO_BIG $content_length - the returned Content-Length exceeded the limit set by the *-sizelimit* option.
* RL HTTP READ_BODY unhandled_encoding $enc - the server used an encoding we don't support (and didn't advertise in the request Accept-\* headers)
* RL HTTP READ_BODY UNHANDLED_CHARSET $charset - the server used a charset we don't support (and didn't advertise in the request Accept-\* headers)

Required Packages
-----------------
* uri - from Tcllib
* gc_class - https://github.com/RubyLane/gc_class
* tls - for HTTPS support (optional)
* sockopt - https://github.com/cyanogilvie/sockopt (optional)

License
-------

This package is licensed under the same terms as the Tcl core.

