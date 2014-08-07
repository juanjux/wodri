#!/bin/sh
cd ../source/webbackend
DUB=/usr/local/bin/dub
$DUB build --force  -v --build=plain --config=curltest && rm -f test.o && ./test
