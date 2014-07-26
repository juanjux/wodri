module db.mongo;

import std.stdio;
import std.typecons;
import std.string;
import std.datetime: SysTime, TimeZone;
import std.array;
import std.range;
import std.json;
import std.path;
import std.algorithm;
import std.file;
import std.regex;
import std.traits;
import std.utf;

import vibe.db.mongo.mongo;
import vibe.core.log;
import vibe.data.json;

import arsd.htmltotext;
import db.userfilter: Match, Action, UserFilter, SizeRuleType;
import db.envelope;
import db.conversation;

version(unittest)
{
    import db.test_support;
}

private MongoDatabase g_mongoDB;
private shared immutable RetrieverConfig g_config;

alias bsonStr      = deserializeBson!string;
alias bsonId       = deserializeBson!BsonObjectID;
alias bsonBool     = deserializeBson!bool;
alias bsonStrArray = deserializeBson!(string[]);
alias bsonStrHash  = deserializeBson!(string[string]);
double bsonNumber(const Bson input)
{
    switch(input.type)
    {
        case Bson.Type.double_:
            return deserializeBson!double(input);
        case Bson.Type.int_:
            return to!double(deserializeBson!int(input));
        case Bson.Type.long_:
            return to!double(deserializeBson!long(input));
        default:
            auto err = format("Bson input is not of numeric type but: ", input.type);
            logError(err);
            throw new Exception(err);
    }
    assert(0);
}


auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");

version(db_test) version = db_usetestdb;

/**
 * Read the /etc/dbconnect.json file, check for missing keys and connect
 */
shared static this()
{
    auto mandatoryKeys = ["host", "name",  "password", "port",
                               "testname", "type", "user"];
    sort(mandatoryKeys);

    auto dbData = parseJSON(readText("/etc/webmail/dbconnect.json"));
    auto sortedKeys = dbData.object.keys.dup;
    sort(sortedKeys);

    const keysDiff = setDifference(sortedKeys, mandatoryKeys).array;
    enforce(!keysDiff.length, "Mandatory keys missing on dbconnect.json config file: %s"
                              ~ to!string(keysDiff));
    enforce(dbData["type"].str == "mongodb", "Only MongoDB is currently supported");
    string connectStr = format("mongodb://%s:%s@%s:%s/%s?safe=true",
                               dbData["user"].str,
                               dbData["password"].str,
                               dbData["host"].str,
                               dbData["port"].integer,
                               "admin");

    version(db_usetestdb)
    {
        g_mongoDB = connectMongoDB(connectStr).getDatabase(dbData["testname"].str);
        insertTestSettings();
    }
    else
        g_mongoDB = connectMongoDB(connectStr).getDatabase(dbData["name"].str);

    g_config = getInitialConfig();
    ensureIndexes();
}


const MongoCollection collection(string name) 
{ 
    return g_mongoDB[name];
}

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

ref const(RetrieverConfig) getConfig() { return g_config; }

private const(RetrieverConfig) getInitialConfig()
{
    RetrieverConfig _config;
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

    _config.mainDir              = bsonStr(dbConfig.mainDir);
    _config.apiDomain            = bsonStr(dbConfig.apiDomain);
    _config.smtpServer           = bsonStr(dbConfig.smtpServer);
    _config.smtpUser             = bsonStr(dbConfig.smtpUser);
    _config.smtpPass             = bsonStr(dbConfig.smtpPass);
    _config.smtpEncription       = to!uint(bsonNumber(dbConfig.smtpEncription));
    _config.smtpPort             = to!ulong(bsonNumber(dbConfig.smtpPort));
    _config.salt                 = bsonStr(dbConfig.salt);
    auto dbPath                  = bsonStr(dbConfig.rawEmailStore);
    // If the db path starts with '/' interpret it as absolute
    _config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                           dbPath:
                                                           buildPath(_config.mainDir,
                                                                     dbPath);
    auto attachPath              = bsonStr(dbConfig.attachmentStore);
    _config.attachmentStore      = attachPath.startsWith(dirSeparator)?
                                                               attachPath:
                                                               buildPath(_config.mainDir,
                                                                         attachPath);
    _config.incomingMessageLimit = to!ulong(bsonNumber(dbConfig.incomingMessageLimit));
    _config.storeTextIndex       = bsonBool(dbConfig.storeTextIndex);
    _config.bodyPeekLength       = to!uint(bsonNumber(dbConfig.bodyPeekLength));
    _config.URLAttachmentPath    = bsonStr(dbConfig.URLAttachmentPath);
    _config.URLStaticPath        = bsonStr(dbConfig.URLStaticPath);
    return _config;
}


private void ensureIndexes()
{
    collection("conversation").ensureIndex(["links.message-id": 1, "userId": 1]);
}

Flag!"HasDefaultUser" domainHasDefaultUser(string domainName)
{
    auto domain = collection("domain").findOne(["name": domainName],
                                              ["defaultUser": 1],
                                              QueryFlags.None);
    if (!domain.isNull &&
        !domain.defaultUser.isNull &&
        bsonStr(domain.defaultUser).length)
        return Yes.HasDefaultUser;
    return No.HasDefaultUser;
}


string getUserHash(string loginName)
{
    auto user = collection("user").findOne(["loginName": loginName],
                                          ["loginHash": 1],
                                          QueryFlags.None);
    if (!user.isNull && !user.loginHash.isNull)
        return bsonStr(user.loginHash);
    return "";
}


