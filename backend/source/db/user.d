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
    static User get(string id)
    {
        return getFromDirectField("_id", id);
    }


    static User getFromLoginName(string login)
    {
        return getFromDirectField("loginName", login);
    }


    static User getFromAddress(string address)
    {
        auto userResult = collection("user").findOne(
                parseJsonString(`{"addresses": {"$in": [` ~ Json(address).toString ~ `]}}`)
        );

        if (!userResult.isNull)
            return userDocToObject(userResult);
        return null;
    }


    static bool addressIsLocal(string address)
    {
        if (!address.length)
            return false;
        if (Domain.hasDefaultUser(address.split("@")[1]))
            return true;
        return getFromAddress(address) !is null;
    }


    private static User getFromDirectField(string fieldName, string fieldValue)
    {
        auto userResult = collection("user").findOne([fieldName: fieldValue]);
        return userResult.isNull ? null : userDocToObject(userResult); 
    }


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

    unittest // get
    {
        writeln("Testing User.get");
        recreateTestDb();
        auto userObject = User.get("doesntexits");
        assert(userObject is null);
        auto userDoc = collection("user").findOne(["loginName": "testuser"]);
        assert(!userDoc.isNull);
        userObject = User.get(bsonStr(userDoc._id));
        assert(userObject !is null);
        assert(bsonStr(userDoc._id) == userObject.id);
    }


    unittest 
    {
        writeln("Testing User.getFromLoginName");
        recreateTestDb();
        auto userObject = User.getFromLoginName("doesntexists");
        assert(userObject is null);
        userObject = User.getFromLoginName("testuser");
        assert(userObject !is null);
        auto userDoc = collection("user").findOne(["loginName": "testuser"]);
        assert(!userDoc.isNull);
        assert(bsonStr(userDoc._id) == userObject.id);
    }


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
}
