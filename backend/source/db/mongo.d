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
            auto err = format("Bson input is not of numeric type but: %s", input.type);
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
    auto mandatoryKeys = ["host", "name",  "password", "port", "testname", "type", "user"];
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
        auto dbName = dbData["testname"].str;
    else
        auto dbName = dbData["name"].str;

    g_mongoDB = connectMongoDB(connectStr).getDatabase(dbName);
    ensureIndexes();
}


MongoCollection collection(string name) { return g_mongoDB[name]; }


private void ensureIndexes()
{
    collection("conversation").ensureIndex(["links.message-id": 1, "userId": 1]);
}
