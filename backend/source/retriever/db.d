module retriever.db;

import std.stdio;
import std.string;
import std.array;
import std.range;
import std.json;
import std.path;
import std.algorithm;
import std.file;

import vibe.db.mongo.mongo;
import vibe.core.log;
import vibe.data.json;

import retriever.userrule: Match, Action, UserFilter, SizeRuleType;
import retriever.incomingemail;
import retriever.envelope;

MongoDatabase mongoDB;
RetrieverConfig config;
bool connected = false;

alias bsonStr      = deserializeBson!string;
alias bsonId       = deserializeBson!BsonObjectID;
alias bsonBool     = deserializeBson!bool;
alias bsonStrArray = deserializeBson!(string[]);
alias bsonStrHash  = deserializeBson!(string[string]);

version(db_test) version = db_usetestdb;

/**
 * Read the /etc/dbconnect.json file, check for missing keys and connect
 */
static this()
{
    auto mandatoryKeys = ["host", "name",  "password", "port", "testname", "type", "user"];
    sort(mandatoryKeys);

    auto dbData = parseJSON(readText("/etc/webmail/dbconnect.json"));
    auto sortedKeys = dbData.object.keys.dup;
    sort(sortedKeys);

    auto keysDiff = setDifference(sortedKeys, mandatoryKeys).array;
    enforce(!keysDiff.length, "Mandatory keys missing on dbconnect.json config file: %s"
                              ~ to!string(keysDiff));
    enforce(dbData["type"].str == "mongodb", "Only MongoDB is currently supported");
    string connectStr = format("mongodb://%s:%s@%s:%s/%s",
                               dbData["user"].str,
                               dbData["password"].str,
                               dbData["host"].str,
                               dbData["port"].integer,
                               "admin");

    auto client = connectMongoDB(connectStr);
    version(db_usetestdb)
    {
        mongoDB = client.getDatabase(dbData["testname"].str);
        insertTestSettings();
    }
    else
    {
        mongoDB = client.getDatabase(dbData["name"].str);
    }
    config = getInitialConfig();
}


struct RetrieverConfig
{
    string mainDir;
    string rawEmailStore;
    string attachmentStore;
    ulong  incomingMessageLimit;
    string smtpServer;
    uint   smtpEncription;
    ulong  smtpPort;
    string smtpUser;
    string smtpPass;
}


double bsonNumber(Bson input)
{
    switch(input.type)
    {
        case Bson.Type.double_:
            return deserializeBson!double(input);
        case Bson.Type.int_:
            return to!double(deserializeBson!int(input));
        case Bson.Type.long_:
            return to!double(deserializeBson!long(input));
        default:
            auto err = format("Bson input is not of numeric type but: ", input.type);
            logError(err);
            throw new Exception(err);
    }
    assert(0);
}


ref RetrieverConfig getConfig()
{
    return config;
}


RetrieverConfig getInitialConfig()
{
    RetrieverConfig config;
    auto dbConfig = mongoDB["settings"].findOne(["module": "retriever"]);
    if (dbConfig.isNull)
    {
        auto err = "Could not retrieve config database, collection:settings,"~
                   " module=retriever";
        logError(err);
        throw new Exception(err);
    }

    // If the db path starts with '/' interpret it as absolute
    config.mainDir              = bsonStr(dbConfig.mainDir);
    config.smtpServer           = bsonStr(dbConfig.smtpServer);
    config.smtpUser             = bsonStr(dbConfig.smtpUser);
    config.smtpPass             = bsonStr(dbConfig.smtpPass);
    config.smtpEncription       = to!uint(bsonNumber(dbConfig.smtpEncription));
    config.smtpPort             = to!ulong(bsonNumber(dbConfig.smtpPort));
    auto dbPath                 = bsonStr(dbConfig.rawEmailStore);
    config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                           dbPath:
                                                           buildPath(config.mainDir, dbPath);
    auto attachPath             = bsonStr(dbConfig.attachmentStore);
    config.attachmentStore      = attachPath.startsWith(dirSeparator)?
                                                               attachPath:
                                                               buildPath(config.mainDir, attachPath);
    config.incomingMessageLimit = to!ulong(bsonNumber(dbConfig.incomingMessageLimit));
    return config;
}


