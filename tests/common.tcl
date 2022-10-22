if {[llength [info commands replay_server]] > 0} return
try {

tcltest::loadTestedCommands
package require rl_http
package require md5
package require chantricks
package require uri

proc ::rl_http::log {lvl msg} {
	puts stderr $msg
}

proc parse_reqs bytes { #<<<
    set rl_httpreqs	{}
    while {[string length $bytes]} {
		if {![regexp {^(.*?)\r\n(.*?)\r\n\r\n(.*)$} $bytes - reqline headers tail]} {
			error "Can't extract reqline and headers from [binary encode base64 $bytes]"
		}
		if {![regexp {^([-!#$%&'*+.^_`|~a-zA-Z0-0]+) ([^ ]+) HTTP/([0-9]\.[0-9])$} $reqline - method request_target ver]} {
			error "Can't parse reqline: ($reqline)"
		}
		# Unfold headers
		regsub -all {\r\n(?: |\t)+} $headers { } headers
		set hdrs	{}
		foreach {- headerline} [regexp -all -inline {^(.*?)(?:\r\n|$)} $headers] {
			foreach {- header_name header_value} [regexp -all -inline {^([-!#$%&'*+.^_`|~a-zA-Z0-9]+):[ \t]*(.*?)[ \t]*$} $headerline] {
				foreach v [split $header_value ,] {
					set v	[string trim $v " \t"]
					dict lappend hdrs [string tolower $header_name] $v
				}
			}
		}

		# Reconstruct rl_http constructor arguments from the req and headers
		set rl_httpargs	[list $method $request_target -ver $ver]
		set req_headers	{}

		set got_content_len	0
		foreach {h vals} $hdrs {
			switch $h {
				accept		{lappend rl_httpargs -accept		[lindex $vals end]}
				host		{lappend rl_httpargs -override_host	[lindex $vals end]}
				user-agent	{lappend rl_httpargs -useragent		[lindex $vals end]}
				content-length {
					set len	[lindex $vals end]
					if {$len > [string length $tail]} {
						error "Content-Length from header doesn't match write tail: [string length $tail]"
					}
					set data	[string range $tail 0 $len-1]
					set bytes	[string range $tail $len end]
					lappend rl_httpargs -data $data
					set got_content_len	1
				}
				connection - accept-encoding - accept-charset {}
				default	{
					foreach v $vals {
						lappend req_headers	$h $v
					}
				}
			}
		}
		if {!$got_content_len} {
			if {[string length $tail]} {
				lappend rl_httpargs -data $tail
			}
			set bytes	{}
		}
		if {$req_headers ne {}} {
			lappend rl_httpargs -headers $req_headers
		}

		lappend rl_httpreqs $rl_httpargs
    }
    set rl_httpreqs
}

#>>>
gc_class create replay_server { #<<<
    variable {*}{
		dump
		port
		afterid	
		datum
		write_chunks
		clients
    }

    constructor a_dump { #<<<
		if {[self next] ne ""} next
		set dump	$a_dump
		set listen	[socket -server [namespace code {my _accept}] 0]
		set port	[lindex [chan configure $listen -sockname] 2]
		set afterid	""
		set clients	{}
		foreach {reltime dir b64} $dump {
			if {$dir ne "read"} continue
			lappend write_chunks	[expr {int($reltime)}] [binary decode base64 $b64]
		}
    }

    #>>>
    destructor { #<<<
		after cancel $afterid; set afterid ""
		if {[info exists listen]} {
			close $listen
			unset listen
		}
		foreach chan [dict keys $clients] {
			close $chan
		}
		set clients	{}
		if {[self next] ne ""} next
    }

    #>>>
    method port {} {set port}
    method _accept {chan cl_ip cl_port} { #<<<
		chan configure $chan -translation binary -blocking 0 -buffering none
		chan event $chan readable [namespace code [list my _readable $chan]]
		dict set clients $chan {}
		my _post_next_write [clock microseconds] $chan $write_chunks
    }

    #>>>
    method _readable chan { #<<<
		set chunk	[read $chan]
		if {$chunk ne {}} {
			#puts stderr "tap_server read:\n$chunk"
		}
		if {[eof $chan]} {
			close $chan
			dict unset clients $chan
			return
		}
		# TODO: check $chunk against what we're expecting to receive
    }

    #>>>
    method _post_next_write {datum chan remaining} { #<<<
		try {
			while {[llength $remaining]} {
				set rel_elapsed	[expr {[clock microseconds] - $datum}]
				#puts stderr "_post_next_write rel_elapsed: $rel_elapsed, next: ([lindex $remaining 0])"
				if {$rel_elapsed < [lindex $remaining 0]} {
					break
				}
				set remaining	[lassign $remaining[unset remaining] - bytes]
				#puts stderr "tap_server writing next chunk: [string length $bytes] bytes"
				puts -nonewline $chan $bytes
				flush $chan
			}
			if {[llength $remaining]} {
				set delay_ms	[expr {max(1,([lindex $remaining 0] - ([clock microseconds]-$datum))/1000)}]
				#puts stderr "waiting $delay_ms ms to write the next chunk"
				set afterid		[after $delay_ms [namespace code [list my _post_next_write $datum $chan $remaining]]]
			}
		} on error {errmsg options} {
			puts stderr "Unhandled error in _post_next_write: [dict get $options -errorinfo]"
			return -options $options $errmsg
		}
    }

    #>>>
}

#>>>
proc replay_tap tap_dump { #<<<
    set requests	{}
    set writebytes	{}
    foreach {rel dir b64} $tap_dump {
		if {$dir ne "write"} continue
		append writebytes [binary decode base64 $b64]
    }
    replay_server instvar s $tap_dump
    set base	http://localhost:[$s port]

    lmap req [parse_reqs $writebytes] {
		set args	[lassign $req method target]
		rl_http instvar h $method $base$target {*}$args
		list [$h code] [$h headers] [$h body]
    }
}

#>>>
} on error {errmsg options} {
   puts stderr "Error loading common.tcl: [dict get $options -errorinfo]"
}

# vim: ft=tcl foldmethod=marker foldmarker=<<<,>>> ts=4 shiftwidth=4
