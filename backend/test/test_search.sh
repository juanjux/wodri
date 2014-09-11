#!/bin/sh
cd ../source/db
dub build -v --build=debug --config=search_test && ./test && rm -f test.o
