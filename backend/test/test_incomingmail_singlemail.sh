#!/bin/sh
cd ../source/retriever
dub build --build=plain --force --config=incomingmail_singletest && ./test && rm -f ./test
