#!/bin/sh
VIBEDIR=/home/juanjux/.dub/packages/vibe-d-0.7.20/source
dmd -main\
    -version=generatetestdata\
    -dw\
    -m64\
    -inline\
    -O\
    -unittest\
    -version=VibeLibeventDriver\
    -L/usr/lib/x86_64-linux-gnu/libevent.a\
    -I../source/lib\
    -I../source\
    -I/home/juanjux/.dub/packages/libevent-master/\
    -I$VIBEDIR\
    ../source/retriever/incomingemail.d\
    ../source/lib/characterencodings.d\
    $VIBEDIR/vibe/utils/dictionarylist.d\
    $VIBEDIR/vibe/utils/array.d\
    $VIBEDIR/vibe/utils/string.d\
    $VIBEDIR/vibe/utils/memory.d\
    $VIBEDIR/vibe/utils/hashmap.d\
    $VIBEDIR/vibe/data/json.d\
    $VIBEDIR/vibe/data/serialization.d\
    $VIBEDIR/vibe/core/args.d\
    $VIBEDIR/vibe/core/concurrency.d\
    $VIBEDIR/vibe/core/log.d\
    $VIBEDIR/vibe/core/task.d\
    $VIBEDIR/vibe/core/sync.d\
    $VIBEDIR/vibe/core/stream.d\
    $VIBEDIR/vibe/core/driver.d\
    $VIBEDIR/vibe/core/file.d\
    $VIBEDIR/vibe/core/core.d\
    $VIBEDIR/vibe/core/net.d\
    $VIBEDIR/vibe/core/drivers/threadedfile.d\
    $VIBEDIR/vibe/core/drivers/utils.d\
    $VIBEDIR/vibe/core/drivers/libevent2.d\
    $VIBEDIR/vibe/core/drivers/libevent2_tcp.d\
    $VIBEDIR/vibe/inet/url.d\
    $VIBEDIR/vibe/inet/path.d\
    $VIBEDIR/vibe/textfilter/html.d\
    $VIBEDIR/vibe/textfilter/urlencode.d\
    $VIBEDIR/vibe/internal/meta/uda.d\
    $VIBEDIR/vibe/internal/meta/traits.d &&\
    rm -f incomingemail.o && ./incomingemail 

