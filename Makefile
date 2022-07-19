TCLSH = tclsh8.6

all:

test:
	$(TCLSH) tests/all.tcl $(TESTFLAGS)

clean:
