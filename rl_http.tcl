package require Tcl 8.6
package require gc_class
package require Thread
package require parse_args

namespace eval ::rl_http {
	namespace export *

	variable tls_driver
	if {![info exists tls_driver]} {
		set tls_driver	[expr {
			[catch {package require s2n}] ? "tls" : "s2n"
		}]
	}

	# If the resolve package is available, use it for async name resolution
	variable have_resolve [expr {
		[catch {package require resolve}] == 0
	}]

	variable have_reuri [expr {
		[catch {package require reuri 0.13}] == 0
	}]
	if {!$have_reuri} {
		package require uri	;# from tcllib
	}

	if {[llength [info commands ::log]]} {
		interp alias {} ::rl_http::log {} ::log
	} else {
		proc log {lvl msg} { #<<<
			puts $msg
			#return
			## This is slow for some reason ±50 usec
			#set s		[expr {[clock microseconds] / 1e6}]
			#set frac	[string range [format %.6f [expr {fmod($s, 1.0)}]] 1 end]
			#puts stdout "[clock format [expr {int($s)}] -format {%Y-%m-%d %H:%M:%S} -timezone :UTC]$frac $msg"
		}

		#>>>
	}
	if {[llength [info commands utf8buffer]]} {
		utf8buffer destroy
	}
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
			#return {initialize finalize read write flush drain clear}
			return {initialize finalize read write}
		}

		#>>>
		proc finalize chan { ::rl_http::log debug "tapchan $chan finalize" }
		proc read {chan bytes} { #<<<
			::rl_http::log debug "rl_http tapchan $chan read [binary encode base64 $bytes]"
			set bytes
		}

		#>>>
		proc flush chan { #<<<
			::rl_http::log debug "rl_http tapchan $chan flush"
			return {}
		}

		#>>>
		proc clear chan { #<<<
			::rl_http::log debug "rl_http tapchan $chan clear"
			return {}
		}

		#>>>
		proc drain chan { #<<<
			::rl_http::log debug "rl_http tapchan $chan drain"
			return {}
		}

		#>>>
		proc write {chan bytes} { #<<<
			::rl_http::log debug "rl_http tapchan $chan write [binary encode base64 $bytes]"
			set bytes
		}

		#>>>
	}

	variable _force_vwait	0
	proc force_vwait_io script { #<<<
		variable _force_vwait
		incr _force_vwait
		try {
			uplevel 1 $script
		} on break {r o} - on continue {r o} {
			dict incr o -level 1
			return -options $o $r
		} on return {r o} {
			dict incr o -level 1
			dict set o -code return
			return -options $o $r
		} finally {
			incr _force_vwait -1
		}
	}

	#>>>
}

