#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_singletest && ./test && rm -f ./test
