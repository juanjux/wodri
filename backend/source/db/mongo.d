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
import std.traits;
import std.utf;

import vibe.db.mongo.mongo;
import vibe.core.log;
import vibe.data.json;

import arsd.htmltotext;

version(db_test) version = db_usetestdb;

private MongoDatabase g_mongoDB;

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

    ensureIndexes();
}


MongoCollection collection(string name) 
{ 
    return g_mongoDB[name];
}

// XXX static?
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
