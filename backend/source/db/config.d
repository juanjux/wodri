module db.config;

import std.path;
import std.conv;
import std.algorithm;

import vibe.core.log;

import db.mongo;

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
    {
        return buildPath(this.mainDir, this.attachmentStore);
    }

    @property string absRawEmailStore() const
    {
        return buildPath(this.mainDir, this.rawEmailStore);
    }
}

private shared immutable RetrieverConfig g_config;

shared static this()
{
    immutable dbConfig = collection("settings").findOne(["module": "retriever"]);
    if (dbConfig.isNull)
    {
        auto err = "Could not retrieve config database, collection:settings,"~
                   " module=retriever";
        logError(err);
        throw new Exception(err);
    }

    void checkNotNull(string[] keys)
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
    auto dbPath                  = bsonStr(dbConfig.rawEmailStore);
    // If the db path starts with '/' interpret it as absolute
    g_config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                           dbPath:
                                                           buildPath(g_config.mainDir,
                                                                     dbPath);
    auto attachPath              = bsonStr(dbConfig.attachmentStore);
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

ref const(RetrieverConfig) getConfig() { return g_config; }
