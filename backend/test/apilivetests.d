#!/usr/bin/env rdmd
import std.process;
import std.array;
import std.string;
import std.stdio;
import std.json;
import std.algorithm;
import std.exception;

string[] jsonToArray(JSONValue val)
{
    return array(map!(x => x.str)(val.array));
}


void testGetConversation()
{
    writeln("Testing outside testGetConversation");

    auto curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=20&page=0");
    auto retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0, "CURL didnt return 0");
    assert(retCurl.output.length);

    JSONValue conversations;
    assertNotThrown(conversations = parseJSON(retCurl.output));

    auto convId1 = conversations[0]["dbId"].str;
    assert(convId1.length);

    curlCmd = escapeShellCommand(
                    "curl", "-s", "-X", "GET", "-H", 
                    "Content-Type: application/json", 
                    format("http://127.0.0.1:8080/api/%s/conversation/", convId1)
    );
    retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0, "CURL didnt return 0");
    assert(retCurl.output.length);
    JSONValue conversation;
    assertNotThrown(conversation = parseJSON(retCurl.output));
}


void testGetTagConversations()
{
    writeln("Testing outside getTagConversations");

    auto curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=20&page=0");
    auto retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0, "CURL didnt return 0");
    assert(retCurl.output.length);

    JSONValue conversations;
    assertNotThrown(conversations = parseJSON(retCurl.output));
    assertNotThrown(conversations[0]);
    assertNotThrown(conversations[0]["numMessages"].integer);
    assertNotThrown(conversations[0]["lastDate"].str);
    assertNotThrown(conversations[0]["subject"].str);

    assert(strip(conversations[0]["subject"].str) == "Tired of Your Hosting Company?");
    assert(strip(conversations[1]["subject"].str) == "Fwd: Hello My Dearest, please I need your help! POK TEST");
    assert(strip(conversations[2]["subject"].str) == "Attachment test");

    assert(conversations[0]["numMessages"].integer == 1 &&
           conversations[1]["numMessages"].integer == 3 &&
           conversations[2]["numMessages"].integer == 1 &&
           conversations[3]["numMessages"].integer == 2);

    assert(conversations[0]["lastDate"].str > conversations[1]["lastDate"].str && 
           conversations[1]["lastDate"].str > conversations[2]["lastDate"].str &&
           conversations[2]["lastDate"].str > conversations[3]["lastDate"].str);
    auto newerDate = conversations[0]["lastDate"].str;
    auto olderDate = conversations[3]["lastDate"].str;

    assert(jsonToArray(conversations[0]["shortAuthors"])    == ["SupremacyHosting.com Sales"]);
    assert(jsonToArray(conversations[3]["shortAuthors"])    == ["Test Sender", "Some User"]);
    assert(jsonToArray(conversations[3]["attachFileNames"]) == ["google.png", "profilephoto.jpeg"]);


    curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=2&page=0");
    retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0);
    assert(retCurl.output.length);
    JSONValue conversations2;
    assertNotThrown(conversations2 = parseJSON(retCurl.output));
    assert(conversations2[0]["lastDate"].str == newerDate);

    curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=2&page=1");
    retCurl = executeShell(curlCmd);
    JSONValue conversations3;
    assertNotThrown(conversations3 = parseJSON(retCurl.output));
    assert(retCurl.status == 0);
    assert(retCurl.output.length);
    assert(conversations3[1]["lastDate"].str == olderDate);
}




void main()
{
    testGetTagConversations();
    testGetConversation();
    // This stupid message is needed because sometimes this crashes quietly
    writeln("Ooooooooook, all tests finished");
}
