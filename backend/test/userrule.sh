#!/bin/sh
cd ../source/retriever
dub build -v --build=plain --config=userrule_test && ./test && rm -f ./test
