DESTDIR=/usr/local
PACKAGE_NAME=rl_http
VER=1.14.4
TCLSH=tclsh

all: tm/$(PACKAGE_NAME)-$(VER).tm

tm/$(PACKAGE_NAME)-$(VER).tm: rl_http.tcl
	mkdir -p tm
	cp rl_http.tcl tm/$(PACKAGE_NAME)-$(VER).tm

install-tm: tm/$(PACKAGE_NAME)-$(VER).tm
	mkdir -p $(DESTDIR)/lib/tcl8/site-tcl
	cp $< $(DESTDIR)/lib/tcl8/site-tcl/

install: install-tm

clean:
	rm -r tm

test: tm/$(PACKAGE_NAME)-$(VER).tm
	$(TCLSH) tests/all.tcl $(TESTFLAGS) -load "source [file join $$::tcltest::testsDirectory .. tm $(PACKAGE_NAME)-$(VER).tm]; package provide $(PACKAGE_NAME) $(VER)"

.PHONY: all clean install install-tm test
