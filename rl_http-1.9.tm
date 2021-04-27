package require Tcl 8.6
package require uri	;# from tcllib
package require gc_class
package require Thread
package require parse_args

namespace eval ::rl_http {
	namespace export *


	proc log {lvl msg} { #<<<
		set s		[expr {[clock microseconds] / 1e6}]
		set frac	[string range [format %.6f [expr {fmod($s, 1.0)}]] 1 end]
		puts stderr "[clock format [expr {int($s)}] -format "%Y-%m-%d %H:%M:%S$frac" -timezone :UTC] $msg"
	}

	#>>>
	::gc_class create utf8buffer { #<<<
		variable {*}{
			utf8chunks
			bytelength
		}

		constructor {} { #<<<
			if {[self next] ne ""} next

			set utf8chunks	{}
			set bytelength	0
		}

		#>>>

		method append chunk { #<<<
			set utf8chunk	[encoding convertto utf-8 $chunk]
			lappend utf8chunks	$utf8chunk
			incr bytelength	[string length $utf8chunk]
		}

		#>>>
		method bytelength {} {set bytelength}
		method write chan { #<<<
			foreach utf8chunk $utf8chunks {
				puts -nonewline $chan $utf8chunk
			}
			set utf8chunks	{}
			set bytelength	0
		}

		#>>>
	}

	#>>>
	namespace eval tapchan {
		namespace export *
		namespace ensemble create -prefixes no

		proc initialize {chan mode} { #<<<
			::rl_http::log debug "rl_http tapchan $chan initialize $mode"
			return {initialize finalize read write}
		}

		#>>>
		proc finalize chan { ::rl_http::log debug "tapchan $chan finalize" }
		proc read {chan bytes} { #<<<
			::rl_http::log debug "rl_http tapchan $chan read [binary encode base64 $bytes]"
			set bytes
		}

		#>>>
		proc write {chan bytes} { #<<<
			::rl_http::log debug "rl_http tapchan $chan write [binary encode base64 $bytes]"
			set bytes
		}

		#>>>
	}
}

# Start the keepalive timeout handler thread <<<
tsv::lock rl_http_threads {
	if {![tsv::exists rl_http_threads keepalive_handler]} {

		if {[info commands ns_thread] eq ""} {
			set start_thread	thread::create
		} else {
			# using thread::create in Naviserver seems to cause a deadlock (at least when called during server startup)
			set start_thread	{ns_thread begindetached}
		}

		{*}$start_thread {
			if {[info commands ns_log] ne ""} {
				interp alias {} log {} ns_log
			} else {
				proc log {lvl msg} {
					set s		[expr {[clock microseconds] / 1e6}]
					set frac	[string range [format %.6f [expr {fmod($s, 1.0)}]] 1 end]
					puts stderr "[clock format [expr {int($s)}] -format "%Y-%m-%d %H:%M:%S$frac" -timezone :UTC] $msg"
				}
			}

			while 1 {
				after 5000

				set now			[clock seconds]
				set to_close	{}
				tsv::lock rl_http_keepalive_chans {
					foreach key [tsv::array names rl_http_keepalive_chans] {
						for {set i 0} {$i < [tsv::llength rl_http_keepalive_chans $key]} {incr i} {
							lassign [tsv::lindex rl_http_keepalive_chans $key $i] chan expires

							if {$now > $expires} {
								# Defer the actual closing until after we release the lock on rl_http_keepalive_chans
								lappend to_close	$key [tsv::lpop rl_http_keepalive_chans $key $i]
							}
						}

						if {[tsv::llength rl_http_keepalive_chans $key] == 0} {
							tsv::unset rl_http_keepalive_chans $key
						}
					}
				}

				foreach {key chaninfo} $to_close {
					lassign $chaninfo chan expires
					try {
						#log debug "Closing expired channel $chan to $key"
						thread::attach $chan
						close $chan
					} on error {errmsg options} {
						# TODO: what?
						log debug "Error retiring expired parked channel $chan to $key: [dict get $options -errorinfo]"
					}
				}
			}
		}

		tsv::set rl_http_threads keepalive_handler started
		unset start_thread
	}
}
#>>>

