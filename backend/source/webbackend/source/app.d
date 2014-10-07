/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/
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

    // log
    setLogFile(buildPath(config.mainDir, "backend", "log", "webbackend.log"),
               LogLevel.info);
    //setLogLevel(LogLevel.debugV);

    // auth
    router.any("*", performBasicAuth("Site Realm", toDelegate(&checkAuth)));
    // /attachment/[fileName]
    router.get(joinPath(ensureStartSlash(config.URLAttachmentPath), "*"),
               serveStaticFiles(removeStartSlash(config.URLStaticPath)));

    // API objects
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
