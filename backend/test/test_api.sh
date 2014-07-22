#!/bin/sh
cd ../source/webbackend
DUB=/usr/local/bin/dub
$DUB build  -v --build=plain --config=apitest && rm -f test.o && ./test