::gc_class create ::rl_http {
	variable {*}{
		method
		url
		wait
		timeout_afterid
		u
		response
		settings
		sock
		resp_headers_buf
		resp_body_buf
		chunk_buf
		starttime
		keepalive
		collected
		async_gap_start
	}

	constructor {a_method a_url args} { #<<<
		if {"::parse_args" ni [namespace path]} {
			namespace path [list {*}[namespace path] ::parse_args]
		}

		set method	$a_method
		set url		$a_url

		if {[self next] ne ""} next

		parse_args $args {
			-timeout		{-default 15}
			-ver			{-default 1.1}
			-accept			{-default */*}
			-headers		{-default {}}
			-sizelimit		{-default ""}
			-data			{-default ""}
			-data_cb		{-default {}}
			-data_len		{-default ""}
			-override_host	{-default ""}
			-tapchan		{-default ""}
			-useragent		{-default "Ruby Lane HTTP client"}
            -stats_cx		{-default ""}
			-async			{-boolean -# {If set, don't wait for the response (get it with [$obj collect] later)}}
			-keepalive		{-default 1 -# {Not used}}
		} settings

		set resp_headers_buf	""
		set resp_body_buf		""
		set chunk_buf			""
		set keepalive			yes
		set collected			false

		set response {
			headers	{}
			data	{}
		}

		set method	[string toupper $method]
		if {$method ni {GET PUT POST DELETE HEAD PATCH OPTIONS}} {
			error "HTTP method \"$method\" not supported"
		}

		try {
		    array set u	[uri::split $url]
		} on error {res err} {
		    throw [list RL URI ERROR] $err
		}
		if {![info exists u(scheme)] || $u(scheme) ni {http https unix}} {
			throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $u(scheme)] "URL scheme \"[if {[info exists u(scheme)]} {set u(scheme)}]\" not supported"
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

		set starttime	[clock microseconds]
		my _connect
		my _send_request
		set async_gap_start	[clock microseconds]
		if {![dict get $settings async]} {
			my collect
		}
	}

	#>>>
	destructor { #<<<
		if {[info exists sock] && $sock in [chan names]} {close $sock}
		my _cancel_timeout
		if {[self next] ne ""} next
	}

	#>>>

	method collect {} { #<<<
		if {$collected} return
		if {[dict get $settings async]} {
			set async_gap	[expr {[clock microseconds] - $async_gap_start}]
		} else {
			set async_gap	0
		}

		my _read_headers
		my _parse_statusline
		my _parse_headers $resp_headers_buf
		my _read_body
		set elapsed	[expr {[clock microseconds] - $starttime - $async_gap}]
		my _stats [expr {$elapsed / 1e3}]

		my _cancel_timeout

		if {[dict exists $response headers connection] && "close" in [dict get $response headers connection]} {
			close $sock
			unset sock
		} else {
			my _keepalive_park $sock $u(scheme) $u(host) $u(port) 15
			unset sock
		}

		set collected	true
		return
	}

	#>>>
	method _connected {} { set wait	connected }
	method _timeout {}   { set wait	timeout }
	method _cancel_timeout {} { #<<<
		if {![info exists timeout_afterid]} return
		after cancel $timeout_afterid; set timeout_afterid	""
	}

	#>>>
	method _keepalive_connect {scheme host port} { #<<<
		#::rl_http::log debug "[self] _keepalive_connect $scheme $host $port"
		set key		$scheme://$host:$port
		tsv::lock rl_http_keepalive_chans {
			if {![tsv::exists rl_http_keepalive_chans $key]} {
				tsv::set rl_http_keepalive_chans $key {}
			}
		}
		#::rl_http::log debug "Looking for parked connection $key: [tsv::array get rl_http_keepalive_chans]"
		while {[set chaninfo [tsv::lpop rl_http_keepalive_chans $key 0]] ne ""} {
			lassign $chaninfo chan expiry
			#::rl_http::log debug "[self] reusing $chan for $scheme://$host:$port"
			try {
				thread::attach $chan
				# Check if the remote closed on us <<<
				chan configure $chan -blocking 0
				chan read $chan
				if {[chan eof $chan]} {
					::rl_http::log notice "parked chan collapsed: $chan"
					chan close $chan
					continue
				}
				# Check if the remote closed on us >>>
			} on ok {} {
				if {[dict get $settings tapchan] ne ""} {
					chan push $chan [dict get $settings tapchan]
				}
				return $chan
			} on error {errmsg options} {
				::rl_http::log notice "Error attaching to parked chan \"$chan\": [dict get $options -errorinfo]"
			}
		}
		#::rl_http::log debug "Falling back on opening new connection $scheme://$host:$port"
		if {[regexp {^\[(.*)\]$} $host - socket]} {
			# HTTP-over-unix-domain-sockets
			package require unix_sockets
			switch -- $scheme {
				http  {set chan	[unix_sockets::connect $socket]}
				https {
					set chan	[unix_sockets::connect $socket]
					tls::import $chan
				}
				default {throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $scheme] "Scheme $scheme is not supported"}
			}
		} else {
			switch -- $scheme {
				http  {set chan	[socket -async $host $port]}
				https {set chan [tls::socket -async $host $port]}
				default {throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $scheme] "Scheme $scheme is not supported"}
			}

			try {
				package require sockopt
				sockopt::setsockopt $chan SOL_TCP TCP_NODELAY 1
			} on error {} {
			} on ok {} {
				#puts stderr "Set TCP_NODELAY"
			}
		}
		if {[dict get $settings tapchan] ne ""} {
			chan push $chan [dict get $settings tapchan]
		}
		set chan
	}

	#>>>
	method _keepalive_park {chan scheme host port timeout} { #<<<
		#::rl_http::log notice "Parking $scheme://$host:$port"
		if {$chan in [chan names]} {
			if {[dict get $settings tapchan] ne ""} {
				chan pop $chan
			}
			thread::detach $chan
			tsv::lappend rl_http_keepalive_chans $scheme://$host:$port [list $chan [expr {[clock seconds] + $timeout}]]
		}
	}

	#>>>
	method _connect {} { #<<<
		set sock	[my _keepalive_connect $u(scheme) $u(host) $u(port)]
		chan configure $sock -translation {auto crlf} -blocking 0 -buffering full -buffersize 65536 -encoding ascii
		chan event $sock writable [namespace code {my _connected}]
		if {[string is double -strict [dict get $settings timeout]]} {
			set timeout_afterid	[after [expr {int([dict get $settings timeout] * 1000)}] [namespace code {my _timeout}]]
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
		puts $sock "$method $u(path)[if {$u(query) ne ""} {set _ ?$u(query)}] HTTP/[dict get $settings ver]"
		set have_headers	[lsort -unique [lmap {k v} [dict get $settings headers] {string tolower $k}]]
		if {"host" ni $have_headers} {
			if {[dict get $settings override_host] ne ""} {
				puts $sock "Host: [dict get $settings override_host]"
			} else {
				if {[regexp {^\[.*\]$} $u(host)]} {
					# Unix domain socket
					puts $sock "Host: localhost"
				} else {
					puts $sock "Host: $u(host)[if {$u(port) != 80} {set _ :$u(port)}]"
				}
			}
		}
		puts $sock "Accept: [dict get $settings accept]"
		puts $sock "Accept-Encoding: gzip, deflate, compress"
		puts $sock "Accept-Charset: utf-8, iso-8859-1;q=0.5, windows-1252;q=0.5"
		puts $sock "User-Agent: [dict get $settings useragent]"
		foreach {k v} [dict get $settings headers] {
			puts $sock [format {%s: %s} [string trim $k] [string map {"\r" "" "\n" ""} $v]]
		}
		if {[dict get $settings data] ne ""} {
			# Assumes the declared charset is utf-8.  It's important to add this to the mimetype like so:
			# Content-Type: text/xml; charset=utf-8
			puts $sock "Content-Length: [string length [dict get $settings data]]"
		} elseif {[string is integer -strict [dict get $settings data_len]] && [dict get $settings data_cb] ne ""} {
			puts $sock "Content-Length: [dict get $settings data_len]"
		}
		puts $sock "Connection: keep-alive"
		puts $sock ""
		if {[dict get $settings data] ne ""} {
			chan configure $sock -translation {auto binary}
			puts -nonewline $sock [dict get $settings data]
			chan configure $sock -translation {auto crlf} -encoding ascii
		} elseif {[dict get $settings data_cb] ne ""} {
			chan configure $sock -translation {auto binary}
			uplevel #0 [list {*}[dict get $settings data_cb] $sock]
			chan configure $sock -translation {auto crlf} -encoding ascii
		}
		flush $sock
	}

	#>>>
	method _read_headers {} { #<<<
		chan configure $sock -buffering line -translation {auto crlf} -encoding ascii
		chan event $sock readable [namespace code {my _readable_headers}]
		my _readable_headers
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
		while 1 {
			set line	[gets $sock]
			if {[eof $sock]} {
				set wait dropped
				return
			}

			if {[chan blocked $sock]} return

			if {![dict exists $response statusline]} {
				if {$line eq ""} {
					# This is expressly forbidden in the HTTP RFC, but for some
					# reason I'm getting these from the sugarcrm rest api
					continue
				}
				dict set response statusline $line
				continue
			}

			if {$line eq ""} {
				set wait	ok
				return
			}

			append resp_headers_buf $line \n
		}
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
			if {![regexp {^([^:]+):\s*(.*)$} $line - k v]} {
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
	method _readable_chunk_control {} { #<<<
		set chunk_buf	[gets $sock]

		if {[eof $sock]} {
			set wait dropped
			return
		}

		if {$chunk_buf eq "" && [chan blocked $sock]} {
			return
		}

		set wait	ok
	}

	#>>>
	method _read_chunk_control {} { #<<<
		chan configure $sock -translation {auto crlf} -encoding ascii -buffering line
		chan event $sock readable [namespace code {my _readable_chunk_control}]
		my _readable_chunk_control

		if {![info exists wait]} {
			vwait [namespace current]::wait
		}
		set body_status	$wait
		unset wait
		if {[info exists sock] && $sock in [chan names]} {
			chan event $sock readable {}
		}

		if {$body_status ne "ok"} {
			throw [list RL HTTP READ_BODY $body_status] "Error reading HTTP chunk control line: $body_status"
		}

		if {![regexp {^([0-9a-fA-F]+)(?:;(.+))?$} $chunk_buf - octets chunk_extensions_enc]} {
			throw [list RL HTTP READ_BODY CORRUPT_CHUNKED] "Corrupt HTTP Transfer-Encoding: chunked body"
		}

		# Convert chunk_extensions to a dict
		set chunk_extensions	[concat {*}[lmap e [split $chunk_extensions_enc ";"] {
			regexp {^([^=]+)(?:=(.*))?$} $e - name value
			list $name $value
		}]]

		set octets	0x$octets

		list $octets $chunk_extensions
	}

	#>>>
	method _read_chunk_data length { #<<<
		set expecting	[expr {$length + 2}]		;# +2: trailing \r\n
		chan configure $sock -buffersize [expr {min(1000000, $expecting)}] -buffering full -translation binary
		chan event $sock readable [namespace code [list my _readable_body $expecting]]
		my _readable_body $expecting
		if {![info exists wait]} {
			vwait [namespace current]::wait
		}
		set body_status	$wait
		unset wait
		if {[info exists sock] && $sock in [chan names]} {
			chan event $sock readable {}
		}

		if {$body_status ne "ok"} {
			throw [list RL HTTP READ_BODY $body_status] "Error reading HTTP response chunk: $body_status"
		}

		if {[string range $resp_body_buf end-1 end] ne "\r\n"} {
			throw [list RL HTTP READ_BODY CORRUPT_CHUNKED] "Corrupt HTTP Transfer-Encoding: chunked body"
		}
		set resp_body_buf	[string range [try {set resp_body_buf} finally {unset resp_body_buf}] 0 end-2]
	}

	#>>>
	method _read_body {} { #<<<
		if {[dict get $response code] == 204 || $method eq "HEAD"} {
			# 204 means No Content - there is nothing to read in this case
			dict set response body ""
			return
		}

		if {[dict exists $response headers content-length]} {
			set content_length	[lindex [dict get $response headers content-length] 0]
			if {[dict get $settings sizelimit] ne ""} {
				if {$content_length > [dict get $settings sizelimit]} {
					throw [list RL HTTP READ_BODY TOO_BIG $content_length] "Content-Length exceeds maximum: $content_length > [dict get $settings sizelimit]"
				}
			}
			chan configure $sock -buffersize [expr {min(1000000, $content_length)}]
		}

		if {[dict exists $response headers transfer-encoding]} {
			set total_expecting	0
			while 1 {
				lassign [my _read_chunk_control] length chunk_extensions
				if {$length == 0} break
				incr total_expecting $length
				my _read_chunk_data $total_expecting
			}
			my _read_headers
		} else {
			chan configure $sock -buffering full -translation binary
			if {[dict exists $response headers content-length]} {
				set expecting	[lindex [dict get $response headers content-length] 0]
			} else {
				set expecting	""
			}
			chan event $sock readable [namespace code [list my _readable_body $expecting]]
			my _readable_body $expecting
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
		}

		# Check content-length (if provided) to ensure we got the whole response body
		if {[dict exists $response headers content-length]} {
			set content_length	[lindex [dict get $response headers content-length] end]
			if {[string length $resp_body_buf] != $content_length} {
				throw [list RL HTTP READ_BODY truncated] "Expecting $content_length bytes in HTTP response body, got [string length $resp_body_buf]"
			}
		} elseif {[dict get $settings sizelimit] ne ""} {
			# Need to check the sizelimit here again in-case the server didn't
			# supply a Content-Length header, although it will be less useful
			# since we already have the response body in memory, but at least
			# we can honour the contract with our caller that we won't return a
			# response bigger than -sizelimit
			if {[string length $resp_body_buf] > [dict get $settings sizelimit]} {
				throw [list RL HTTP READ_BODY TOO_BIG [string length $resp_body_buf]] "Content-Length exceeds maximum: [string length $resp_body_buf] > [dict get $settings sizelimit]"
			}
		}

		# Decode transfer-encoding and content-encoding
		foreach header {transfer-encoding content-encoding} {
			if {[dict exists $response headers $header]} {
				foreach enc [lreverse [dict get $response headers $header]] {
					switch -nocase -- $enc {
						chunked {
							# Handled during read
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
	method _readable_body {{expecting ""}} { #<<<
		if {$expecting ne ""} {
			set chunk	[read $sock [expr {$expecting - [string length $resp_body_buf]}]]
		} else {
			set chunk	[read $sock]
		}
		append resp_body_buf	$chunk

		if {[eof $sock]} {
			close $sock
			set wait	ok
			return
		}
		if {$expecting ne ""} {
			set remain		[expr {$expecting - [string length $resp_body_buf]}]
			if {$remain <= 0} {
				set wait	ok
				return
			}
			chan configure $sock -buffersize [expr {min(1000000, $remain)}]
		}
	}

	#>>>
	method _stats ms { #<<<
		# intended to be replaced if stats need to be logged
	}

	#>>>

	foreach accessor {code body headers} {
		method $accessor {} "my collect; dict get \$response [list $accessor]"
	}

	# Utility HTTP-related class methods
	if {[info commands ns_urlencode] eq ""} {
		package require http
		self method encode_query_params args { #<<<
			http::formatQuery {*}$args
		}

		#>>>
	} else {
		self method encode_query_params args { #<<<
			join [lmap {k v} $args {
				format %s=%s [ns_urlencode -charset utf-8 -- $k] [ns_urlencode -charset utf-8 -- $v]
			}] &
		}

		#>>>
	}

	self method utf8buffer args {tailcall ::rl_http::utf8buffer {*}$args}
}


# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
