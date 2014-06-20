module retriever.db;

import std.stdio;
import std.string;
import std.path;
import std.algorithm;

import vibe.db.mongo.mongo;
import vibe.core.log;
import vibe.data.json;

import retriever.userrule: Match, Action, UserFilter, SizeRuleType;
import retriever.incomingemail;
import retriever.envelope;

MongoDatabase mongoDB;
RetrieverConfig config;
bool connected = false;

// FIXME: read db config from file
static this()
{
    mongoDB = connectMongoDB("localhost").getDatabase("webmail");
    config  = getInitialConfig();
}

struct RetrieverConfig
{
    string mainDir;
    string rawMailStore;
    string attachmentStore;
    ulong  incomingMessageLimit;
    string smtpServer;
    uint   smtpEncription;
    ulong  smtpPort;
    string smtpUser;
    string smtpPass;
}


ref RetrieverConfig getConfig()
{
    return config;
}


// XXX test when test db
RetrieverConfig getInitialConfig()
{
    RetrieverConfig config;
    auto dbConfig = mongoDB["settings"].findOne(["module": "retriever"]);
    if (dbConfig == Bson(null))
    {
        auto err = "Could not retrieve config database, collection:settings,"~
                   " module=retriever";
        logError(err);
        throw new Exception(err);
    }

    // If the db path starts with '/' interpret it as absolute
    config.mainDir              = deserializeBson!string (dbConfig["mainDir"]);
    config.smtpServer           = deserializeBson!string (dbConfig["smtpServer"]);
    config.smtpUser             = deserializeBson!string (dbConfig["smtpUser"]);
    config.smtpPass             = deserializeBson!string (dbConfig["smtpPass"]);
    config.smtpEncription       = to!uint(deserializeBson!double (dbConfig["smtpEncription"]));
    config.smtpPort             = to!ulong(deserializeBson!double (dbConfig["smtpPort"]));
    auto dbPath                 = deserializeBson!string (dbConfig["rawMailStore"]);
    config.rawMailStore         = dbPath.startsWith(dirSeparator)? dbPath: buildPath(config.mainDir, dbPath);
    auto attachPath             = deserializeBson!string (dbConfig["attachmentStore"]);
    config.attachmentStore      = attachPath.startsWith(dirSeparator)? attachPath: buildPath(config.mainDir, attachPath);
    config.incomingMessageLimit = to!ulong(deserializeBson!double(dbConfig["incomingMessageLimit"]));

    return config;
}


// XXX test when test DB
bool domainHasDefaultUser(string domainName)
{
    auto domain = mongoDB["domain"].findOne(["name": domainName]);
    if (domain != Bson(null) &&
        domain["defaultUser"] != Bson(null) &&
        domain["defaultUser"].toString().length)
        return true;
    return false;
}


// XXX test when test DB
UserFilter[] getAddressFilters(string address)
{
    UserFilter[] res;
    //auto userRuleCursor = mongoDB["userrule"].find(["destinationAccounts": address]);
    auto userRuleFindJson = format(`{"destinationAccounts": {"$in": ["%s"]}}`, address);
    auto userRuleCursor = mongoDB["userrule"].find(parseJsonString(userRuleFindJson));

    foreach(rule; userRuleCursor)
    {
        Match match;
        Action action;
        try
        {
            match.totalSizeType  =  deserializeBson!string     (rule["SizeRuleType"]) ==  "SmallerThan"?
                                                                              SizeRuleType.SmallerThan:
                                                                              SizeRuleType.GreaterThan;
            match.withAttachment = deserializeBson!bool       (rule["withAttachment"]);
            match.withHtml       = deserializeBson!bool       (rule["withHtml"]);
            match.withSizeLimit  = deserializeBson!bool       (rule["withSizeLimit"]);
            match.bodyMatches    = deserializeBson!(string[]) (rule["bodyMatches"]);
            match.headerMatches  = deserializeBson!(string[string])(rule["headerMatches"]);
            action.noInbox       = deserializeBson!bool       (rule["noInbox"]);
            action.markAsRead    = deserializeBson!bool       (rule["markAsRead"]);
            action.deleteIt      = deserializeBson!bool       (rule["delete"]);
            action.neverSpam     = deserializeBson!bool       (rule["neverSpam"]);
            action.setSpam       = deserializeBson!bool       (rule["setSpam"]);
            action.tagFavorite   = deserializeBson!bool       (rule["tagFavorite"]);
            action.forwardTo     = deserializeBson!string     (rule["forwardTo"]);
            action.addTags       = deserializeBson!(string[]) (rule["addTags"]);

            res ~= new UserFilter(match, action);
        } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
    }
    return res;
}


