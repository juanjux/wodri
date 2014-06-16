module retriever.db;

import std.stdio;
import std.string;
import std.path;

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


// XXX test when I've the test DB
void saveEmailToDb(IncomingEmail email, Envelope envelope)
{
    string jsonizeField(string headerName, bool removeQuotes = false, bool onlyValue=false)
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


    auto partAppender = appender!string;
    foreach(part; email.textualParts)
    {
        partAppender.put("\"textpart\": {\"contenttype\": " ~ Json(part.ctype.name).toString() ~ ",");
        partAppender.put(" \"content\": " ~ Json(part.textContent).toString() ~ "},");
    }
    string textPartsJsonStr = partAppender.data;

    partAppender.clear();
    foreach(attach; email.attachments)
    {
        partAppender.put(`"attachment": {"contenttype": "` ~ Json(attach.ctype).toString() ~ `",`);
        partAppender.put(` "realpath": "` ~ Json(attach.realPath).toString() ~ `",`);
        partAppender.put(` "size": ` ~ Json(attach.size).toString() ~ `,`);

        if (attach.content_id.length)
            partAppender.put(` "contentid": "` ~ Json(attach.content_id).toString() ~ `",`);
        if (attach.filename.length)
            partAppender.put(` "filename": "` ~ Json(attach.filename).toString() ~ `",`);

    }
    string attachmentsJsonStr = partAppender.data();
    partAppender.clear();

    auto emailInsertJson = format(`
        {
            "rawMailPath": "%s",
            %s
            %s
            "from":
            {
                "content": %s
                "addresses": %s,
            },
            "to":
            {
                "content": %s
                "addresses": %s,
            },
            %s
            %s
            %s
            %s
            "textParts":
            {
                %s
            },
            "attachments":
            {
                %s
            },
        }`, email.rawMailPath,
            jsonizeField("message-id", true),
            jsonizeField("references"),
            jsonizeField("from", false, true),
            to!string(email.headers["From"].addresses),
            jsonizeField("to", false, true),
            to!string(email.headers["To"].addresses),
            jsonizeField("date", true),
            jsonizeField("subject"),
            jsonizeField("cc"),
            jsonizeField("bcc"),
            textPartsJsonStr,
            attachmentsJsonStr,
        );

    auto f = File("/home/juanjux/borrame.txt", "a");
    f.write(emailInsertJson);
    f.flush(); f.close();

    Json jusr = parseJsonString(emailInsertJson);
    mongoDB["emails"].insert(jusr);

    auto envelopeInsertJson = `
    {
        id_email: %s,
        tags: [%s],
        destinationAddress: "%s",
        id_user: %s,
    }`;
}


version(dbtest)
unittest
{
    writeln("Starting db.d unittest...");
    auto config = getConfig();
    // XXX probar mas, todo con la BBDD de prueba (cre
}
