#!/usr/bin/env rdmd
import std.process;
import std.array;
import std.stdio;
import std.json;
import std.algorithm;
import std.exception;

string[] jsonToArray(JSONValue val)
{
    return array(map!(x => x.str)(val.array));
}

/**
 * rdmd this code with the API server running 
 */
void testGetTagConversations()
{
    // getTagConversations
    writeln("Testing outside getTagConversations");
    auto curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=20&page=0");
    auto retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0);
    assert(retCurl.output.length);

    JSONValue conversations;
    assertNotThrown(conversations = parseJSON(retCurl.output));
    assertNotThrown(conversations[0]);
    assertNotThrown(conversations[0]["numMessages"].integer);
    assertNotThrown(conversations[0]["lastDate"].str);
    assertNotThrown(conversations[0]["attachmentsFilenames"].str);

    assert(conversations[0]["numMessages"].integer == 1 &&
           conversations[1]["numMessages"].integer == 3 &&
           conversations[2]["numMessages"].integer == 1 &&
           conversations[3]["numMessages"].integer == 2);

    assert(conversations[0]["lastDate"].str > conversations[1]["lastDate"].str && 
           conversations[1]["lastDate"].str > conversations[2]["lastDate"].str &&
           conversations[2]["lastDate"].str > conversations[3]["lastDate"].str);
    auto newerDate = conversations[0]["lastDate"].str;
    auto olderDate = conversations[3]["newerDate"].str;

    assert(jsonToArray(conversations[0]["shortAuthors"]) == ["SupremacyHosting.com Sales"]);
    assert(jsonToArray(conversations[3]["shortAuthors"]) == ["Test Sender", "Some User"]);
    assert(jsonToArray(conversations[3]["attachFileNames"]) == ["google.png", "profilephoto.jpeg"]);


    curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=2&page=0");
    retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0);
    assert(retCurl.output.length);
    assert(conversations[0]["lastDate"].str == newerDate);

    curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            "http://127.0.0.1:8080/api/tag/?name=inbox&limit=2&page=1");
    retCurl = executeShell(curlCmd);
    assert(retCurl.status == 0);
    assert(retCurl.output.length);
    assert(conversations[1]["lastDate"].str == olderDate);

}

void main()
{
    testGetTagConversations();
}