bool addressIsLocal(string address)
{
    if (!address.length)
        return false;

    if (domainHasDefaultUser(address.split("@")[1]))
        return true;

    auto selector   = parseJsonString(`{"addresses": {"$in": ["` ~ address ~ `"]}}`);
    auto userRecord = collection("user").findOne(selector);
    return !userRecord.isNull;
}


/**
 * From removes variants of "Re:"/"RE:"/"re:" in the subject
 */
package string cleanSubject(string subject)
{
    return replaceAll!(x => "")(subject, SUBJECT_CLEAN_REGEX);
}


string getUserIdFromAddress(string address)
{
    auto userResult = collection("user").findOne(
            parseJsonString(format(`{"addresses": {"$in": ["%s"]}}`, address)),
            ["_id": 1],
            QueryFlags.None
    );
    return userResult.isNull? "": bsonStr(userResult._id);
}




//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_usetestdb)
{
    string[] TEST_EMAILS = ["multipart_mixed_rel_alternative_attachments",
                            "simple_alternative_noattach",
                            "spam_tagged",
                            "with_2megs_attachment",
                            "spam_notagged_nomsgid"];

    void insertTestSettings()
    {
        collection("settings").remove();
        string settingsJsonStr = format(`
        {
                "_id"                  : "5399793904ac3d27431d0669",
                "mainDir"              : "/home/juanjux/webmail",
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

version(db_test)
version(db_usetestdb)
{
    unittest // domainHasDefaultUser
    {
        writeln("Testing domainHasDefaultUser");
        recreateTestDb();
        assert(domainHasDefaultUser("testdatabase.com"), "domainHasDefaultUser1");
        assert(!domainHasDefaultUser("anotherdomain.com"), "domainHasDefaultUser2");
    }

    unittest // getUserHash
    {
        assert(getUserHash("testuser") == "8AQl5bqZMY3vbczoBWJiTFVclKU=");
        assert(getUserHash("anotherUser") == "YHOxxOHmvwzceoxYkqJiQWslrmY=");
    }



    unittest // addressIsLocal
    {
        writeln("Testing addressIsLocal");
        recreateTestDb();
        assert(addressIsLocal("testuser@testdatabase.com"));
        assert(addressIsLocal("random@testdatabase.com")); // has default user
        assert(addressIsLocal("anotherUser@testdatabase.com"));
        assert(addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!addressIsLocal("random@anotherdomain.com"));
    }
}


version(db_insertalltest) unittest
{
    writeln("Testing Inserting Everything");
    recreateTestDb();

    import std.datetime;
    import std.process;
    import retriever.incomingemail;
    import db.email;

    string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
    string origEmailDir    = buildPath(backendTestDir, "emails", "single_emails");
    string rawEmailStore   = buildPath(backendTestDir, "rawemails");
    string attachmentStore = buildPath(backendTestDir, "attachments");
    int[string] brokenEmails;
    StopWatch sw;
    StopWatch totalSw;
    ulong totalTime = 0;
    ulong count = 0;

    foreach (ref DirEntry e; getSortedEmailFilesList(origEmailDir))
    {
        //if (indexOf(e, "47") == -1) continue; // For testing a specific email
        //if (to!int(e.name.baseName) < 3457) continue; // For testing from some email forward
        writeln(e.name, "...");

        totalSw.start();
        if (baseName(e.name) in brokenEmails)
            continue;
        auto inEmail = new IncomingEmailImpl();

        sw.start();
        inEmail.loadFromFile(File(e.name), attachmentStore);
        sw.stop(); writeln("loadFromFile time: ", sw.peek().msecs); sw.reset();

        sw.start();
        auto dbEmail = new Email(inEmail);
        sw.stop(); writeln("DBEmail instance: ", sw.peek().msecs); sw.reset();


        sw.start();
        auto localReceivers = dbEmail.localReceivers();
        if (!localReceivers.length)
        {
            writeln("SKIPPING, not local receivers");
            continue; // probably a message from the "sent" folder
        }

        auto envelope = new Envelope(dbEmail, localReceivers[0]);
        envelope.userId = getUserIdFromAddress(envelope.destination);
        assert(envelope.userId.length,
              "Please replace the destination in the test emails, not: " ~
              envelope.destination);
        sw.stop(); writeln("getUserIdFromAddress time: ", sw.peek().msecs); sw.reset();

        if (dbEmail.isValid)
        {
            writeln("Subject: ", dbEmail.getHeader("subject").rawValue);

            sw.start();
            envelope.emailId = dbEmail.store();
            sw.stop(); writeln("dbEmail.store(): ", sw.peek().msecs); sw.reset();

            sw.start();
            envelope.store();
            sw.stop(); writeln("envelope.store(): ", sw.peek().msecs); sw.reset();

            sw.start();
            auto convId = Conversation.upsert(dbEmail, 
                                              envelope.userId, 
                                              ["inbox": true]).dbId;

            sw.stop(); writeln("Conversation: ", convId, " time: ", sw.peek().msecs); sw.reset();
        }
        else
            writeln("SKIPPING, invalid email");

        totalSw.stop();
        if (dbEmail.isValid)
        {
            auto emailTime = totalSw.peek().msecs;
            totalTime += emailTime;
            ++count;
            writeln("Total time for this email: ", emailTime);
        }
        writeln("Valid emails until now: ", count); writeln;
        totalSw.reset();
    }

    writeln("Total number of valid emails: ", count);
    writeln("Average time per valid email: ", totalTime/count);

    // Clean the attachment and rawEmail dirs
    system(format("rm -f %s/*", attachmentStore));
    system(format("rm -f %s/*", rawEmailStore));
}


