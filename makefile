DMD=dmd

FILES:=$(wildcard source/stdx/collections/*d)

test:
	$(DMD) -ofbin/unittest -Isource -unittest -main $(FILES)
	./bin/unittest
