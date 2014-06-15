module retriever.db;

import std.stdio;
import std.string;
import std.path;

import vibe.db.mongo.mongo;
import vibe.core.log;

MongoDatabase db;
bool connected = false;

struct RetrieverConfig
{
    string mainDir;
    string rawMailStore;
    string attachmentStore;
    ulong incomingMessageLimit;
}


void initializeDb()
{
    // FIXME: read db config from file
    if (!connected)
        db = connectMongoDB("localhost").getDatabase("webmail");
}


MongoDatabase getDatabase()
{
    initializeDb();
    return db;
}


RetrieverConfig getConfig()
{
    initializeDb();

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
    auto mongoDB = getConfig();
}
