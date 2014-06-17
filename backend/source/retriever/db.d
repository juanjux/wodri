module retriever.db;

import std.stdio;
import std.string;
import std.path;
version(dbtest) import std.file;

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
    auto dbPath                 = deserializeBson!string (dbConfig["rawMailStore"]);
    config.rawMailStore         = dbPath.startsWith(dirSeparator)? dbPath: buildPath(config.mainDir, dbPath);
    dbPath                      = deserializeBson!string (dbConfig["attachmentStore"]);
    config.attachmentStore      = dbPath.startsWith(dirSeparator)? dbPath: buildPath(config.mainDir, dbPath);
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
    auto userRuleCursor = mongoDB["userrule"].find(["destinationAccounts": address]);

    foreach(rule; userRuleCursor)
    {
        Match match;
        Action action;
        try
        {
            match.totalSizeType  =  deserializeBson!string     (rule["SizeRuleType"]) ==  "SmallerThan"?
                                                                              SizeRuleType.SmallerThan:
                                                                              SizeRuleType.GreaterThan;
            match.withAttachment =  deserializeBson!bool       (rule["withAttachment"]);
            match.withHtml       =  deserializeBson!bool       (rule["withHtml"]);
            match.withSizeLimit  =  deserializeBson!bool       (rule["withSizeLimit"]);
            match.bodyMatches    =  deserializeBson!(string[]) (rule["bodyMatches"]);
            match.headerMatches  =  deserializeBson!(string[string])(rule["headerMatches"]);
            action.noInbox       =  deserializeBson!bool       (rule["noInbox"]);
            action.markAsRead    =  deserializeBson!bool       (rule["markAsRead"]);
            action.deleteIt      =  deserializeBson!bool       (rule["delete"]);
            action.neverSpam     =  deserializeBson!bool       (rule["neverSpam"]);
            action.setSpam       =  deserializeBson!bool       (rule["setSpam"]);
            action.tagFavorite   =  deserializeBson!bool       (rule["tagFavorite"]);
            action.forwardTo     =  deserializeBson!string     (rule["forwardTo"]);
            action.addTags       =  deserializeBson!(string[]) (rule["addTags"]);

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
        string strHeader = strip(email.headers[headerName].rawValue);
        if (removeQuotes)
            strHeader = removechars(strHeader, "\"");

        if (onlyValue)
            ret = format("%s,", Json(strHeader).toString());
        else
            ret = format("\"%s\": %s,", headerName, Json(strHeader).toString());
    }
    return ret;
}


// XXX test when I've the test DB
void saveEmailToDb(IncomingEmail email, Envelope envelope)
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
    realToRawValue       = jsonizeField(email, realToField, false, true);
    realToAddresses = to!string(email.headers[realToField].addresses);

    string referencesJsonStr;
    if ("References" in email.headers)
        referencesJsonStr = format(`"references": %s,`, to!string(email.headers["References"].addresses));

    auto emailInsertJson = format(`{"rawMailPath": "%s", %s 
                                   %s
                                   "from": { "content": %s "addresses": %s },
                                   "to": { "content": %s "addresses": %s },
                                    %s %s %s %s %s
                                   "textParts": [ %s ],
                                   "attachments": [ %s ] }`,
            email.rawMailPath,
            jsonizeField(email, "message-id", true),
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
    //auto emailInsertJson = format(`{"textParts": [ %s ]}`, textPartsJsonStr);

    // XXX quitar
    auto f = File("/home/juanjux/borrame.txt", "w");
    f.write(emailInsertJson);
    f.flush(); f.close();

    Json jusr = parseJsonString(emailInsertJson);
    mongoDB["email"].insert(jusr);

    auto envelopeInsertJson = `
    {
        idEmail: %s,
        tags: [%s],
        destinationAddress: "%s",
        idUser: %s,
    }`;
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
    writeln("Starting db.d unittest...");
    string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
    string origMailDir     = buildPath(backendTestDir, "emails", "single_emails");
    string rawMailStore    = buildPath(backendTestDir, "rawmails");
    string attachmentStore = buildPath(backendTestDir, "attachments");

    int[string] brokenMails;

    foreach (DirEntry e; getSortedEmailFilesList(origMailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific mail
        //if (to!int(e.name.baseName) < 51504) continue; // For testing from some mail forward

        if (baseName(e.name) in brokenMails) 
            continue;

        auto email = new IncomingEmail(rawMailStore, attachmentStore);
        email.loadFromFile(File(e.name), false);
        auto envelope = Envelope(email, "foo@foo.com");
        if (email.isValid)
        {
            writeln(e.name, "...");
            saveEmailToDb(email, envelope);
        }
    // XXX limpieza, borrar ficheros
    }
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

        auto filter = new UserFilter(match, action);
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
