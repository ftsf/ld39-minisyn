APPNAME=minisyn
NIMC=nim
DATE=$(shell date +%Y-%m-%d)

SOURCES=src/main.nim

minisynd: src/main.nim
	nim c -d:debug --nimcache:nimcache/debug -p:../nico -o:$@ --threads:on -d:gif $<

minisyn: src/main.nim
	nim c -d:release --nimcache:nimcache/release -p:../nico -o:$@ --threads:on -d:gif $<

rund: minisynd
	./minisynd

run: minisyn
	./minisyn

osx: src/main.nim
	${NIMC} c -p:../nico -d:release -d:osx --threads:on -o:minisyn.app/Contents/MacOS/minisyn src/main.nim
	cp -r assets minisyn.app/Contents/Resources/
	find minisyn.app/Contents/Resources/assets/ -name '*.wav' -delete
	rm minisyn-${DATE}-osx.zip || true
	zip --symlinks -r ${APPNAME}-${DATE}-osx.zip minisyn.app

linux64: $(SOURCES)
	${NIMC} c -p:../nico -d:release --threads:on -o:linux/${APPNAME}.x86_64 src/main.nim

linux32: $(SOURCES)
	${NIMC} c -p:../nico -d:release -d:linux32 --threads:on -o:linux/${APPNAME}.x86 src/main.nim

linux: linux32 linux64
	cp -r assets linux
	find linux/assets/ -name '*.wav' -delete
	cd linux; \
	tar czf ../${APPNAME}-${DATE}-linux.tar.gz .

windows:
	${NIMC} c -p:../nico -d:release -d:windows --tlsEmulation:off --threads:on -o:winversion/${APPNAME}.exe src/main.nim
	cp -r assets winversion
	find winversion/assets/ -name '*.wav' -delete
	rm ${APPNAME}-${DATE}-win32.zip || true
	cd winversion; \
	zip -r ../${APPNAME}-${DATE}-win32.zip .

.PHONY: run rund windows linux linux64 linux32 osx
