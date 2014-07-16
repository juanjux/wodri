import vibe.d;
import std.stdio;
import apiobjects;

shared static this()
{
    auto router = new URLRouter;
    router.registerRestInterface(new ApiImpl);
    auto routes = router.getAllRoutes();
    //router.get("/tag/:name/limit/:limit/page/:page", &getTagConversations);
    writeln("XXX routes: ", routes);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = ["127.0.0.1"];
    listenHTTP(settings, router);
}

version(apitest)
unittest // getTagConversations
{
    auto apiClient = new RestInterfaceClient!Api("http://127.0.0.1:8080");
    auto conversations = apiClient.getTagConversations("inbox", 50, 0);
    assert(conversations.length == 4);
    assert(conversations[0].numMessages == 2 &&
           conversations[1].numMessages == 3 &&
           conversations[2].numMessages == 1 &&
           conversations[3].numMessages == 1);
    // XXX validar conversations
    // XXX usar tambien CURL para probar la direccion
    //logInfo("Conversations: %s", conversations);
}
