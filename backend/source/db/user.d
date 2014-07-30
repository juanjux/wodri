module db.user;

import std.array;
import db.mongo;
import db.domain;
import vibe.data.bson;
import vibe.db.mongo.mongo;

final class User
{
    string id;
    string loginName;
    string[] addresses;
    bool admin;
    string loginHash;
    string name;
    string surname;

    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================
    static private User userDocToObject(ref Bson userDoc)
    {
        auto ret = new User();
        if (userDoc.isNull)
            return ret;

        ret.id = bsonStr(userDoc._id);
        ret.loginName = bsonStr(userDoc.loginName);
        ret.addresses = bsonStrArray(userDoc.addresses);
        ret.admin = bsonBool(userDoc.admin);
        ret.loginHash = bsonStr(userDoc.loginHash);
        ret.name = bsonStr(userDoc.name);
        ret.surname = bsonStr(userDoc.surname);
        return ret;
    }


    static User getFromAddress(string address)
    {
        User ret = null;
        auto userResult = collection("user").findOne(
                parseJsonString(`{"addresses": {"$in": ["` ~ address ~ `"]}}`)
        );

        if (!userResult.isNull)
            return userDocToObject(userResult);
        return ret;
    }


    static string getPasswordHash(string loginName)
    {
        auto user = collection("user").findOne(["loginName": loginName],
                                               ["loginHash": 1],
                                               QueryFlags.None);
        if (!user.isNull && !user.loginHash.isNull)
            return bsonStr(user.loginHash);
        return "";
    }


    static bool addressIsLocal(string address)
    {
        if (!address.length)
            return false;
        if (Domain.hasDefaultUser(address.split("@")[1]))
            return true;
        return getFromAddress(address) !is null;
    }
}

//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.test_support;

    unittest // getFromAddress + userDocToObject
    {
        writeln("Testing User.getFromAddress");
        recreateTestDb();

        auto user = User.getFromAddress("noexistnoexist@bla.com");
        assert(user is null);

        user = User.getFromAddress("testuser@testdatabase.com");
        assert(user.loginName == "testuser");
        assert(user.addresses == ["testuser@testdatabase.com"]);
        assert(user.admin);
        assert(user.loginHash == "8AQl5bqZMY3vbczoBWJiTFVclKU=");
        assert(user.name == "testUserName");
        assert(user.surname == "testUserSurName");
    }

    unittest // User.addressIsLocal
    {
        writeln("Testing User.addressIsLocal");
        recreateTestDb();
        assert(User.addressIsLocal("testuser@testdatabase.com"));
        assert(User.addressIsLocal("random@testdatabase.com")); // has default user
        assert(User.addressIsLocal("anotherUser@testdatabase.com"));
        assert(User.addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!User.addressIsLocal("random@anotherdomain.com"));
    }

    unittest // getPasswordHash
    {
        writeln("Testing User.getPasswordHash");
        recreateTestDb();
        assert(User.getPasswordHash("testuser") == "8AQl5bqZMY3vbczoBWJiTFVclKU=");
        assert(User.getPasswordHash("anotherUser") == "YHOxxOHmvwzceoxYkqJiQWslrmY=");
    }

}
