FPC = fpc
UNITDIR = src/units
SRC = src
BUILDFLAGS = -Mobjfpc -Scghi -O2 -g -gl -Fi$(UNITDIR) -Fu$(UNITDIR) -FE. -FU.

.PHONY: all clean test

all: opendisk

opendisk: $(SRC)/opendisk.lpr $(UNITDIR)/FileTree.pas $(UNITDIR)/DirReader.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/Formatters.pas
	$(FPC) $(BUILDFLAGS) -oopendisk $(SRC)/opendisk.lpr

test: tests/test_filetree
	./tests/test_filetree

tests/test_filetree: tests/test_filetree.pas $(UNITDIR)/FileTree.pas
	$(FPC) $(BUILDFLAGS) -otests/test_filetree tests/test_filetree.pas

clean:
	rm -f opendisk tests/test_filetree *.o *.ppu $(UNITDIR)/*.o $(UNITDIR)/*.ppu \
		tests/*.o tests/*.ppu link*.res linkfiles*.res ppas.sh