# Start the keepalive timeout handler thread <<<
tsv::lock rl_http_threads {
	if {![tsv::exists rl_http_threads keepalive_handler]} {

		if {[llength [info commands ns_thread]] > 0 && [catch {package present ns_shim}]} {
			# using thread::create in Naviserver seems to cause a deadlock (at least when called during server startup)
			set start_thread	{ns_thread begindetached}
		} else {
			set start_thread	thread::create
		}

		{*}$start_thread {
			if {[info commands ns_log] ne ""} {
				interp alias {} log {} ns_log
			} else {
				proc log {lvl msg} {
					set s		[expr {[clock microseconds] / 1e6}]
					set frac	[string range [format %.6f [expr {fmod($s, 1.0)}]] 1 end]
					puts stderr "[clock format [expr {int($s)}] -format "%Y-%m-%d %H:%M:%S" -timezone :UTC]$frac $msg"
				}
			}

			while 1 {
				after 5000

				set now			[expr {[clock microseconds]/1e6}]
				set to_close	{}
				tsv::lock rl_http_keepalive_chans {
					foreach {key parked_chans} [tsv::array get rl_http_keepalive_chans] {
						set pruned	[lmap chaninfo $parked_chans {
							lassign $chaninfo chan expires prev_uses first_use
							if {$now > $expires} {
								lappend to_close	$key $chan
								continue
							}
							set chaninfo
						}]

						if {[llength $pruned] == 0} {
							tsv::unset rl_http_keepalive_chans $key
						} else {
							tsv::set rl_http_keepalive_chans $key $pruned
						}
					}
				}

				foreach {key chan} $to_close {
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

if {[llength [info commands rl_http::async_io]]} {
	rl_http::async_io destroy
}
oo::class create rl_http::async_io { #<<<
	variable {*}{
		timeout_afterid
	}

	method _timeout {type message} { #<<<
		my destroy
		throw [list RL HTTP TIMEOUT $type] $message
	}

	#>>>
	method _connect_async {chanscript seconds} { # Connect to $ip:$port, with timeout support (-async + wait for writable event) <<<
		variable ::rl_http::_force_vwait
		my variable _timeout_connect_seq
		my variable _timeout_connect_res

		set my_seq	[incr _timeout_connect_seq]

		set timeout_afterid	""
		try {
			if {[info coroutine] ne "" && $_force_vwait == 0} {
				set ev_prefix	[list [info coroutine]]
				set wait_cmd	{set _timeout_connect_res($my_seq)	[yield]}
			} else {
				set ev_prefix	[list set   [namespace current]::_timeout_connect_res($my_seq)]
				set wait_cmd	[list vwait [namespace current]::_timeout_connect_res($my_seq)]
			}

			set timeout_afterid		[after [expr {int(round($seconds * 1000))}] [list {*}$ev_prefix timeout]]
			set before	[clock microseconds]
			set chan				[uplevel 1 $chanscript]
			#puts stderr "chan script $chanscript blocked for [format %.3f [expr {([clock microseconds]-$before)/1e3}]] ms"
			chan event $chan writable [list {*}$ev_prefix connected]

			#puts stderr "Waiting for writable on new chan $chan: $wait_cmd"
			try $wait_cmd
			#puts stderr "Got writable on $chan [format %.3f [expr {([clock microseconds]-$before)/1e3}]] ms from start of chan script"

			switch -- $_timeout_connect_res($my_seq) {
				connected {}
				timeout { my _timeout CONNECTION "Timeout connecting to server" }
				default { throw {RL HTTP PANIC} "Unexpected status connecting to server: ($_timeout_connect_res($my_seq))" }
			}
		} on error {errmsg options} {
			catch {
				close $chan
				unset chan
			}
			return -options $options $errmsg
		} finally {
			after cancel $timeout_afterid; set timeout_afterid	""
			if {[info exists chan] && $chan in [chan names]} {
				chan event $chan writable {}
			}
			unset -nocomplain _timeout_connect_res($my_seq)
		}

		set chan
	}

	#>>>
	method _wait_for_readable {chan seconds} { #<<<
		variable ::rl_http::_force_vwait
		my variable _wait_for_readable_seq
		my variable _wait_for_readable_res

		set my_seq	[incr _wait_for_readable_seq]

		set timeout_afterid	""
		try {
			if {[info coroutine] ne "" && $_force_vwait == 0} {
				set ev_prefix	[list [info coroutine]]
				set wait_cmd	{set _wait_for_readable_res($my_seq)	[yield]}
			} else {
				set ev_prefix	[list set   [namespace current]::_wait_for_readable_res($my_seq)]
				set wait_cmd	[list vwait [namespace current]::_wait_for_readable_res($my_seq)]
			}

			if {$seconds ne ""} {
				set timeout_afterid	[after [expr {int(round($seconds * 1000))}] [list {*}$ev_prefix timeout]]
			}
			chan event $chan readable [list {*}$ev_prefix readable]

			#puts stderr "Waiting for readable on $chan: $wait_cmd <[info frame -1]>"
			try $wait_cmd
			#puts stderr "Got readable on $chan"

			switch -- $_wait_for_readable_res($my_seq) {
				readable {}
				timeout {
					my _timeout READ "Timeout waiting for read"
				}
				default {
					throw {RL HTTP PANIC} "Unexpected status waiting for data: ($_wait_for_readable_res($my_seq))"
				}
			}
		} finally {
			after cancel $timeout_afterid; set timeout_afterid	""
			if {$chan in [chan names]} {
				chan event $chan readable {}
			}
			unset -nocomplain _wait_for_readable_res($my_seq)
		}
	}

	#>>>
	method _log {lvl msg} { #<<<
		# Override this to log messages
	}

	#>>>
}

#>>>

::gc_class create ::rl_http {
	superclass ::rl_http::async_io

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
		prev_uses
		first_use
	}

	constructor {a_method a_url args} { #<<<
		namespace path {::oo::Helpers ::parse_args}

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
			-max_keepalive_age		{-default -1 -# {keep a connection for at most this many seconds. <0 = no limit}}
			-max_keepalive_count	{-default -1 -# {keep a connection for at most this many requests. <0 = no limit}}
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
			if {$::rl_http::have_reuri} {
				set u(scheme)	[reuri get $url scheme]
				set u(host)		[reuri get $url host]
				if {[reuri get $url hosttype] eq "local"} {
					set u(port)		"<unix>"
					set u(host)		[file join {*}$u(host)]
				} else {
					set u(port)		[reuri get $url port [expr {
						$u(scheme) eq "http" ? 80 : 443
					}]]
				}
				set u(path)		[reuri extract $url path ""]
				set u(query)	[reuri extract $url query ""]
			} else {
				array set u	[uri::split $url]
				if {[regexp {^\[(?:v0.local:)?(/.*)\]$} $u(host) - u(host)]} {
					set u(port)	"<unix>"
				} elseif {$u(port) eq ""} {
					set u(port) [dict get {
						http	80
						https	443
					} $u(scheme)]
				}
			}
		} trap {RL HTTP} {errmsg options} {
			return -options $options $errmsg
		} on error {errmsg options} {
			::rl_http::log error "Error parsing URI [dict get $options -errorcode]: [dict get $options -errorinfo]"
			throw [list RL URI ERROR] $errmsg
		}

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

		if {$sock in [chan names]} {
			if {[dict exists $response headers connection] && "close" in [dict get $response headers connection]} {
				close $sock
				unset sock
			} else {
				#::rl_http::log debug "Parking keepalive connection: $sock $u(scheme) $u(host) $u(port)"
				my _keepalive_park $sock $u(scheme) $u(host) $u(port) 15
				unset sock
			}
		} else {
			unset sock
		}

		set collected	true
		return
	}

	#>>>
	method _timeout {type message} { #<<<
		# TODO: keep context info to provide a more granular error: timeout during headers read, etc.
		throw [list RL HTTP TIMEOUT $type] $message
	}

	#>>>
	method _cancel_timeout {} { #<<<
		if {![info exists timeout_afterid]} return
		after cancel $timeout_afterid; set timeout_afterid	""
	}

	#>>>
	method _keepalive_connect {scheme host port} { #<<<
		#::rl_http::log debug "[self] _keepalive_connect $scheme $host $port"
		set key		$scheme://$host:$port
		set popchan {key { # Retrieve the next idle keepalive channel for $key <<<
			tsv::lock rl_http_keepalive_chans {
				if {![tsv::exists rl_http_keepalive_chans $key]} {
					return {}
				}
				set chaninfo	[tsv::lpop rl_http_keepalive_chans $key]
				if {$chaninfo eq ""} {
					tsv::unset rl_http_keepalive_chans $key
				}
				set chaninfo
			}
		}}
		#>>>
		#::rl_http::log debug "Looking for parked connection $key: [tsv::array get rl_http_keepalive_chans]"
		while {[set chaninfo [apply $popchan $key]] ne ""} {
			lassign $chaninfo chan expiry prev_uses first_use
			#::rl_http::log debug "[self] reusing $chan for $scheme://$host:$port"
			try {
				thread::attach $chan
				set age	[expr {[clock microseconds]/1e6 - $first_use}]
				if {
					[set max_age [dict get $settings max_keepalive_age]] >= 0 &&
					$age > $max_age
				} {
					#::rl_http::log notice "parked chan too old: $chan for $key (remain: [tsv::get rl_http_keepalive_chans $key])"
					::rl_http::log notice "parked chan too old: $chan for $key"
					chan close $chan
					continue
				} else {
					# Check if the remote closed on us or is too old <<<
					chan configure $chan -blocking 0
					chan read $chan
					if {[chan eof $chan]} {
						#::rl_http::log notice "parked chan collapsed: $chan for $key (remain: [tsv::get rl_http_keepalive_chans $key])"
						::rl_http::log notice "parked chan collapsed: $chan for $key"
						chan close $chan
						continue
					}
					# Check if the remote closed on us >>>
				}
				#puts stderr "Reusing keepalive chan $chan, age: $age, first_use: $first_use"
			} on ok {} {
				if {[dict get $settings tapchan] ne ""} {
					chan push $chan [dict get $settings tapchan]
				}
				#::rl_http::log debug "returning parked chan $chan"
				return $chan
			} on error {errmsg options} {
				::rl_http::log notice "Error attaching to parked chan \"$chan\": [dict get $options -errorinfo]"
			}
		}
		#::rl_http::log debug "Falling back on opening new connection $scheme://$host:$port"
		if {$port eq "<unix>"} {
			# HTTP-over-unix-domain-sockets
			package require unix_sockets
			switch -- $scheme {
				http  {set chan	[my _connect_async {unix_sockets::connect $host} [my _remaining_timeout]]}
				https {
					set chan	[my _connect_async {unix_sockets::connect $host} [my _remaining_timeout]]
					my push_tls $chan {}
				}
				default {throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $scheme] "Scheme $scheme is not supported"}
			}
		} else {
			if {$::rl_http::have_resolve} {
				# $port resolution: RFC 3986 doesn't support non-decimal ports in URIs, so we don't
				# resolve them here
				if {
					![tsv::exists _rl_http_resolve_cache $host] ||
					[clock seconds] - [dict get [tsv::get _rl_http_resolve_cache $host] ts] > 60
				} {
					resolve::resolver instvar resolve
					#::rl_http::log notice "[self] resolving $host"
					#set now	[clock microseconds]
					$resolve add $host
					set addrs	[$resolve get $host -timeout [my _remaining_timeout]]
					#::rl_http::log notice "[self] Got result for $host in [format %.3f [expr {([clock microseconds]-$now)/1e3}]] ms"
					tsv::set _rl_http_resolve_cache $host [list addrs $addrs ts [clock seconds]]
					# TODO: maybe have a background grooming thread go through this cache periodically and
					# remove expired entries?
				} else {
					set addrs	[dict get [tsv::get _rl_http_resolve_cache $host] addrs]
					#::rl_http::log debug "Reused cached addrs for $host:$port: $addrs"
				}
			} else {
				set addrs	[list $host]
				#::rl_http::log debug "No resolve package available, created addr list as $addrs"
			}

			# Try each of the resolved addresses in order, fail if all fail to connect
			set i	0
			foreach addr $addrs {
				incr i
				set chost	$addr
				set cport	$port

				try {
					#::rl_http::log debug "attempting to connect to $chost $port for $scheme://$host:$port"
					switch -- $scheme {
						http  {set chan	[my _connect_async {socket -async $chost $cport}  [my _remaining_timeout]]}
						https {
							set chan [my _connect_async {socket -async $chost $cport}     [my _remaining_timeout]]
							#set before	[clock microseconds]
							my push_tls $chan $host
							#set chan	[s2n::socket -prefer throughput -servername $host $chost $cport]
							#::rl_http::log debug "push_tls on connected socket: [format %.3f [expr {([clock microseconds] - $before)/1e3}]] ms"
						}
						default {throw [list RL HTTP CONNECT UNSUPPORTED_SCHEME $scheme] "Scheme $scheme is not supported"}
					}
					break
				} on error {errmsg options} {
					if {$i < [llength $addrs]} {
						# More remain to try
						::rl_http::log notice "Error connecting to $chost:$cport for $host:$port, trying next address"
						continue
					}
					return -options $options $errmsg
				}
			}
			if {![info exists chan]} {
				# Shouldn't be reachable, the last failed addr attempt above should have thrown an error
				throw [list RL HTTP CONNECT FAILED $scheme://$host:$port] "Couldn't connect to $scheme://$host:$port"
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
		set prev_uses	0
		set first_use	[expr {[clock microseconds] / 1e6}]
		set chan
	}

	#>>>
	method push_tls {chan servername} { #<<<
		variable ::rl_http::tls_driver
		if {$::rl_http::tls_driver eq "s2n"} {
			package require s2n
			if {$servername eq ""} {
				s2n::push $chan -prefer throughput
			} else {
				s2n::push $chan -servername $servername -prefer throughput
			}
		} else {
			package require tls
			if {$servername eq ""} {
				tls::import $chan -require true -cadir /etc/ssl/certs
			} else {
				tls::import $chan -servername $servername -require true -cadir /etc/ssl/certs
			}
		}
	}

	#>>>
	method _keepalive_park {chan scheme host port timeout} { #<<<
		#::rl_http::log notice "Parking $scheme://$host:$port"
		if {$chan in [chan names]} {
			if {[dict get $settings tapchan] ne ""} {
				chan pop $chan
			}

			# Apply -max_keepalive_* limits if set
			set now		[expr {[clock microseconds] / 1e6}]
			set age		[expr {$now - $first_use}]
			set uses	[expr {$prev_uses + 1}]
			if {
				(
					[set max_age	[dict get $settings max_keepalive_age]] >= 0 &&
					$age >= $max_age
				) || (
					[set max_uses	[dict get $settings max_keepalive_count]] >= 0 &&
					$uses >= $max_uses
				)
			} {
				close $chan
				return
			}

			set expires	[expr {
				$max_age >= 0
					? $first_use + $max_age
					: $now + $timeout
			}]

			thread::detach $chan
			tsv::lpush rl_http_keepalive_chans $scheme://$host:$port [list \
				$chan \
				$expires \
				$uses \
				$first_use \
			]
		}
	}

	#>>>
	method _connect {} { #<<<
		set sock	[my _keepalive_connect $u(scheme) $u(host) $u(port)]
		chan configure $sock \
			-translation {auto crlf} \
			-blocking 0 \
			-buffering full \
			-buffersize 65536 \
			-encoding ascii
	}

	#>>>
	method _send_request {} { #<<<
		puts $sock "$method $u(path)[if {$u(query) ne ""} {set _ ?$u(query)}] HTTP/[dict get $settings ver]"
		set have_headers	[lsort -unique [lmap {k v} [dict get $settings headers] {string tolower $k}]]

		if {$::rl_http::have_reuri} {
			set encode_host {str {reuri encode host $str}}
		} else {
			set encode_host {str {set str}}	;# Wrong, but matches what was happening before, so not a regression
		}

		if {"host" ni $have_headers} {
			if {[dict get $settings override_host] ne ""} {
				puts $sock "Host: [apply $encode_host [dict get $settings override_host]]"
			} else {
				if {$u(port) eq "<unix>"} {
					# Unix domain socket
					puts $sock "Host: localhost"
				} else {
					puts $sock "Host: [apply $encode_host $u(host)][if {$u(port) != 80} {set _ :$u(port)}]"
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
			chan configure $sock -buffersize 1000000
			chan configure $sock -translation {auto binary}
			puts -nonewline $sock [dict get $settings data]
			chan configure $sock -translation {auto crlf} -encoding ascii
		} elseif {[dict get $settings data_cb] ne ""} {
			chan configure $sock -buffersize 1000000
			chan configure $sock -translation {auto binary}
			uplevel #0 [list {*}[dict get $settings data_cb] $sock]
			chan configure $sock -translation {auto crlf} -encoding ascii
		}
		flush $sock
	}

	#>>>
	method _remaining_timeout {} { #<<<
		if {[dict get $settings timeout] eq ""} return
		set remain	[expr {
			[dict get $settings timeout] - ([clock microseconds] - $starttime) / 1e6
		}]
		if {$remain < 0} {return 0.0}
		set remain
	}

	#>>>
	method _read_headers {} { #<<<
		chan configure $sock -buffering line -translation {auto crlf} -encoding ascii
		while 1 {
			#set before	[clock microseconds]
			set line	[gets $sock]
			#set elapsed_usec	[expr {[clock microseconds] - $before}]
			if {[eof $sock]} {
				set headers_status	dropped
				break
			}

			if {![chan blocked $sock]} {
				if {![dict exists $response statusline]} {
					if {$line eq ""} {
						# RFC 7230 Section 3.5
						continue
					}
					dict set response statusline $line
					my _response_start $line
					continue
				}

				if {$line eq ""} {
					set headers_status	ok
					break
				}

				append resp_headers_buf $line \n
			} else {
				my _wait_for_readable $sock [my _remaining_timeout]
			}
		}

		if {$headers_status ne "ok"} {
			throw [list RL HTTP READ_HEADERS $headers_status] "Error reading HTTP headers: $headers_status"
		}
	}

	#>>>
	method _response_start line {}	;# Hook this to get called when the status line is received
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
			set kl	[string tolower $k]

			set vl	[if {$kl in {
				age
				authorization
				content-length
				content-location
				content-md5
				content-range
				content-type
				date
				etag
				expires
				from
				host
				if-modified-since
				if-range
				if-unmodified-since
				last-modified
				location
				max-forwards
				proxy-authentication
				range
				referer
				retry-after
				server
				user-agent
				set-cookie
				cookie
			}} {
				list [string trim $v]
			} else {
				lmap e [split $v ,] {string trim $e}
			}]

			my _append_headers $kl [lmap e $vl {string trim $e}]
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
	method _read_chunk_control {} { #<<<
		chan configure $sock -translation {auto crlf} -encoding ascii -buffering line

		while 1 {
			set chunk_buf	[gets $sock]

			if {[eof $sock]} {
				set body_status	dropped
				break
			}

			if {![chan blocked $sock]} {
				set body_status	ok
				break
			}

			my _wait_for_readable $sock [my _remaining_timeout]
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

		while 1 {
			unset -nocomplain wait
			my _readable_body $expecting
			if {[info exists wait]} break
			my _wait_for_readable $sock [my _remaining_timeout]
		}
		set body_status	$wait

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

			while 1 {
				my _readable_body $expecting
				if {[info exists wait]} break
				my _wait_for_readable $sock [my _remaining_timeout]
			}
			set body_status	$wait

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
	if {$::rl_http::have_reuri} {
		self method encode_query_params args {reuri::query new $args}
	} elseif {[info commands ns_urlencode] eq ""} {
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
