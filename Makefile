# Toolchain locations are discovered; override any of them on the command
# line, e.g. `make gui LAZARUSDIR=~/lazarus`.
FPC ?= fpc
# Lazarus: lazbuild from PATH, else a checkout in ~/src/lazarus.
LAZBUILD ?= $(or $(shell command -v lazbuild 2>/dev/null),$(HOME)/src/lazarus/lazbuild)
LAZARUSDIR ?= $(patsubst %/,%,$(dir $(realpath $(LAZBUILD))))
UNITDIR = src/units
SRC = src
# Extra unit path for the macOS univint headers. Empty by default: a standard
# fpc.cfg already searches units/$fpctarget/*.
UNIVINT ?=
LDWRAP = $(CURDIR)/tools/ldwrap
BUILDFLAGS = -Mobjfpc -Scghi -O2 -g -gl -Fi$(UNITDIR) -Fu$(UNITDIR) \
	$(if $(UNIVINT),-Fu$(UNIVINT)) \
	-k'-framework CoreFoundation' -k'-framework CoreServices' -FE. -FU.

.PHONY: all clean test gui app check-platform

all: opendisk

opendisk: $(SRC)/opendisk.lpr $(UNITDIR)/FileTree.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/Formatters.pas \
		$(UNITDIR)/ChartItem.pas $(UNITDIR)/RingsLayout.pas \
		$(UNITDIR)/RingsSVG.pas $(UNITDIR)/SearchIndex.pas $(UNITDIR)/PlatformTextFold.pas \
		$(UNITDIR)/ScanTopology.pas $(UNITDIR)/PlatformProcessTuning.pas \
		$(UNITDIR)/Incremental.pas $(UNITDIR)/ChangeJournal.pas $(UNITDIR)/PlatformChangeJournal.pas $(UNITDIR)/JournalFactory.pas \
		$(UNITDIR)/ScanCache.pas $(UNITDIR)/Volumes.pas \
		$(UNITDIR)/PlatformFS.pas $(UNITDIR)/PlatformVolumes.pas \
		$(UNITDIR)/PlatformShell.pas $(UNITDIR)/PlatformLocale.pas
	$(FPC) $(BUILDFLAGS) -oopendisk $(SRC)/opendisk.lpr

# Cocoa LCL needs Xcode ld-classic — new ld (1267+) rejects FPC ObjC method lists.
gui: src/gui/OpenDiskGUI.lpi tools/ldwrap/ld
	@test -x "$(LAZBUILD)" || { echo "lazbuild not found: put it on PATH or pass LAZBUILD=/path/to/lazbuild" >&2; exit 1; }
	$(LAZBUILD) --lazarusdir=$(LAZARUSDIR) --compiler=$$(command -v $(FPC)) \
		--opt="-FD$(LDWRAP)" \
		src/gui/OpenDiskGUI.lpi

# OpenDisk.app: the GUI binary copied (not linked) into a proper bundle with
# packaging/Info.plist and icon, ad-hoc signed so Finder and the Dock
# launch it cleanly.
APP = OpenDisk.app
app: gui packaging/Info.plist packaging/OpenDisk.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp opendisk-gui $(APP)/Contents/MacOS/OpenDisk
	cp packaging/Info.plist $(APP)/Contents/Info.plist
	cp packaging/OpenDisk.icns $(APP)/Contents/Resources/OpenDisk.icns
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force --sign - $(APP)
	plutil -lint $(APP)/Contents/Info.plist

# OS-specific code stays in src/units/Platform*.pas (od-31j.29).
check-platform:
	./tests/test_check_platform.sh
	./tools/check-platform.sh

# ld and the as symlink are generated; ld.in finds ld-classic via xcrun.
tools/ldwrap/ld: tools/ldwrap/ld.in
	@AS=$$(xcrun --find as 2>/dev/null) || { echo "xcrun cannot find 'as': install Xcode" >&2; exit 1; }; \
		mkdir -p tools/ldwrap && cp tools/ldwrap/ld.in tools/ldwrap/ld && \
		chmod +x tools/ldwrap/ld && ln -sf "$$AS" tools/ldwrap/as

