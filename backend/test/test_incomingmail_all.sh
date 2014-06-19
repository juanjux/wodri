#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_allmailstest && ./test && rm -f ./test