bool domainHasDefaultUser(string domainName)
{
    auto domain = mongoDB["domain"].findOne(["name": domainName]);
    if (!domain.isNull &&
        !domain.defaultUser.isNull &&
        bsonStr(domain.defaultUser).length)
        return true;
    return false;
}


UserFilter[] getAddressFilters(string address)
{
    UserFilter[] res;
    auto userRuleFindJson = format(`{"destinationAccounts": {"$in": ["%s"]}}`, address);
    auto userRuleCursor   = mongoDB["userrule"].find(parseJsonString(userRuleFindJson));

    foreach(rule; userRuleCursor)
    {
        Match match;
        Action action;
        try
        {
            auto sizeRule = bsonStr(rule.match_sizeRuleType);
            switch(sizeRule)
            {
                case "None":
                    match.totalSizeType = SizeRuleType.None; break;
                case "SmallerThan":
                    match.totalSizeType = SizeRuleType.SmallerThan; break;
                case "GreaterThan":
                    match.totalSizeType = SizeRuleType.GreaterThan; break;
                default:
                    auto err = "SizeRuleType must be one of None, GreaterThan or SmallerThan";
                    logError(err);
                    throw new Exception(err);
            }
            match.withAttachment = bsonBool      (rule.match_withAttachment);
            match.withHtml       = bsonBool      (rule.match_withHtml);
            match.totalSizeValue = to!ulong(bsonNumber(rule.match_totalSizeValue));
            match.bodyMatches    = bsonStrArray  (rule.match_bodyText);
            match.headerMatches  = bsonStrHash   (rule.match_headers);
            action.noInbox       = bsonBool      (rule.action_noInbox);
            action.markAsRead    = bsonBool      (rule.action_markAsRead);
            action.deleteIt      = bsonBool      (rule.action_delete);
            action.neverSpam     = bsonBool      (rule.action_neverSpam);
            action.setSpam       = bsonBool      (rule.action_setSpam);
            action.forwardTo     = bsonStrArray  (rule.action_forwardTo);
            action.addTags       = bsonStrArray  (rule.action_addTags);

            res ~= new UserFilter(match, action);
        } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
    }
    return res;
}


bool addressIsLocal(string address)
{
    if (!address.length)
        return false;

    if (domainHasDefaultUser(address.split("@")[1]))
        return true;

    auto jsonStr    = `{"addresses": {"$in": ["` ~ address ~ `"]}}`;
    auto userRecord = mongoDB["user"].findOne(parseJsonString(jsonStr));
    return !userRecord.isNull;
}


string[] localReceivers(IncomingEmail email)
{
    string[] allAddresses;
    string[] localAddresses;

    foreach(headerName; ["to", "cc", "bcc", "delivered-to"])
        allAddresses ~= email.getHeader(headerName).addresses;

    foreach(addr; allAddresses)
        if (addressIsLocal(addr))
            localAddresses ~= addr;

    return localAddresses;
}


string jsonizeHeader(IncomingEmail email, string headerName,
                     bool removeQuotes = false, bool onlyValue=false)
{
    string ret;
    auto hdr = email.getHeader(headerName);
    if (hdr.rawValue.length)
    {
        string strHeader = hdr.rawValue;
        if (removeQuotes)
            strHeader = removechars(strHeader, "\"");

        if (onlyValue)
            ret = format("%s,", Json(strHeader).toString());
        else
            ret = format("\"%s\": %s,", headerName, Json(strHeader).toString());
    }
    if (onlyValue && !ret.length)
        ret = `"",`;
    return ret;
}


string getEmailIdByMessageId(string messageId)
{
    auto jsonFind = parseJsonString(format(`{"message-id": "%s"}`, messageId));
    auto res = mongoDB["email"].findOne(jsonFind);
    if (!res.isNull)
        return bsonStr(res["_id"]);
    return "";
}


