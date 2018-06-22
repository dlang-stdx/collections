DMD=dmd

FILES:=$(wildcard source/stdx/collections/*d)
DFLAGS=

test:
	$(DMD) -ofbin/unittest -Isource -unittest -main $(DFLAGS) $(FILES)
	./bin/unittest
