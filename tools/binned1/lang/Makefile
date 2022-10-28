
all: d_lang.so cpp_lang.so c_lang.so

d_lang.so: d_parser.c d_scanner.cc
	gcc -shared -o d_lang.so -fPIC d_parser.c d_scanner.cc -lstdc++

cpp_lang.so: cpp_parser.c cpp_scanner.cc
	gcc -shared -o cpp_lang.so -fPIC cpp_parser.c cpp_scanner.cc -lstdc++

c_lang.so: c_parser.c
	gcc -shared -o c_lang.so -fPIC c_parser.c

.PHONY: clean
clean:
	rm -f ./*.so