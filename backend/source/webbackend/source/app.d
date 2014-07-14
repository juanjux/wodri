import vibe.d;
import std.stdio;
import apiobjects;

shared static this()
{
    auto router = new URLRouter;
    router.registerRestInterface(new ApiImpl);
    auto routes = router.getAllRoutes();
    writeln(routes);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["127.0.0.1"];
    listenHTTP(settings, router);
}

// XXX convert to unittest
shared static this()
{
    // create a client to talk to the API implementation over the REST interface
    runTask({
        auto apiClient = new RestInterfaceClient!Api("http://127.0.0.1:8080");
        auto conversations = apiClient.getTag("inbox", 50);
        writeln(conversations);
        //logInfo("Conversations: %s", conversations);
    });
}
