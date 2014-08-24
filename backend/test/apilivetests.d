#!/usr/bin/env rdmd
import core.thread;
import std.algorithm;
import std.array;
import std.datetime: dur;
import std.conv;
import std.digest.md;
import std.exception;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.typecons;

/**
 * IMPORTANT: run the db.d tests (test_db.sh) before running these tests so the DB
 * is loaded
 */

enum USER = "testuser";
enum PASS = "secret";
enum URL  = "http://127.0.0.1:8080/api";
enum URL2 = "http://127.0.0.1:8080";
string[string] emptyDict;


string callCurl2(string object,
                string apiCall,
                string[string] parameters=emptyDict,
                string method="GET",
                string postData="",
                string user=USER,
                string pass=PASS)
{
    Appender!string parametersStr;
    string joiner = "?";
    foreach(key, value; parameters)
    {
        parametersStr.put(joiner ~ key ~ "=" ~ value);
        joiner = "&";
    }

    Appender!string pathStr;
    pathStr.put(URL2   ~ "/");
    pathStr.put(object ~ "/");

    if (apiCall.length)
        pathStr.put(apiCall ~ "/");

    if (parametersStr.data.length)
        pathStr.put(parametersStr.data);

    auto dataPart = postData.length? postData: "{}";
    auto curlCmd = escapeShellCommand(
            "curl", "-u", user ~ ":" ~ pass, "-s", "-X", method, "-H",
            "Content-Type: application/json", "--data", dataPart,
            pathStr.data
    );

    writeln("\t" ~ method ~ ": " ~ pathStr.data);
    //writeln(curlCmd);

    auto retCurl = executeShell(curlCmd);
    if (retCurl.status)
        throw new Exception("bad curl result: " ~ retCurl.output);

    return retCurl.output;
}


string[] jsonToArray(JSONValue val)
{
    return array(map!(x => x.str)(val.array));
}

void recreateTestDb()
{
    callCurl2("test", "testrebuilddb");
}


void deleteEmail(string id, bool purge=false)
{
    auto purgeStr = format(`{"purge": %s}`, to!int(purge));
    callCurl2("message", id, emptyDict, "DELETE", purgeStr);
}


string emailJson(string dbId, string messageId)
{
    auto json = format(
            `{
            "dbId": "%s",
            "messageId": "%s",
            "from": "anotherUser@testdatabase.com",
            "to": "juanjux@gmail.com",
            "cc": "",
            "bcc": "",
            "subject": "test subject 2 ñññ",
            "isoDate": "2014-05-27T05:42:30Z",
            "date": "Mon, 27 May 2014 07:42:30 +0200",
            "bodyHtml": "",
            "bodyPlain": "hola mundo",
            "deleted": false,
            "draft": true,
            "attachments": [
                {
                    "Url": "/attachments/somecode.jpg",
                    "dbId": "",
                    "ctype": "image/jpeg",
                    "filename": "somecode.jpg",
                    "contentId": "somecontentid",
                    "size": 1000,
                }
            ]
            }`,
            dbId, messageId);
    return json;
}


JSONValue upsertDraft(string apiEmailJson, string replyDbId)
{
    auto json = format(
    `{
        "draftContent": %s,
        "replyDbId": "%s",
     }`, apiEmailJson, replyDbId);

    return parseJSON(
            callCurl2( "message", "", emptyDict, "POST", json, "anotherUser", "secret")
    );
}


void deleteConversation(string id, bool purge=false)
{
    auto purgeStr = format(`{"purge": %s}`, to!int(purge));
    callCurl2("conv", id, emptyDict, "DELETE", purgeStr);
}



JSONValue getConversations(string tag, uint limit, uint page, bool loadDeleted=false)
{
    auto paramsDict = ["limit": to!string(limit),
                       "page": to!string(page)];
    if (loadDeleted)
        paramsDict["loadDeleted"] = "1";

    return parseJSON(callCurl2("conv", "tag/"~tag, paramsDict));
}


JSONValue getConversationById(string id)
{
    return parseJSON(callCurl2("conv", id));
}


JSONValue getEmail(string id, Flag!"GetRaw" raw = No.GetRaw)
{
    auto rawStr = raw ? "/raw" : "";
    return parseJSON(callCurl2("message", id ~ rawStr));
}


