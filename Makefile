minisynd: src/main.nim
	nim c -d:debug --nimcache:nimcache/debug -p:../nico -o:$@ --threads:on -d:gif $<

minisyn: src/main.nim
	nim c -d:release --nimcache:nimcache/release -p:../nico -o:$@ --threads:on -d:gif $<

rund: minisynd
	./minisynd

run: minisyn
	./minisyn

.PHONY: run rund
