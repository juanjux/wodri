#!/usr/bin/env rdmd
import std.digest.md;
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


JSONValue getConversations(string tag, uint limit, uint page)
{

    auto curlCmd = escapeShellCommand("curl", "-s", "-X", "GET", "-H", 
            "Content-Type: application/json", 
            format("http://127.0.0.1:8080/api/tag/?name=%s&limit=%d&page=%d", 
            tag, limit, page));
    auto retCurl = executeShell(curlCmd);
    if (retCurl.status != 0 || !retCurl.output.length)
        throw new Exception("bad curl result");

    auto conversations = parseJSON(retCurl.output);
    return conversations;
}


JSONValue getConversationById(string id)
{
    auto curlCmd = escapeShellCommand(
                    "curl", "-s", "-X", "GET", "-H", 
                    "Content-Type: application/json", 
                    format("http://127.0.0.1:8080/api/%s/conversation/", id)
    );
    auto retCurl = executeShell(curlCmd);
    if (retCurl.status != 0 || !retCurl.output.length)
        throw new Exception("bad curl result");

    auto conversation = parseJSON(retCurl.output);
    return conversation;
}


JSONValue getEmailById(string id)
{
    auto curlCmd = escapeShellCommand(
                    "curl", "-s", "-X", "GET", "-H", 
                    "Content-Type: application/json", 
                    format("http://127.0.0.1:8080/api/%s/email/", id)
    );
    auto retCurl = executeShell(curlCmd);
    if (retCurl.status != 0 || !retCurl.output.length)
        throw new Exception("bad curl result");

    auto email = parseJSON(retCurl.output);
    return email;
}


void testGetConversation()
{
    writeln("Testing outside testGetConversation");
    JSONValue conversations;
    conversations = getConversations("inbox", 20, 0);

    auto convId1 = conversations[0]["dbId"].str;
    auto convId2 = conversations[1]["dbId"].str;
    auto convId3 = conversations[2]["dbId"].str;
    auto convId4 = conversations[3]["dbId"].str;
    enforce(convId1.length);

    auto conversation  = getConversationById(convId1);
    auto conversation2 = getConversationById(convId2);
    auto conversation3 = getConversationById(convId3);
    auto conversation4 = getConversationById(convId4);
    // XXX comprobar valores de las conversaciones
}


void testGetTagConversations()
{
    writeln("Testing outside getTagConversations");

    JSONValue conversations;
    conversations = getConversations("inbox", 20, 0);

    enforce(strip(conversations[0]["subject"].str) == "Tired of Your Hosting Company?");
    enforce(strip(conversations[1]["subject"].str) == "Fwd: Hello My Dearest, please I need your help! POK TEST");
    enforce(strip(conversations[2]["subject"].str) == "Attachment test");

    enforce(conversations[0]["numMessages"].integer == 1 &&
           conversations[1]["numMessages"].integer == 3 &&
           conversations[2]["numMessages"].integer == 1 &&
           conversations[3]["numMessages"].integer == 2);

    enforce(conversations[0]["lastDate"].str > conversations[1]["lastDate"].str && 
           conversations[1]["lastDate"].str > conversations[2]["lastDate"].str &&
           conversations[2]["lastDate"].str > conversations[3]["lastDate"].str);
    auto newerDate = conversations[0]["lastDate"].str;
    auto olderDate = conversations[3]["lastDate"].str;

    enforce(jsonToArray(conversations[0]["shortAuthors"])    == ["SupremacyHosting.com Sales"]);
    enforce(jsonToArray(conversations[3]["shortAuthors"])    == ["Test Sender", "Some User"]);
    enforce(jsonToArray(conversations[3]["attachFileNames"]) == ["google.png", "profilephoto.jpeg"]);

    conversations = getConversations("inbox", 2, 0);
    enforce(conversations[0]["lastDate"].str == newerDate);

    conversations = getConversations("inbox", 2, 1);
    enforce(conversations[1]["lastDate"].str == olderDate);
}

