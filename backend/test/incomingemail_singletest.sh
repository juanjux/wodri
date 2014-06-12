#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_singletest --force && ./test && rm -f ./test
