#!/bin/sh
cd ../source/db
dub build -v --build=plain --config=db_test && ./test && rm -f test.o
