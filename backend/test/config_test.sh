#!/bin/sh
cd ../source/retriever
dub build -v --build=plain --config=config_test && ./test && rm -f ./test && rm -f  test.o