string upsertConversation(string[] references, string messageId, string emailDbId, string userId)
{
    // Search for a conversation with one of these references
    string conversationId;
    char[][] reversed = to!(char[][])(references ~ messageId);
    reverse(reversed);
    auto jsonFindStr = format(`{"userId": "%s", "links.message-id": {"$in": %s}}`, userId, reversed);
    auto convFind    = mongoDB["conversation"].findOne(parseJsonString(jsonFindStr));

    if (!convFind.isNull)
    {
        // conversation with these references or msgid exists: check if our own
        // msgId is in the result (can happen if some msg below in the
        // conversation thread enters the system before this one)
        int idx = -1;
        string jsonUpdateStr;

        foreach(entry; convFind["links"])
        {
            idx++;
            if (bsonStr(entry["message-id"]) == messageId)
            {
                // Found ourselves in the Conversation document; update the
                // (empty) emailId with our own
                jsonUpdateStr = format(`{"$set": {"links.%d.emailId": "%s"}}`, idx, emailDbId);
                break;
            }
        }

        if (!jsonUpdateStr.length)
            // Found conversation without this message id, add it to the conversation
            jsonUpdateStr = format(`{"$push": {"links": {"message-id": "%s", "emailId": "%s"}}}`,
                                  messageId, emailDbId);

        conversationId = bsonStr(convFind["_id"]);
        mongoDB["conversation"].update(["_id": conversationId], parseJsonString(jsonUpdateStr));
    }
    else
    {
        // No existing conversation found with these messages references+msgid;
        // create a new one and add our references+msgid to it
        auto linksAppender = appender!string;
        string referenceEmailId;

        // references
        foreach(reference; references)
        {
            referenceEmailId = getEmailIdByMessageId(reference); // empty string if not found and that's ok here
            linksAppender.put(format(`{"message-id": "%s", "emailId": "%s"},`,
                                     reference, referenceEmailId));
        }
        // me too!
        linksAppender.put(format(`{"message-id": "%s", "emailId": "%s"}`,
                                 messageId, emailDbId));
        auto convIdNew = BsonObjectID.generate();
        auto jsonInsert = parseJsonString(format(`{"_id": "%s", "userId": "%s", "links": [%s]}`,
                                                 convIdNew, userId, linksAppender.data));
        mongoDB["conversation"].insert(jsonInsert);
        conversationId = convIdNew.toString;
    }
    return conversationId;
}


void storeEnvelope(Envelope envelope)
{
    string[] enabledTags;
    foreach(string tag, bool enabled; envelope.tags)
        if (enabled) enabledTags ~= tag;
    auto envelopeId = BsonObjectID.generate();

    auto envelopeInsertJson = format(`{"_id": "%s",
                                    "emailId": "%s",
                                    "userId": "%s",
                                    "destinationAddress": "%s",
                                    "forwardTo": %s,
                                    "tags": %s}`,
                                      envelopeId,
                                      BsonObjectID.fromString(envelope.emailId),
                                      BsonObjectID.fromString(envelope.userId),
                                      envelope.destination,
                                      to!string(envelope.forwardTo),
                                      to!string(enabledTags));
    mongoDB["envelope"].insert(parseJsonString(envelopeInsertJson));
}


string getUserIdFromAddress(string address)
{
    auto userFindJson = format(`{"addresses": {"$in": ["%s"]}}`, address);
    auto userResult = mongoDB["user"].findOne(parseJsonString(userFindJson));
    if (userResult.isNull)
        return "";
    return bsonStr(userResult._id);
}


