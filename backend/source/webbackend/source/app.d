import vibe.d;
import std.stdio;
import apiobjects;
version(curl_tests) import std.process;

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
{
    version = db_usetestdb;
    unittest // getTagConversations
    {
        logInfo("Testing getTagConversations");
        auto apiClient = new RestInterfaceClient!Api("http://127.0.0.1:8080");
        auto conversations = apiClient.getTagConversations("inbox", 50, 0);
        writeln("XXX Conversations: \n", conversations);
        assert(conversations.length <= 4);
        assert(conversations[0].numMessages == 1 &&
               conversations[1].numMessages == 3 &&
               conversations[2].numMessages == 1 &&
               conversations[3].numMessages == 2);
        assert(conversations[0].lastDate > conversations[1].lastDate && 
               conversations[1].lastDate > conversations[2].lastDate &&
               conversations[2].lastDate > conversations[3].lastDate);
        assert(conversations[0].shortAuthors == ["SupremacyHosting.com Sales"]);
        assert(conversations[3].shortAuthors == ["Test Sender", "Some User"]);
        assert(!conversations[0].attachFileNames.length);
        assert(conversations[3].attachFileNames ==  ["google.png", "profilephoto.jpeg"]);

        // XXX testear limit y page
    }
    version(curl_tests)
    unittest 
    {
        //auto curlCmd = `curl -X GET -H "Content-Type: application/json" "http://localhost:8080/api/tag/?name=inbox&limit=20&page=0"`;
        auto curlCmd = escapeShellCommand("curl", "-X", "GET", "-H", "Content-Type: application/json", "http://localhost:8080/api/tag/?name=inbox&limit=20&page=0");
        logInfo(shell(curlCmd));

    }
}
