module app;

import db.config: getConfig;
import std.path;
import std.stdio;
import vibe.core.log;
import vibe.d;
import vibe.http.fileserver;
import vibe.inet.path;
import webbackend.api;
import webbackend.utils;
import common.utils;


shared static this()
{
    immutable config = getConfig();
    auto router = new URLRouter;

    // Log
    setLogFile(buildPath(config.mainDir, "backend", "log", "webbackend.log"),
               LogLevel.info);
    //setLogLevel(LogLevel.debugV);

    // Auth
    router.any("*", performBasicAuth("Site Realm", toDelegate(&checkAuth)));
    // /attachment/[fileName]
    router.get(joinPath(ensureStartSlash(config.URLAttachmentPath), "*"),
               serveStaticFiles(removeStartSlash(config.URLStaticPath)));

    // /conv/*
    router.registerRestInterface(new MessageImpl);
    router.registerRestInterface(new SearchImpl);
    router.registerRestInterface(new ConvImpl);
    router.registerRestInterface(new TestImpl);

    foreach (route; router.getAllRoutes)
        writeln(route);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["127.0.0.1"];
    listenHTTP(settings, router);
}
// api tests are done from ../../tests/apilivetests.d
