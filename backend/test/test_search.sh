#!/bin/sh
cd ../source/retriever
dub build -v --build=release --config=search_test && ./test && rm -f test.o
