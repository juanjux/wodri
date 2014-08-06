#!/usr/bin/env rdmd
import std.digest.md;
import std.process;
import std.typecons;
import std.array;
import std.string;
import std.stdio;
import std.json;
import std.algorithm;
import std.exception;

/**
 * IMPORTANT: run the db.d tests (test_db.sh) before running these tests so the DB
 * is loaded
 */

enum USER = "testuser";
enum PASS = "secret";
enum URL  = "http://127.0.0.1:8080/api";

string callCurl(string apicall, string operationName, string id="", string method="GET")
{
    auto realId = id.length? "/"~id: "";
    auto curlCmd = escapeShellCommand(
            "curl", "-u", USER~":"~PASS, "-s", "-X", method, "-H",
            "Content-Type: application/json",
            format("%s%s/%s", URL, realId, apicall)
    );
    auto retCurl = executeShell(curlCmd);
    writeln("\t" ~ curlCmd);
    if (retCurl.status)
        throw new Exception("bad curl result while " ~ operationName);

    return retCurl.output;
}


string[] jsonToArray(JSONValue val)
{
    return array(map!(x => x.str)(val.array));
}

void recreateTestDb()
{
    callCurl("testrebuilddb/", "rebuilding test DB");
}


void deleteEmail(string id, bool purge=false)
{
    auto purgeStr = purge? "?purge=1": "";
    callCurl("emaildelete/" ~ purgeStr, "deleting email", id);
}


void unDeleteEmail(string id)
{
    callCurl("emailundelete/", "un-deleting email", id);
}


void deleteConversation(string id, bool purge=false)
{
    auto purgeStr = purge? "?purge=1": "";
    callCurl("conversationdelete/" ~ purgeStr, "deleting conversation", id);
}



JSONValue getConversations(string tag, uint limit, uint page, bool loadDeleted=false)
{
    auto loadStr = loadDeleted? "&loadDeleted=1": "";
    auto ret = callCurl(format("%s/tag/?limit=%d&page=%d%s", tag, limit, page, loadStr),
                             "getting conversations");

    auto conversations = parseJSON(ret);
    return conversations;
}


JSONValue getConversationById(string id)
{
    auto ret = callCurl("conversation/", "getting conversation by id", id);
    auto conversation = parseJSON(ret);
    return conversation;
}


JSONValue getEmail(string id, Flag!"GetRaw" raw = No.GetRaw)
{
    string name = raw == Yes.GetRaw?"raw":"email";
    auto ret = callCurl(name ~ "/", "getting single email", id);
    auto email = parseJSON(ret);
    return email;
}


