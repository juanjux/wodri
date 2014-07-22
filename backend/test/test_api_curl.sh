#!/bin/sh
cd ../source/webbackend
DUB=/usr/local/bin/dub
$DUB run -v --build=plain --config=curltest&
sleep 5
rdmd ../../test/apilivetests.d
killall dub
killall test
