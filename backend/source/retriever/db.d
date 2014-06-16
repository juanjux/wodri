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
        if (attach.content_id.length)
            partAppender.put(` "contentid": ` ~ Json(attach.content_id).toString() ~ `,`);
        if (attach.filename.length)
            partAppender.put(` "filename": ` ~ Json(attach.filename).toString() ~ `,`);
        partAppender.put("},\n");
    }
    string attachmentsJsonStr = partAppender.data();
    partAppender.clear();

    // Some mails doesnt have a "To:" header but a "Delivered-To:". Really.
    string real_toField, real_toRaw, real_toAddresses;
    if ("To" in email.headers)
        real_toField = "To";
    else if ("Cc" in email.headers)
        real_toField = "Cc";
    else if ("Bcc" in email.headers)
        real_toField = "Bcc";
    else if ("Delivered-To" in email.headers)
        real_toField = "Delivered-To";
    else
        throw new Exception("Cant insert to DB mail without destination");
    real_toRaw       = jsonizeField(email, real_toField, false, true);
    real_toAddresses = to!string(email.headers[real_toField].addresses);

    auto emailInsertJson = format(`{"rawMailPath": "%s", %s %s
                                   "from": { "content": %s "addresses": %s },
                                   "to": { "content": %s "addresses": %s },
                                    %s %s %s %s
                                   "textParts": [ %s ],
                                   "attachments": [ %s ] }`,
            email.rawMailPath,
            jsonizeField(email, "message-id", true),
            jsonizeField(email, "references"),
            jsonizeField(email,"from", false, true),
            to!string(email.headers["From"].addresses),
            real_toRaw,
            real_toAddresses,
            jsonizeField(email, "date", true),
            jsonizeField(email, "subject"),
            jsonizeField(email, "cc"),
            jsonizeField(email, "bcc"),
            textPartsJsonStr,
            attachmentsJsonStr);

    // XXX quitar
    auto f = File("/home/juanjux/borrame.txt", "a");
    f.write(emailInsertJson);
    f.flush(); f.close();

    Json jusr = parseJsonString(emailInsertJson);
    mongoDB["email"].insert(jusr);

    auto envelopeInsertJson = `
    {
        id_email: %s,
        tags: [%s],
        destinationAddress: "%s",
        id_user: %s,
    }`;
}




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
    int[string] skipMails;

    foreach (DirEntry e; getSortedEmailFilesList(origMailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific mail
        //if (to!int(e.name.baseName) < 32000) continue; // For testing from some mail forward

        if (baseName(e.name) in brokenMails || baseName(e.name) in skipMails)
            continue;

        auto email = new IncomingEmail(rawMailStore, attachmentStore);
        email.loadFromFile(File(e.name), false);
        auto envelope = Envelope(email, "foo@foo.com");
        if (email.isValid)
        {
            writeln(e.name, "...");
            saveEmailToDb(email, envelope);
        }
    }
}
