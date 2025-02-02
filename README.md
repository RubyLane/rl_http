RL\_HTTP
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
* Supports HTTP over unix domain sockets (with the unix\_sockets package)
* Fully async single threaded mode if called from coroutines, partial support with vwait if not

Quick Reference
---------------
rl\_http instvar *varname* *METHOD* *url* ?*-option* *value* ...?

### Options
| Option | Default | Description |
|--------|---------|-------------|
| -timeout | 15.0 | Time in seconds after which to consider the request a timeout.  The timeout applies from the start of the connection attempt until the response is fully received.  Use a value of "" to disable |
| -ver | 1.1 | The HTTP version to declare in the request |
| -accept | \*/\* | The Accept header to send with the request |
| -headers | | The request headers to send, as a list similar to a dictionary but allowing duplicate keys: HTTP headers can be multivalued |
| -sizelimit | |  If set, and the returned Content-Length is larger than this value, and exception will be raised: {RL HTTP READ\_BODY TOO\_BIG $content\_length} |
| -data | | The body of the request.  Must already be encoded to bytes |
| -data\_cb | | If set, the value is used as a command prefix to invoke to write the request body to the socket.  The socket channel is appended as the first argument.  The channel is in binary mode for writing |
| -data\_len | | If -data\_cb is used, the -data\_len option can be used to supply a Content-Length header in the request |
| -override\_host | | If set, use the supplied value as the request Host header, otherwise default to the authority section of the supplied url |
| -tapchan | | If set, a stacked channel will be layered on top of the socket, with the -tapchan value used as the command prefix for the reflected channel handler.  An example handler is provided as ::rl\_http::tapchan, which logs the read and write events and the base64 encoded bytes on the wire, for debugging.  Redefine ::rl\_http::log to suit your environment (default writes to stderr) |
| -useragent | Ruby Lane HTTP client | The value to send as the User-Agent header in the request |
| -max\_keepalive\_age | -1 | If >= 0, the maximum age of a keepalive connection |
| -max\_keepalive\_count | -1 | If >=0, the maximum number of requests on a keepalive connection |
| -keepalive\_check | h {return true} | A lambda that can opt to close a connection rather than parking it for potential future reuse.  The *h* argument is the rl\_http instance, so things like the HTTP status or response headers can be interrogated |

### Instance Methods
| Method | Arguments | Description |
|--------|-----------|-------------|
| code | | The HTTP status code of the response |
| headers | | The response headers, as a dictionary with the headers as keys, normalized to lower case, and the values as a list (HTTP headers are multi-valued) |
| body | | The response body, decoded and interpreted in the charset according to the response headers |

Usage
-----

rl\_http uses gc\_class, so instance management is best left to bound instance variables:

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

### Headers

Response headers (returned by the *headers* method) are represented as a dictionary with the header names as the keys, normalized to lowercase.  The values are a list (HTTP headers can be multi-valued)

### Upload body data and encoding

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

### Exceptions
* RL URI ERROR - the supplied url cannot be parsed.
* RL HTTP CONNECT UNSUPPORTED\_SCHEME $scheme - the scheme specified in the url is not supported.
* RL HTTP CONNECT timeout - attempting to connect to the server timed out.
* RL HTTP READ\_HEADERS timeout - timeout while reading the response headers from the server.
* RL HTTP READ\_HEADERS dropped - the TCP connection was closed while reading the response headers.
* RL HTTP PARSE\_HEADERS $line - error parsing the response status line or headers.
* RL HTTP READ\_BODY timeout - timeout while reading the response body.
* RL HTTP READ\_BODY dropped - the TCP connection was closed while reading the body.
* RL HTTP READ\_BODY truncated - the server returned fewer bytes in the body than it promised in the Content-Length response header.
* RL HTTP READ\_BODY CORRUPT\_CHUNKED - the server returned malformed Transfer-Encoding: Chunked data.
* RL HTTP READ\_BODY TOO\_BIG $content\_length - the returned Content-Length exceeded the limit set by the *-sizelimit* option.
* RL HTTP READ\_BODY unhandled\_encoding $enc - the server used an encoding we don't support (and didn't advertise in the request Accept-\* headers)
* RL HTTP READ\_BODY UNHANDLED\_CHARSET $charset - the server used a charset we don't support (and didn't advertise in the request Accept-\* headers)

Required Packages
-----------------
* gc\_class - https://github.com/RubyLane/gc_class
* reuri - https://github.com/cyanogilvie/reuri, or uri from Tcllib (required if reuri is not available)
* s2n, tls or twapi - for HTTPS support (optional).  https://github.com/cyanogilvie/tcl-s2n
* sockopt - https://github.com/cyanogilvie/sockopt - sets TCP\_NODELAY (optional)
* unix\_sockets - https://github.com/cyanogilvie/unix_sockets - adds support for HTTP-over-UDS (optional)
* resolve - https://github.com/cyanogilvie/resolve - adds support for async name resolution and caching (optional)

License
-------

This package is licensed under the same terms as the Tcl core.

