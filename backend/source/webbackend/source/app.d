import vibe.d;
import std.stdio;
import apiobjects;

version(apitest) version = db_usetestdb;

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

version(apitest)
unittest
{
    auto apiClient = new RestInterfaceClient!Api("http://127.0.0.1:8080");
    auto conversations = apiClient.getTag("inbox", 50);
    logInfo("Conversations: %s", conversations);
}
