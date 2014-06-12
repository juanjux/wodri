#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=userrule_test --force && ./test && rm -f ./test