string storeEmail(IncomingEmail email)
{
    // Our conversation finding code needs msgid so add it if the email is
    // missing one
    if (!email.getHeader("message-id").rawValue.length)
        email.generateMessageId();

    // json for the text parts
    auto partAppender = appender!string;
    foreach(idx, part; email.textualParts)
    {
        partAppender.put("{\"contentType\": " ~ Json(part.ctype.name).toString() ~ ","
                          "\"content\": "     ~ Json(part.textContent).toString() ~ "},");
    }
    string textPartsJsonStr = partAppender.data;
    partAppender.clear();

    // json for the attachments
    foreach(attach; email.attachments)
    {
        partAppender.put(`{"contentType": `   ~ Json(attach.ctype).toString()     ~ `,` ~
                         ` "realPath": `      ~ Json(attach.realPath).toString()  ~ `,` ~
                         ` "size": `          ~ Json(attach.size).toString()      ~ `,`);
        if (attach.contentId.length)
            partAppender.put(` "contentId": ` ~ Json(attach.contentId).toString() ~ `,`);
        if (attach.filename.length)
            partAppender.put(` "fileName": `  ~ Json(attach.filename).toString()  ~ `,`);
        partAppender.put("},");
    }
    string attachmentsJsonStr = partAppender.data();
    partAppender.clear();

    // Some emails doesnt have a "To:" header but a "Delivered-To:". Really.
    string realReceiverField, realReceiverRawValue, realReceiverAddresses;
    if ("to" in email.headers)
        realReceiverField = "To";
    else if ("bcc" in email.headers)
        realReceiverField = "Bcc";
    else if ("delivered-to" in email.headers)
        realReceiverField = "delivered-to";
    else
    {
        auto err = "Cant insert to DB email without destination";
        logError(err);
        throw new Exception(err);
    }
    realReceiverRawValue  = email.jsonizeHeader(realReceiverField, false, true);
    realReceiverAddresses = to!string(email.headers[realReceiverField].addresses);

    // Json for the headers
    // (see the schema.txt doc)
    bool[string] alreadyDone;
    partAppender.put("{");
    foreach(headerName, headerValue; email.headers)
    {
        if (among(toLower(headerName), "from", "message-id"))
            // these are outside headers because they're indexed
            continue;

        // email.headers can have several values per key and thus be repeated
        // in the foreach iteration but we extract all the first time
        if (headerName in alreadyDone)
            continue;
        alreadyDone[headerName] = true;

        auto allValues = email.headers.getAll(headerName);
        partAppender.put(format(`"%s": [`, toLower(headerName)));
        foreach(hv; allValues)
        {
            partAppender.put(format(`{"rawValue": %s`, Json(hv.rawValue).toString));
            if (hv.addresses.length)
                partAppender.put(format(`,"addresses": %s`, to!string(hv.addresses)));
            partAppender.put("},");
        }
        partAppender.put("],");
        //partAppender.put(format(`"%s": %s` ~ ",\n", capitalize(headerName),
                                 //Json(headerValue.rawValue).toString()));
    }
    partAppender.put("}");
    string rawHeadersStr = partAppender.data();
    partAppender.clear();

    auto documentId = BsonObjectID.generate();
    auto emailInsertJson = format(`{"_id": "%s",` ~
                                  `"rawEmailPath": "%s",` ~
                                  `"message-id": "%s",`    ~
                                  `"isodate": "%s",`      ~
                                  `"from": { "rawValue": %s "addresses": %s },` ~
                                  `"receivers": { "rawValue": %s "addresses": %s },`   ~
                                  `"headers": %s, `    ~
                                  `"textParts": [ %s ], ` ~
                                  `"attachments": [ %s ] }`,
                                        documentId,
                                        email.rawEmailPath,
                                        email.getHeader("message-id").addresses[0],
                                        BsonDate(email.date).toString,
                                        email.jsonizeHeader("from", false, true),
                                        to!string(email.getHeader("from").addresses),
                                        realReceiverRawValue,
                                        realReceiverAddresses,
                                        rawHeadersStr,
                                        textPartsJsonStr,
                                        attachmentsJsonStr);
    //writeln(emailInsertJson);
    auto parsedJson = parseJsonString(emailInsertJson);
    mongoDB["email"].insert(parsedJson);
    return documentId.toString();
}


/**
    Search for an equal email on the DB, comparing all relevant fields
*/
bool emailAlreadyOnDb(IncomingEmail email)
{
    auto incomingMsgId = email.getHeader("message-id");
    if (!incomingMsgId.rawValue.length)
        return false;

    auto emailInDb = mongoDB["email"].findOne(["message-id": incomingMsgId.addresses[0]]);
    if (emailInDb.isNull)
        return false;

    if (
        email.getHeader("subject").rawValue != bsonStr(emailInDb.headers.subject[0].rawValue) ||
        email.getHeader("from").rawValue    != bsonStr(emailInDb.from.rawValue)               ||
        email.getHeader("to").rawValue      != bsonStr(emailInDb.receivers.rawValue)          ||
        email.getHeader("date").rawValue    != bsonStr(emailInDb.headers.date[0].rawValue))
        return false;
    return true;
}