void addTag(string id, string tag)
{
    auto json = format(`{"tag":"%s"}`, tag);
    callCurl2("conv", id~"/tag", emptyDict, "POST", json);
}


void removeTag(string id, string tag)
{
    auto json = format(`{"tag":"%s"}`, tag);
    callCurl2("conv", id~"/tag", emptyDict, "DELETE", json);
}


JSONValue search(string[] terms,
            string dateStart,
            string dateEnd,
            uint limit,
            uint page,
            int loadDeleted)
{
    auto json = format(`{"terms":%s,"dateStart":"%s","dateEnd":"%s","limit":%s,`~
                       `"page":%s,"loadDeleted":%s}`,
                       terms, dateStart, dateEnd, limit, page, loadDeleted);
    return parseJSON(callCurl2("search", "", emptyDict, "POST", json));
}


JSONValue addAttachment(string emailId)
{
    string base64Content = "aGVsbG8gd29ybGQ="; // "hello world"
    auto postData = format(`{"attachment":`~
                          `{"Url": "",`~
                          `"dbId": "",`~
                          `"ctype": "text/plain",`~
                          `"filename": "test.txt",`~
                          `"contentId": "somecontentid",`~
                          `"size": 12345},`~
                      `"base64Content": "%s"}`, base64Content);

    return parseJSON(
            callCurl2("message", emailId~"/attachment", emptyDict, "PUT", postData)
    );
}

void deleteAttachment(string emailId, string attachId)
{
    callCurl2(
            "message", 
            emailId~"/attachment", 
            emptyDict, 
            "DELETE", 
            format(`{"attachmentId": "%s"}`, attachId)
    );
}

/// Actual tests start here
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
    writeln("\nTesting GET /conv/tag/:name/?limit=%s&page=%s");
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


void testConversationAddTag()
{
    writeln("\nTesting PUT /conv/addtag/:id/:tag/");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[3]["dbId"].str;
    addTag(convId, "newtag");
    auto conv = getConversationById(convId);
    enforce(jsonToArray(conv["tags"]) == ["inbox", "newtag"]);

    // again the same tag
    addTag(convId, "newtag");
    conv = getConversationById(convId);
    enforce(jsonToArray(conv["tags"]) == ["inbox", "newtag"]);

    // tags with mixed case should be lowered
    addTag(convId, "LOWERme");
    conv = getConversationById(convId);
    enforce(jsonToArray(conv["tags"]) == ["inbox", "lowerme", "newtag"]);
}


void testConversationRemoveTag()
{
    writeln("\tTesting DELETE /conv/:id/tag/");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[0]["dbId"].str;
    removeTag(convId, "inbox");
    auto conv = getConversationById(convId);
    enforce(jsonToArray(conv["tags"]).length == 0);

    addTag(convId, "sometag");
    addTag(convId, "othertag");
    addTag(convId, "finaltag");
    removeTag(convId, "SoMeTaG");
    conv = getConversationById(convId);
    enforce(jsonToArray(conv["tags"]) == ["finaltag", "othertag"]);

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
    writeln("\nTesting GET /message/:id/raw");
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
    writeln("\nTesting DELETE /message/:id/");
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
    writeln("\nTesting DELETE /message/:id/ (purging)");
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
    writeln("\nTesting DELETE /conv/:id/ (no purge)");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[0]["dbId"].str;
    auto conv = getConversationById(convId);
    deleteConversation(convId);
    auto reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].array[0].str == "deleted");
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.TRUE);
    auto email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.TRUE);
}


void testPurgeConversation()
{
    writeln("\nTesting DELETE /conv/:id/ (purging)");
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
    writeln("\nTesting PUT /conv/:id/undo/delete/");
    recreateTestDb();
    auto conversations = getConversations("inbox", 20, 0);
    auto convId = conversations[1]["dbId"].str;
    auto conv = getConversationById(convId);
    deleteConversation(convId);
    auto reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].array[0].str == "deleted");
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.TRUE);
    auto email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.TRUE);

    callCurl2(
            "conv",
            convId~"/undo/delete",
            emptyDict,
            "PUT"
    );

    reloadedConv = getConversationById(convId);
    enforce(reloadedConv["tags"].jsonToArray == ["inbox"]);
    enforce(reloadedConv["summaries"].array[0]["deleted"].type == JSON_TYPE.FALSE);
    email = getEmail(reloadedConv["summaries"].array[0]["dbId"].str);
    enforce(email["deleted"].type == JSON_TYPE.FALSE);
}