void testGetEmail()
{
    writeln("Testing outside testGetEmail");

    JSONValue conversations;
    conversations = getConversations("inbox", 20, 0);
    JSONValue singleConversation;
    singleConversation = getConversationById(conversations[0]["dbId"].str);

    JSONValue email;
    email = getEmailById(singleConversation["summaries"][0]["dbId"].str);
    enforce(email["dbId"].str == singleConversation["summaries"][0]["dbId"].str);
    enforce(strip(email["from"].str) ==  "SupremacyHosting.com Sales <brian@supremacyhosting.com>");
    enforce(strip(email["subject"].str) == "Tired of Your Hosting Company?");
    enforce(strip(email["to"].str) == "<anotherUser@anotherdomain.com>");
    enforce(strip(email["cc"].str) == "");
    enforce(strip(email["bcc"].str) == "");
    enforce(strip(email["date"].str) == "");
    enforce(toHexString(md5Of(email["bodyHtml"].str)) == "1425A9DB565D0AD15BAA02E43978B75A");
    enforce(email["attachments"].array.length == 0);

    singleConversation = getConversationById(conversations[3]["dbId"].str);
    email = getEmailById(singleConversation["summaries"][0]["dbId"].str);
    enforce(email["dbId"].str == singleConversation["summaries"][0]["dbId"].str);
    enforce(strip(email["from"].str) ==  "Test Sender <someuser@insomedomain.com>");
    enforce(strip(email["subject"].str) == "some subject");
    enforce(strip(email["to"].str) == "Test User2 <testuser@testdatabase.com>");
    enforce(strip(email["cc"].str) == "");
    enforce(strip(email["bcc"].str) == "");
    enforce(strip(email["date"].str) == "Sat, 25 Dec 2010 13:31:57 +0100");
    enforce(toHexString(md5Of(email["bodyHtml"].str)) == "710774126557E2D8219DCE10761B5838");
    enforce(email["attachments"].array.length == 0);

    email = getEmailById(singleConversation["summaries"][1]["dbId"].str);
    enforce(email["dbId"].str == singleConversation["summaries"][1]["dbId"].str);
    enforce(strip(email["from"].str) ==  "Some User <someuser@somedomain.com>");
    enforce(strip(email["subject"].str) == "Fwd: Se ha evitado un inicio de sesión sospechoso");
    enforce(strip(email["to"].str) == "Test User1 <testuser@testdatabase.com>");
    enforce(strip(email["cc"].str) == "");
    enforce(strip(email["bcc"].str) == "");
    enforce(strip(email["date"].str) == "Mon, 27 May 2013 07:42:30 +0200");
    enforce(toHexString(md5Of(email["bodyHtml"].str)) == "977920E20B2BF801EC56E318564C4770");
    enforce(email["attachments"].array.length == 2);

    enforce(strip(email["attachments"][0]["Url"].str) == "");
    enforce(strip(email["attachments"][0]["contentId"].str) == "<google>");
    enforce(strip(email["attachments"][0]["ctype"].str) == "image/png");
    enforce(strip(email["attachments"][0]["filename"].str) == "google.png");
    enforce(email["attachments"][0]["size"].integer == 6321);

    enforce(strip(email["attachments"][1]["Url"].str) == "");
    enforce(strip(email["attachments"][1]["contentId"].str) == "<profilephoto>");
    enforce(strip(email["attachments"][1]["ctype"].str) == "image/jpeg");
    enforce(strip(email["attachments"][1]["filename"].str) == "profilephoto.jpeg");
    enforce(email["attachments"][1]["size"].integer == 1063);
}


void main()
{
    testGetTagConversations();
    testGetConversation();
    testGetEmail();
    // This stupid message is needed because sometimes this crashes quietly
    writeln("Ooooooooook, all tests finished");
}
