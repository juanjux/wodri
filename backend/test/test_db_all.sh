#!/bin/sh
cd ../source/retriever
dub build -v --build=plain --config= db_insertalltest && ./test && rm -f test.o
