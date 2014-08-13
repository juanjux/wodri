#!/bin/sh
cd ../source/retriever
#dub build -v --build=plain --config=db_test && ./test && rm -f ./test && rm -f  test.o
dub build -v --build=plain --config=search_test && ./test && rm -f test.o
