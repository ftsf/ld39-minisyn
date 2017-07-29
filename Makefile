minisyn: src/main.nim
	nim c -p:../nico -o:$@ --threads:on -d:gif $<

run: minisyn
	./minisyn

.PHONY: run
