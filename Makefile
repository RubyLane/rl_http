DESTDIR=
PREFIX=/usr/local
PACKAGE_NAME=rl_http
VER=1.17
TCLSH=tclsh

all: tm/$(PACKAGE_NAME)-$(VER).tm

tm/$(PACKAGE_NAME)-$(VER).tm: rl_http.tcl
	mkdir -p tm
	cp rl_http.tcl tm/$(PACKAGE_NAME)-$(VER).tm

install-tm: tm/$(PACKAGE_NAME)-$(VER).tm
	mkdir -p $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl
	cp $< $(DESTDIR)$(PREFIX)/lib/tcl8/site-tcl/

install: install-tm

clean:
	rm -r tm

test: tm/$(PACKAGE_NAME)-$(VER).tm
	$(TCLSH) tests/all.tcl $(TESTFLAGS) -load "source [file join $$::tcltest::testsDirectory .. tm $(PACKAGE_NAME)-$(VER).tm]; package provide $(PACKAGE_NAME) $(VER)"

vim-gdb: tm/$(PACKAGE_NAME)-$(VER).tm
	vim -c "set number" -c "set mouse=a" -c "set foldlevel=100" -c "Termdebug -ex set\ print\ pretty\ on --args $(TCLSH) tests/all.tcl -singleproc 1 -load source\ [file\ join\ $$::tcltest::testsDirectory\ ..\ tm\ $(PACKAGE_NAME)-$(VER).tm];\ package\ provide\ $(PACKAGE_NAME)\ $(VER) $(TESTFLAGS)" -c "2windo set nonumber" -c "1windo set nonumber"

.PHONY: all clean install install-tm test
