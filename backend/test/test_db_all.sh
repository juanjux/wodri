#!/bin/sh
cd ../source/db
dub build -v --build=plain --config=db_insertalltest && ./test && rm -f test.o
