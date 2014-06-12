#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_allmailstest --force && ./test && rm -f ./test
