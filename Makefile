APPNAME=minisyn
NIMC=nim
DATE=$(shell date +%Y-%m-%d)

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
	cp -r maps minisyn.app/Contents/Resources/
	cp config.ini minisyn.app/Contents/Resources/
	find minisyn.app/Contents/Resources/assets/ -name '*.wav' -delete
	rm minisyn-${DATE}-osx.zip || true
	zip --symlinks -r ${APPNAME}-${DATE}-osx.zip minisyn.app

.PHONY: run rund