void testUnDeleteEmail()
{
    writeln("\nTesting PUT /message/:id/undo/delete");
    recreateTestDb();
    auto convId = getConversations("inbox", 20, 0)[1]["dbId"].str;
    auto conv = getConversationById(convId);
    auto emailId = conv["summaries"][0]["dbId"].str;
    deleteEmail(emailId);
    callCurl2(
            "message",
            emailId~"/undo/delete",
            emptyDict,
            "PUT"
    );
    auto email = getEmail(emailId);
    email = getEmail(emailId);
    enforce(email["deleted"].type == JSON_TYPE.FALSE);
}


void testSearch()
{
    writeln("\nTesting POST /search/");
    recreateTestDb();
    auto searchRes = search(["some"], "", "", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 3);
    auto first  = searchRes["conversations"].array[0];
    auto second = searchRes["conversations"].array[1];
    auto third  = searchRes["conversations"].array[2];

    // limit = 1, page = 0
    searchRes = search(["some"], "", "", 1, 0, 0);
    enforce(searchRes["conversations"].array.length == 1);
    enforce(searchRes["conversations"].array.length == 1);
    enforce(searchRes["totalResultCount"].integer == 3);
    enforce(searchRes["startIndex"].integer == 0);
    enforce(first["dbId"].str == searchRes["conversations"].array[0]["dbId"].str);

    searchRes = search(["some"], "", "", 0, 0, 0);
    enforce(searchRes["conversations"].array.length == 0);

    // limit = 2 and page = 1 should give the third element
    searchRes = search(["some"], "", "", 2, 1, 0);
    enforce(searchRes["conversations"].array.length == 1);
    enforce(searchRes["totalResultCount"].integer == 3);
    enforce(searchRes["startIndex"].integer == 2);
    enforce(third["dbId"].str == searchRes["conversations"].array[0]["dbId"].str);

    // limit = 3 page = 1: no elements
    searchRes = search(["some"], "", "", 3, 1, 0);
    enforce(searchRes["conversations"].array.length == 0);
    enforce(searchRes["totalResultCount"].integer == 3);
    enforce(searchRes["startIndex"].integer == 3); // yep

    // outside range: no elements
    searchRes = search(["some"], "", "", 100, 100, 0);
    enforce(searchRes["conversations"].array.length == 0);
    enforce(searchRes["totalResultCount"].integer == 3);
    enforce(searchRes["startIndex"].integer == 3); // yep

    // non matching search
    searchRes = search(["nomatch"], "", "", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 0);
    enforce(searchRes["totalResultCount"].integer == 0);
    enforce(searchRes["startIndex"].integer == 0);

    // some match, some doesnt
    searchRes = search(["nomatch", "some"], "", "", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 3);
    enforce(searchRes["totalResultCount"].integer == 3);
    enforce(searchRes["startIndex"].integer == 0);

    // startDate test
    searchRes = search(["some"], "2014-01-01T00:00:00Z", "", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 2);
    enforce(searchRes["totalResultCount"].integer == 2);
    enforce(searchRes["startIndex"].integer == 0);

    // endDate test
    searchRes = search(["some"], "", "2014-01-01T00:00:00Z", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 1);
    enforce(searchRes["totalResultCount"].integer == 1);
    enforce(searchRes["startIndex"].integer == 0);

    // startDate+endDate
    searchRes = search(["some"], "2014-01-01T00:00:00Z", "2014-07-01T00:00:00Z", 20, 0, 0);
    enforce(searchRes["conversations"].array.length == 2);
    enforce(searchRes["totalResultCount"].integer == 2);
    enforce(searchRes["startIndex"].integer == 0);
}

