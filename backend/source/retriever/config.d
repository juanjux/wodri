module retriever.config;

import std.path;
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
}


RetrieverConfig getConfig(MongoDatabase db)
{
    RetrieverConfig config;
    auto dbConfig = db["settings"].findOne(["module": "retriever"]);
    if (dbConfig == Bson(null))
    {
        auto err = "Could not retrieve config database, collection:settings, module=retriever";
        logError(err);
        throw new Exception(err);
    }

    config.mainDir         = deserializeBson!string (dbConfig["mainDir"]);
    config.rawMailStore    = buildPath(config.mainDir, deserializeBson!string (dbConfig["rawMailStore"]));
    config.attachmentStore = buildPath(config.mainDir, deserializeBson!string (dbConfig["attachmentStore"]));
    return config;
}


unittest
{
    auto db = connectMongoDB("localhost").getDatabase("webmail");
    auto conf = getConfig(db);
}
