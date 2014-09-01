module db.config;

import std.path;
import std.conv;
import std.algorithm;
import vibe.core.log;
version(MongoDriver) import db.mongo.mongo;

version(db_usetestdb)     version = anytestdb;
version(db_usebigdb)      version = anytestdb;
version(db_insertalltest) version = anytestdb;
version(db_insertalltest) version = db_usebigdb;
version(search_test)      version = db_usebigdb;

struct RetrieverConfig
{
    string mainDir;
    string apiDomain;
    string rawEmailStore;
    string attachmentStore;
    string salt;
    ulong  incomingMessageLimit;
    bool   storeTextIndex;
    string smtpServer;
    uint   smtpEncription;
    ulong  smtpPort;
    string smtpUser;
    string smtpPass;
    uint   bodyPeekLength;
    string URLAttachmentPath;
    string URLStaticPath;

    @property string absAttachmentStore() const
    nothrow
    {
        return buildPath(this.mainDir, this.attachmentStore);
    }

    @property string absRawEmailStore() const
    nothrow
    {
        return buildPath(this.mainDir, this.rawEmailStore);
    }
}
private shared immutable RetrieverConfig g_config;

// Read config from the DB into g_config
shared static this()
{
    version(anytestdb)
        insertTestSettings();

    immutable dbConfig = collection("settings").findOne(["module": "retriever"]);
    if (dbConfig.isNull)
    {
        auto err = "Could not retrieve config database, collection:settings,"~
                   " module=retriever";
        logError(err);
        throw new Exception(err);
    }

    void checkNotNull(in string[] keys)
    {
        string[] missingKeys = [];
        foreach(key; keys)
            if (dbConfig[key].isNull)
                missingKeys ~= key;

        if (missingKeys.length)
        {
            auto err = "Missing keys in retriever DB config collection: " ~
                                 to!string(missingKeys);
            logError(err);
            throw new Exception(err);
        }
    }

    checkNotNull(["mainDir", "apiDomain", "smtpServer", "smtpUser", "smtpPass",
            "smtpEncription", "smtpPort", "rawEmailStore", "attachmentStore", "salt",
            "incomingMessageLimit", "storeTextIndex", "bodyPeekLength",
            "URLAttachmentPath", "URLStaticPath"]);

    g_config.mainDir              = bsonStr(dbConfig.mainDir);
    g_config.apiDomain            = bsonStr(dbConfig.apiDomain);
    g_config.smtpServer           = bsonStr(dbConfig.smtpServer);
    g_config.smtpUser             = bsonStr(dbConfig.smtpUser);
    g_config.smtpPass             = bsonStr(dbConfig.smtpPass);
    g_config.smtpEncription       = to!uint(bsonNumber(dbConfig.smtpEncription));
    g_config.smtpPort             = to!ulong(bsonNumber(dbConfig.smtpPort));
    g_config.salt                 = bsonStr(dbConfig.salt);
    auto dbPath                   = bsonStr(dbConfig.rawEmailStore);
    // If the db path starts with '/' interpret it as absolute
    g_config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                           dbPath:
                                                           buildPath(g_config.mainDir,
                                                                     dbPath);
    auto attachPath               = bsonStr(dbConfig.attachmentStore);
    g_config.attachmentStore      = attachPath.startsWith(dirSeparator)?
                                                               attachPath:
                                                               buildPath(g_config.mainDir,
                                                                         attachPath);
    g_config.incomingMessageLimit = to!ulong(bsonNumber(dbConfig.incomingMessageLimit));
    g_config.storeTextIndex       = bsonBool(dbConfig.storeTextIndex);
    g_config.bodyPeekLength       = to!uint(bsonNumber(dbConfig.bodyPeekLength));
    g_config.URLAttachmentPath    = bsonStr(dbConfig.URLAttachmentPath);
    g_config.URLStaticPath        = bsonStr(dbConfig.URLStaticPath);
}

ref immutable(RetrieverConfig) getConfig() { return g_config; }

// testing config
version(anytestdb)
{
    import std.string;
    import vibe.data.json;

    void insertTestSettings()
    {
        collection("settings").remove();
        string settingsJsonStr = format(`
        {
                "_id"                  : "5399793904ac3d27431d0669",
                "mainDir"              : "/home/juanjux/wodri",
                "apiDomain"            : "juanjux.mooo.com",
                "salt"                 : "someSalt",
                "attachmentStore"      : "backend/test/attachments",
                "incomingMessageLimit" : 15728640,
                "storeTextIndex"       : true,
                "module"               : "retriever",
                "rawEmailStore"        : "backend/test/rawemails",
                "smtpEncription"       : 0,
                "smtpPass"             : "smtpPass",
                "smtpPort"             : 25,
                "smtpServer"           : "localhost",
                "smtpUser"             : "smtpUser",
                "bodyPeekLength"       : 100,
                "URLAttachmentPath"    : "attachment",
                "URLStaticPath"        : "public",
        }`);
        collection("settings").insert(parseJsonString(settingsJsonStr));
    }
}