void testGetConversation()
{
    writeln("\nTesting GET /api/:id/conversation/");
    recreateTestDb();
    JSONValue conversations;
    conversations = getConversations("inbox", 20, 0);

    auto convId1 = conversations[0]["dbId"].str;
    auto convId2 = conversations[1]["dbId"].str;
    auto convId3 = conversations[2]["dbId"].str;
    auto convId4 = conversations[3]["dbId"].str;
    enforce(convId1.length);

    auto conversation  = getConversationById(convId2);
    enforce(conversation["lastDate"].str == "2014-06-10T12:51:10Z");
    enforce(conversation["subject"].str == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
    enforce(jsonToArray(conversation["tags"]) == ["inbox"]);

    auto conversation2 = getConversationById(convId1);
    auto conversation3 = getConversationById(convId3);
    auto conversation4 = getConversationById(convId4);

    // delete email, check that the returned email summaries have that email.deleted=true
    conversations = getConversations("inbox", 20, 0);
    auto twoEmailsConvId = conversations[3]["dbId"].str;
    auto conversationSingleEmail = getConversationById(twoEmailsConvId);
    enforce(conversationSingleEmail["summaries"].array.length == 2);
    // delete the first email of this conversation
    deleteEmail(conversationSingleEmail["summaries"].array[0]["dbId"].str);
    auto conversationSingleEmailReload = getConversationById(twoEmailsConvId);
    // first should be deleted, second shouldn't
    enforce(conversationSingleEmailReload["summaries"].array[0]["deleted"].type == JSON_TYPE.TRUE);
    enforce(conversationSingleEmailReload["summaries"].array[1]["deleted"].type == JSON_TYPE.FALSE);
}

void testGetTagConversations()
{
    writeln("\nTesting GET /api/:name/tag/?limit=%d&page=%d");
    recreateTestDb();
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

    // XXX: when /conversationaddtag is implemented add test:
    // 1. Set tag "deleted" to a conversation
    // 2. getConversations(loadDeleted = false), check size and tags (none with deleted)
    // 3. getConversations(loadDeleted = true), check size and tags (one with deleted)
}

void testGetEmail()
{
    writeln("\nTesting GET /api/:id/email");
    recreateTestDb();

    auto conversations = getConversations("inbox", 20, 0);
    auto singleConversation = getConversationById(conversations[0]["dbId"].str);

    JSONValue email;
    email = getEmail(singleConversation["summaries"][0]["dbId"].str);
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
    email = getEmail(singleConversation["summaries"][0]["dbId"].str);
    enforce(email["dbId"].str == singleConversation["summaries"][0]["dbId"].str);
    enforce(strip(email["from"].str) ==  "Test Sender <someuser@insomedomain.com>");
    enforce(strip(email["subject"].str) == "some subject \"and quotes\" and noquotes");
    enforce(strip(email["to"].str) == "Test User2 <testuser@testdatabase.com>");
    enforce(strip(email["cc"].str) == "");
    enforce(strip(email["bcc"].str) == "");
    enforce(strip(email["date"].str) == "Sat, 25 Dec 2010 13:31:57 +0100");
    enforce(toHexString(md5Of(email["bodyHtml"].str)) == "710774126557E2D8219DCE10761B5838");
    enforce(email["attachments"].array.length == 0);

    email = getEmail(singleConversation["summaries"][1]["dbId"].str);
    enforce(email["dbId"].str == singleConversation["summaries"][1]["dbId"].str);
    enforce(strip(email["from"].str) ==  "Some User <someuser@somedomain.com>");
    enforce(strip(email["subject"].str) == "Fwd: Se ha evitado un inicio de sesión sospechoso");
    enforce(strip(email["to"].str) == "Test User1 <testuser@testdatabase.com>");
    enforce(strip(email["cc"].str) == "");
    enforce(strip(email["bcc"].str) == "");
    enforce(strip(email["date"].str) == "Mon, 27 May 2013 07:42:30 +0200");
    enforce(toHexString(md5Of(email["bodyHtml"].str)) == "977920E20B2BF801EC56E318564C4770");
    enforce(email["attachments"].array.length == 2);

    enforce(strip(email["attachments"][0]["contentId"].str) == "<google>");
    enforce(strip(email["attachments"][0]["ctype"].str) == "image/png");
    enforce(strip(email["attachments"][0]["filename"].str) == "google.png");
    enforce(email["attachments"][0]["Url"].str.startsWith("/attachment"));
    enforce(email["attachments"][0]["Url"].str.endsWith(".png"));
    enforce(email["attachments"][0]["size"].integer == 6321);

    enforce(strip(email["attachments"][1]["contentId"].str) == "<profilephoto>");
    enforce(strip(email["attachments"][1]["ctype"].str) == "image/jpeg");
    enforce(strip(email["attachments"][1]["filename"].str) == "profilephoto.jpeg");
    enforce(email["attachments"][1]["Url"].str.startsWith("/attachment"));
    enforce(email["attachments"][1]["Url"].str.endsWith(".jpeg"));
    enforce(email["attachments"][1]["size"].integer == 1063);
}

void testGetRawEmail()
{
    writeln("\nTesting GET /api/:id/raw");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto singleConversation = getConversationById(conversations[3]["dbId"].str);
    auto rawText = getEmail(singleConversation["summaries"][1]["dbId"].str, Yes.GetRaw).str;
    // if this fails, check first the you didn't clean the messeges (rerun test_db.sh)
    enforce(toHexString(md5Of(rawText)) == "55E0B6D2FCA0C06A886C965DC24D1EBE");
    enforce(rawText.length == 22516);
}


void testDeleteEmail()
{
    writeln("\nTesting GET /api/:id/emaildelete");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto singleConversation = getConversationById(conversations[0]["dbId"].str);

    auto emailId = singleConversation["summaries"][0]["dbId"].str;
    auto email = getEmail(emailId);
    deleteEmail(emailId);
    auto reloadedEmail = getEmail(emailId);
    enforce(reloadedEmail["deleted"].type == JSON_TYPE.TRUE);
}


void testPurgeEmail()
{
    writeln("\nTesting GET /api/:id/emaildelete?purge=1");
    recreateTestDb();
    
    auto conversations = getConversations("inbox", 20, 0);
    auto singleConversationId = conversations[0]["dbId"].str;
    auto singleConversation = getConversationById(singleConversationId);
    auto emailId = singleConversation["summaries"][0]["dbId"].str;
    deleteEmail(emailId, true);
    auto reloadedEmail = getEmail(emailId);
    enforce(reloadedEmail.type == JSON_TYPE.NULL);

    // Check that the conversation 0 has been removed too, since it was its only email
    auto reloadedSingleConversation = getConversationById(singleConversationId);
    enforce(reloadedSingleConversation.type == JSON_TYPE.NULL);

    // Now purge an email from a conversation with one single email in DB (the ones we're
    // deleting) and two references to mails not in DB: the conversation should be purged
    // too
    recreateTestDb();
    conversations = getConversations("inbox", 20, 0);
    auto fakeMultiConversationId = conversations[2]["dbId"].str;
    auto fakeMultiConversation = getConversationById(fakeMultiConversationId);
    emailId = fakeMultiConversation["summaries"][0]["dbId"].str;
    deleteEmail(emailId, true);
    reloadedEmail = getEmail(emailId);
    enforce(reloadedEmail.type == JSON_TYPE.NULL);

    auto reloadedFakeMultiConversation = getConversationById(fakeMultiConversationId);
    enforce(reloadedFakeMultiConversation.type == JSON_TYPE.NULL);

    // Idem for a conversation with two emails in DB. The conversation SHOULD NOT be 
    // removed and only an email should be in the summaries
    recreateTestDb();
    conversations = getConversations("inbox", 20, 0);
    auto multiConversationId = conversations[3]["dbId"].str;
    auto multiConversation = getConversationById(multiConversationId);
    emailId = multiConversation["summaries"][0]["dbId"].str;
    deleteEmail(emailId, true);
    reloadedEmail = getEmail(emailId);
    enforce(reloadedEmail.type == JSON_TYPE.NULL);

    auto reloadedMultiConversation = getConversationById(multiConversationId);
    enforce(reloadedMultiConversation.type != JSON_TYPE.NULL);
    enforce(reloadedMultiConversation["summaries"].array.length == 1);
    enforce(reloadedMultiConversation["summaries"].array[0]["dbId"].str != emailId);
}


void testDeleteConversation()
{
    writeln("\nTesting GET /api/:id/conversationdelete?purge=0");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[0]["dbId"].str;
    auto conv = getConversationById(convId);
    deleteConversation(convId);
    auto reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].array[1].str == "deleted");
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.TRUE);
    auto email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.TRUE);
}


