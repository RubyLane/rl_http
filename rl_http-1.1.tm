package require Tcl 8.6
package require uri	;# from tcllib

oo::class create rl_http {
	variable {*}{
		method
		wait
		timeout_afterid
		u
		response
		settings
		sock
		resp_headers_buf
		resp_body_buf
	}

	constructor {a_method url args} { #<<<
		set method	$a_method

		if {[llength [info commands ns_log]] == 0} {
			proc ns_log {lvl msg} {puts $msg}
		}

		if {[self next] ne ""} next

		set settings [dict merge {
			-timeout	15
			-ver		1.1
			-accept		*/*
			-headers	{}
			-sizelimit	""
			-data		""
		} $args]

		set resp_headers_buf	""
		set resp_body_buf		""

		set response {
			headers	{}
			data	{}
		}

		set method	[string toupper $method]
		if {$method ni {GET PUT POST DELETE HEAD}} {
			error "HTTP method \"$method\" not supported"
		}

		try {
		    array set u	[uri::split $url]
		} on error {res err} {
		    throw [list RL URI ERROR] $err
		}
		if {![info exists u(scheme)] || $u(scheme) ni {http https}} {
			throw [list RL HTTP BAD_URL] "URL scheme \"[if {[info exists u(scheme)]} {set u(scheme)}]\" not supported"
		}
		if {$u(port) eq ""} {
			set u(port) [dict get {
				http	80
				https	443
			} $u(scheme)]
		}
		if {$u(scheme) eq "https"} {package require tls}
		if {[string index $u(path) 0] ne "/"} {
			set u(path)	/$u(path)
		}

		my _connect
		my _send_request
		my _read_headers
		my _parse_statusline
		my _parse_headers $resp_headers_buf
		my _read_body

		my _cancel_timeout
	}

	#>>>
	destructor { #<<<
		if {[info exists sock] && $sock in [chan names]} {close $sock}
		my _cancel_timeout
		if {[self next] ne ""} next
	}

	#>>>
	method _connected {} { set wait	connected }
	method _timeout {}   { set wait	timeout }
	method _cancel_timeout {} { #<<<
		if {![info exists timeout_afterid]} return
		after cancel $timeout_afterid; set timeout_afterid	""
	}

	#>>>
	method _connect {} { #<<<
		switch -- $u(scheme) {
			http  {set sock	[socket -async $u(host) $u(port)]}
			https {set sock [tls::socket -async $u(host) $u(port)]}
			default {throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $u(scheme)] "Scheme $u(scheme) is not supported"}
		}
		chan configure $sock -translation {auto crlf} -blocking 0 -buffering full -buffersize 65536 -encoding ascii
		chan event $sock writable [namespace code {my _connected}]
		if {[string is double -strict [dict get $settings -timeout]]} {
			set timeout_afterid	[after [expr {int([dict get $settings -timeout] * 1000)}] [namespace code {my _timeout}]]
		}
		if {![info exists wait]} {
			vwait [namespace current]::wait
		}
		if {[info exists sock] && $sock in [chan names]} {
			chan event $sock writable {}
		}

		if {$wait ne "connected"} {
			throw [list RL HTTP CONNECT $wait] "HTTP connect failed: $wait"
		}
		unset wait
	}

	#>>>
	method _send_request {} { #<<<
		puts $sock "$method $u(path)[if {$u(query) ne ""} {set _ ?$u(query)}] HTTP/[dict get $settings -ver]"
		puts $sock "Host: $u(host)[if {$u(port) != 80} {set _ :$u(port)}]"
		puts $sock "Accept: [dict get $settings -accept]"
		puts $sock "Accept-Encoding: gzip, deflate, compress"
		puts $sock "Accept-Charset: utf-8, iso-8859-1;q=0.5, windows-1252;q=0.5"
		puts $sock "User-Agent: Ruby Lane HTTP client"
		foreach {k v} [dict get $settings -headers] {
			puts $sock [format {%s: %s} [string trim $k] [string map {"\r" "" "\n" ""} $v]]
		}
		if {[dict get $settings -data] ne ""} {
			# Assumes the declared charset is utf-8.  It's important to add this to the mimetype like so:
			# Content-Type: text/xml; charset=utf-8
			puts $sock "Content-Length: [string length [dict get $settings -data]]"
		}
		puts $sock "Connection: close"
		puts $sock ""
		if {[dict get $settings -data] ne ""} {
			chan configure $sock -translation {auto binary}
			puts -nonewline $sock [dict get $settings -data]
			chan configure $sock -translation {auto crlf} -encoding ascii
		}
		flush $sock
	}

	#>>>
	method _read_headers {} { #<<<
		chan configure $sock -buffering line
		chan event $sock readable [namespace code {my _readable_headers}]
		if {![info exists wait]} {
			vwait [namespace current]::wait
		}
		set headers_status	$wait
		unset wait
		if {[info exists sock] && $sock in [chan names]} {
			chan event $sock readable {}
		}

		if {$headers_status ne "ok"} {
			throw [list RL HTTP READ_HEADERS $headers_status] "Error reading HTTP headers: $headers_status"
		}
	}

	#>>>
	method _readable_headers {} { #<<<
		set line	[gets $sock]
		if {[eof $sock]} {
			set wait dropped
			return
		}

		if {![dict exists $response statusline]} {
			if {$line eq ""} {
				# This is expressly forbidden in the HTTP RFC, but for some
				# reason I'm getting these from the sugarcrm rest api
				return
			}
			dict set response statusline $line
			return
		}

		if {$line eq ""} {
			set wait	ok
			return
		}

		append resp_headers_buf $line \n
	}

	#>>>
	method _parse_statusline {} { #<<<
		if {![regexp {^HTTP/([0-9]+\.[0-9]+) ([0-9][0-9][0-9]) (.*)$} [dict get $response statusline] - resp_http_ver http_code]} {
			throw [list RL HTTP PARSE_HEADERS [dict get $response statusline]] "Invalid HTTP status line: \"[dict get $response statusline]\""
		}
		dict set response ver $resp_http_ver
		dict set response code $http_code
	}

	#>>>
	method _parse_headers header_txt { #<<<
		# Unfold headers
		regsub -all {\n\s+} $header_txt { } header_txt

		foreach line [split [string trim $header_txt] \n] {
			if {![regexp {^([^:]+):\s+(.*)$} $line - k v]} {
				throw [list RL HTTP PARSE_HEADERS $line] "Unable to parse HTTP response header line: \"$line\""
			}
			my _append_headers [string tolower $k] [lmap e [split $v ,] {string trim $e}]
		}
	}

	#>>>
	method _append_headers {k vlist} { #<<<
		if {![dict exists $response headers $k]} {
			dict set response headers $k {}
		}
		dict with response {
			dict lappend headers [string tolower $k] {*}$vlist
		}
	}

	#>>>
	method _read_body {} { #<<<
		if {[dict get $response code] == 204 || $method eq "HEAD"} {
			# 204 means No Content - there is nothing to read in this case
			dict set response body ""
			return
		}

		if {[dict get $settings -sizelimit] ne "" && [dict exists $response headers content-length]} {
			set content_length	[lindex [dict get $response headers content-length] 0]
			if {$content_length > [dict get $settings -sizelimit]} {
				throw [list RL HTTP READ_BODY TOO_BIG $content_length] "Content-Length exceeds maximum: $content_length > [dict get $settings -sizelimit]"
			}
		}

		chan configure $sock -buffering full -translation binary
		chan event $sock readable [namespace code {my _readable_body}]
		if {![info exists wait]} {
			vwait [namespace current]::wait
		}
		set body_status	$wait
		unset wait
		if {[info exists sock] && $sock in [chan names]} {
			chan event $sock readable {}
		}

		if {$body_status ne "ok"} {
			throw [list RL HTTP READ_BODY $body_status] "Error reading HTTP response body: $body_status"
		}

		# Check content-length (if provided) to ensure we got the whole response body
		if {[dict exists $response headers content-length]} {
			set content_length	[lindex [dict get $response headers content-length] end]
			if {[string length $resp_body_buf] != $content_length} {
				throw [list RL HTTP READ_BODY truncated] "Expecting $content_length bytes in HTTP response body, got [string length $resp_body_buf]"
			}
		} elseif {[dict get $settings -sizelimit] ne ""} {
			# Need to check the sizelimit here again in-case the server didn't
			# supply a Content-Length header, although it will be less useful
			# since we already have the response body in memory, but at least
			# we can honour the contract with our caller that we won't return a
			# response bigger than -sizelimit
			if {[string length $resp_body_buf] > [dict get $settings -sizelimit]} {
				throw [list RL HTTP READ_BODY TOO_BIG [string length $resp_body_buf]] "Content-Length exceeds maximum: [string length $resp_body_buf] > [dict get $settings -sizelimit]"
			}
		}

		# Decode transfer-encoding and content-encoding
		foreach header {transfer-encoding content-encoding} {
			if {[dict exists $response headers $header]} {
				foreach enc [lreverse [dict get $response headers $header]] {
					switch -nocase -- $enc {
						chunked {
							# Blegh
							set raw	$resp_body_buf
							set resp_body_buf	""

							while {1} {
								if {![regexp {^([0-9a-fA-F]+)(?:;([^\r\n]+))?\r\n(.*)$} $raw - octets chunk_extensions_enc raw]} {
									throw [list RL HTTP READ_BODY CORRUPT_CHUNKED] "Corrupt HTTP Transfer-Encoding: chunked body"
								}

								# Convert chunk_extensions to a dict
								set chunk_extensions	[concat {*}[lmap e [split $chunk_extensions_enc ";"] {
									regexp {^([^=]+)(?:=(.*))?$} $e - name value
									list $name $value
								}]]

								set octets	0x$octets
								if {$octets == 0} break
								append resp_body_buf	[string range $raw 0 $octets-1]
								if {[string range $raw $octets $octets+1] ne "\r\n"} {
									throw [list RL HTTP READ_BODY CORRUPT_CHUNKED] "Corrupt HTTP Transfer-Encoding: chunked body"
								}
								set raw					[string range $raw $octets+2 end]
							}
							# chunked encoding can include headers _after_ the body...
							if {[string length $raw] != 0} {
								my _parse_headers $raw
							}
						}
						base64                { set resp_body_buf	[binary decode base64 $resp_body_buf] }
						gzip - x-gzip         { set resp_body_buf	[zlib gunzip $resp_body_buf] }
						deflate               { set resp_body_buf	[zlib inflate $resp_body_buf] }
						compress - x-compress { set resp_body_buf	[zlib decompress $resp_body_buf] }
						identity - 8bit - 7bit - binary {}
						default {
							throw [list RL HTTP READ_BODY unhandled_encoding $enc] "Unhandled HTTP response body $header: \"$enc\""
						}
					}
				}
			}
		}

		# Convert from the specified charset encoding (if supplied)
		if {[dict exists $response headers content-type]} {
			set content_type	[lindex [dict get $response headers content-type] end]
			if {[regexp -nocase {^((?:text|application)/[^ ]+)(?:\scharset=\"?([^\"]+)\"?)?$} $content_type - mimetype charset]} {
				if {$charset eq ""} {
					# Some mimetypes have default charsets
					switch -- $mimetype {
						application/json -
						text/json {
							set charset		utf-8
						}

						application/xml -
						text/xml {
							# According to the RFC, text/xml should default to
							# US-ASCII, but this is widely regarded as stupid,
							# and US-ASCII is a subset of UTF-8 anyway.  Any
							# documents that fail because of an invalid UTF-8
							# encoding were broken anyway (they contained bytes
							# not legal for US-ASCII either)
							set charset		utf-8
						}

						default {
							set charset		identity
						}
					}
				}

				switch -nocase -- $charset {
					utf-8        { set resp_body_buf [encoding convertfrom utf-8     $resp_body_buf] }
					iso-8859-1   { set resp_body_buf [encoding convertfrom iso8859-1 $resp_body_buf] }
					windows-1252 { set resp_body_buf [encoding convertfrom cp1252    $resp_body_buf] }
					identity     {}
					default {
						# Only broken servers will land here - we specified the set of encodings we support in the
						# request Accept-Encoding header
						throw [list RL HTTP READ_BODY UNHANDLED_CHARSET $charset] "Unhandled HTTP response body charset: \"$charset\""
					}
				}
			}
		}

		dict set response body $resp_body_buf
	}

	#>>>
	method _readable_body {} { #<<<
		set chunk	[read $sock]
		append resp_body_buf	$chunk

		if {[eof $sock]} {
			close $sock
			set wait	ok
			return
		}
	}

	#>>>

	foreach accessor {code body headers} {
		method $accessor {} "dict get \$response [list $accessor]"
	}
}


# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
