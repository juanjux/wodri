module db.config;

import db.dbinterface.driverconfiginterface;
import std.path;

version(MongoDriver)
{
    import db.mongo.mongo;
    import db.mongo.driverconfigmongo;
}

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

private shared immutable RetrieverConfig g_retrieverConfig;
private DriverConfigInterface g_driverInterface;

// Read config from the DB into g_config
shared static this()
{
    version(MongoDriver)
        g_driverInterface = new DriverConfigMongo();

    g_retrieverConfig = g_driverInterface.getConfig();

    version(anytestdb)
        g_driverInterface.insertTestSettings();
}

ref immutable(RetrieverConfig) getConfig() { return g_retrieverConfig; }
