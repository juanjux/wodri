module retriever.config;

import std.path;
import std.algorithm;
import vibe.core.log;
import vibe.db.mongo.database;
import vibe.data.bson;

version(unittest)
{
    import std.stdio;
    import vibe.db.mongo.mongo;
}

struct RetrieverConfig
{
    string mainDir;
    string rawMailStore;
    string attachmentStore;
    ulong incomingMessageLimit;
}


RetrieverConfig getConfig(MongoDatabase db)
{
    RetrieverConfig config;
    auto dbConfig = db["settings"].findOne(["module": "retriever"]);
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


unittest
{
    auto db = connectMongoDB("localhost").getDatabase("webmail");
    auto conf = getConfig(db);
}