//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_usetestdb) string[] TEST_EMAILS = ["multipart_mixed_rel_alternative_attachments",
                                               "simple_alternative_noattach",
                                               "spam_tagged",
                                               "with_2megs_attachment",
                                               "spam_notagged_nomsgid"];
version(db_usetestdb)
{
    void insertTestSettings()
    {
        mongoDB["settings"].remove();
        string settingsJsonStr = format(`
        {
                "_id" : "5399793904ac3d27431d0669",
                "mainDir" : "/home/juanjux/webmail",
                "attachmentStore" : "backend/test/attachments",
                "incomingMessageLimit" : 15728640,
                "module" : "retriever",
                "rawEmailStore" : "backend/test/rawemails",
                "smtpEncription" : 0,
                "smtpPass" : "smtpPass",
                "smtpPort" : 25,
                "smtpServer" : "localhost",
                "smtpUser" : "smtpUser"
        }`);
        mongoDB["settings"].insert(parseJsonString(settingsJsonStr));
    }


    void recreateTestDb()
    {
        foreach(string collection; ["envelope", "email", "conversation", "domain", "user", "userrule"])
            mongoDB[collection].remove();

        // Fill the test DB
        string backendTestDataDir_ = buildPath(getConfig().mainDir, "backend", "test", "testdb");
        string[string] jsonfile2collection = ["user1.json": "user",
                                              "user2.json": "user",
                                              "domain1.json": "domain",
                                              "domain2.json": "domain",
                                              "userrule1.json": "userrule",
                                              "userrule2.json": "userrule",];
        foreach(file_, collection; jsonfile2collection)
            mongoDB[collection].insert(parseJsonString(readText(buildPath(backendTestDataDir_, file_))));

        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        foreach(mailname; TEST_EMAILS)
        {
            auto email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
            email.loadFromFile(buildPath(backendTestEmailsDir, mailname), false);
            assert(email.isValid, "Email is not valid");
            auto destination = email.getHeader("to").addresses[0];
            auto emailId = storeEmail(email);
            auto userId = getUserIdFromAddress(destination);
            auto envelope = Envelope(email, destination, userId, emailId);
            envelope.tags["inbox"] = true;
            storeEnvelope(envelope);
            upsertConversation(email.getHeader("references").addresses,
                                      email.headers["message-id"].addresses[0],
                                      emailId, userId);
        }
    }
}