void testPurgeConversation()
{
    writeln("\nTesting GET /api:/id/conversationdelete?purge=1");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[3]["dbId"].str;
    auto conv = getConversationById(convId);
    deleteConversation(convId, true);
    auto reloadedConv = getConversationById(convId);
    enforce(reloadedConv.type == JSON_TYPE.NULL);
    auto email1 = getEmail(conv["summaries"].array[0]["dbId"].str);
    auto email2 = getEmail(conv["summaries"].array[1]["dbId"].str);
    enforce(email1.type == JSON_TYPE.NULL);
    enforce(email2.type == JSON_TYPE.NULL);
}


void testUndeleteConversation()
{
    writeln("\nTesting GET /api:/id/conversationundelete");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[1]["dbId"].str;
    auto conv = getConversationById(convId);
    deleteConversation(convId);
    auto reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].array[1].str == "deleted");
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.TRUE);
    auto email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.TRUE);

    callCurl("conversationundelete/", "un-deleting conversation", convId);
    reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].jsonToArray == ["inbox"]);
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.FALSE);
    email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.FALSE);
}


void testUnDeleteEmail()
{
    writeln("\nTesting GET /api/:id/emailundelete");
    recreateTestDb();
    auto convId = getConversations("inbox", 20, 0)[1]["dbId"].str;
    auto conv = getConversationById(convId);
    auto emailId = conv["summaries"][0]["dbId"].str;
    deleteEmail(emailId);
    callCurl("emailundelete/", "un-deleting email", emailId);
    auto email = getEmail(emailId);
    email = getEmail(emailId);
    enforce(email["deleted"].type == JSON_TYPE.FALSE);
}

void main()
{
    testGetTagConversations();
    testGetConversation();
    testGetEmail();
    testGetRawEmail();
    testDeleteEmail();
    testPurgeEmail();
    testDeleteConversation();
    testPurgeConversation();
    testUndeleteConversation();
    testUnDeleteEmail();
    writeln("All CURL tests finished");
}
