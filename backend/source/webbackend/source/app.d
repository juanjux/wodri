module app;

import vibe.d;
import std.stdio;
import webbackend.api;

shared static this()
{
    auto router = new URLRouter;
    router.registerRestInterface(new ApiImpl);
    auto routes = router.getAllRoutes();
    writeln("XXX ROUTES:"); writeln(routes);
    //router.get("/tag/:name/limit/:limit/page/:page", &getTagConversations);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["127.0.0.1"];
    listenHTTP(settings, router);
}

version(apitest)
{
    version = db_usetestdb;
    unittest // getTagConversations
    {
        logInfo("Testing getTagConversations");
        auto apiClient = new RestInterfaceClient!Api("http://127.0.0.1:8080");
        auto conversations = apiClient.getTagConversations("inbox", 50, 0);
        assert(conversations.length <= 4);
        assert(conversations[0].numMessages == 1 &&
               conversations[1].numMessages == 3 &&
               conversations[2].numMessages == 1 &&
               conversations[3].numMessages == 2);
        assert(conversations[0].lastDate > conversations[1].lastDate && 
               conversations[1].lastDate > conversations[2].lastDate &&
               conversations[2].lastDate > conversations[3].lastDate);

        auto newerDate = conversations[0].lastDate;
        auto olderDate = conversations[3].lastDate;

        assert(conversations[0].shortAuthors == ["SupremacyHosting.com Sales"]);
        assert(conversations[3].shortAuthors == ["Test Sender", "Some User"]);
        assert(!conversations[0].attachFileNames.length);
        assert(conversations[3].attachFileNames ==  ["google.png", "profilephoto.jpeg"]);

        conversations = apiClient.getTagConversations("inbox", 2, 0);
        assert(conversations.length == 2);
        assert(conversations[0].lastDate == newerDate);
        conversations = apiClient.getTagConversations("inbox", 2, 1);
        assert(conversations.length == 2);
        assert(conversations[1].lastDate == olderDate);
    }
}