version(db_test)
{
    unittest // domainHasDefaultUser
    {
        recreateTestDb();
        assert(domainHasDefaultUser("testdatabase.com"), "domainHasDefaultUser1");
        assert(!domainHasDefaultUser("anotherdomain.com"), "domainHasDefaultUser2");
    }

    unittest // getAddressFilters
    {
        recreateTestDb();
        auto filters = getAddressFilters("testuser@testdatabase.com");
        assert(filters.length == 1);
        assert(!filters[0].match.withAttachment);
        assert(!filters[0].match.withHtml);
        assert(filters[0].match.totalSizeType == SizeRuleType.GreaterThan);
        assert(filters[0].match.totalSizeValue == 100485760);
        assert(filters[0].match.bodyMatches.length == 1);
        assert(filters[0].match.bodyMatches[0] == "XXXBODYMATCHXXX");
        assert(filters[0].match.headerMatches.length == 1);
        assert("From" in filters[0].match.headerMatches);
        assert(filters[0].match.headerMatches["From"] == "juanjo@juanjoalvarez.net");
        assert(!filters[0].action.forwardTo.length);
        assert(!filters[0].action.noInbox);
        assert(filters[0].action.markAsRead);
        assert(!filters[0].action.deleteIt);
        assert(filters[0].action.neverSpam);
        assert(!filters[0].action.setSpam);
        assert(filters[0].action.addTags == ["testtag1", "testtag2"]);
        filters = getAddressFilters("anotherUser@anotherdomain.com");
        assert(filters[0].action.addTags == ["testtag3", "testtag4"]);
        auto newfilters = getAddressFilters("anotherUser@testdatabase.com");
        assert(filters[0].action.addTags == newfilters[0].action.addTags);
    }

    unittest // addressIsLocal
    {
        recreateTestDb();
        assert(addressIsLocal("testuser@testdatabase.com"));
        assert(addressIsLocal("random@testdatabase.com")); // has default user
        assert(addressIsLocal("anotherUser@testdatabase.com"));
        assert(addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!addressIsLocal("random@anotherdomain.com"));
    }

    unittest // jsonizeHeader
    {
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        auto email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
        email.loadFromFile(buildPath(backendTestEmailsDir, "simple_alternative_noattach"), false);
        assert(email.jsonizeHeader("from") == `"from": " Test Sender <someuser@insomedomain.com>",`);
        assert(email.jsonizeHeader("to") == `"to": " Test User2 <testuser@testdatabase.com>",`);
        assert(email.jsonizeHeader("Date", true, true) == `" Sat, 25 Dec 2010 13:31:57 +0100",`);
    }

    unittest // getEmailIdByMessageId
    {
        recreateTestDb();
        auto id1 = getEmailIdByMessageId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        auto id2 = getEmailIdByMessageId("AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        auto id3 = getEmailIdByMessageId("CAGA-+RScZe0tqmG4rbPTSrSCKT8BmkNAGBUOgvCOT5ywycZzZA@mail.gmail.com");
        auto id4 = getEmailIdByMessageId("doesntexist");

        assert(id4 == "");
        assert((id1.length == id2.length) && (id3.length == id1.length) && id1.length == 24);
        auto arr = [id1, id2, id3, id4];
        assert(count(arr, id1) == 1);
        assert(count(arr, id2) == 1);
        assert(count(arr, id3) == 1);
        assert(count(arr, id4) == 1);
    }

    unittest // upsertConversation
    {
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        auto email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"), false);
        auto userId = getUserIdFromAddress(email.getHeader("to").addresses[0]);
        // test1: insert as is, should create a new conversation with this email as single member
        auto emailId = storeEmail(email);
        auto convId = upsertConversation(email.getHeader("references").addresses,
                                         email.getHeader("message-id").addresses[0],
                                         emailId, userId);
        auto convDoc = mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 1);
        assert(bsonStr(convDoc.links[0]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[0].emailId) == emailId);

        // test2: insert as a msgid of a reference already on a conversation, check that the right
        // conversationId is returned and the emailId added to its entry in the conversation.links
        recreateTestDb();
        email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"), false);
        email.headers["message-id"].addresses[0] = "testreference@blabla.testdomain.com";
        emailId = storeEmail(email);
        convId = upsertConversation(email.getHeader("references").addresses,
                                         email.getHeader("message-id").addresses[0],
                                         emailId, userId);
        convDoc = mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 3);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);

        // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
        // is added to that conversation
        recreateTestDb();
        email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
        email.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"), false);
        string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
        email.addHeader(refHeader);
        emailId = storeEmail(email);
        convId = upsertConversation(email.getHeader("references").addresses,
                                         email.getHeader("message-id").addresses[0],
                                         emailId, userId);
        convDoc = mongoDB["conversation"].findOne(["_id": convId]);
        assert(!convDoc.isNull);
        assert(bsonStr(convDoc.userId) == userId);
        assert(convDoc.links.type == Bson.Type.array);
        assert(convDoc.links.length == 2);
        assert(bsonStr(convDoc.links[1]["message-id"]) == email.getHeader("message-id").addresses[0]);
        assert(bsonStr(convDoc.links[1].emailId) == emailId);
    }

    unittest // storeEnvelope
    {
        import std.exception;
        import core.exception;
        recreateTestDb();
        auto cursor = mongoDB["envelope"].find(["destinationAddress": "testuser@testdatabase.com"]);
        assert(!cursor.empty);
        auto envDoc = cursor.front;
        cursor.popFrontExactly(2);
        assert(cursor.empty);
        assert(collectException!AssertError(cursor.popFront));
        assert(envDoc.forwardTo.type == Bson.Type.array);
        auto userId = getUserIdFromAddress("testuser@testdatabase.com");
        assert(bsonStr(envDoc.userId) == userId);
        assert(envDoc.tags.type == Bson.Type.array);
        assert(envDoc.tags.length == 1);
        assert(bsonStr(envDoc.tags[0]) == "inbox");
        auto emailId = getEmailIdByMessageId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
        assert(bsonStr(envDoc.emailId) == emailId);
    }

    unittest // storeEmail
    {
        recreateTestDb();
        auto cursor = mongoDB["email"].find();
        cursor.sort(parseJsonString(`{"_id": 1}`));
        assert(!cursor.empty);
        auto emailDoc = cursor.front; // email 0
        assert(emailDoc.headers.references[0].addresses.length == 1);
        assert(bsonStr(emailDoc.headers.references[0].addresses[0]) == "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
        assert(bsonStr(emailDoc.headers.subject[0].rawValue) == " Fwd: Se ha evitado un inicio de sesión sospechoso");
        assert(emailDoc.attachments.length == 2);
        assert(bsonStr(emailDoc.isodate) == "2013-05-27T03:42:30Z");
        assert(bsonStr(emailDoc.receivers.addresses[0]) == "testuser@testdatabase.com");
        assert(bsonStr(emailDoc.from.addresses[0]) == "someuser@somedomain.com");
        assert(emailDoc.textParts.length == 2);
        // check generated msgid
        cursor.popFrontExactly(countUntil(TEST_EMAILS, "spam_notagged_nomsgid"));
        auto emailDocNoId = cursor.front;
        assert(bsonStr(cursor.front["message-id"]).length);
    }

    unittest // emailAlreadyOnDb
    {
        recreateTestDb();
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");
        // ignore the nomsgid email (last one) since it cant be checked to be on DB
        foreach(mailname; TEST_EMAILS[0..$-1])
        {
            auto email = new IncomingEmail(config.rawEmailStore, config.attachmentStore);
            email.loadFromFile(buildPath(backendTestEmailsDir, mailname), false);
            assert(emailAlreadyOnDb(email));
        }

    }
}


