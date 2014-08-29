module db.mongo;

import arsd.htmltotext;
import std.algorithm;
import std.array;
import std.datetime: SysTime, TimeZone;
import std.file;
import std.json;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;
import std.utf;
import vibe.core.log;
import vibe.data.bson;
import vibe.data.json;
import vibe.db.mongo.mongo;

version(db_usetestdb)     version = anytestdb;
version(db_usebigdb)      version = anytestdb;
version(db_insertalltest) version = anytestdb;
version(db_insertalltest) version = db_usebigdb;
version(search_test)      version = db_usebigdb;

private MongoDatabase g_mongoDB;

T bsonSafe(T)(const Bson bson) 
{ 
    return bson.isNull ? T.init : deserializeBson!T(bson); 
}

alias bsonStr          = deserializeBson!string;
alias bsonStrSafe      = bsonSafe!string;
alias bsonId           = deserializeBson!BsonObjectID;
alias bsonBool         = deserializeBson!bool;
alias bsonBoolSafe     = bsonSafe!bool;
alias bsonStrArray     = deserializeBson!(string[]);
alias bsonStrArraySafe = bsonSafe!(string[]);
alias bsonStrHash      = deserializeBson!(string[string]);

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
            auto err = format("Bson input is not of numeric type but: %s", 
                              input.type);
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

    immutable dbData = parseJSON(readText("/etc/webmail/dbconnect.json"));
    string[] sortedKeys = dbData.object.keys.dup;
    sort(sortedKeys);

    const keysDiff = setDifference(sortedKeys, mandatoryKeys).array;
    enforce(!keysDiff.length, "Mandatory keys missing on dbconnect.json config file: %s"
                              ~ to!string(keysDiff));
    enforce(dbData["type"].str == "mongodb", "Only MongoDB is currently supported");
    immutable connectStr = format(
            "mongodb://%s:%s@%s:%s/%s?safe=true",
            dbData["user"].str,
            dbData["password"].str,
            dbData["host"].str,
            dbData["port"].integer,
            "admin"
    );

    version(db_usetestdb)
        immutable dbName = dbData["testname"].str;
    else version(db_usebigdb)
        immutable dbName = dbData["testname"].str~"_all"; // FIXME: add another setting
    else
        immutable dbName = dbData["name"].str;

    g_mongoDB = connectMongoDB(connectStr).getDatabase(dbName);
    ensureIndexes();
}


MongoCollection collection(string name) { return g_mongoDB[name]; }


private void ensureIndexes()
{
    collection("conversation").ensureIndex(["links.message-id": 1, "userId": 1]);
    collection("email").ensureIndex(["message-id": 1, "userId": 1, "isoDate": 1]);
    collection("emailIndexContents").ensureIndex(["emailDbId": 1]);
}


/** Shortcut for a common case of getting a doc with/without some fields */
// FIXME: make the conversion of fields to map (or json string) at compile time
Bson findOneById(in string coll, in string id, in string[] fields ...)
{
    uint[string] map;
    foreach(field; fields)
        map[field] = 1;

    return collection(coll).findOne(["_id": id], map, QueryFlags.None);
}
