module app;

import std.stdio;
import std.path;
import vibe.d;
import vibe.core.log;
import vibe.crypto.passwordhash;
import vibe.http.fileserver;
import vibe.inet.path;
import webbackend.api;
import db.mongo: getUserHash;
import db.config: getConfig;

bool checkAuth(string user, string password)
{
    return testSimplePasswordHash(getUserHash(user), password, getConfig.salt);
} 


pure string removeStartSlash(string path)
{
    if (path.startsWith("/"))
        return path[1..$];
    return path;
}
pure string removeEndSlash(string path)
{
    if (path.endsWith("/"))
        return path[0..$-1];
    return path;
}
pure string removeStartEndSlashes(string path)
{
    return removeStartSlash(removeEndSlash(path));
}


shared static this()
{
    //setLogLevel(LogLevel.debugV);

    auto config = getConfig();
    auto router = new URLRouter;

  // Auth
    router.any("*", performBasicAuth("Site Realm", toDelegate(&checkAuth)));
  // /attachment/[fileName]
    router.get(joinPath(joinPath("/", config.URLAttachmentPath), "*"), 
               serveStaticFiles(removeStartSlash(config.URLStaticPath)));
  // /api/[rest_api]
    router.registerRestInterface(new ApiImpl);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["127.0.0.1"];
    listenHTTP(settings, router);
}

// api tests are done from ../../tests/apilivetests.d