void testAddAttach()
{
    writeln("\nTesting PUT /email/:id/attachment/");
    recreateTestDb();
    auto convId = getConversations("inbox", 20, 0)[2]["dbId"].str;
    auto conv = getConversationById(convId);
    auto emailId = conv["summaries"][0]["dbId"].str;

    auto emailDocPrev = getEmail(emailId);
    enforce(emailDocPrev["attachments"].array.length == 1);
    auto attachId = addAttachment(emailDocPrev["dbId"].str).str;

    auto emailDocPost = getEmail(emailId);
    enforce(emailDocPost["attachments"].array.length == 2);
    auto testAttach = emailDocPost["attachments"].array[1];
    enforce(testAttach["dbId"].str == attachId);
    enforce(testAttach["contentId"].str == "somecontentid");
    enforce(testAttach["filename"].str == "test.txt");
    enforce(testAttach["size"].integer == 11);
    enforce(testAttach["dbId"].str.length);
    auto url = testAttach["Url"].str[1..$];
    auto filePath = absolutePath(buildNormalizedPath(
                __FILE__.dirName,
                "attachments",
                baseName(url))
    );
    enforce(filePath.exists);
    enforce(readText(filePath) == "hello world");
}


void testRemoveAttach()
{
    writeln("\nTesting DELETE /email/:id/attachment/:attachid");
    recreateTestDb();

    auto convId = getConversations("inbox", 20, 0)[2]["dbId"].str;
    auto conv = getConversationById(convId);
    auto emailId = conv["summaries"][0]["dbId"].str;
    auto emailDocPrev = getEmail(emailId);
    enforce(emailDocPrev["attachments"].array.length == 1);

    auto attachId = addAttachment(emailDocPrev["dbId"].str).str;
    auto emailDocPre = getEmail(emailId);
    enforce(emailDocPre["attachments"].array.length == 2);
    auto url = emailDocPre["attachments"].array[1]["Url"].str[1..$];
    auto filePath = absolutePath(buildNormalizedPath(
                __FILE__.dirName,
                "attachments",
                baseName(url))
    );
    enforce(filePath.exists);

    deleteAttachment(emailId, attachId);
    auto emailDocPost = getEmail(emailId);
    enforce(emailDocPost["attachments"].array.length == 1);
    enforce(emailDocPost["attachments"].array[0]["dbId"].str != attachId);
    enforce(!filePath.exists);
}

void testUpsertDraft()
{
    writeln("\nTestin POST /api/draft");
    // Test1: New draft, no reply
    recreateTestDb();
    auto email = emailJson("", "");
    auto newId = upsertDraft(email, "").str;
    JSONValue dbEmail = getEmail(newId);
    enforce(dbEmail["dbId"].str == newId);
    enforce(dbEmail["attachments"].array.length == 0);
    auto msgId = dbEmail["messageId"].str;
    enforce(msgId.endsWith("@testdatabase.com"));

    // Test2: Update draft, no reply
    email = emailJson(newId, msgId);
    auto sameId = upsertDraft(email, "").str;
    enforce(sameId == newId);
    dbEmail = getEmail(sameId);
    enforce(dbEmail["dbId"].str == sameId);

    // Test3: New draft, reply
    auto conversations = getConversations("inbox", 20, 0);
    auto convId1 = conversations[0]["dbId"].str;
    auto conversation = getConversationById(convId1);
    auto emailId = conversation["summaries"][0]["dbId"].str;

    email = emailJson("", "");
    auto newReplyId = upsertDraft(email, emailId).str;
    enforce(newReplyId != newId);
    dbEmail = getEmail(newReplyId);
    enforce(dbEmail["dbId"].str == newReplyId);
    msgId = dbEmail["messageId"].str;
    enforce(msgId.endsWith("@testdatabase.com"));

    // Test4: Update draft, reply
    email = emailJson(newReplyId, msgId);
    auto updateReplyId = upsertDraft(email, emailId).str;
    enforce(updateReplyId == newReplyId);
    dbEmail = getEmail(updateReplyId);
    enforce(dbEmail["dbId"].str == updateReplyId);
    msgId = dbEmail["messageId"].str;
    enforce(msgId.endsWith("@testdatabase.com"));
}


void main()
{
    testGetTagConversations();
    testGetConversation();
    testConversationAddTag();
    testConversationRemoveTag();
    testGetEmail();
    testGetRawEmail();
    testDeleteEmail();
    testPurgeEmail();
    testDeleteConversation();
    testPurgeConversation();
    testUndeleteConversation();
    testUnDeleteEmail();
    testSearch();
    testUpsertDraft();
    testAddAttach();
    testRemoveAttach();
    writeln("All CURL tests finished");
}
