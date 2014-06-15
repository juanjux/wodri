module retriever.db;

import std.stdio;
import std.string;
import std.path;

import vibe.db.mongo.mongo;
import vibe.core.log;
import retriever.userrule: Match, Action, UserFilter, SizeRuleType;

MongoDatabase mongoDB;
bool connected = false;

// FIXME: read db config from file
static this()
{
    mongoDB = connectMongoDB("localhost").getDatabase("webmail");
}

struct RetrieverConfig
{
    string mainDir;
    string rawMailStore;
    string attachmentStore;
    ulong incomingMessageLimit;
}

MongoDatabase getDatabase()
{
    return mongoDB;
}


RetrieverConfig getConfig()
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


bool domainHasDefaultUser(string domainName)
{
    auto domain = mongoDB["domain"].findOne(["name": domainName]);
    if (domain != Bson(null) &&
        domain["defaultUser"] != Bson(null) &&
        domain["defaultUser"].length)
        return true;

    return false;
}


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


bool addressIsLocal(string address)
{
    if (!address.length)
        return false;

    if (domainHasDefaultUser(address.split("@")[1]))
        return true;

    auto jsonStr = `{"addresses": {"$in": ["` ~ address ~ `]}}`;
    auto userRecord = mongoDB["user"].findOne(parseJsonString(jsonStr));
    return (userRecord == Bson("null"));
}


version(dbtest)
{
    unittest
    {
        writeln("Starting db.d unittest...");
        auto config = getConfig();
        // XXX probar mas, todo con la BBDD de prueba (cre
    }
}