test: tests/test_filetree tests/test_dirreader tests/test_scancache \
		tests/test_incremental tests/test_fsevents tests/test_volumes \
		tests/test_collector tests/test_protectedpaths tests/test_ringslayout \
		tests/test_traversal tests/test_volumeroot tests/test_texttrim \
		tests/test_formatters tests/test_search tests/test_remove \
		tests/test_cleanable tests/test_topology tests/test_deletejob
	./tests/test_check_platform.sh
	./tools/check-platform.sh
	./tests/test_filetree
	./tests/test_dirreader
	./tests/test_scancache
	./tests/test_incremental
	./tests/test_fsevents
	./tests/test_volumes
	./tests/test_collector
	./tests/test_protectedpaths
	./tests/test_ringslayout
	./tests/test_traversal
	./tests/test_volumeroot
	./tests/test_texttrim
	./tests/test_formatters
	./tests/test_search
	./tests/test_remove
	./tests/test_cleanable
	./tests/test_topology
	./tests/test_deletejob

tests/test_filetree: tests/test_filetree.pas $(UNITDIR)/FileTree.pas
	$(FPC) $(BUILDFLAGS) -otests/test_filetree tests/test_filetree.pas

tests/test_dirreader: tests/test_dirreader.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas \
		$(UNITDIR)/PlatformFS.pas $(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_dirreader tests/test_dirreader.pas

tests/test_scancache: tests/test_scancache.pas $(UNITDIR)/FileTree.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas $(UNITDIR)/ScanCache.pas \
		$(UNITDIR)/PlatformFS.pas $(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_scancache tests/test_scancache.pas

tests/test_incremental: tests/test_incremental.pas $(UNITDIR)/FileTree.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas \
		$(UNITDIR)/Incremental.pas $(UNITDIR)/PlatformFS.pas $(UNITDIR)/PlatformVolumes.pas \
		$(UNITDIR)/Volumes.pas $(UNITDIR)/ChangeJournal.pas $(UNITDIR)/PlatformChangeJournal.pas $(UNITDIR)/JournalFactory.pas
	$(FPC) $(BUILDFLAGS) -otests/test_incremental tests/test_incremental.pas

tests/test_fsevents: tests/test_fsevents.pas $(UNITDIR)/ChangeJournal.pas $(UNITDIR)/PlatformChangeJournal.pas $(UNITDIR)/JournalFactory.pas \
		$(UNITDIR)/PlatformFS.pas $(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_fsevents tests/test_fsevents.pas

tests/test_volumes: tests/test_volumes.pas $(UNITDIR)/Volumes.pas \
		$(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_volumes tests/test_volumes.pas

tests/test_collector: tests/test_collector.pas $(UNITDIR)/Collector.pas \
		$(UNITDIR)/PlatformRemove.pas $(UNITDIR)/ProtectedPaths.pas $(UNITDIR)/PlatformProtectedRoots.pas
	$(FPC) $(BUILDFLAGS) -otests/test_collector tests/test_collector.pas

tests/test_protectedpaths: tests/test_protectedpaths.pas \
		$(UNITDIR)/ProtectedPaths.pas $(UNITDIR)/PlatformProtectedRoots.pas \
		$(UNITDIR)/PlatformFS.pas
	$(FPC) $(BUILDFLAGS) -otests/test_protectedpaths tests/test_protectedpaths.pas

tests/test_ringslayout: tests/test_ringslayout.pas $(UNITDIR)/RingsLayout.pas \
		$(UNITDIR)/ChartItem.pas $(UNITDIR)/FileTree.pas
	$(FPC) $(BUILDFLAGS) -otests/test_ringslayout tests/test_ringslayout.pas

tests/test_traversal: tests/test_traversal.pas $(UNITDIR)/Traversal.pas \
		$(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas $(UNITDIR)/FileTree.pas $(UNITDIR)/PlatformFS.pas \
		$(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_traversal tests/test_traversal.pas

tests/test_volumeroot: tests/test_volumeroot.pas $(UNITDIR)/Incremental.pas \
		$(UNITDIR)/ChangeJournal.pas $(UNITDIR)/PlatformChangeJournal.pas $(UNITDIR)/JournalFactory.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas \
		$(UNITDIR)/Volumes.pas $(UNITDIR)/PlatformVolumes.pas
	$(FPC) $(BUILDFLAGS) -otests/test_volumeroot tests/test_volumeroot.pas

tests/test_texttrim: tests/test_texttrim.pas $(UNITDIR)/TextTrim.pas
	$(FPC) $(BUILDFLAGS) -otests/test_texttrim tests/test_texttrim.pas

tests/test_formatters: tests/test_formatters.pas $(UNITDIR)/Formatters.pas \
		$(UNITDIR)/PlatformLocale.pas tests/data/bytecount_en_US.tsv \
		tests/data/bytecount_en_PL.tsv
	$(FPC) $(BUILDFLAGS) -otests/test_formatters tests/test_formatters.pas

tests/test_search: tests/test_search.pas $(UNITDIR)/SearchIndex.pas \
		$(UNITDIR)/PlatformTextFold.pas $(UNITDIR)/FileTree.pas
	$(FPC) $(BUILDFLAGS) -otests/test_search tests/test_search.pas

tests/test_remove: tests/test_remove.pas $(UNITDIR)/PlatformRemove.pas
	$(FPC) $(BUILDFLAGS) -otests/test_remove tests/test_remove.pas

tests/test_cleanable: tests/test_cleanable.pas $(UNITDIR)/CleanableSpace.pas \
		$(UNITDIR)/PlatformCacheCatalog.pas $(UNITDIR)/FileTree.pas $(UNITDIR)/PlatformFS.pas
	$(FPC) $(BUILDFLAGS) -otests/test_cleanable tests/test_cleanable.pas

tests/test_topology: tests/test_topology.pas $(UNITDIR)/ScanTopology.pas \
		$(UNITDIR)/PlatformProcessTuning.pas \
		$(UNITDIR)/Traversal.pas $(UNITDIR)/FileTree.pas $(UNITDIR)/Volumes.pas \
		$(UNITDIR)/PlatformVolumes.pas $(UNITDIR)/DirTypes.pas $(UNITDIR)/PlatformDirReader.pas \
		$(UNITDIR)/PlatformFS.pas $(UNITDIR)/ScanCache.pas $(UNITDIR)/Incremental.pas \
		$(UNITDIR)/ChangeJournal.pas $(UNITDIR)/PlatformChangeJournal.pas $(UNITDIR)/JournalFactory.pas
	$(FPC) $(BUILDFLAGS) -otests/test_topology tests/test_topology.pas

tests/test_deletejob: tests/test_deletejob.pas $(UNITDIR)/Collector.pas \
		$(UNITDIR)/PlatformRemove.pas $(UNITDIR)/ProtectedPaths.pas $(UNITDIR)/PlatformProtectedRoots.pas
	$(FPC) $(BUILDFLAGS) -otests/test_deletejob tests/test_deletejob.pas

clean:
	rm -f opendisk opendisk-gui tests/test_filetree tests/test_dirreader \
		tests/test_scancache tests/test_incremental tests/test_fsevents tests/test_volumes \
		tests/test_collector tests/test_protectedpaths tests/test_ringslayout \
		tests/test_traversal tests/test_volumeroot tests/test_texttrim \
		tests/test_formatters tests/test_search tests/test_remove tests/test_cleanable tests/test_topology tests/test_deletejob *.o *.ppu $(UNITDIR)/*.o $(UNITDIR)/*.ppu \
		tests/*.o tests/*.ppu link*.res linkfiles*.res ppas.sh
	rm -rf src/gui/lib $(APP)