version(db_insertalltest) unittest
{
    version(db_usetestdb)
        recreateTestDb();
    import std.datetime;
    import std.process;

    writeln("Starting db.d unittest...");
    string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
    string origEmailDir    = buildPath(backendTestDir, "emails", "single_emails");
    string rawEmailStore   = buildPath(backendTestDir, "rawemails");
    string attachmentStore = buildPath(backendTestDir, "attachments");
    int[string] brokenEmails;
    StopWatch sw;
    StopWatch totalSw;
    ulong totalTime = 0;
    ulong count = 0;

    foreach (DirEntry e; getSortedEmailFilesList(origEmailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific email
        //if (to!int(e.name.baseName) < 62879) continue; // For testing from some email forward
        writeln(e.name, "...");

        totalSw.start();
        if (baseName(e.name) in brokenEmails)
            continue;
        auto email = new IncomingEmail(rawEmailStore, attachmentStore);

        sw.start();
        email.loadFromFile(File(e.name), false);
        sw.stop(); writeln("loadFromFile time: ", sw.peek().usecs); sw.reset();


        sw.start();
        auto localReceivers = localReceivers(email);
        if (!localReceivers.length)
        {
            writeln("SKIPPING, not local receivers");
            continue; // probably a message from the "sent" folder
        }

        //auto email_withcopy = new IncomingEmail(rawEmailStore, attachmentStore);
        //sw.start();
        //email_withcopy.loadFromFile(File(e.name), true);
        //sw.stop(); writeln("loadFromFile_withCopy time: ", sw.peek().usecs); sw.reset();

        auto envelope = Envelope(email, localReceivers[0]);
        envelope.userId = getUserIdFromAddress(envelope.destination);
        assert(envelope.userId.length,
              "Please replace the destination in the test emails, not: " ~
              envelope.destination);
        envelope.tags["inbox"] = true;
        sw.stop(); writeln("getUserIdFromAddress time: ", sw.peek().usecs); sw.reset();

        if (email.isValid)
        {
            writeln("Subject: ", email.getHeader("subject").rawValue);

            sw.start();
            envelope.emailId = storeEmail(email);
            sw.stop(); writeln("storeEmail: ", sw.peek().usecs); sw.reset();

            sw.start();
            envelope.storeEnvelope;
            sw.stop(); writeln("storeEnvelope: ", sw.peek().usecs); sw.reset();

            sw.start();
            auto convId = upsertConversation(email.getHeader("references").addresses,
                                                    email.headers["message-id"].addresses[0],
                                                    envelope.emailId, envelope.userId);
            sw.stop();
            writeln("Conversation: ", convId, " time: ", sw.peek().usecs);
            sw.reset();
        } 
        else
            writeln("SKIPPING, invalid email");

        totalSw.stop();
        if (email.isValid)
        {
            auto emailTime = totalSw.peek().usecs;
            totalTime += emailTime;
            ++count;
            writeln("Total time for this email: ", emailTime);
        }
        writeln("Valid emails until now: ", count); writeln;
        totalSw.reset();
    }

    writeln("Total number of valid emails: ", count);
    writeln("Average time per valid email: ", totalTime/count);

    // Clean the attachment and rawEmail dirs
    system(format("rm -f %s/*", attachmentStore));
    system(format("rm -f %s/*", rawEmailStore));
}


version(userrule_test) unittest
{
    version(db_usetestdb)
        recreateTestDb();
    writeln("Starting userrule.d unittests...");
    auto config = getConfig();
    auto testDir = buildPath(config.mainDir, "backend", "test");
    auto testEmailDir = buildPath(testDir, "testemails");

    Envelope reInstance(Match match, Action action)
    {
        auto email = new IncomingEmail(buildPath(testDir, "rawemails"),
                                       buildPath(testDir, "attachments"));
        email.loadFromFile(buildPath(testEmailDir, "with_2megs_attachment"));
        auto envelope = Envelope(email, "foo@foo.com");
        envelope.tags = ["inbox": true];
        auto filter   = new UserFilter(match, action);
        filter.apply(envelope);
        return envelope;
    }

    // Match the From, set unread to false
    Match match; match.headerMatches["from"] = "someuser@somedomain.com";
    Action action; action.markAsRead = true;
    auto envelope = reInstance(match, action);
    assert("unread" in envelope.tags && !envelope.tags["unread"]);

    // Fail to match the From
    Match match2; match2.headerMatches["from"] = "foo@foo.com";
    Action action2; action2.markAsRead = true;
    envelope = reInstance(match2, action2);
    assert("unread" !in envelope.tags);

    // Match the withAttachment, set inbox to false
    Match match3; match3.withAttachment = true;
    Action action3; action3.noInbox = true;
    envelope = reInstance(match3, action3);
    assert("inbox" in envelope.tags && !envelope.tags["inbox"]);

    // Match the withHtml, set deleted to true
    Match match4; match4.withHtml = true;
    Action action4; action4.deleteIt = true;
    envelope = reInstance(match4, action4);
    assert("deleted" in envelope.tags && envelope.tags["deleted"]);

    // Negative match on body
    Match match5; match5.bodyMatches = ["nomatch_atall"];
    Action action5; action5.deleteIt = true;
    envelope = reInstance(match5, action5);
    assert("deleted" !in envelope.tags);

    //Match SizeGreaterThan, set tag
    Match match6;
    match6.totalSizeType = SizeRuleType.GreaterThan;
    match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
    Action action6; action6.addTags = ["testtag1", "testtag2"];
    envelope = reInstance(match6, action6);
    assert("testtag1" in envelope.tags && "testtag2" in envelope.tags);

    //Dont match SizeGreaterThan, set tag
    auto size1 = envelope.email.computeSize();
    auto size2 = 2*1024*1024;
    Match match7;
    match7.totalSizeType = SizeRuleType.GreaterThan;
    match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
    Action action7; action7.addTags = ["testtag1", "testtag2"];
    envelope = reInstance(match7, action7);
    assert("testtag1" !in envelope.tags && "testtag2" !in envelope.tags);

    // Match SizeSmallerThan, set forward
    Match match8;
    match8.totalSizeType = SizeRuleType.SmallerThan;
    match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
    Action action8;
    action8.forwardTo = ["juanjux@yahoo.es"];
    envelope = reInstance(match8, action8);
    assert(envelope.forwardTo[0] == "juanjux@yahoo.es");

    // Dont match SizeSmallerTham
    Match match9;
    match9.totalSizeType = SizeRuleType.SmallerThan;
    match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
    Action action9;
    action9.forwardTo = ["juanjux@yahoo.es"];
    envelope = reInstance(match9, action9);
    assert(!envelope.forwardTo.length);
}