// XXX tests when I've the test DB
bool addressIsLocal(string address)
{
    if (!address.length)
        return false;

    if (domainHasDefaultUser(address.split("@")[1]))
        return true;

    auto jsonStr    = `{"addresses": {"$in": ["` ~ address ~ `"]}}`;
    auto userRecord = mongoDB["user"].findOne(parseJsonString(jsonStr));
    return (userRecord == Bson("null"));
}


string jsonizeField(IncomingEmail email, string headerName, bool removeQuotes = false, bool onlyValue=false)
{
    string ret;
    if (headerName in email.headers && email.headers[headerName].rawValue.length)
    {
        string strHeader = email.headers[headerName].rawValue;
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
    if (res != Bson(null))
        return deserializeBson!string(res["_id"]);
    return "";
}


// XXX tests when I've the test DB
string getOrCreateConversationId(string[] references, string messageId, string emailDbId, string userId)
{
    string[] newReferences;
    if (references.length)
    {
        // Search for a conversation with one of these references
        char[][] reversed = to!(char[][])(references);
        reverse(reversed);
        auto jsonFindStr = format(`{"userId": "%s", "links.messageId": {"$in": %s}}`, userId, reversed);
        auto convFind = mongoDB["conversation"].findOne(parseJsonString(jsonFindStr));

        // found: add this messageId to the existing conversation and return the conversationId
        if (convFind != Bson(null))
        {
            auto convId = deserializeBson!string(convFind["_id"]);
            auto jsonUpdateStr = format(`{"$push": {"links": {"messageId": "%s", "emailId": "%s"}}}`, messageId, emailDbId);
            mongoDB["conversation"].update(["_id": convId], parseJsonString(jsonUpdateStr));
            return convId;
        }
    }

    // The email didnt have references or no Conversation found for its
    // references: create a new one and add the references + our msgid to it
    auto linksAppender = appender!string;
    foreach(reference; references)
    {
        auto referenceEmailId = getEmailIdByMessageId(reference); // empty string if not found
        linksAppender.put(format(`{"messageId": "%s", "emailId": "%s"},`, reference, referenceEmailId));
    }
    // Also this message 
    linksAppender.put(format(`{"messageId": "%s", "emailId": "%s"}`, messageId, emailDbId));
    auto convIdNew = BsonObjectID.generate();
    auto jsonInsert = parseJsonString(format(`{"_id": "%s", "userId": "%s", "links": [%s]}`, 
                                             convIdNew, userId, linksAppender.data));
    mongoDB["conversation"].insert(jsonInsert);
    return convIdNew.toString;
}


// XXX tests when I've the test DB
void saveEnvelope(Envelope envelope)
{
    string[] enabledTags;
    foreach(string tag, bool enabled; envelope.tags)
        if (enabled) enabledTags ~= tag;
    auto envelopeId = BsonObjectID.generate();

    auto envelopeInsertJson = format(`{"_id": "%s",
                                    "idEmail": "%s",
                                    "idUser": "%s",
                                    "destinationAddress": "%s",
                                    "forwardedTo": %s,
                                    "tags": %s}`,
                                      envelopeId,
                                      BsonObjectID.fromString(envelope.emailId),
                                      BsonObjectID.fromString(envelope.userId),
                                      envelope.destination,
                                      to!string(envelope.doForwardTo),
                                      to!string(enabledTags));
    mongoDB["envelope"].insert(parseJsonString(envelopeInsertJson));
}


// XXX tests when I've the test DB
string getUserIdFromAddress(string address)
{
    auto userFindJson = format(`{"addresses": {"$in": ["%s"]}}`, address);
    auto userResult = mongoDB["user"].findOne(parseJsonString(userFindJson));
    if (userResult == Bson(null))
        return "";
    return deserializeBson!BsonObjectID(userResult["_id"]).toString();
}


// XXX test when I've the test DB
string saveEmailToDb(IncomingEmail email)
{
    auto partAppender = appender!string;
    foreach(idx, part; email.textualParts)
    {
        partAppender.put("{\n");
        partAppender.put("\"contenttype\": " ~ Json(part.ctype.name).toString() ~ ",\n");
        partAppender.put("\"content\": " ~ Json(part.textContent).toString() ~ "\n");
        partAppender.put("},\n");
    }
    string textPartsJsonStr = partAppender.data;
    partAppender.clear();

    foreach(attach; email.attachments)
    {
        partAppender.put("{\n");
        partAppender.put(`"contenttype": ` ~ Json(attach.ctype).toString() ~ `,`);
        partAppender.put(` "realpath": ` ~ Json(attach.realPath).toString() ~ `,`);
        partAppender.put(` "size": ` ~ Json(attach.size).toString() ~ `,`);
        if (attach.contentId.length)
            partAppender.put(` "contentid": ` ~ Json(attach.contentId).toString() ~ `,`);
        if (attach.filename.length)
            partAppender.put(` "filename": ` ~ Json(attach.filename).toString() ~ `,`);
        partAppender.put("},\n");
    }
    string attachmentsJsonStr = partAppender.data();
    partAppender.clear();

    // Some mails doesnt have a "To:" header but a "Delivered-To:". Really.
    string realToField, realToRawValue, realToAddresses;
    if ("To" in email.headers)
        realToField = "To";
    else if ("Bcc" in email.headers)
        realToField = "Bcc";
    else if ("Delivered-To" in email.headers)
        realToField = "Delivered-To";
    else
        throw new Exception("Cant insert to DB mail without destination");
    realToRawValue  = jsonizeField(email, realToField, false, true);
    realToAddresses = to!string(email.headers[realToField].addresses);

    // Format the reference list
    string referencesJsonStr;
    bool hasRefs = false;
    if ("References" in email.headers)
    {
        referencesJsonStr = format(`"references": %s,`, to!string(email.headers["References"].addresses));
        hasRefs = true;
    }

    auto messageId = BsonObjectID.generate();
    auto emailInsertJson = format(`{"_id": "%s",
                                    "rawMailPath": "%s",
                                   "message-id": "%s",
                                   "isodate": "%s",
                                   %s
                                   "from": { "content": %s "addresses": %s },
                                   "to": { "content": %s "addresses": %s },
                                    %s %s %s %s %s
                                   "textParts": [ %s ],
                                   "attachments": [ %s ] }`,
                                        messageId,
                                        email.rawMailPath,
                                        email.headers["message-id"].addresses[0],
                                        BsonDate(email.date).toString,
                                        referencesJsonStr,
                                        jsonizeField(email,"from", false, true),
                                        to!string(email.headers["From"].addresses),
                                        realToRawValue,
                                        realToAddresses,
                                        jsonizeField(email, "date", true),
                                        jsonizeField(email, "subject"),
                                        jsonizeField(email, "cc"),
                                        jsonizeField(email, "bcc"),
                                        jsonizeField(email, "in-reply-to"),
                                        textPartsJsonStr,
                                        attachmentsJsonStr);

    auto parsedJson = parseJsonString(emailInsertJson);
    mongoDB["email"].insert(parsedJson);
    return messageId.toString();
}









//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


// XXX falta:
// - recuperar de nuevo de Mongo y comparar con objeto en memoria
version(dbtest)
unittest
{
    import std.file;
    import std.datetime;
    import std.process;

    writeln("Starting db.d unittest...");
    string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
    string origMailDir     = buildPath(backendTestDir, "emails", "single_emails");
    string rawMailStore    = buildPath(backendTestDir, "rawmails");
    string attachmentStore = buildPath(backendTestDir, "attachments");
    int[string] brokenMails;
    StopWatch sw;
    StopWatch totalSw;
    ulong totalTime = 0;
    ulong count = 0;


    foreach (DirEntry e; getSortedEmailFilesList(origMailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific mail
        //if (to!int(e.name.baseName) < 62879) continue; // For testing from some mail forward

        writeln(e.name, "...");

        totalSw.start();
        if (baseName(e.name) in brokenMails)
            continue;
        auto email = new IncomingEmail(rawMailStore, attachmentStore);
        auto email_withcopy = new IncomingEmail(rawMailStore, attachmentStore);

        sw.start();
        email.loadFromFile(File(e.name), false);
        sw.stop(); writeln("loadFromFile time: ", sw.peek().usecs); sw.reset();

        sw.start();
        email_withcopy.loadFromFile(File(e.name), true);
        sw.stop(); writeln("loadFromFile_withCopy time: ", sw.peek().usecs); sw.reset();

        sw.start();
        auto envelope = Envelope(email, "juanjux@juanjux.mooo.com");
        envelope.userId = getUserIdFromAddress(envelope.destination);
        envelope.tags["inbox"] = true;
        sw.stop(); writeln("getUserIdFromAddress time: ", sw.peek().usecs); sw.reset();

        if (email.isValid)
        {
            if ("Subject" in email.headers)
                writeln("Subject: ", email.headers["Subject"].rawValue);

            sw.start();
            envelope.emailId = saveEmailToDb(email);
            sw.stop(); writeln("saveEmailToDb: ", sw.peek().usecs); sw.reset();

            sw.start();
            envelope.saveEnvelope;
            sw.stop(); writeln("saveEnvelope: ", sw.peek().usecs); sw.reset();

            string[] references;
            if ("References" in email.headers && email.headers["References"].addresses.length)
                references = email.headers["References"].addresses;

            sw.start();
            auto convId = getOrCreateConversationId(references, email.headers["Message-ID"].addresses[0],
                                      envelope.emailId, envelope.userId);
            sw.stop();
            writeln("Conversation: ", convId, " time: ", sw.peek().usecs);
            sw.reset();
        }

        totalSw.stop();
        if (email.isValid)
        {
            auto emailTime = totalSw.peek().usecs;
            totalTime += emailTime;
            ++count;
            writeln("Total time for this email: ", emailTime);
        }
        totalSw.reset();
    }

    writeln("Total number of valid emails: ", count);
    writeln("Average time per valid email: ", totalTime/count);

    // Clean the attachment and rawMail dirs
    system(format("rm -f %s/*", attachmentStore));
    system(format("rm -f %s/*", rawMailStore));
}


version(UserRuleTest)
unittest
{
    writeln("Starting userrule.d unittests...");
    auto filters = getAddressFilters("juanjux@juanjux.mooo.com");
    auto config = getConfig();
    auto testDir = buildPath(config.mainDir, "backend", "test");
    auto testMailDir = buildPath(testDir, "testmails");

    Envelope reInstance(Match match, Action action)
    {
        auto email = new IncomingEmail(buildPath(testDir, "rawmails"),
                                       buildPath(testDir, "attachments"));
        email.loadFromFile(buildPath(testMailDir, "with_attachment"));
        auto envelope = Envelope(email, "foo@foo.com");
        envelope.tags = ["inbox": true];
        auto filter   = new UserFilter(match, action);
        filter.apply(envelope);
        return envelope;
    }

    // Match the From, set unread to false
    Match match; match.headerMatches["From"] = "juanjo@juanjoalvarez.net";
    Action action; action.markAsRead = true;
    auto envelope = reInstance(match, action);
    assert("unread" in envelope.tags && !envelope.tags["unread"]);

    // Fail to match the From
    Match match2; match2.headerMatches["From"] = "foo@foo.com";
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
    match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
    match6.withSizeLimit = true;
    Action action6; action6.addTags = ["testtag1", "testtag2"];
    envelope = reInstance(match6, action6);
    assert("testtag1" in envelope.tags && "testtag2" in envelope.tags);

    //Dont match SizeGreaterThan, set tag
    auto size1 = envelope.email.computeSize();
    auto size2 = 2*1024*1024;
    Match match7;
    match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
    match7.withSizeLimit = true;
    Action action7; action7.addTags = ["testtag1", "testtag2"];
    envelope = reInstance(match7, action7);
    assert("testtag1" !in envelope.tags && "testtag2" !in envelope.tags);

    // Match SizeSmallerThan, set forward
    Match match8;
    match8.totalSizeType = SizeRuleType.SmallerThan;
    match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
    match8.withSizeLimit = true;
    Action action8;
    action8.forwardTo = "juanjux@yahoo.es";
    envelope = reInstance(match8, action8);
    assert(envelope.doForwardTo[0] == "juanjux@yahoo.es");

    // Dont match SizeSmallerTham
    Match match9;
    match9.totalSizeType = SizeRuleType.SmallerThan;
    match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
    match9.withSizeLimit = true;
    Action action9;
    action9.forwardTo = "juanjux@yahoo.es";
    envelope = reInstance(match9, action9);
    assert(!envelope.doForwardTo.length);
}
